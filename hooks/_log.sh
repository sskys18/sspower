#!/usr/bin/env bash
# Shared logging helper for sspower hooks.
# Format matches scripts/codex-bridge.mjs logEvent():
#   ISO_TS [level] source key="value" key="value" ...
#
# Usage:
#   source "$(dirname "$0")/_log.sh"
#   log_event warn hook.auto-review kind=deny_predecessor cmd_preview="cd .. && git push"

SSPOWER_LOG_FILE="${SSPOWER_LOG_FILE:-$HOME/.claude/sspower/codex.log}"
SSPOWER_LOG_MAX_LINES="${SSPOWER_LOG_MAX_LINES:-1000}"
SSPOWER_LOG_KEEP_TAIL="${SSPOWER_LOG_KEEP_TAIL:-500}"

# Rotate log if it grew past SSPOWER_LOG_MAX_LINES, keeping the last
# SSPOWER_LOG_KEEP_TAIL lines. Matches scripts/codex-bridge.mjs
# rotateLogOnce() defaults so the file size cap is consistent across
# both writers. Best effort; never errors out.
# Path moved to ~/.claude/sspower/codex.log; rotation knobs intentionally stay env (no jq dep in hook hot path) — see docs/specs/2026-05-18-sspower-config-consolidation-design.md carve-out.
_sspower_rotate_log() {
  [ -f "$SSPOWER_LOG_FILE" ] || return 0
  local lines
  lines=$(wc -l < "$SSPOWER_LOG_FILE" 2>/dev/null | tr -d ' ' || echo 0)
  case "$lines" in ''|*[!0-9]*) return 0 ;; esac
  [ "$lines" -gt "$SSPOWER_LOG_MAX_LINES" ] || return 0
  (
    umask 077
    local tmp="$SSPOWER_LOG_FILE.rot.$$"
    tail -n "$SSPOWER_LOG_KEEP_TAIL" "$SSPOWER_LOG_FILE" > "$tmp" 2>/dev/null \
      && mv -f "$tmp" "$SSPOWER_LOG_FILE" 2>/dev/null
    chmod 600 "$SSPOWER_LOG_FILE" 2>/dev/null || true
  ) 2>/dev/null || true
}

log_event() {
  local level="$1" source="$2"
  shift 2
  local ts kvs="" k v esc
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || return 0
  for arg in "$@"; do
    k="${arg%%=*}"
    v="${arg#*=}"
    esc="${v//\\/\\\\}"
    esc="${esc//\"/\\\"}"
    esc="${esc//$'\n'/\\n}"
    kvs="$kvs $k=\"$esc\""
  done
  _sspower_rotate_log
  # Force private perms (0600) so the log can never leak via group/other
  # read. Bridge's logEvent in codex-bridge.mjs uses the same mode.
  local existed=0
  [ -f "$SSPOWER_LOG_FILE" ] && existed=1
  (
    umask 077
    mkdir -p "$(dirname "$SSPOWER_LOG_FILE")" 2>/dev/null || exit 0
    printf '%s [%s] %s%s\n' "$ts" "$level" "$source" "$kvs" >> "$SSPOWER_LOG_FILE"
  ) 2>/dev/null || true
  if [ "$existed" = "0" ] && [ -f "$SSPOWER_LOG_FILE" ]; then
    chmod 600 "$SSPOWER_LOG_FILE" 2>/dev/null || true
  fi
}
