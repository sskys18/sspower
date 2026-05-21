#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="${ROOT}/hooks/session-start"
command -v jq      >/dev/null 2>&1 || { echo "SKIP: test-session-start-mem (no jq)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: test-session-start-mem (no python3)"; exit 0; }
FAIL=0; ok(){ echo "PASS: $1"; }; bad(){ echo "FAIL: $1 :: $2"; FAIL=1; }

WORK="$(mktemp -d)"
trap 'rm -r "$WORK"' EXIT
PROJ="$WORK/proj"; mkdir -p "$PROJ"
mkdir -p "$WORK/bin"
export UV_LOG="$WORK/uvx.log"

# Fake `uvx`: log full argv to $UV_LOG, behave per $FAKE_MODE.
#   ok   -> print a search-results JSON envelope, exit 0
#   r10  -> exit 10 (degraded)
#   r30  -> exit 30 (dep missing)
#   weird-> exit 7  (unmapped uvx-internal code -> wrapper must normalize to 30)
write_fake_uvx() {
  cat > "$WORK/bin/uvx" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${UV_LOG:?}"
case "${FAKE_MODE:-ok}" in
  ok)    echo '[{"id":"abc1234567890def","source":"digest-recent","score":1.0,"content":"MEM_MARKER recent decision block","scope":"project:deadbeef","layer":"decision","ts":"2026-05-20T09:00:00Z"}]'; exit 0 ;;
  r10)   echo "degraded" >&2; exit 10 ;;
  r30)   echo "dep missing" >&2; exit 30 ;;
  weird) echo "boom" >&2; exit 7 ;;
esac
STUB
  chmod +x "$WORK/bin/uvx"
}
write_fake_uvx
: > "$UV_LOG"

payload() { jq -nc --arg cwd "$PROJ" '{session_id:"s",cwd:$cwd,hook_event_name:"SessionStart",source:"startup"}'; }

# Case A: search succeeds -> additionalContext carries the marker, the
# `sspower-mem search` argv shape is exactly the spec's, hook exits 0.
: > "$UV_LOG"
O="$(payload | FAKE_MODE=ok PATH="$WORK/bin:$PATH" "$HOOK")"; RC=$?
LOG="$(cat "$UV_LOG")"
[ "$RC" -eq 0 ] && ok "case A: hook exits 0" || bad "case A exit" "rc=$RC"
echo "$O" | jq -e '.hookSpecificOutput.hookEventName=="SessionStart"' >/dev/null \
  && ok "case A: emits SessionStart JSON" || bad "case A shape" "$O"
echo "$O" | jq -e '.hookSpecificOutput.additionalContext|test("MEM_MARKER")' >/dev/null \
  && ok "case A: recent memory injected" || bad "case A inject" "$O"
echo "$O" | jq -e '.hookSpecificOutput.additionalContext|test("using-sspower")' >/dev/null \
  && ok "case A: using-sspower block still present" || bad "case A skill block" "$O"
assert_arg() { case "$LOG" in *"$1"*) ok "case A: $2" ;; *) bad "case A: $2" "$LOG" ;; esac ; }
assert_arg '--offline --from'      'invoked via uvx --offline --from'
assert_arg 'scripts/sspower_mem'   '--from points at sspower_mem source'
assert_arg 'sspower-mem search'    'sspower-mem search subcommand'
assert_arg "--cwd $PROJ"           '--cwd is the payload cwd'
assert_arg '--scope project,user'  'scope project,user'
assert_arg '--mode recent'         '--mode recent (no --query at SessionStart)'
assert_arg '--top-k 8'             '--top-k 8'
assert_arg '--json'                '--json'
case "$LOG" in *'--query'*) bad "case A: unexpected --query" "$LOG" ;; *) ok "case A: no --query" ;; esac

# Case B: search degraded (rc=10) -> hook exits 0, no marker, skill block intact.
O="$(payload | FAKE_MODE=r10 PATH="$WORK/bin:$PATH" "$HOOK")"; RC=$?
[ "$RC" -eq 0 ] && ok "case B: rc=10 hook exits 0" || bad "case B exit" "rc=$RC"
echo "$O" | jq -e '.hookSpecificOutput.additionalContext|test("MEM_MARKER")|not' >/dev/null \
  && ok "case B: rc=10 injects no memory" || bad "case B inject" "$O"
echo "$O" | jq -e '.hookSpecificOutput.additionalContext|test("using-sspower")' >/dev/null \
  && ok "case B: rc=10 skill block survives" || bad "case B skill block" "$O"

# Case C: search dep-missing (rc=30) -> hook exits 0, no marker, AND the
# wrapper positively logs the rc=30 dep-missing message on stderr (proves the
# rc=30 path was taken, not just an empty result).
ERRC="$WORK/errC"
O="$(payload | FAKE_MODE=r30 PATH="$WORK/bin:$PATH" "$HOOK" 2>"$ERRC")"; RC=$?
[ "$RC" -eq 0 ] && ok "case C: rc=30 hook exits 0" || bad "case C exit" "rc=$RC"
echo "$O" | jq -e '.hookSpecificOutput.additionalContext|test("MEM_MARKER")|not' >/dev/null \
  && ok "case C: rc=30 injects no memory" || bad "case C inject" "$O"
grep -q 'rc=30' "$ERRC" \
  && ok "case C: wrapper logged rc=30 dep-missing" || bad "case C: rc=30 not logged" "$(cat "$ERRC")"

# Case D: uvx-internal exit 7 -> wrapper normalizes to rc=30 -> hook exits 0, no marker.
O="$(payload | FAKE_MODE=weird PATH="$WORK/bin:$PATH" "$HOOK")"; RC=$?
[ "$RC" -eq 0 ] && ok "case D: unmapped rc normalizes, hook exits 0" || bad "case D exit" "rc=$RC"
echo "$O" | jq -e '.hookSpecificOutput.additionalContext|test("MEM_MARKER")|not' >/dev/null \
  && ok "case D: unmapped rc injects no memory" || bad "case D inject" "$O"

# Case E: uvx absent entirely -> pre-flight `command -v uvx` -> rc=30 -> hook exits 0.
O="$(payload | PATH="/usr/bin:/bin" "$HOOK")"; RC=$?
[ "$RC" -eq 0 ] && ok "case E: uvx missing, hook exits 0" || bad "case E exit" "rc=$RC"
echo "$O" | jq -e '.hookSpecificOutput.hookEventName=="SessionStart"' >/dev/null \
  && ok "case E: still emits valid JSON" || bad "case E shape" "$O"

# Case F: payload has no cwd -> search not attempted, hook exits 0 with valid JSON.
: > "$UV_LOG"
O="$(jq -nc '{session_id:"s",hook_event_name:"SessionStart"}' | FAKE_MODE=ok PATH="$WORK/bin:$PATH" "$HOOK")"; RC=$?
[ "$RC" -eq 0 ] && ok "case F: no cwd, hook exits 0" || bad "case F exit" "rc=$RC"
grep -q 'sspower-mem search' "$UV_LOG" \
  && bad "case F: search ran without cwd" "$(cat "$UV_LOG")" \
  || ok "case F: no cwd skips search"

[ "$FAIL" -eq 0 ] && echo "PASS: test-session-start-mem" || { echo "FAIL: test-session-start-mem"; exit 1; }
