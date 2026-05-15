#!/usr/bin/env bash
# Deterministic codex-bridge stub.
#   $SSPOWER_FAKE_BRIDGE_RESPONSE  → stdout payload
#   $SSPOWER_FAKE_BRIDGE_EXIT      → exit code
#   $SSPOWER_FAKE_BRIDGE_STDERR    → stderr payload
#   $SSPOWER_FAKE_BRIDGE_SENTINEL  → touch this file on every invocation
set -u
stdout_payload="${SSPOWER_FAKE_BRIDGE_RESPONSE:-}"
stderr_payload="${SSPOWER_FAKE_BRIDGE_STDERR:-}"
exit_code="${SSPOWER_FAKE_BRIDGE_EXIT:-0}"
[ -n "${SSPOWER_FAKE_BRIDGE_SENTINEL:-}" ] && : >> "$SSPOWER_FAKE_BRIDGE_SENTINEL"
[ -n "$stdout_payload" ] && printf '%s' "$stdout_payload"
[ -n "$stderr_payload" ] && printf '%s' "$stderr_payload" >&2
exit "$exit_code"
