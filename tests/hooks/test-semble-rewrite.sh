#!/usr/bin/env bash
set -uo pipefail
H="$(cd "$(dirname "$0")/../.." && pwd)/hooks/semble-rewrite.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: test-semble-rewrite (no jq - harness dep)"; exit 0; }
FAIL=0; ok(){ echo "PASS: $1"; }; bad(){ echo "FAIL: $1 :: $2"; FAIL=1; }
# jq builder - valid JSON even when the command contains quotes / regex chars.
j(){ jq -nc --arg c "$1" '{tool_input:{command:$c}}'; }

# The hook will not rewrite to a binary that is absent (it would emit a broken
# command). So with no semble_rs the ONLY correct behavior is fail-open
# passthrough for EVERY input - assert that deterministically and stop.
if ! command -v semble_rs >/dev/null 2>&1; then
  for c in 'ls -R src' 'grep -R ident .' 'ls -la' 'cat x'; do
    O="$(j "$c" | "$H")"; [[ -z "$O" ]] && ok "no-semble passthrough: $c" || bad "no-semble passthrough: $c" "$O"
  done
  [[ $FAIL -eq 0 ]] && echo "PASS: test-semble-rewrite" || { echo "FAIL: test-semble-rewrite"; exit 1; }
  exit 0
fi

# ls -> EXPLICIT permissionDecision:"ask" (single emit path; no auto-allow).
O="$(j 'ls -R src' | "$H")"
echo "$O" | jq -e '(.hookSpecificOutput.permissionDecision=="ask") and (.hookSpecificOutput.updatedInput.command=="semble_rs tree src")' >/dev/null \
  && ok "ls -R -> ask" || bad "ls -R ask" "$O"

O="$(j 'ls -l -R src' | "$H")"   # separated flags must still classify
echo "$O" | jq -e '(.hookSpecificOutput.permissionDecision=="ask") and (.hookSpecificOutput.updatedInput.command=="semble_rs tree src")' >/dev/null \
  && ok "ls -l -R src (separated) -> ask" || bad "ls separated" "$O"

O="$(j 'ls -laR' | "$H")"
echo "$O" | jq -e '(.hookSpecificOutput.permissionDecision=="ask") and (.hookSpecificOutput.updatedInput.command=="semble_rs tree .")' >/dev/null \
  && ok "ls -laR -> ask, tree ." || bad "ls -laR" "$O"

# grep -> EXPLICIT permissionDecision:"ask" (DP-2 - not unset fall-through).
O="$(j 'grep -R runLspGate src' | "$H")"
echo "$O" | jq -e '(.hookSpecificOutput.permissionDecision=="ask") and (.hookSpecificOutput.updatedInput.command=="semble_rs search --compact runLspGate src")' >/dev/null \
  && ok "grep ident -> explicit ask" || bad "grep ask" "$O"

O="$(j 'grep -r ident' | "$H")"  # -r, default path .
echo "$O" | jq -e '(.hookSpecificOutput.permissionDecision=="ask") and (.hookSpecificOutput.updatedInput.command=="semble_rs search --compact ident .")' >/dev/null \
  && ok "grep -r ident -> ask, path defaults ." || bad "grep -r default path" "$O"

# DP-2 locked: separated recursive flags `grep -R -r x .` classify correctly.
O="$(j 'grep -R -r x .' | "$H")"
echo "$O" | jq -e '(.hookSpecificOutput.permissionDecision=="ask") and (.hookSpecificOutput.updatedInput.command=="semble_rs search --compact x .")' >/dev/null \
  && ok "grep -R -r x . (separated recursive flags) -> ask" || bad "grep separated -R -r" "$O"

# ls ask assertions covered above.
# DP-1: lowercase `ls -r` is REVERSE-sort, NOT recursive -> must NOT rewrite.
# DP-2 STRICT: anything beyond exactly -R/-r (grep) must pass through.
for c in 'ls -r src' 'ls -lr' 'ls -r' \
         'grep -Rn ident .' 'grep -R -i Foo src' 'grep -Rw foo .' 'grep -RF lit .' \
         'grep -RE pat .' 'grep --recursive ident .' 'grep -R "a.*b" .' \
         'grep -R ident -n' 'grep -R Foo -i' 'grep -R x a b' \
         'ls -la' 'cat foo' 'ls -R | head' 'ls -R && pwd' 'ls -R src&' 'ls --color -R .'; do
  O="$(j "$c" | "$H")"; [[ -z "$O" ]] && ok "noop: $c" || bad "noop: $c" "$O"
done

O="$(SSPOWER_SEMBLE_REWRITE=0 sh -c "printf '{\"tool_input\":{\"command\":\"ls -R\"}}' | '$H'")"
[[ -z "$O" ]] && ok "disable env" || bad "disable env" "$O"

[[ $FAIL -eq 0 ]] && echo "PASS: test-semble-rewrite" || { echo "FAIL: test-semble-rewrite"; exit 1; }
