#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLI="$ROOT/tools/codex-lsp/dist/cli.js"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# Seeded TS error file + a clean file.
printf 'export const x: number = "nope";\n' > "$WORK/bad.ts"
printf 'export const y: number = 1;\n' > "$WORK/good.ts"
node - "$ROOT" "$CLI" "$WORK" <<'EOF'
const [,, ROOT, CLI, WORK] = process.argv;
const { McpLspClient, isCleanDiagnosticsText } = await import(`${ROOT}/scripts/mcp-lsp-client.mjs`);
const c = new McpLspClient(CLI, WORK);
const started = await c.start(45000);
if (!started) { console.log("FAIL: initialize handshake failed"); process.exit(1); }
const bad = await c.diagnostics(`${WORK}/bad.ts`);
const good = await c.diagnostics(`${WORK}/good.ts`);
await c.stop();
if (!bad.ok) { console.log("FAIL: bad.ts diagnostics call did not return ok"); process.exit(1); }
if (isCleanDiagnosticsText(bad.text)) { console.log(`FAIL: bad.ts reported clean; text=${bad.text}`); process.exit(1); }
if (!good.ok || !isCleanDiagnosticsText(good.text)) { console.log(`FAIL: good.ts not clean; ok=${good.ok} text=${good.text}`); process.exit(1); }
console.log("PASS: handshake + bad.ts has diagnostics + good.ts clean");
EOF
echo "PASS: test-mcp-lsp-client"
