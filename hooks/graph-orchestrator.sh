#!/usr/bin/env bash
# UserPromptSubmit hook — concurrent semble + graph context injection.
# REPLACES semble-context.sh in hooks.json when SSPOWER_GRAPH_ORCHESTRATOR=on.
#
# Fail-OPEN: any error / missing dep / timeout -> emit nothing OR exec
# semble-context.sh as fallback (no-graph path).
#
# Budget: 5s per child (timeout), 6s wall, 2KB per source after merge.
#
# Flags:
#   SSPOWER_GRAPH_ORCHESTRATOR=off    full bypass (exec semble-context.sh)
#   SSPOWER_SEMBLE=0                  disable semble child only
#   SSPOWER_GRAPH=0                   disable graph child only

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_log.sh" 2>/dev/null || true

# Single EXIT trap (do NOT add a second `trap ... EXIT` later — it would
# overwrite this one and lose the _sspower_exit_guard call).
# Temp file paths are exported into the function via globals set below.
SEMBLE_OUT=""
GRAPH_OUT=""
_orch_cleanup() {
  local rc=$?
  [[ -n "$SEMBLE_OUT" ]] && rm -f "$SEMBLE_OUT" 2>/dev/null
  [[ -n "$GRAPH_OUT"  ]] && rm -f "$GRAPH_OUT"  2>/dev/null
  command -v _sspower_exit_guard >/dev/null 2>&1 \
    && _sspower_exit_guard "$rc" "0" hook.graph-orchestrator
  return "$rc"
}
trap '_orch_cleanup' EXIT

DIAG_LOG="${HOME}/.claude/sspower/codex.log"
log_hook() {
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$(dirname "$DIAG_LOG")" 2>/dev/null
  ( printf '%s [%s] hook.graph-orchestrator %s\n' "$ts" "$1" "$2" >> "$DIAG_LOG" ) 2>/dev/null || true
}

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SEMBLE_HOOK="$PLUGIN_ROOT/hooks/semble-context.sh"

INPUT="$(cat 2>/dev/null || true)"

# Fast exits — fall back to semble-context.sh, never silent-drop the
# semble path (D-P4-3).
# NOTE: plan's `printf '%s' "$INPUT" | exec "$SEMBLE_HOOK"` would `exec`
# inside the pipeline's subshell and leave the orchestrator running past
# the call (verified: `bash -c 'f(){ echo s | exec cat; }; f; echo HERE'`
# prints HERE). We use a here-string so `exec` replaces THIS process and
# semble-context.sh sees INPUT on stdin.
exec_semble_fallback() {
  exec "$SEMBLE_HOOK" <<< "$INPUT"
}

[[ "${SSPOWER_GRAPH_ORCHESTRATOR:-on}" != "on" ]] && exec_semble_fallback
command -v jq >/dev/null 2>&1 || exec_semble_fallback

PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
[[ -z "$CWD" ]] && CWD="$(pwd)"
[[ -z "$PROMPT" ]] && exit 0
(( ${#PROMPT} < 20 )) && exit 0
[[ "$PROMPT" =~ ^/ ]] && exit 0

# Graph-absent → pure semble fallback (D-P4-3).
GRAPH_DIR="$CWD/.claude/graph"
[[ ! -f "$GRAPH_DIR/index.sqlite" ]] && exec_semble_fallback

# Dirty-queue staleness → semble-only (D-P4-4). Inline refresh would
# blow the 6s wall budget.
if [[ -s "$GRAPH_DIR/dirty" ]]; then
  log_hook info "kind=skip_graph reason=dirty"
  exec_semble_fallback
fi

# Resolve timeout binary (gtimeout > timeout > perl alarm > unbounded).
if command -v gtimeout >/dev/null 2>&1; then TO=(gtimeout)
elif command -v timeout >/dev/null 2>&1; then TO=(timeout)
elif command -v perl >/dev/null 2>&1; then TO=(perl -e 'alarm shift; exec @ARGV')
else TO=(); fi

# ---- Fork children -----------------------------------------------------
# Assign the globals declared above so _orch_cleanup will rm them.
SEMBLE_OUT=$(mktemp -t sspower-orch-semble-XXXXXX)
GRAPH_OUT=$(mktemp -t sspower-orch-graph-XXXXXX)

START="$(date +%s)"

(
  if [[ "${SSPOWER_SEMBLE:-1}" != "0" ]] && command -v semble_rs >/dev/null 2>&1; then
    ${TO[@]+"${TO[@]}"} 5 semble_rs plan "$PROMPT" "$CWD" >"$SEMBLE_OUT" 2>/dev/null || true
  fi
) &
SEMBLE_PID=$!

(
  if [[ "${SSPOWER_GRAPH:-1}" != "0" ]]; then
    ${TO[@]+"${TO[@]}"} 5 "$PLUGIN_ROOT/bin/sspower-graph-bootstrap.sh" \
      context "$PROMPT" --cwd "$CWD" --json >"$GRAPH_OUT" 2>/dev/null || true
  fi
) &
GRAPH_PID=$!

# ---- Wait with 6s wall budget ------------------------------------------
WALL_BUDGET=6
DEADLINE=$(( START + WALL_BUDGET ))
while :; do
  NOW=$(date +%s)
  (( NOW >= DEADLINE )) && break
  if ! kill -0 "$SEMBLE_PID" 2>/dev/null && ! kill -0 "$GRAPH_PID" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

# Kill any survivors.
kill -TERM "$SEMBLE_PID" 2>/dev/null || true
kill -TERM "$GRAPH_PID" 2>/dev/null || true
wait 2>/dev/null || true

DUR=$(( $(date +%s) - START ))

# ---- Per-source cap (D-P4-2, tuned T12.3 round 1) ----------------------
# SEM_CAP=3000 matches legacy semble-context.sh SSPOWER_SEMBLE_MAX_CHARS=3000
# default so candidate doesn't lose answerable bytes vs baseline.
# GR_CAP=2048 keeps room for graph context when it returns hits.
SEM_CAP=3000
GR_CAP=2048
MARKER='
[...truncated]'

cap_file() {
  local f="$1" cap="$2"
  [[ ! -s "$f" ]] && { printf ''; return; }
  local content
  content="$(cat "$f")"
  if (( ${#content} > cap )); then
    printf '%s%s' "${content:0:$(( cap - ${#MARKER} ))}" "$MARKER"
  else
    printf '%s' "$content"
  fi
}

SEMBLE_TXT="$(cap_file "$SEMBLE_OUT" "$SEM_CAP")"
GRAPH_TXT="$(cap_file "$GRAPH_OUT" "$GR_CAP")"

# ---- Merge + emit ------------------------------------------------------
MERGED=""
if [[ -n "$SEMBLE_TXT" ]]; then
  MERGED+="[semble_rs repo orientation - advisory, token-cheap; verify before acting]:
$SEMBLE_TXT"
fi
if [[ -n "$GRAPH_TXT" ]]; then
  [[ -n "$MERGED" ]] && MERGED+="

"
  MERGED+="[sspower-graph context - advisory; symbol-level, may include ambiguous-name matches]:
$GRAPH_TXT"
fi

if [[ -z "$MERGED" ]]; then
  log_hook info "kind=empty dur=${DUR}s cwd=$CWD"
  exit 0
fi

log_hook info "kind=inject dur=${DUR}s semble_bytes=${#SEMBLE_TXT} graph_bytes=${#GRAPH_TXT} cwd=$CWD"
printf '%s' "$MERGED" | jq -Rs '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:.}}'
exit 0
