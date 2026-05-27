#!/usr/bin/env bash
# P3 graph-metric-reconcile: merges per-session spool jsonl into sessions.json.
set -euo pipefail

PAYLOAD="$(cat)"
SID="$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null)"
CWD="$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty' 2>/dev/null)"
END_REASON="$(printf '%s' "$PAYLOAD" | jq -r '.reason // empty' 2>/dev/null)"
[ -z "$SID" ] || [ -z "$CWD" ] && exit 0

node "$CLAUDE_PLUGIN_ROOT/scripts/graph/mcp-tools/metric.mjs" \
  reconcile --session "$SID" --cwd "$CWD" ${END_REASON:+--reason "$END_REASON"} || true
exit 0
