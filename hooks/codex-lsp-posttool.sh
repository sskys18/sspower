#!/usr/bin/env bash
# PostToolUse:Write|Edit|MultiEdit - run vendored codex-lsp on the file Claude
# just edited. DE-FANGED to ADVISORY (D-B6): strip codex-lsp's decision:block,
# surface only additionalContext. Fail-OPEN: resolver null / timeout / non-zero
# / no jq -> exit 0 silent. Disable: export SSPOWER_CODEX_LSP_POSTTOOL=0

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_log.sh" 2>/dev/null || true
trap '_sspower_exit_guard $? "0" hook.codex-lsp-posttool' EXIT

[[ "${SSPOWER_CODEX_LSP_POSTTOOL:-1}" == "0" ]] && exit 0

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
DIAG_LOG="${HOME}/.claude/sspower/codex.log"
log_hook() { local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)";
  mkdir -p "$(dirname "$DIAG_LOG")" 2>/dev/null
  ( printf '%s [%s] hook.codex-lsp-posttool %s\n' "$ts" "$1" "$2" >> "$DIAG_LOG" ) 2>/dev/null || true; }

command -v node >/dev/null 2>&1 || exit 0
command -v jq   >/dev/null 2>&1 || exit 0

CLI="$(node -e 'import("'"${PLUGIN_ROOT}"'/scripts/lib/codex-lsp-path.mjs").then(m=>{const p=m.resolveCodexLspCli();process.stdout.write(p||"")}).catch(()=>process.exit(0))' 2>/dev/null)"
[[ -z "$CLI" || ! -f "$CLI" ]] && { log_hook info "kind=skip reason=no-codex-lsp"; exit 0; }

INPUT="$(cat)"

# Portable hard timeout (codex-lsp ~2 s/file; cap 4 s).
TOUT="${SSPOWER_CODEX_LSP_TIMEOUT:-4}"
[[ "$TOUT" =~ ^[0-9]+$ ]] || TOUT=4; TOUT=$((10#$TOUT))
if command -v gtimeout >/dev/null 2>&1; then TO=(gtimeout "$TOUT")
elif command -v timeout >/dev/null 2>&1; then TO=(timeout "$TOUT")
elif command -v perl >/dev/null 2>&1; then TO=(perl -e 'alarm shift; exec @ARGV' "$TOUT")
else TO=(); fi   # no timeout binary AND no perl (extreme): run unbounded, never hard-fail

RAW=""
# bash-3.2-safe empty-array expansion - runs node directly if no wrapper.
if ! RAW="$(printf '%s' "$INPUT" | ${TO[@]+"${TO[@]}"} node "$CLI" hook post-tool-use 2>/dev/null)"; then
  log_hook warn "kind=lsp_nonzero_or_timeout"; exit 0
fi
[[ -z "$RAW" ]] && exit 0   # codex-lsp emits nothing when diagnostics clean

# De-fang (DP-4): keep ONLY hookSpecificOutput.additionalContext. Do NOT fall
# back to top-level .reason - that would re-broaden the block contract. If
# codex-lsp ever emits a verdict without additionalContext, we stay silent
# (fail-open) rather than surface a raw block reason.
CTX="$(printf '%s' "$RAW" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
[[ -z "$CTX" ]] && { log_hook info "kind=skip reason=no-additionalContext"; exit 0; }

log_hook info "kind=advisory_diag bytes=${#CTX}"
jq -n --arg c "ADVISORY (P5, non-blocking) - codex-lsp diagnostics on your last edit; fix before proceeding:
$CTX" \
  '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}'
exit 0
