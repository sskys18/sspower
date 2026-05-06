#!/usr/bin/env bash
# Shared logging helper for sspower hooks.
# Format matches scripts/codex-bridge.mjs logEvent():
#   ISO_TS [level] source key="value" key="value" ...
#
# Usage:
#   source "$(dirname "$0")/_log.sh"
#   log_event warn hook.auto-review kind=deny_predecessor cmd_preview="cd .. && git push"

SSPOWER_LOG_FILE="${SSPOWER_LOG_FILE:-$HOME/.claude/sspower-codex.log}"

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
