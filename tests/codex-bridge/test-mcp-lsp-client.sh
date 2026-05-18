#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLI="$ROOT/tools/codex-lsp/dist/cli.js"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# Seeded TS error file + a clean file.
printf 'export const x: number = "nope";\n' > "$WORK/bad.ts"
printf 'export const y: number = 1;\n' > "$WORK/good.ts"

# Hermetic stub MCP server: speaks the newline-JSON protocol, ignores the
# `mcp` argv the client passes, and returns a canned diagnostics result whose
# shape is driven by env STUB_MODE (missing_dependency | no_files | clean).
cat > "$WORK/stub-mcp.mjs" <<'STUB'
let buf = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (d) => {
  buf += d;
  let nl;
  while ((nl = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (!line) continue;
    let m;
    try { m = JSON.parse(line); } catch { continue; }
    if (m.method === "initialize") {
      process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: m.id, result: { protocolVersion: "2024-11-05", capabilities: {}, serverInfo: { name: "stub", version: "1" } } }) + "\n");
    } else if (m.method === "tools/call") {
      const mode = process.env.STUB_MODE;
      let result;
      if (mode === "missing_dependency") {
        result = { content: [{ type: "text", text: "LSP server 'x' is configured but NOT INSTALLED." }], details: { errorKind: "missing_dependency" }, isError: false };
      } else if (mode === "no_files") {
        result = { content: [{ type: "text", text: "No source files found in directory." }], details: { errorKind: "no_files" }, isError: false };
      } else {
        result = { content: [{ type: "text", text: "No diagnostics found" }], isError: false };
      }
      process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: m.id, result }) + "\n");
    }
    // notifications (id absent) need no reply
  }
});
STUB

node - "$ROOT" "$CLI" "$WORK" <<'EOF'
const [,, ROOT, CLI, WORK] = process.argv;
const { McpLspClient, isCleanDiagnosticsText } = await import(`${ROOT}/scripts/mcp-lsp-client.mjs`);

// --- Real vendored server: handshake + bad.ts has diagnostics + good.ts clean
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

// --- Stub server: missing_dependency must fail-open (ok:false)
const stub = `${WORK}/stub-mcp.mjs`;
async function stubDiag(mode) {
  process.env.STUB_MODE = mode;
  const s = new McpLspClient(stub, WORK);
  const ok = await s.start(15000);
  if (!ok) { console.log(`FAIL: stub(${mode}) handshake failed`); process.exit(1); }
  const r = await s.diagnostics(`${WORK}/bad.ts`);
  await s.stop();
  return r;
}
const miss = await stubDiag("missing_dependency");
if (miss.ok !== false) { console.log(`FAIL: missing_dependency not fail-open; ok=${miss.ok} text=${miss.text}`); process.exit(1); }
console.log("PASS: missing_dependency response is fail-open (ok:false)");

const nofiles = await stubDiag("no_files");
if (nofiles.ok !== false) { console.log(`FAIL: no_files not fail-open; ok=${nofiles.ok} text=${nofiles.text}`); process.exit(1); }
console.log("PASS: no_files response is fail-open (ok:false)");

const norm = await stubDiag("clean");
if (!norm.ok || !isCleanDiagnosticsText(norm.text)) { console.log(`FAIL: normal diagnostics not ok/clean; ok=${norm.ok} text=${norm.text}`); process.exit(1); }
console.log("PASS: normal diagnostics still returns ok:true and clean");

// --- Unit: text-only NOT INSTALLED signal is treated clean (belt-and-suspenders)
if (isCleanDiagnosticsText("LSP server 'x' is configured but NOT INSTALLED.") !== true) {
  console.log("FAIL: isCleanDiagnosticsText did not treat NOT INSTALLED text as clean");
  process.exit(1);
}
console.log("PASS: isCleanDiagnosticsText('...NOT INSTALLED...') === true");
EOF
echo "PASS: test-mcp-lsp-client"
