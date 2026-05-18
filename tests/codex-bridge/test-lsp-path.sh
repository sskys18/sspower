#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MOD="$ROOT/scripts/lib/codex-lsp-path.mjs"

OUT=$(node -e 'import(process.argv[1]).then(m=>console.log(m.resolveCodexLspCli()))' "$MOD")
case "$OUT" in
  */tools/codex-lsp/dist/cli.js) echo "PASS: resolves vendored" ;;
  *) echo "FAIL: expected vendored path, got $OUT"; exit 1 ;;
esac

OUT2=$(SSPOWER_CODEX_LSP_CLI=/nonexistent node -e 'import(process.argv[1]).then(m=>console.log(m.resolveCodexLspCli()))' "$MOD")
case "$OUT2" in
  */tools/codex-lsp/dist/cli.js) echo "PASS: bad override falls back to vendored" ;;
  *) echo "FAIL: override fallback, got $OUT2"; exit 1 ;;
esac

T=$(mktemp)
OUT3=$(SSPOWER_CODEX_LSP_CLI="$T" node -e 'import(process.argv[1]).then(m=>console.log(m.resolveCodexLspCli()))' "$MOD")
rm -f "$T"
if [ "$OUT3" = "$T" ]; then
  echo "PASS: valid override honored verbatim"
else
  echo "FAIL: expected override $T, got $OUT3"; exit 1
fi

echo "PASS: test-lsp-path"
