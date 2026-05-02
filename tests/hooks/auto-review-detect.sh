#!/usr/bin/env bash
# Smoke tests for the hook command-detection + decision logic. We
# exercise the python parser directly and the bypass / non-trigger
# paths of the two hook scripts. The end-to-end "this commit would
# include a plan file" tests bypass codex (SSPOWER_AUTO_REVIEW=off)
# but still exercise the dry-run discovery path.

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
  printf '%s' "$cmd" | python3 "$PARSER" | jq -r ".${field}"
}

parse_arr() {
  local field="$1" cmd="$2"
  printf '%s' "$cmd" | python3 "$PARSER" | jq -r ".${field}[]?"
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

echo "[parser: work_dir capture]"
assert_eq "no -C"                   ""           "$(parse_field work_dir 'git commit')"
assert_eq "-C dir"                  "/tmp/x"     "$(parse_field work_dir 'git -C /tmp/x commit')"
assert_eq "--git-dir=path"          "/tmp/x.git" "$(parse_field work_dir 'git --git-dir=/tmp/x.git commit')"
assert_eq "--work-tree path"        "/tmp/wt"    "$(parse_field work_dir 'git --work-tree /tmp/wt commit')"
assert_eq "-C with quoted dir"      "/path with space" "$(parse_field work_dir 'git -C "/path with space" commit')"

echo "[parser: subcommand_args verbatim]"
assert_eq "no args"                 ""           "$(parse_arr subcommand_args 'git commit')"
assert_eq "preserves order/quoting" "$(printf -- '-m\nmsg with space\nfoo.md')" "$(parse_arr subcommand_args 'git commit -m "msg with space" foo.md')"

echo "[parser: merge_sources octopus]"
assert_eq "single source"           "feat/foo"   "$(parse_arr merge_sources 'git merge feat/foo')"
assert_eq "octopus 3 sources"       "$(printf 'a\nb\nc')" "$(parse_arr merge_sources 'git merge a b c')"
assert_eq "with -m + 2 sources"     "$(printf 'a\nb')"    "$(parse_arr merge_sources 'git merge -m "msg" a b')"
assert_eq "with -X + 2 sources"     "$(printf 'a\nb')"    "$(parse_arr merge_sources 'git merge -X theirs a b')"
assert_eq "merge --abort"           ""           "$(parse_arr merge_sources 'git merge --abort')"

# --- auto-spec-gate.sh ------------------------------------------------------
echo "[auto-spec-gate.sh]"

WORK=$(mktemp -d -t sspower-hooktest-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
(
  cd "$WORK"
  git init -q
  git config user.email t@t
  git config user.name t
  git config commit.gpgsign false
  echo "# initial" > seed.md
  git add seed.md
  git commit -q -m init
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
out=$(run_gate_in_work 'git commit -m x' 'SSPOWER_AUTO_REVIEW=off' 2>&1); rc=$?
assert_eq "bypass exit"   "0" "$rc"
assert_eq "bypass quiet"  ""  "$out"

# Non-commit.
out=$(run_gate_in_work 'ls -la' 2>&1); rc=$?
assert_eq "non-commit exit"  "0" "$rc"
assert_eq "non-commit quiet" ""  "$out"

# User-typed --dry-run: don't gate.
out=$(run_gate_in_work 'git commit --dry-run' 2>&1); rc=$?
assert_eq "user --dry-run exit"  "0" "$rc"
assert_eq "user --dry-run quiet" "" "$out"

# Plain commit, no plan staged, nothing to do.
(cd "$WORK" && echo "x" > unrelated.txt && git add unrelated.txt)
out=$(run_gate_in_work 'git commit -m x' 2>&1); rc=$?
assert_eq "plain no-plan exit"  "0" "$rc"

# Pathspec commit OUTSIDE plan dir, with a plan ALSO staged: must NOT
# gate (the staged plan won't be in this commit).
(
  cd "$WORK"
  mkdir -p docs/plans
  echo "# v1" > docs/plans/x.md
  git add docs/plans/x.md
  echo "y" > also.txt
  git add also.txt
)
out=$(run_gate_in_work 'git commit -m x also.txt' 2>&1); rc=$?
assert_eq "pathspec outside plan: exit"  "0" "$rc"
assert_eq "pathspec outside plan: no review" "" "$(printf '%s' "$out" | grep -i review || true)"

# Pathspec commit INSIDE plan dir: gate triggers, bypass-on so exit 0.
out=$(run_gate_in_work 'git commit -m x docs/plans/x.md' 'SSPOWER_AUTO_REVIEW=off' 2>&1); rc=$?
assert_eq "pathspec inside plan + bypass" "0" "$rc"

# Directory pathspec: `git commit docs/plans` should match.
# We can't easily assert "would gate" without mocking codex, so use
# bypass and just verify it doesn't blow up.
out=$(run_gate_in_work 'git commit -m x docs/plans' 'SSPOWER_AUTO_REVIEW=off' 2>&1); rc=$?
assert_eq "directory pathspec exit" "0" "$rc"

# --include picks up index even with a non-plan pathspec. Prove the
# dry-run path notices: with x.md staged AND also.txt also staged,
# `git commit -i also.txt` includes BOTH. Our gate should see the plan.
# Use bypass.
out=$(run_gate_in_work 'git commit -m x -i also.txt' 'SSPOWER_AUTO_REVIEW=off' 2>&1); rc=$?
assert_eq "--include + plan staged" "0" "$rc"

# Symlink under docs/plans/ refused even when staged (so dry-run lists
# it and we reach the worktree-source path). Without staging, git
# rejects the pathspec itself; staging gets us into the gate.
(
  cd "$WORK"
  rm -f docs/plans/evil.md
  ln -s /etc/passwd docs/plans/evil.md
  git add docs/plans/evil.md
)
out=$(run_gate_in_work 'git commit -m bump docs/plans/evil.md' 2>&1); rc=$?
assert_eq "symlink pathspec: exit"  "0" "$rc"
assert_eq "symlink pathspec: warning" "1" "$(printf '%s' "$out" | grep -c 'refusing symlink' || true)"

# `git -C otherrepo commit` -- must consult the OTHER repo.
OTHER=$(mktemp -d -t sspower-other-XXXXXX)
(
  cd "$OTHER"
  git init -q
  git config user.email t@t
  git config user.name t
  mkdir -p docs/plans
  echo "# o" > docs/plans/o.md
  git add docs/plans/o.md
)
out=$(cd "$WORK" && SSPOWER_AUTO_REVIEW=off CLAUDE_PLUGIN_ROOT="$ROOT" \
  bash "$GATE" <<EOF
{"tool_input":{"command":"git -C $OTHER commit -m x"}}
EOF
); rc=$?
assert_eq "git -C otherrepo: exit" "0" "$rc"
rm -rf "$OTHER"

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
assert_eq "push bypass"  "0" "$rc"

out=$(run_review_in_work 'ls' 2>&1); rc=$?
assert_eq "non-trigger"  "0" "$rc"

out=$(run_review_in_work 'git merge --abort' 2>&1); rc=$?
assert_eq "merge --abort"  "0" "$rc"

out=$(run_review_in_work 'gh pr create --title "t" --body "b"' 'SSPOWER_AUTO_REVIEW=off' 2>&1); rc=$?
assert_eq "gh pr create quoted bypass" "0" "$rc"

# Octopus merge: 3 unresolvable sources -> exit 0 (nothing reviewable).
out=$(run_review_in_work 'git merge a b c' 2>&1); rc=$?
assert_eq "octopus all-unresolvable" "0" "$rc"

echo
echo "passed: $PASS"
echo "failed: $FAIL"
[ "$FAIL" -eq 0 ]
