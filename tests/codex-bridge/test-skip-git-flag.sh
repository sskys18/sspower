#!/bin/bash
# Regression: bridge must pass --skip-git-repo-check on both `exec` and
# `exec resume` codex spawn paths. codex >= 0.131 refuses non-git CWDs
# without it. Uses --print-args (no real codex spawn).
set -euo pipefail

BRIDGE="$(dirname "$0")/../../scripts/codex-bridge.mjs"

assert_has() {
  local label="$1" args_json="$2"
  if echo "$args_json" | jq -e '.args | index("--skip-git-repo-check")' >/dev/null; then
    echo "PASS: $label has --skip-git-repo-check"
  else
    echo "FAIL: $label MISSING --skip-git-repo-check"
    echo "  args: $args_json"
    exit 1
  fi
}

# `implement` -> runCodexExec
OUT=$(node "$BRIDGE" implement --print-args --prompt "x" --cd /tmp 2>/dev/null)
assert_has "implement (exec)" "$OUT"

# `review` -> runCodexExec
OUT=$(node "$BRIDGE" review --print-args --prompt "x" --cd /tmp 2>/dev/null)
assert_has "review (exec)" "$OUT"

# `resume` -> runCodexResume — needs --session-id placeholder
# Mandatory: if resume silently emits nothing, the --skip-git-repo-check
# regression for the resume code path is undetected. Treat empty output
# as a hard failure (not a tolerated skip).
OUT=$(node "$BRIDGE" resume --print-args --prompt "x" --session-id deadbeef-dead-beef-dead-beefdeadbeef --cd /tmp 2>/dev/null)
if [ -z "$OUT" ]; then
  echo "FAIL: resume --print-args emitted no output — regression in resume path"
  exit 1
fi
assert_has "resume (exec resume)" "$OUT"

echo "PASS: test-skip-git-flag"
