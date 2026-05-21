#!/usr/bin/env bash
# SessionStart hook - one-line availability status + DETACHED model warm.
# Never blocks: warm runs backgrounded & disowned (cold = one-time ~60 MB dl).
# Fail-OPEN: missing tools -> status line says so, exit 0.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_log.sh" 2>/dev/null || true
trap '_sspower_exit_guard $? "0" hook.semble-session' EXIT

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

have() { command -v "$1" >/dev/null 2>&1 && echo "ok" || echo "MISSING"; }

S_SEMBLE="$(have semble_rs)"
S_NODE="$(have node)"
S_JQ="$(have jq)"

# codex-lsp path via the canonical resolver (DP-6: SSPOWER_CODEX_LSP_CLI
# override -> vendored -> null). Never hardcode the vendored path.
S_LSP="MISSING"
if [[ "$S_NODE" == "ok" ]]; then
  _cli="$(node -e 'import("'"${PLUGIN_ROOT}"'/scripts/lib/codex-lsp-path.mjs").then(m=>{const p=m.resolveCodexLspCli();process.stdout.write(p||"")}).catch(()=>{})' 2>/dev/null)"
  [[ -n "$_cli" && -f "$_cli" ]] && S_LSP="ok"
fi

# Detached + time-bounded warm. `( cmd & )` runs in a subshell that exits
# immediately; the child is reparented to init (effective disown, portable -
# bash `disown` is unavailable in a one-shot subshell). A timeout caps the
# one-time ~60 MB cold model pull so a stuck download cannot leak forever.
if [[ "$S_SEMBLE" == "ok" && "${SSPOWER_SEMBLE_WARM:-1}" != "0" ]]; then
  WARM_T="${SSPOWER_SEMBLE_WARM_TIMEOUT:-90}"
  [[ "$WARM_T" =~ ^[0-9]+$ ]] || WARM_T=90; WARM_T=$((10#$WARM_T))
  # Array form (no string word-splitting), consistent with the other hooks.
  # perl-alarm fallback guarantees a hard bound even when neither gtimeout nor
  # timeout exists (stock macOS ships neither; perl is present) - the warm is
  # ALWAYS time-bounded, never an unbounded detached download.
  if command -v gtimeout >/dev/null 2>&1; then WTO=(gtimeout "$WARM_T")
  elif command -v timeout >/dev/null 2>&1; then WTO=(timeout "$WARM_T")
  elif command -v perl >/dev/null 2>&1; then WTO=(perl -e 'alarm shift; exec @ARGV' "$WARM_T")
  else WTO=(); fi   # only if even perl is absent - extreme; warm simply unbounded then
  # bash-3.2-safe: `${arr[@]+"${arr[@]}"}` avoids set -u unbound error on empty array.
  ( ${WTO[@]+"${WTO[@]}"} semble_rs search --compact __sspower_warm__ . >/dev/null 2>&1 & ) >/dev/null 2>&1
fi

STATUS="sspower P5 context layer - semble_rs:${S_SEMBLE} codex-lsp:${S_LSP} node:${S_NODE} jq:${S_JQ}"
[[ "$S_SEMBLE" != "ok" ]] && STATUS="${STATUS} (semble inject + rewrite inert; install: cargo install semble_rs)"

# jq builds the JSON when available; bash fallback only if jq absent (status
# text is ASCII-only and control-char-free by construction, so the fallback
# is safe here - unlike the user-content hooks which hard-require jq).
if command -v jq >/dev/null 2>&1; then
  jq -n --arg c "$STATUS" \
    '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
else
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$STATUS"
fi
exit 0
