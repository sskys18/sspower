#!/bin/bash
set -euo pipefail

# Note: this test only verifies the registry round-trip. The steer codepath
# was verified manually during Task 4 development with a longer-running
# prompt. Automating the steer test requires forcing Codex to produce a
# session rollout artifact, which depends on prompt complexity and isn't
# stable across Codex versions. See plan §Risks for the deferral rationale.

BRIDGE="$(dirname "$0")/../../scripts/codex-bridge.mjs"
STATE_DIR="$HOME/.claude/state/sspower/codex"

# Clean slate (only files matching test-registry pattern, don't blow away other sessions)
mkdir -p "$STATE_DIR"

echo "[test] Spawning rescue in background"
START_TS=$(date -u +"%Y-%m-%dT%H:%M:%S")
node "$BRIDGE" rescue --prompt "say hello and stop" > /tmp/test-rescue.out 2>&1 &
BRIDGE_PID=$!

# Wait up to 60s for state file to appear (Codex cold start can be slow).
# Match by subcommand + started_at, NOT by $BRIDGE_PID: the registry stores
# the codex child PID, not the node bridge wrapper PID.
SID=""
for i in $(seq 1 60); do
  SID=$(node "$BRIDGE" ps 2>/dev/null | jq -r --arg t "$START_TS" '
    [.[] | select(.subcommand=="rescue" and .started_at >= $t)]
    | .[0].session_id // empty
  ')
  [ -n "$SID" ] && break
  if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
    SID=$(node "$BRIDGE" ps 2>/dev/null | jq -r --arg t "$START_TS" '
      [.[] | select(.subcommand=="rescue" and .started_at >= $t)]
      | .[0].session_id // empty
    ')
    break
  fi
  sleep 1
done

if [ -z "$SID" ]; then
  echo "FAIL: no session id found after 60s"
  kill "$BRIDGE_PID" 2>/dev/null || true
  exit 1
fi

echo "[test] Session: $SID"

PHASE=$(node "$BRIDGE" status "$SID" | jq -r '.phase')
echo "[test] Phase: $PHASE"
[ -n "$PHASE" ] && [ "$PHASE" != "null" ] || { echo "FAIL: empty phase"; exit 1; }

wait "$BRIDGE_PID" || true

FINAL_STATUS=$(node "$BRIDGE" status "$SID" | jq -r '.status')
echo "[test] Final status: $FINAL_STATUS"
[ "$FINAL_STATUS" = "done" ] || { echo "FAIL: expected done, got $FINAL_STATUS"; exit 1; }

[ -f "$STATE_DIR/$SID.events.jsonl" ] || { echo "FAIL: no events log"; exit 1; }
EVT_COUNT=$(wc -l < "$STATE_DIR/$SID.events.jsonl")
echo "[test] Events logged: $EVT_COUNT"
[ "$EVT_COUNT" -gt 0 ] || { echo "FAIL: zero events"; exit 1; }

echo "PASS: registry test"
