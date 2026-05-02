#!/usr/bin/env bash
# Smoke tests for hook command-detection logic. No Codex round-trip;
# we exercise the bypass + non-trigger paths and the new git-subcommand
# helper directly.

set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOKS="$ROOT/hooks"
DETECT="$HOOKS/_git-cmd-detect.sh"
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

# --- _git-cmd-detect.sh -----------------------------------------------------
echo "[git_subcommand]"
# shellcheck source=../../hooks/_git-cmd-detect.sh
. "$DETECT"

assert_eq "plain commit"          "commit" "$(git_subcommand 'git commit -m foo')"
assert_eq "amend"                 "commit" "$(git_subcommand 'git commit --amend')"
assert_eq "git -c X commit"       "commit" "$(git_subcommand 'git -c user.name=x commit -m foo')"
assert_eq "git --no-pager commit" "commit" "$(git_subcommand 'git --no-pager commit -m foo')"
assert_eq "git -C dir commit"     "commit" "$(git_subcommand 'git -C /tmp/repo commit -m foo')"
assert_eq "env-prefixed"          "commit" "$(git_subcommand 'GIT_EDITOR=vi FOO=bar git commit')"
assert_eq "git push"              "push"   "$(git_subcommand 'git push origin main')"
assert_eq "git -c X push"         "push"   "$(git_subcommand 'git -c http.proxy=p push')"
assert_eq "git merge"             "merge"  "$(git_subcommand 'git merge feat/foo')"
assert_eq "commit-tree (not commit)" "commit-tree" "$(git_subcommand 'git commit-tree X')"
assert_eq "non-git"               ""       "$(git_subcommand 'ls -la')"
assert_eq "pipeline (caller-bypass)" ""    "$(git_subcommand 'cd dir && git commit')"

# --- auto-spec-gate.sh ------------------------------------------------------
echo "[auto-spec-gate.sh]"

run_gate() {
  local cmd="$1"
  CLAUDE_PLUGIN_ROOT="$ROOT" bash "$GATE" <<EOF
{"tool_input":{"command":"$cmd"}}
EOF
}

# Set up a throwaway repo so `git diff --cached` can run even though we
# never actually commit.
WORK=$(mktemp -d -t sspower-hooktest-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
(
  cd "$WORK"
  git init -q
  git config user.email t@t
  git config user.name t
)

# Bypass via env var.
out=$(SSPOWER_AUTO_REVIEW=off run_gate 'git commit -m x' 2>&1)
rc=$?
assert_eq "bypass exit"      "0" "$rc"
assert_eq "bypass quiet"     ""  "$out"

# Non-commit: pass through silently.
out=$(cd "$WORK" && CLAUDE_PLUGIN_ROOT="$ROOT" bash "$GATE" <<<'{"tool_input":{"command":"ls -la"}}' 2>&1)
rc=$?
assert_eq "non-commit exit"  "0" "$rc"
assert_eq "non-commit quiet" ""  "$out"

# `git -c X commit` with no plan staged: pass through (used to MISS the
# commit-detection regex entirely; helper now catches it).
out=$(cd "$WORK" && CLAUDE_PLUGIN_ROOT="$ROOT" bash "$GATE" <<<'{"tool_input":{"command":"git -c user.name=x commit -m foo"}}' 2>&1)
rc=$?
assert_eq "git-c-commit nostaged exit"  "0" "$rc"
assert_eq "git-c-commit nostaged quiet" "" "$out"

# Plan staged + bypass on (would otherwise call codex). Use bypass to
# avoid network.
(
  cd "$WORK"
  mkdir -p docs/plans
  echo "# Plan" > docs/plans/test.md
  git add docs/plans/test.md
)
out=$(cd "$WORK" && SSPOWER_AUTO_REVIEW=off CLAUDE_PLUGIN_ROOT="$ROOT" bash "$GATE" <<<'{"tool_input":{"command":"git -c x=y commit -m foo"}}' 2>&1)
rc=$?
assert_eq "plan staged + bypass exit"  "0" "$rc"

# --- auto-review.sh --------------------------------------------------------
echo "[auto-review.sh]"

# Bypass.
out=$(cd "$WORK" && SSPOWER_AUTO_REVIEW=off CLAUDE_PLUGIN_ROOT="$ROOT" bash "$REVIEW" <<<'{"tool_input":{"command":"git push"}}' 2>&1)
rc=$?
assert_eq "push bypass exit"  "0" "$rc"

# Non-trigger.
out=$(cd "$WORK" && CLAUDE_PLUGIN_ROOT="$ROOT" bash "$REVIEW" <<<'{"tool_input":{"command":"ls"}}' 2>&1)
rc=$?
assert_eq "non-trigger exit"  "0" "$rc"

# git merge --abort / no resolvable source: pass through.
out=$(cd "$WORK" && CLAUDE_PLUGIN_ROOT="$ROOT" bash "$REVIEW" <<<'{"tool_input":{"command":"git merge --abort"}}' 2>&1)
rc=$?
assert_eq "merge --abort exit"  "0" "$rc"

# Summary.
echo
echo "passed: $PASS"
echo "failed: $FAIL"
[ "$FAIL" -eq 0 ]
