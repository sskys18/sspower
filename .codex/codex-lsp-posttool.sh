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
  # Block mode (D-B6). D-B7 still wins for INFRA absence: downgrade a block
  # whose diagnostics are "server NOT INSTALLED" / "No supported source
  # files" / "No LSP server configured" to approve; pass real code-error
  # blocks through unchanged.
  printf '%s' "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let j;try{j=JSON.parse(s)}catch{console.log(s);process.exit(0)}const blob=JSON.stringify(j);if(j.decision==="block"&&(blob.includes("is configured but NOT INSTALLED")||blob.includes("No supported source files found in directory:")||blob.includes("No LSP server configured for extension:"))){console.log(JSON.stringify({decision:"approve",reason:"codex-lsp infra absent (missing server / no source files) — fail-open per D-B7"}))}else{console.log(s.trim())}})'
  exit 0
fi
# Advisory default: strip any block decision → approve, keep diagnostics as context.
printf '%s' "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);j.decision="approve";console.log(JSON.stringify(j))}catch{console.log("{\"decision\":\"approve\"}")}})'
exit 0
