#!/usr/bin/env bash
set -uo pipefail
H="$(cd "$(dirname "$0")/../.." && pwd)/hooks/semble-session.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: test-semble-session (no jq - harness dep)"; exit 0; }
FAIL=0; ok(){ echo "PASS: $1"; }; bad(){ echo "FAIL: $1 :: $2"; FAIL=1; }

O="$(echo '{}' | SSPOWER_SEMBLE_WARM=0 "$H")"
echo "$O" | jq -e '.hookSpecificOutput.hookEventName=="SessionStart" and (.hookSpecificOutput.additionalContext|test("semble_rs:(ok|MISSING)") and test("codex-lsp:(ok|MISSING)"))' >/dev/null \
  && ok "status line shape (incl codex-lsp via resolver)" || bad "status line" "$O"

# Detached-warm proof: warm ENABLED (default). If warm ran inline a cold model
# pull would block many seconds; the `( ... & )` disown must return immediately.
START="$(date +%s)"
O="$(echo '{}' | "$H")"
DUR=$(( $(date +%s) - START ))
(( DUR <= 3 )) && ok "detached warm non-blocking (<=3s, warm ON)" || bad "warm blocked" "${DUR}s"
echo "$O" | jq -e '.hookSpecificOutput.hookEventName=="SessionStart"' >/dev/null \
  && ok "still emits status with warm on" || bad "warm-on status" "$O"

[[ $FAIL -eq 0 ]] && echo "PASS: test-semble-session" || { echo "FAIL: test-semble-session"; exit 1; }
