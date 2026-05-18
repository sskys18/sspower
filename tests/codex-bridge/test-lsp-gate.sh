#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
git -C "$WORK" init -q
printf 'export const x: number = "bad";\n' > "$WORK/bad.ts"
node - "$ROOT" "$WORK" <<'EOF'
const [,, ROOT, WORK] = process.argv;
const m = await import(`${ROOT}/scripts/codex-bridge.mjs`);
const _lsp = await m.__test_runLspGate(WORK, null, false);
if (_lsp.status !== "errors") { console.log(`FAIL: expected errors, got ${JSON.stringify(_lsp)}`); process.exit(1); }
if (_lsp.decision !== "would-block") { console.log(`FAIL: advisory must be would-block, got ${_lsp.decision}`); process.exit(1); }
console.log("PASS: advisory gate -> status=errors decision=would-block");
EOF
echo "PASS: test-lsp-gate"
