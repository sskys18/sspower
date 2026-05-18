#!/bin/bash
# Codex PostToolUse → codex-lsp diagnostics on the just-edited file.
# Advisory: ALWAYS exit 0 (D-B6 — never blocks Codex until the user flips
# SSPOWER_LSP_SELFREPAIR_BLOCK). Fail-open if codex-lsp unresolved.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$(node -e 'import(process.argv[1]).then(m=>{const p=m.resolveCodexLspCli();process.stdout.write(p||"")})' "$ROOT/scripts/lib/codex-lsp-path.mjs" 2>/dev/null)"
[ -z "$CLI" ] && { echo '{"decision":"approve","reason":"codex-lsp unresolved — advisory skip"}'; exit 0; }
OUT="$(node "$CLI" hook post-tool-use 2>/dev/null || true)"
if [ "${SSPOWER_LSP_SELFREPAIR_BLOCK:-}" = "1" ] && printf '%s' "$OUT" | grep -q '"decision":"block"'; then
  printf '%s\n' "$OUT"; exit 0   # block passed through ONLY when gate flipped
fi
# Advisory default: strip any block decision → approve, keep diagnostics as context.
printf '%s' "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);j.decision="approve";console.log(JSON.stringify(j))}catch{console.log("{\"decision\":\"approve\"}")}})'
exit 0
