#!/usr/bin/env bash
# Smoke tests for the hook command-detection logic. No Codex round-trip;
# we exercise the python parser directly and the bypass / non-trigger
# paths of the two hook scripts.

set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOKS="$ROOT/hooks"
PARSER="$HOOKS/_parse-git-cmd.py"
GATE="$HOOKS/auto-spec-gate.sh"
REVIEW="$HOOKS/auto-review.sh"

PASS=0
FAIL=0

assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "  ok   $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL $label"
    echo "       want: $want"
    echo "       got : $got"
    FAIL=$((FAIL + 1))
  fi
}

parse_field() {
  local field="$1" cmd="$2"
  # Don't use `// empty` — that swallows `false` (jq's // alternative
  # treats false as nullish, so `.commit_all // empty` yields "" for
  # `false`). Plain `.${field}` returns "" for absent and the literal
  # for booleans / strings.
  printf '%s' "$cmd" | python3 "$PARSER" | jq -r ".${field}"
}

# --- _parse-git-cmd.py ------------------------------------------------------
echo "[parser: subcommand]"
assert_eq "plain commit"            "commit" "$(parse_field subcommand 'git commit -m foo')"
assert_eq "amend"                   "commit" "$(parse_field subcommand 'git commit --amend')"
assert_eq "git -c X commit"         "commit" "$(parse_field subcommand 'git -c user.name=x commit -m foo')"
assert_eq "git --no-pager commit"   "commit" "$(parse_field subcommand 'git --no-pager commit -m foo')"
assert_eq "git -C dir commit"       "commit" "$(parse_field subcommand 'git -C /tmp/repo commit -m foo')"
assert_eq "env-prefixed"            "commit" "$(parse_field subcommand 'GIT_EDITOR=vi FOO=bar git commit')"
assert_eq "quoted -c value"         "commit" "$(parse_field subcommand 'git -c "user.name=foo bar" commit')"
assert_eq "quoted env value"        "commit" "$(parse_field subcommand 'FOO="bar baz" git commit')"
assert_eq "quoted -m message"       "commit" "$(parse_field subcommand 'git commit -m "msg with space"')"
assert_eq "git push"                "push"   "$(parse_field subcommand 'git push origin main')"
assert_eq "git -c X push"           "push"   "$(parse_field subcommand 'git -c http.proxy=p push')"
assert_eq "git merge"               "merge"  "$(parse_field subcommand 'git merge feat/foo')"
assert_eq "commit-tree (not commit)" "commit-tree" "$(parse_field subcommand 'git commit-tree X')"
assert_eq "non-git"                 ""       "$(parse_field subcommand 'ls -la')"
assert_eq "unbalanced quotes"       ""       "$(parse_field subcommand 'git "commit -m foo')"

echo "[parser: commit_all]"
assert_eq "plain commit -> false"   "false"  "$(parse_field commit_all 'git commit -m foo')"
assert_eq "-a"                      "true"   "$(parse_field commit_all 'git commit -a -m foo')"
assert_eq "--all"                   "true"   "$(parse_field commit_all 'git commit --all')"
assert_eq "-am combo"               "true"   "$(parse_field commit_all 'git commit -am foo')"
assert_eq "-avm combo"              "true"   "$(parse_field commit_all 'git commit -avm foo')"
assert_eq "-vS no a"                "false"  "$(parse_field commit_all 'git commit -vS')"
assert_eq "quoted -m no a"          "false"  "$(parse_field commit_all 'git commit -m "all hands"')"

echo "[parser: merge_source]"
assert_eq "merge feat/X"            "feat/foo" "$(parse_field merge_source 'git merge feat/foo')"
assert_eq "merge -m msg feat/X"     "feat/foo" "$(parse_field merge_source 'git merge -m "merge msg" feat/foo')"
assert_eq "merge -X theirs feat/X"  "feat/foo" "$(parse_field merge_source 'git merge -X theirs feat/foo')"
assert_eq "merge -s recursive feat/X" "feat/foo" "$(parse_field merge_source 'git merge -s recursive feat/foo')"
assert_eq "merge --strategy=ours feat/X" "feat/foo" "$(parse_field merge_source 'git merge --strategy=ours feat/foo')"
assert_eq "merge --abort"           ""       "$(parse_field merge_source 'git merge --abort')"

# --- auto-spec-gate.sh ------------------------------------------------------
echo "[auto-spec-gate.sh]"

WORK=$(mktemp -d -t sspower-hooktest-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
(
  cd "$WORK"
  git init -q
  git config user.email t@t
  git config user.name t
)

run_gate_in_work() {
  local cmd="$1"
  local extra_env="${2:-}"
  cd "$WORK" && env $extra_env CLAUDE_PLUGIN_ROOT="$ROOT" \
    bash "$GATE" <<EOF
{"tool_input":{"command":"$cmd"}}
EOF
}

# Bypass.
out=$(run_gate_in_work 'git commit -m x' 'SSPOWER_AUTO_REVIEW=off' 2>&1)
rc=$?
assert_eq "bypass exit"   "0" "$rc"
assert_eq "bypass quiet"  ""  "$out"

# Non-commit.
out=$(run_gate_in_work 'ls -la' 2>&1); rc=$?
assert_eq "non-commit exit"  "0" "$rc"
assert_eq "non-commit quiet" ""  "$out"

# Quoted env + commit, no plan staged.
out=$(run_gate_in_work 'FOO="a b" git commit -m foo' 2>&1); rc=$?
assert_eq "quoted-env nostaged"  "0" "$rc"

# Quoted -c + commit, no plan staged.
out=$(run_gate_in_work 'git -c "user.name=foo bar" commit -m m' 2>&1); rc=$?
assert_eq "quoted -c nostaged"   "0" "$rc"

# `git commit -a` with plan modified-not-staged: bypass-on so no codex
# call, but verify the hook reaches the trigger path. (Hard to assert
# without mocking codex; SSPOWER_AUTO_REVIEW=off short-circuits early
# anyway. We just confirm exit 0.)
(
  cd "$WORK"
  mkdir -p docs/plans
  echo "# v1" > docs/plans/test.md
  git add docs/plans/test.md
  git commit -q -m initial
  echo "# v2" > docs/plans/test.md
)
out=$(run_gate_in_work 'git commit -am bump' 'SSPOWER_AUTO_REVIEW=off' 2>&1); rc=$?
assert_eq "commit -a + plan dirty exit" "0" "$rc"

# --- auto-review.sh --------------------------------------------------------
echo "[auto-review.sh]"

run_review_in_work() {
  local cmd="$1"
  local extra_env="${2:-}"
  cd "$WORK" && env $extra_env CLAUDE_PLUGIN_ROOT="$ROOT" \
    bash "$REVIEW" <<EOF
{"tool_input":{"command":"$cmd"}}
EOF
}

out=$(run_review_in_work 'git push' 'SSPOWER_AUTO_REVIEW=off' 2>&1); rc=$?
assert_eq "push bypass exit"  "0" "$rc"

out=$(run_review_in_work 'ls' 2>&1); rc=$?
assert_eq "non-trigger exit"  "0" "$rc"

out=$(run_review_in_work 'git merge --abort' 2>&1); rc=$?
assert_eq "merge --abort exit"  "0" "$rc"

# `gh pr create` with quoted body — must trigger (and bypass-out exit 0).
out=$(run_review_in_work 'gh pr create --title "t" --body "b"' 'SSPOWER_AUTO_REVIEW=off' 2>&1); rc=$?
assert_eq "gh pr create quoted bypass" "0" "$rc"

echo
echo "passed: $PASS"
echo "failed: $FAIL"
[ "$FAIL" -eq 0 ]
