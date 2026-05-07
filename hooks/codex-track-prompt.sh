#!/bin/bash
# UserPromptSubmit hook: auto-surface active Codex sessions to Claude.
#
# Reads ~/.claude/state/sspower/codex/*.json, filters to running OR
# recently-finished (within 5min) records, prints one compact line per
# session to stdout. Hook stdout is injected into Claude's prompt context.
#
# Silent (no output) when no sessions to report. Hard cap at 5 lines so
# busy registries can't blow context budget.
#
# Hard timeout: 1s. Disk IO only — no network, no codex calls.

set -euo pipefail

STATE_DIR="$HOME/.claude/state/sspower/codex"

# No registry yet → silent exit.
[ -d "$STATE_DIR" ] || exit 0

# Need jq. If absent, silent fail (don't break user prompts).
command -v jq >/dev/null 2>&1 || exit 0

# Cutoff: 5 minutes ago. macOS BSD date and GNU date differ; this works on both
# (returns epoch seconds).
NOW_EPOCH=$(date +%s)
CUTOFF_EPOCH=$((NOW_EPOCH - 300))

# Glob expansion safe — STATE_DIR exists. nullglob via shopt-equivalent:
shopt -s nullglob 2>/dev/null || true

declare -a LINES
COUNT=0
MAX_LINES=5

for file in "$STATE_DIR"/*.json; do
  [ -f "$file" ] || continue

  # One jq call per file. Schema: status, subcommand, session_id, phase,
  # started_at, updated_at, trace.{tool_calls,edits,execs,errors,tokens}, pid, bridge_pid.
  # Emits tab-separated fields including pid/bridge_pid for liveness check below.
  # Bridge writes ISO timestamps with millisecond precision (e.g. "...T03:14:55.000Z").
  # jq's fromdateiso8601 only accepts seconds precision, so strip milliseconds first.
  RAW=$(jq -r --argjson cutoff "$CUTOFF_EPOCH" '
    . as $r
    | (try ($r.updated_at | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch 0) as $updated
    | if ($r.status == "running") or ($r.status as $s | ["done","error","killed"] | index($s) and $updated >= $cutoff) then
        [
          ($r.status // "?"),
          ($r.session_id // "?")[0:8],
          ($r.subcommand // "?"),
          ($r.phase // "?"),
          (($r.duration_ms // 0) / 1000 | floor),
          ($r.trace.tool_calls // 0),
          ($r.trace.edits // 0),
          ($r.trace.execs // 0),
          ($r.trace.errors // 0),
          ($r.trace.tokens.input // 0),
          ($r.trace.tokens.output // 0),
          ($updated),
          ($r.pid // 0),
          ($r.bridge_pid // 0)
        ] | @tsv
      else
        empty
      end
  ' "$file" 2>/dev/null) || continue

  [ -n "$RAW" ] || continue

  # Stale detection: if status=running but supervising process is dead,
  # the record is a zombie from a crashed bridge. Match registry's
  # isLiveRunning semantics (bridge_pid preferred, fall back to age window).
  STATUS=$(echo "$RAW" | cut -f1)
  UPDATED=$(echo "$RAW" | cut -f12)
  PID=$(echo "$RAW" | cut -f13)
  BRIDGE_PID=$(echo "$RAW" | cut -f14)
  if [ "$STATUS" = "running" ]; then
    LIVE=1
    if [ "$BRIDGE_PID" -gt 1 ]; then
      kill -0 "$BRIDGE_PID" 2>/dev/null || LIVE=0
    else
      # Legacy record: age window proxy + child pid liveness.
      # Use grouping (no subshell) so LIVE=0 propagates to outer scope.
      AGE=$((NOW_EPOCH - UPDATED))
      [ "$AGE" -gt 300 ] && LIVE=0
      if [ "$LIVE" = "1" ] && [ "$PID" -gt 1 ]; then
        kill -0 "$PID" 2>/dev/null || LIVE=0
      fi
    fi
    if [ "$LIVE" = "0" ]; then
      # Old zombies clutter — only surface stale if recently updated (likely just crashed).
      [ "$UPDATED" -lt "$CUTOFF_EPOCH" ] && continue
      RAW=$(echo "$RAW" | awk -F'\t' 'BEGIN{OFS="\t"} {$1="stale"; print}')
    fi
  fi

  LINES+=("$RAW")
done

# Nothing matched → silent exit.
[ "${#LINES[@]}" -gt 0 ] || exit 0

# Sort by updated_at descending (last field), cap to MAX_LINES.
SORTED=$(printf '%s\n' "${LINES[@]}" | sort -t $'\t' -k12,12rn | head -n "$MAX_LINES")

# Format compact lines. Each tsv: status id8 cmd phase dur tools edits execs errors in out updated.
echo "[codex-tracking] active+recent sessions (auto-surface):"
while IFS=$'\t' read -r STATUS ID CMD PHASE DUR TOOLS EDITS EXECS ERRS IN OUT _UPD; do
  # Format token counts as Nk for compactness
  fmt_tok() {
    local n=$1
    if [ "$n" -ge 1000 ]; then
      echo "$((n / 1000))k"
    else
      echo "$n"
    fi
  }
  IN_F=$(fmt_tok "$IN")
  OUT_F=$(fmt_tok "$OUT")
  printf "  %-7s id=%s cmd=%-12s phase=%-8s dur=%4ds tools=%d edits=%d execs=%d err=%d tokens=%s/%s\n" \
    "$STATUS" "$ID" "$CMD" "$PHASE" "$DUR" "$TOOLS" "$EDITS" "$EXECS" "$ERRS" "$IN_F" "$OUT_F"
done <<< "$SORTED"

echo "[codex-tracking] inspect: node \$BRIDGE status <id> | tail <id> | kill <id> | steer --session-id <id>"
