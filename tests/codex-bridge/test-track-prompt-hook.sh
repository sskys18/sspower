#!/bin/bash
# Test the codex-track-prompt UserPromptSubmit hook against synthetic state files.
# Covers: ISO ms timestamp parsing, recent-done filtering, stale detection,
# legacy dead-pid liveness check, empty registry silence, MAX_LINES cap.

set -euo pipefail

HOOK="$(dirname "$0")/../../hooks/codex-track-prompt.sh"
[ -x "$HOOK" ] || { echo "FAIL: hook not executable at $HOOK"; exit 1; }

# Hook is now opt-in (default OFF) to save tokens in normal sessions.
# Tests must enable it explicitly to exercise the body.
export SSPOWER_CODEX_SURFACE=on

# Isolate test from real state by pointing to a fake HOME.
TEST_HOME=$(mktemp -d -t cx-track-test.XXXXXX)
trap "rm -rf '$TEST_HOME'" EXIT
TEST_STATE="$TEST_HOME/.claude/state/sspower/codex"
mkdir -p "$TEST_STATE"

NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
OLD_ISO=$(date -u -v-10M +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null || date -u -d "10 minutes ago" +"%Y-%m-%dT%H:%M:%S.000Z")
RECENT_ISO=$(date -u -v-2M +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null || date -u -d "2 minutes ago" +"%Y-%m-%dT%H:%M:%S.000Z")

# Use sentinel pids: 1 (init, always alive but skipped via >1 check) and 99999 (likely dead).
# For "alive" cases use the test runner's own pid.
MY_PID=$$

mk_record() {
  local file=$1 status=$2 subcommand=$3 phase=$4 updated=$5 pid=$6 bridge_pid=$7
  cat > "$TEST_STATE/$file.json" <<EOF
{
  "session_id": "$file",
  "pid": $pid,
  "bridge_pid": $bridge_pid,
  "subcommand": "$subcommand",
  "cwd": "/tmp",
  "started_at": "$updated",
  "updated_at": "$updated",
  "status": "$status",
  "phase": "$phase",
  "last_kind": "$phase",
  "last_event": null,
  "trace": { "tool_calls": 0, "edits": 0, "execs": 0, "errors": 0, "tokens": { "input": 1500, "output": 200, "total": 1700 } },
  "duration_ms": 5000,
  "exit_code": null
}
EOF
}

# Test 1: empty registry → silent
rm -f "$TEST_STATE"/*.json
OUT=$(HOME="$TEST_HOME" "$HOOK")
[ -z "$OUT" ] || { echo "FAIL: expected empty output for empty registry, got: $OUT"; exit 1; }
echo "[test 1] empty registry silence: PASS"

# Test 2: single running session with live bridge_pid → surfaces
mk_record "01000000-running-live" "running" "rescue" "exec" "$NOW_ISO" "$MY_PID" "$MY_PID"
OUT=$(HOME="$TEST_HOME" "$HOOK")
echo "$OUT" | grep -q "running" || { echo "FAIL: running session not surfaced: $OUT"; exit 1; }
echo "$OUT" | grep -q "01000000" || { echo "FAIL: session id prefix missing: $OUT"; exit 1; }
echo "[test 2] live running session: PASS"

# Test 3: recent done session (within 5min) → surfaces
mk_record "02000000-recent-done" "done" "enrich" "token" "$RECENT_ISO" 0 0
OUT=$(HOME="$TEST_HOME" "$HOOK")
echo "$OUT" | grep -q "02000000" || { echo "FAIL: recent done not surfaced (jq timestamp parse): $OUT"; exit 1; }
echo "$OUT" | grep -q "done" || { echo "FAIL: done status missing: $OUT"; exit 1; }
echo "[test 3] recent done surfaces (jq ms timestamp): PASS"

# Test 4: old done session (>5min) → hidden
rm -f "$TEST_STATE"/*.json
mk_record "03000000-old-done" "done" "rescue" "token" "$OLD_ISO" 0 0
OUT=$(HOME="$TEST_HOME" "$HOOK")
[ -z "$OUT" ] || { echo "FAIL: old done should be hidden: $OUT"; exit 1; }
echo "[test 4] old done hidden: PASS"

# Test 5: zombie record (status=running, bridge_pid=99999 dead) → marked stale, surfaced if recent
rm -f "$TEST_STATE"/*.json
mk_record "04000000-zombie" "running" "rescue" "exec" "$NOW_ISO" 99999 99998
OUT=$(HOME="$TEST_HOME" "$HOOK")
echo "$OUT" | grep -q "stale" || { echo "FAIL: zombie not marked stale: $OUT"; exit 1; }
echo "[test 5] zombie marked stale: PASS"

# Test 6: legacy record (no bridge_pid), running, dead pid, recent → marked stale
rm -f "$TEST_STATE"/*.json
mk_record "05000000-legacy-zombie" "running" "rescue" "exec" "$NOW_ISO" 99999 0
OUT=$(HOME="$TEST_HOME" "$HOOK")
echo "$OUT" | grep -q "stale" || { echo "FAIL: legacy zombie not marked stale: $OUT"; exit 1; }
echo "[test 6] legacy dead-pid stale propagates LIVE: PASS"

# Test 7: MAX_LINES cap (write 7 records, expect 5).
# Use distinct first-8-char prefixes so the truncated id in output is unique per record.
rm -f "$TEST_STATE"/*.json
for i in 1 2 3 4 5 6 7; do
  mk_record "0600000$i-cap" "running" "rescue" "exec" "$NOW_ISO" "$MY_PID" "$MY_PID"
done
OUT=$(HOME="$TEST_HOME" "$HOOK")
COUNT=$(echo "$OUT" | grep -c "id=0600000" || true)
[ "$COUNT" = "5" ] || { echo "FAIL: expected 5 lines (cap), got $COUNT. Output: $OUT"; exit 1; }
echo "[test 7] MAX_LINES cap: PASS"

# Test 8: opt-in gate — without SSPOWER_CODEX_SURFACE=on the hook must
# stay silent even with live sessions in the registry.
mk_record "07000000-gate-test" "running" "rescue" "exec" "$NOW_ISO" "$MY_PID" "$MY_PID"
OUT=$(HOME="$TEST_HOME" env -u SSPOWER_CODEX_SURFACE "$HOOK")
[ -z "$OUT" ] || { echo "FAIL: hook surfaced output when gate unset: $OUT"; exit 1; }
OUT=$(HOME="$TEST_HOME" SSPOWER_CODEX_SURFACE=off "$HOOK")
[ -z "$OUT" ] || { echo "FAIL: hook surfaced output when gate=off: $OUT"; exit 1; }
OUT=$(HOME="$TEST_HOME" SSPOWER_CODEX_SURFACE=1 "$HOOK")
[ -z "$OUT" ] || { echo "FAIL: hook surfaced output when gate=1 (only 'on' opens): $OUT"; exit 1; }
echo "[test 8] opt-in gate: PASS"

echo ""
echo "PASS: all 8 tests passed"
