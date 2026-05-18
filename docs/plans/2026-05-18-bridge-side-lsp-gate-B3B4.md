# Bridge-side LSP Gate + Repair Loop (spec Phase B3+B4, §5.7/§5.7a/§5.7b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use sspower:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`). Strictly sequential — no parallel implementation subagents.

**Goal:** Implement the bridge-side LSP gate (the pulled-forward spec Phase B3+B4) that resolves the P2 B1 gap. The bridge speaks MCP **directly** to the vendored `codex-lsp` `mcp` server post-run, computes authoritative `_lsp` diagnostics over changed files, runs a bounded repair loop, and reports an advisory `_lsp.decision`. This sidesteps Codex 0.130.0's per-MCP-tool-call approval gate entirely (the bridge↔codex-lsp channel never traverses Codex's model tool path).

**Architecture:** A new isolated module `scripts/mcp-lsp-client.mjs` (minimal JSON-RPC-over-stdio MCP client) is spawned by `codex-bridge.mjs` after a Codex `implement`/`resume` run completes. It queries `diagnostics` per changed file, normalizes results into the `_lsp` schema field (bridge-computed, overrides Codex self-report per D-B1), and drives a ≤2-round repair loop via `codex exec resume`. Advisory-only (D-B6): default emits `_lsp.decision="would-block"` without failing the run; a user-flipped env (`SSPOWER_LSP_GATE_BLOCK=1`) promotes to `block`. Fail-OPEN everywhere (D-B7): any MCP/infra failure → `_lsp.status` ∈ {unavailable, skipped}, gate passes, logged.

**Tech Stack:** Node ESM, MCP JSON-RPC 2.0 over stdio (newline-delimited — see Measured Reality), vendored `tools/codex-lsp/dist/cli.js mcp`, `codex exec resume`, JSON Schema.

---

## Source & scope

- **Spec:** `docs/specs/2026-05-17-codex-worker-lsp-gate-design.md` v6 — §5.7, §5.7a, §5.7b; D-B1, D-B3, D-B6, D-B7.
- **Originating plan:** `docs/plans/2026-05-18-codex-worker-lsp-trackB-P2-P6.md` P3 roadmap section (B3+B4). Pulled into the active branch by explicit user decision (2026-05-18) because P2 T6 proved B1-via-Codex-model is unrecoverable without disabling the sandbox.
- **In scope:** `scripts/mcp-lsp-client.mjs`; `_lsp` schema fields; bridge post-run gate wired into `cmdImplement`; advisory/block split; bounded repair loop with the 7 §5.7b termination conditions; real dogfood.
- **Out of scope:** P4 (Codex Stop gate, rules/sandbox profiles), P5 (semble_rs), the B2 PostToolUse hook (already shipped in P2 T4), `_verification` (test-domain field — `_lsp` only here).
- **Branch:** `feat/codex-worker-trackB` (active). Commits standalone (chokepoint rule).

## Measured Reality (P2 T6 dogfood — supersedes spec assumptions where noted)

| Spec assumption | Measured (authoritative) |
|---|---|
| §5.7a "newline/Content-Length framing per MCP" | **Newline-delimited JSON-RPC** confirmed: standalone `node tools/codex-lsp/dist/cli.js mcp` answers `initialize`+`tools/list`+`tools/call` over `\n`-delimited frames, NO `Content-Length` headers. Implement newline framing ONLY. |
| §5.7a "send file URI; call lsp.diagnostics" | Tool is `diagnostics` on server `lsp`; arguments = `{ filePath: <absolute path string>, severity?: "error"|"warning"|"information"|"hint"|"all" }`. NOT a `textDocument`/URI param. `tools/call` params: `{ name: "diagnostics", arguments: { filePath, severity: "error" } }`. |
| MCP protocol version | `initialize` → `protocolVersion: "2024-11-05"`, `serverInfo: { name: "lsp", version: "0.1.0" }`, `capabilities.tools.listChanged: false`. |
| Latency | `initialize` ~44ms, `tools/call status` ~18ms cold. Per-file 30s / gate 120s caps are ample. |
| Clean signal | codex-lsp `diagnostics` returns `content:[{type:"text",text:"No diagnostics found"}]` (or `"No LSP server configured for extension:"` for unsupported) when clean — see Task 1 parser. |

## Decisions resolved during planning (authoritative)

| Topic | Decision | Reasoning |
|---|---|---|
| Framing | Newline-delimited JSON-RPC only | Measured; codex-lsp emits no Content-Length. Implementing both is dead code (YAGNI). |
| Block-mode env | `SSPOWER_LSP_GATE_BLOCK` (default unset = advisory) | Parallel to P2 T4's `SSPOWER_LSP_SELFREPAIR_BLOCK` (B2 hook) but distinct knob — the bridge gate (B3/B4) and the in-Codex hook (B2) are independent gates, independently promotable (D-B6 per-phase). |
| Diagnostics severity filter | Request `severity:"error"` per file | Gate decision is error-driven (§5.7b: "errors ⇒ would-block"). Warnings are noise for a blocking gate. |
| Changed-files source | `git -C <cd> diff --name-only <baseHead> HEAD` ∪ `git -C <cd> diff --name-only` (unstaged) ∪ untracked, filtered to source extensions codex-lsp supports | baseHead already snapshotted by `cmdImplement`. Post-run the Codex edits may be uncommitted (autoCommit runs AFTER the gate), so unstaged + untracked must be included. |
| Gate placement | In `cmdImplement`, AFTER `runCodexExec` returns, BEFORE the `autoCommit` block | §5.7a "post-run gate only"; §5.7b clean ⇒ proceed to auto-commit. Gate must run before commit so a repaired tree is what gets committed. |
| Source-file filter | Extensions from codex-lsp's own builtin map, capped at the ones with an installed server (query `status` once per gate, cache) | Avoids calling `diagnostics` on files with no LSP server (codex-lsp returns "No LSP server configured" — treat as skipped, not error). |
| Repair resume flags | `-c model_reasoning_effort="high"`, NO `--profile`, NO default `-m` | Spec §5.7b + D-A6 Finding 4: resume has no `--profile`; root config governs; no-flag resume must not emit default `-m`. Reuse existing `runCodexResume` (already correct per P1). |

---

# PHASE B3 — MCP stdio client + diagnostics normalization

### Task 1: `scripts/mcp-lsp-client.mjs` — minimal MCP-over-stdio client

**Files:**
- Create: `scripts/mcp-lsp-client.mjs`
- Create: `tests/codex-bridge/test-mcp-lsp-client.sh`

- [ ] **Step 1: Write the client**

Create `scripts/mcp-lsp-client.mjs`:
```javascript
// Minimal JSON-RPC-2.0-over-stdio MCP client for the vendored codex-lsp
// `mcp` server. Newline-delimited framing (measured: codex-lsp emits NO
// Content-Length headers). Single-purpose: spawn → initialize → call
// `diagnostics` per file → shutdown. Fail-OPEN: every error path resolves
// to a structured {status} object, never throws to the caller.
import { spawn } from "node:child_process";

const PROTOCOL_VERSION = "2024-11-05";

export class McpLspClient {
  constructor(cliPath, cwd) {
    this.cliPath = cliPath;
    this.cwd = cwd;
    this.child = null;
    this._buf = "";
    this._nextId = 1;
    this._pending = new Map(); // id -> {resolve, timer}
  }

  // Spawn `node <cli> mcp` and run the initialize handshake.
  // Returns true on success, false on any failure (fail-open).
  async start(initTimeoutMs = 15000) {
    try {
      this.child = spawn("node", [this.cliPath, "mcp"], {
        cwd: this.cwd,
        stdio: ["pipe", "pipe", "ignore"],
        env: { ...process.env },
      });
    } catch {
      return false;
    }
    this.child.on("error", () => this._failAll());
    this.child.stdout.setEncoding("utf8");
    this.child.stdout.on("data", (d) => this._onData(d));
    try {
      const res = await this._request("initialize", {
        protocolVersion: PROTOCOL_VERSION,
        capabilities: {},
        clientInfo: { name: "sspower-bridge", version: "1" },
      }, initTimeoutMs);
      if (!res || !res.result) return false;
      this._notify("notifications/initialized", {});
      return true;
    } catch {
      return false;
    }
  }

  // Call the codex-lsp `diagnostics` tool for one absolute file path.
  // severity defaults to "error". Returns { ok, text } — ok=false on
  // timeout/error (fail-open; caller treats as unavailable).
  async diagnostics(filePath, perCallTimeoutMs = 30000, severity = "error") {
    try {
      const res = await this._request("tools/call", {
        name: "diagnostics",
        arguments: { filePath, severity },
      }, perCallTimeoutMs);
      if (!res || res.error || !res.result) return { ok: false, text: "" };
      const text = (res.result.content || [])
        .filter((b) => b && b.type === "text")
        .map((b) => b.text)
        .join("\n");
      return { ok: true, text };
    } catch {
      return { ok: false, text: "" };
    }
  }

  // Explicit shutdown + process kill. Idempotent, never throws.
  async stop() {
    try { this._notify("notifications/cancelled", {}); } catch { /* ignore */ }
    try { this.child && this.child.kill("SIGTERM"); } catch { /* ignore */ }
    this._failAll();
  }

  _onData(chunk) {
    this._buf += chunk;
    let nl;
    while ((nl = this._buf.indexOf("\n")) >= 0) {
      const line = this._buf.slice(0, nl).trim();
      this._buf = this._buf.slice(nl + 1);
      if (!line) continue;
      let msg;
      try { msg = JSON.parse(line); } catch { continue; }
      if (msg.id != null && this._pending.has(msg.id)) {
        const { resolve, timer } = this._pending.get(msg.id);
        clearTimeout(timer);
        this._pending.delete(msg.id);
        resolve(msg);
      }
    }
  }

  _request(method, params, timeoutMs) {
    return new Promise((resolve) => {
      const id = this._nextId++;
      const timer = setTimeout(() => {
        if (this._pending.has(id)) {
          this._pending.delete(id);
          resolve(null); // fail-open: timeout → null, caller degrades
        }
      }, timeoutMs);
      this._pending.set(id, { resolve, timer });
      const ok = this._write({ jsonrpc: "2.0", id, method, params });
      if (!ok) {
        clearTimeout(timer);
        this._pending.delete(id);
        resolve(null);
      }
    });
  }

  _notify(method, params) {
    this._write({ jsonrpc: "2.0", method, params });
  }

  _write(obj) {
    try {
      if (!this.child || this.child.killed || !this.child.stdin.writable) return false;
      return this.child.stdin.write(JSON.stringify(obj) + "\n");
    } catch {
      return false;
    }
  }

  _failAll() {
    for (const { resolve, timer } of this._pending.values()) {
      clearTimeout(timer);
      resolve(null);
    }
    this._pending.clear();
  }
}

// Clean-diagnostics detection mirrors codex-lsp's own codex-hook.js:
// clean === empty, "No diagnostics found", or "No LSP server configured…".
export function isCleanDiagnosticsText(text) {
  const t = (text || "").trim();
  return (
    t.length === 0 ||
    t === "No diagnostics found" ||
    t.startsWith("No LSP server configured for extension:")
  );
}
```

- [ ] **Step 2: Unit test against the REAL vendored server (no mocks)**

Create `tests/codex-bridge/test-mcp-lsp-client.sh`:
```bash
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
const started = await c.start();
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
```

- [ ] **Step 3: Run it; verify**

Run: `chmod +x tests/codex-bridge/test-mcp-lsp-client.sh && bash tests/codex-bridge/test-mcp-lsp-client.sh`
Expected: ends `PASS: test-mcp-lsp-client`. (`bad.ts` produces a TS error via the builtin typescript server; `good.ts` is clean. Proves the bridge↔codex-lsp MCP round-trip works WITHOUT Codex's approval gate.)

- [ ] **Step 4: Bridge integrity**

Run: `node --check scripts/mcp-lsp-client.mjs`
Expected: no output, exit 0.

---

# PHASE B4 — `_lsp` schema + post-run gate + advisory/block + repair loop

### Task 2: `_lsp` schema fields — DO NOT ADD (corrected after B4 T2 dogfood)

**Files:**
- `schemas/implementation-output.json` — **leave UNMODIFIED**

**DO NOT add `_lsp` to `schemas/implementation-output.json`.**

Rationale: OpenAI strict structured-output (`codex exec --output-schema`) rejects optional properties — every property must be in `required` and `additionalProperties:true` is forbidden. `_lsp` is bridge-injected post-parse (cmdImplement sets `result.structured._lsp`) and is NEVER validated against the schema (`parseStructuredOutput` = plain JSON.parse, no ajv). Adding it to the schema file only breaks the Codex API call (invalid_json_schema 400). The spec §5.7 'schema gains _lsp' is realized at the runtime-object level, not the JSON-Schema-file level.

(The original B4 T2 premise — "`additionalProperties:false` would reject a bridge-added key, so `_lsp` MUST be declared" — was incorrect: there is no re-validation. A real dogfood proved adding `_lsp` 400s Codex in ~7s via `invalid_request_error / invalid_json_schema`. Making `_lsp` `required` to satisfy strict mode would wrongly force the model to emit it; optional properties are categorically rejected. There is no strict-compliant way to keep `_lsp` in the schema — so it stays out entirely.)

- [ ] **Step 1: Confirm `_lsp` is NOT in the schema**

Run: `node -e 'const s=require("./schemas/implementation-output.json");console.log("_lsp absent:", !("_lsp" in s.properties), "| root.required has all props:", s.required.length===Object.keys(s.properties).length)'`
Expected: `_lsp absent: true | root.required has all props: true`.

- [ ] **Step 2: Confirm schema is byte-identical to its pre-B4 state**

Run: `diff <(git show 294ee0b:schemas/implementation-output.json) schemas/implementation-output.json`
Expected: empty output (exit 0).

- [ ] **Step 3: Confirm no parser/test regression**

Run: `bash tests/codex-bridge/test-complete.sh`
Expected: still `PASS=14 FAIL=0`.

### Task 3: Post-run LSP gate in the bridge (advisory `_lsp`, no repair yet)

**Files:**
- Modify: `scripts/codex-bridge.mjs` (import the client; add `runLspGate`; wire into `cmdImplement`)

- [ ] **Step 1: Import + helper — locate seams**

Run: `grep -nE "import .* from \"./lib/codex-lsp-path|resolveCodexLspCli|function cmdImplement|baseHead = |const result = await runCodexExec|opts.autoCommit|cleanupTmpDir\(\)|function logEvent" scripts/codex-bridge.mjs | head`
Re-read `cmdImplement` fully (≈`grep -n 'async function cmdImplement'` → read to its `output(result` line) and `runCodexExec`'s return shape (`_spawnAndCapture` → `{ exitCode, structured, ... }`). The Task 5 (T5 of the prior plan) `resolveCodexLspCli` import already exists at the top — reuse it; do NOT re-import.

- [ ] **Step 2: Add the gate helper**

In `scripts/codex-bridge.mjs`, add an import near the existing local imports (after `import { resolveCodexLspCli } from "./lib/codex-lsp-path.mjs";`):
```javascript
import { McpLspClient, isCleanDiagnosticsText } from "./mcp-lsp-client.mjs";
```
Add this function just above `async function cmdImplement` (re-read surrounding style first):
```javascript
// Source extensions codex-lsp can serve (subset; safe superset is fine —
// files with no server return "No LSP server configured" → treated clean).
const LSP_SOURCE_EXT = new Set([
  ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts",
  ".py", ".pyi", ".rs", ".go", ".rb", ".swift", ".c", ".cpp", ".cc",
  ".cxx", ".h", ".hpp", ".sh", ".bash",
]);

// Changed source files (post-run, pre-commit): committed-since-baseHead
// ∪ unstaged ∪ untracked, filtered to LSP-serviceable extensions.
function lspChangedFiles(cwd, baseHead) {
  const run = (args) => {
    try {
      return execFileSync("git", ["-C", cwd, ...args], {
        encoding: "utf8", stdio: ["ignore", "pipe", "ignore"],
      }).split("\n").map((s) => s.trim()).filter(Boolean);
    } catch { return []; }
  };
  const set = new Set();
  if (baseHead) for (const f of run(["diff", "--name-only", baseHead, "HEAD"])) set.add(f);
  for (const f of run(["diff", "--name-only"])) set.add(f);
  for (const f of run(["diff", "--name-only", "--cached"])) set.add(f);
  for (const f of run(["ls-files", "--others", "--exclude-standard"])) set.add(f);
  const out = [];
  for (const rel of set) {
    const dot = rel.lastIndexOf(".");
    if (dot < 0) continue;
    if (!LSP_SOURCE_EXT.has(rel.slice(dot).toLowerCase())) continue;
    out.push(path.resolve(cwd, rel));
  }
  return out;
}

// Post-run bridge LSP gate. Returns the _lsp object (always — fail-open).
// blockMode = SSPOWER_LSP_GATE_BLOCK==="1".
async function runLspGate(cwd, baseHead, blockMode) {
  const base = {
    status: "skipped", decision: "clean",
    checked_files: [], total_errors: 0, errors: [], repair_rounds: 0,
  };
  const cli = resolveCodexLspCli();
  if (!cli) {
    logEvent("info", "bridge.lsp", { kind: "gate_skipped_unresolved" });
    return base;
  }
  const files = lspChangedFiles(cwd, baseHead);
  if (files.length === 0) {
    logEvent("info", "bridge.lsp", { kind: "gate_no_source_files" });
    return { ...base, status: "clean", decision: "clean" };
  }
  const client = new McpLspClient(cli, cwd);
  const gateDeadline = Date.now() + 120000; // §5.7a whole-gate 120s cap
  const started = await client.start();
  if (!started) {
    await client.stop();
    logEvent("warn", "bridge.lsp", { kind: "gate_unavailable_init" });
    return { ...base, status: "unavailable" };
  }
  const errors = [];
  const checked = [];
  try {
    for (const f of files) {
      if (Date.now() > gateDeadline) {
        logEvent("warn", "bridge.lsp", { kind: "gate_timeout_cap", checked: checked.length });
        await client.stop();
        return { ...base, status: "unavailable", checked_files: checked };
      }
      const remaining = Math.max(1000, gateDeadline - Date.now());
      const { ok, text } = await client.diagnostics(f, Math.min(30000, remaining));
      checked.push(f);
      if (!ok) {
        await client.stop();
        logEvent("warn", "bridge.lsp", { kind: "gate_unavailable_call", file: f });
        return { ...base, status: "unavailable", checked_files: checked };
      }
      if (!isCleanDiagnosticsText(text)) errors.push({ file: f, text });
    }
  } finally {
    await client.stop();
  }
  if (errors.length === 0) {
    logEvent("info", "bridge.lsp", { kind: "gate_clean", files: checked.length });
    return { ...base, status: "clean", decision: "clean", checked_files: checked };
  }
  const decision = blockMode ? "block" : "would-block";
  logEvent("info", "bridge.lsp", {
    kind: "gate_errors", decision, files: checked.length, errs: errors.length,
  });
  return {
    status: "errors", decision,
    checked_files: checked, total_errors: errors.length, errors, repair_rounds: 0,
  };
}
```

- [ ] **Step 3: Wire into `cmdImplement` (gate before auto-commit)**

In `cmdImplement`, immediately AFTER `const result = await runCodexExec(...)` returns and BEFORE the `if (result.exitCode === 0 && ... opts.autoCommit)` block, insert:
```javascript
  // Bridge-side LSP gate (D-B1: bridge-computed _lsp overrides Codex
  // self-report). Advisory by default (D-B6); fail-open (D-B7).
  if (result.structured && (workDir || opts.cd)) {
    const blockMode = process.env.SSPOWER_LSP_GATE_BLOCK === "1";
    const _lsp = await runLspGate(path.resolve(workDir || opts.cd), baseHead, blockMode);
    result.structured._lsp = _lsp;
    if (blockMode && _lsp.decision === "block") {
      result.structured.status = "BLOCKED";
      result.structured.blocked_reason =
        `LSP gate: ${_lsp.total_errors} error(s) in ${_lsp.checked_files.length} file(s)`;
    }
  }
```
(`baseHead` is already in scope from the existing snapshot. Re-read to confirm the variable name; if the snapshot is absent `baseHead` is `null` → `lspChangedFiles` still returns unstaged+untracked, correct.)

- [ ] **Step 4: `--print-args` parity unaffected; integrity**

Run: `node --check scripts/codex-bridge.mjs && node scripts/codex-bridge.mjs implement --print-args --prompt noop --cd /tmp 2>/dev/null | python3 -c 'import json,sys;json.load(sys.stdin);print("print-args still parses")'`
Expected: `print-args still parses` (the gate runs at execution, not arg-assembly — dry-run path untouched).

- [ ] **Step 5: Advisory-mode integration test (real codex-lsp, no Codex run)**

Create `tests/codex-bridge/test-lsp-gate.sh`:
```bash
#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
git -C "$WORK" init -q
printf 'export const x: number = "bad";\n' > "$WORK/bad.ts"
# Drive runLspGate directly via a tiny harness importing the bridge's
# exported helper. Export it for testing (Step 6 makes it importable).
node - "$ROOT" "$WORK" <<'EOF'
const [,, ROOT, WORK] = process.argv;
const m = await import(`${ROOT}/scripts/codex-bridge.mjs`);
const _lsp = await m.__test_runLspGate(WORK, null, false);
if (_lsp.status !== "errors") { console.log(`FAIL: expected errors, got ${JSON.stringify(_lsp)}`); process.exit(1); }
if (_lsp.decision !== "would-block") { console.log(`FAIL: advisory must be would-block, got ${_lsp.decision}`); process.exit(1); }
console.log("PASS: advisory gate -> status=errors decision=would-block");
EOF
echo "PASS: test-lsp-gate"
```

- [ ] **Step 6: Export the helper for testability**

At the bottom of `scripts/codex-bridge.mjs`, near any existing test exports (grep `__test`); if none, add (guarded, no behavior change):
```javascript
export { runLspGate as __test_runLspGate };
```
Re-read the file end first; if it is a CLI-only module with a `main()` dispatch, add the export at top level (ESM named export is inert for CLI use). Then run: `chmod +x tests/codex-bridge/test-lsp-gate.sh && bash tests/codex-bridge/test-lsp-gate.sh`
Expected: ends `PASS: test-lsp-gate`.

### Task 4: Bounded repair loop (§5.7b — 7 termination conditions)

**Files:**
- Modify: `scripts/codex-bridge.mjs` (`runLspRepairLoop`; call it from `cmdImplement` when advisory/block errors and a resumable session exists)

- [ ] **Step 1: Re-read the resume + registry seams**

Run: `grep -nE "function runCodexResume|registry.readState|session_id|_meta|ephemeral: false|function cmdImplement" scripts/codex-bridge.mjs | head`
Confirm `runCodexExec` for implement uses `ephemeral:false` (session resumable) and `result.structured._meta.session_id` carries the id. Re-read `registry.readState` return shape (status field values: `running`/`killed`/`stale`/`done`).

- [ ] **Step 2: Add the repair loop**

Add above `cmdImplement`:
```javascript
// Bounded LSP repair loop (§5.7b / D-B7). ≤2 resume rounds. Terminates on
// ANY of the 7 spec conditions. Returns the final _lsp (decision updated).
// Fail-open: any infra error ends the loop with the current _lsp.
async function runLspRepairLoop(cwd, baseHead, sessionId, _lsp, blockMode) {
  if (!sessionId) return _lsp;                         // cond 4: missing session
  let prevErrHash = "";
  for (let round = 1; round <= 2; round++) {           // cond 1: ≤2 rounds
    // cond 6: pre-resume registry concurrency check
    let rec = null;
    try { rec = registry.readState(sessionId); } catch { rec = null; }
    if (rec && ["running", "killed", "stale"].includes(rec.status)) {
      logEvent("warn", "bridge.lsp", { kind: "repair_abort_registry", status: rec.status, round });
      return { ..._lsp, repair_rounds: round - 1 };
    }
    // cond 7: HEAD drift
    let headBefore = null;
    try {
      headBefore = execFileSync("git", ["-C", cwd, "rev-parse", "HEAD"], {
        encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
    } catch { headBefore = null; }
    if (baseHead && headBefore && headBefore !== baseHead && round === 1) {
      logEvent("warn", "bridge.lsp", { kind: "repair_abort_head_drift", baseHead, headBefore });
      return { ..._lsp, repair_rounds: 0 };
    }
    const diffBefore = lspDiffHash(cwd);
    const errHash = lspErrHash(_lsp.errors);
    if (errHash && errHash === prevErrHash) {           // cond 3: same diagnostics
      logEvent("info", "bridge.lsp", { kind: "repair_stop_same_diag", round });
      return { ..._lsp, repair_rounds: round - 1 };
    }
    prevErrHash = errHash;
    const fileList = _lsp.errors.map((e) => e.file).join(", ");
    const repairPrompt =
      `LSP reports error-severity diagnostics after your edits. Fix ONLY these so the language server is clean. Do not change unrelated code. Files: ${fileList}\n\n` +
      _lsp.errors.map((e) => `--- ${e.file} ---\n${e.text}`).join("\n\n");
    let rr;
    try {
      rr = await runCodexResume(repairPrompt, {
        sessionId, effort: "high", schemaName: "implementation-output", cd: cwd, lspMcp: true,
      });
    } catch {
      logEvent("warn", "bridge.lsp", { kind: "repair_resume_threw", round });
      return { ..._lsp, repair_rounds: round };          // fail-open
    }
    if (!rr || rr.exitCode !== 0) {                       // cond 5: nonzero resume
      logEvent("warn", "bridge.lsp", { kind: "repair_resume_nonzero", round, code: rr && rr.exitCode });
      return { ..._lsp, repair_rounds: round };
    }
    if (lspDiffHash(cwd) === diffBefore) {                // cond 2: no progress
      logEvent("info", "bridge.lsp", { kind: "repair_stop_no_progress", round });
      return { ..._lsp, repair_rounds: round };
    }
    const re = await runLspGate(cwd, baseHead, blockMode);
    re.repair_rounds = round;
    if (re.status === "clean") {
      logEvent("info", "bridge.lsp", { kind: "repair_converged", round });
      return re;                                          // decision=clean
    }
    _lsp = re;                                            // loop with new errors
  }
  logEvent("info", "bridge.lsp", { kind: "repair_exhausted" });
  return { ..._lsp, repair_rounds: 2 };
}

function lspDiffHash(cwd) {
  try {
    const h = require("node:crypto").createHash("sha1");
    h.update(execFileSync("git", ["-C", cwd, "diff", "HEAD"], {
      encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }));
    // git diff HEAD ignores untracked files, but the gate checks them
    // (lspChangedFiles unions ls-files --others). Hash untracked contents
    // too, else a repair that only edits an untracked file looks like
    // "no progress" (cond-2 false-positive → premature loop abort).
    const others = execFileSync("git", ["-C", cwd, "ls-files", "--others", "--exclude-standard"], {
      encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] })
      .split("\n").map((s) => s.trim()).filter(Boolean).sort();
    for (const rel of others) {
      h.update("\0" + rel + "\0");
      try { h.update(fs.readFileSync(path.join(cwd, rel))); } catch { /* gone/binbig: name only */ }
    }
    return h.digest("hex");
  } catch { return ""; }
}
function lspErrHash(errs) {
  try {
    const key = (errs || []).map((e) => e.file + "|" + (e.text || "")).sort().join("\n");
    return require("node:crypto").createHash("sha1").update(key).digest("hex");
  } catch { return ""; }
}
```
(`require` is already available — `createRequire` at bridge top, line ~31. Reuse it; do not re-create. `fs`/`path` are already imported — reuse, do not add imports.)
> Note: hashes untracked file contents too — the gate (lspChangedFiles) checks untracked files, so a diff-HEAD-only hash would false-positive cond-2 (no-progress) when a repair edits an untracked file.

- [ ] **Step 3: Invoke the loop from `cmdImplement`**

Replace the Task 3 Step 3 inserted block's tail so that, when the gate returns `status==="errors"` and a session id exists, the loop runs and its result replaces `_lsp`:
```javascript
  if (result.structured && (workDir || opts.cd)) {
    const cwdAbs = path.resolve(workDir || opts.cd);
    const blockMode = process.env.SSPOWER_LSP_GATE_BLOCK === "1";
    let _lsp = await runLspGate(cwdAbs, baseHead, blockMode);
    if (_lsp.status === "errors") {
      const sid = result.sessionId || result.structured?._meta?.session_id || null;
      _lsp = await runLspRepairLoop(cwdAbs, baseHead, sid, _lsp, blockMode);
    }
    result.structured._lsp = _lsp;
    if (blockMode && _lsp.decision === "block") {
      result.structured.status = "BLOCKED";
      result.structured.blocked_reason =
        `LSP gate: ${_lsp.total_errors} error(s) after ${_lsp.repair_rounds} repair round(s)`;
    }
  }
```
> Note: `result.sessionId` (set in _spawnAndCapture) is the primary source — `_meta.session_id` is stamped later in output(), after the gate, so it is undefined here.
> Implementation extracts this via a shared `_extractSid(result)` helper (exported for test) so the production path and unit test share one source of truth.

- [ ] **Step 4: Termination unit test (no real Codex — stub the resume seam)**

Create `tests/codex-bridge/test-lsp-repair-termination.sh`:
```bash
#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
git -C "$WORK" init -q
node - "$ROOT" "$WORK" <<'EOF'
const [,, ROOT, WORK] = process.argv;
const m = await import(`${ROOT}/scripts/codex-bridge.mjs`);
// cond 4: missing session id → loop returns input _lsp unchanged, 0 rounds.
const inp = { status:"errors", decision:"would-block", checked_files:["x"], total_errors:1, errors:[{file:"x",text:"err"}], repair_rounds:0 };
const out = await m.__test_runLspRepairLoop(WORK, null, null, inp, false);
if (out.repair_rounds !== 0 || out.status !== "errors") { console.log(`FAIL cond4: ${JSON.stringify(out)}`); process.exit(1); }
console.log("PASS: cond4 missing-session terminates with 0 rounds");
EOF
echo "PASS: test-lsp-repair-termination"
```
Add the matching export at the bottom of `scripts/codex-bridge.mjs`:
```javascript
export { runLspRepairLoop as __test_runLspRepairLoop };
```
Run: `chmod +x tests/codex-bridge/test-lsp-repair-termination.sh && bash tests/codex-bridge/test-lsp-repair-termination.sh`
Expected: ends `PASS: test-lsp-repair-termination`.

### Task 5: Real end-to-end dogfood (mandatory — not dry-run)

- [ ] **Step 1: Seeded-error gate + repair convergence (real Codex resume)**

```bash
D=$(mktemp -d)
git -C "$D" init -q
git -C "$D" commit -q --allow-empty -m init
printf 'export const x: number = "not a number";\n' > "$D/bad.ts"
node scripts/codex-bridge.mjs implement --write --cd "$D" --prompt "Create a file ok.ts exporting a const greeting:string = \"hi\". Do not touch bad.ts." > /tmp/b3-dogfood.log 2>&1
echo "EXIT=$?"
grep -iE 'bridge.lsp|gate_|repair_|_lsp|would-block|clean' /tmp/b3-dogfood.log | tail -20
python3 -c 'import json,sys,re; t=open("/tmp/b3-dogfood.log").read(); j=t[t.rfind("{"):]; d=json.loads(j); print("_lsp=",json.dumps(d.get("_lsp"),indent=2))' 2>/dev/null || tail -5 /tmp/b3-dogfood.log
```
Expected: run exit 0; `result._lsp` present; because `bad.ts` is a pre-existing changed file with a type error and the prompt did NOT ask to fix it, `_lsp.status="errors"`, `_lsp.decision="would-block"` (advisory — run NOT blocked, `status` stays `DONE`); `bridge.lsp` events logged. This proves the bridge-direct MCP gate works **without** Codex's approval gate (the P2 B1 blocker is resolved).

- [ ] **Step 2: Clean run → decision=clean**

```bash
D=$(mktemp -d); git -C "$D" init -q; git -C "$D" commit -q --allow-empty -m init
node scripts/codex-bridge.mjs implement --write --cd "$D" --prompt "Create good.ts exporting: export const n: number = 42;" > /tmp/b3-clean.log 2>&1
echo "EXIT=$?"; grep -iE 'gate_clean|"decision": ?"clean"|_lsp' /tmp/b3-clean.log | tail -8
```
Expected: exit 0; `_lsp.status="clean"`, `_lsp.decision="clean"`; gate_clean logged.

- [ ] **Step 3: Update ARCHITECTURE.md — B1 resolved**

In `docs/ARCHITECTURE.md` "Codex LSP self-repair" section, append a subsection "B1 resolution (bridge-side gate, B3+B4)" stating: the bridge now queries codex-lsp's `mcp` server directly via `scripts/mcp-lsp-client.mjs` post-run (newline-delimited JSON-RPC), computing authoritative `_lsp` over changed files; this **sidesteps Codex 0.130.0's per-tool-call approval gate** (the documented P2 T6 blocker) because the bridge↔codex-lsp channel never traverses Codex's model tool path; advisory default (`SSPOWER_LSP_GATE_BLOCK=1` promotes to block); ≤2-round repair loop per §5.7b; fail-open per D-B7. State that spec §9 P2/P3 clause 1 ("lsp.status smoke passes") is now **met via the bridge gate**, not the in-Codex MCP path.

### Task 6: Commit (standalone — chokepoint)

- [ ] **Step 1: Stage**

Run: `git add scripts/mcp-lsp-client.mjs scripts/codex-bridge.mjs schemas/implementation-output.json tests/codex-bridge/test-mcp-lsp-client.sh tests/codex-bridge/test-lsp-gate.sh tests/codex-bridge/test-lsp-repair-termination.sh docs/ARCHITECTURE.md && git status --porcelain`
Expected: only those paths staged; no `docs/plans/*`.

- [ ] **Step 2: Commit**

```bash
git commit -m "feat(b3): bridge-side LSP gate + repair loop — direct codex-lsp MCP client, advisory _lsp, sidesteps Codex tool-approval (resolves P2 B1)"
```
Expected: succeeds (standalone; not a push).

---

## Verification matrix (acceptance — spec §5.7/§5.7a/§5.7b)

| Criterion | Command | Expected |
|---|---|---|
| MCP client round-trip | `bash tests/codex-bridge/test-mcp-lsp-client.sh` | `PASS: test-mcp-lsp-client` |
| Schema valid + optional | `bash tests/codex-bridge/test-complete.sh` | `PASS=14 FAIL=0` |
| Advisory gate verdict | `bash tests/codex-bridge/test-lsp-gate.sh` | `PASS` (status=errors, decision=would-block) |
| Repair termination | `bash tests/codex-bridge/test-lsp-repair-termination.sh` | `PASS` (cond 4: 0 rounds) |
| Real dogfood (errors) | Task 5 Step 1 | exit 0, `_lsp.decision="would-block"`, run NOT blocked |
| Real dogfood (clean) | Task 5 Step 2 | exit 0, `_lsp.decision="clean"` |
| Bridge integrity | `node --check scripts/codex-bridge.mjs && node --check scripts/mcp-lsp-client.mjs` | exit 0 |
| Approval-gate sidestep proven | Task 5 Step 1 log | `gate_*` events present, NO "user cancelled MCP tool call" (bridge path, not Codex model path) |

## Risks & assumptions

- **R1 — codex-lsp wire behavior could change on a future vendored bump.** Mitigated: pinned `05e8f07` (PROVENANCE.md); the client fails-open (`start()`/`diagnostics()` return falsy → `_lsp.status` unavailable/skipped, gate passes).
- **R2 — `diagnostics` may spawn a real language server (slow cold-start).** Mitigated: per-file 30s, whole-gate 120s caps; timeout → unavailable (fail-open). Measured `status` ~18ms; first real `diagnostics` on a TS file pays the typescript-language-server cold start once (<30s observed in Task 1 test).
- **R3 — repair `resume` concurrency with `steer`.** Mitigated: §5.7b cond 6 pre-resume registry check aborts on running/killed/stale.
- **R4 — advisory only (D-B6).** `SSPOWER_LSP_GATE_BLOCK` defaults unset; no run is failed until the user flips it after reviewing clean advisory runs. Distinct from B2's `SSPOWER_LSP_SELFREPAIR_BLOCK`.
- **R5 — HEAD drift / autoCommit ordering.** Gate runs before `autoCommit`; `autoCommit` already refuses on HEAD change vs baseHead. Repair loop cond 7 also aborts on drift. No double-commit.
- **Assumption — Codex tier stays default/`fast`.** No code here sets `service_tier` ([[project-codex-service-tier-flex-unsupported]]); resume uses `-c model_reasoning_effort="high"` only (D-A6 Finding 4 compliant).

## Execution Handoff

**Plan complete. Three execution options:**
1. **Subagent-Driven (recommended)** → sspower:subagent-driven-development (Tasks 1→6, strictly sequential, spec-review then quality-review each)
2. **Inline Execution** → sspower:executing-plans
3. **Codex execute** → `codex-bridge.mjs implement --write`

**Which approach?**
