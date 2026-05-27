# sspower-graph P3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `sspower:subagent-driven-development` (recommended) or `sspower:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the P0 MCP stub with a full 7-tool MCP server, ship a per-project session-state harness + adoption-metric reconciler, update 3 reviewer agents with role-tuned graph-tool guidance.

**Architecture:** A pure-data query layer (`scripts/graph/queries.mjs`) is extracted from the existing CLI handlers. Both the CLI verbs and the per-tool MCP handlers (`scripts/graph/mcp-tools/<tool>.mjs`) call this shared layer. The MCP request handler also calls `recordEvent()` from `scripts/graph/mcp-tools/metric.mjs`, which appends to a per-process-pid spool JSONL keyed by per-project session id (read from `~/.claude/state/sspower/sessions/<sha8(realpath(cwd))>.json` written by `hooks/session-start`). A new `SessionEnd` reconciler merges spool files into `sessions.json`. The bootstrap is amended to preserve caller cwd (P3-D8).

**Tech Stack:** Node ≥22.5, `@modelcontextprotocol/sdk`, `node:sqlite`, bun (lockfile), vitest harness for fixture goldens, bash hooks, `sspower_mem.lock.acquire_lock` Python helper.

**Spec:** `docs/specs/2026-05-27-codegraph-graph-P3-design.md` @ `1af85cf` (Codex `approve`).

**Phase budget:** 5 task-days (T1..T5). Anti-goal at 10 task-days or any of 6 §9 triggers.

---

## File map

| Action | Path | Reason |
|---|---|---|
| Modify | `bin/sspower-graph-bootstrap.sh` | P3-D8: drop top-level `cd $ROOT`, subshell install |
| Modify | `bin/sspower-graph.mjs` | replace stub `runMcpServer()` with dispatcher; CLI handlers call extracted query layer |
| Create | `scripts/graph/queries.mjs` | pure-data query functions (callers, callees, trace, impact, node, context, status) |
| Create | `scripts/graph/mcp-tools/index.mjs` | TOOLS array + dispatch |
| Create | `scripts/graph/mcp-tools/{status,callers,callees,trace,impact,node,context}.mjs` | one handler per MCP tool |
| Create | `scripts/graph/mcp-tools/metric.mjs` | `recordEvent` + `reconcile` + aggregator |
| Create | `scripts/graph/session-state.mjs` | read per-project session-state file w/ cwd validation |
| Modify | `hooks/session-start` | write per-project state file from stdin JSON payload |
| Create | `hooks/graph-metric-reconcile.sh` | SessionEnd hook → metric.mjs reconcile |
| Modify | `hooks/hooks.json` | append reconcile entry to SessionEnd array |
| Modify | `agents/code-reviewer.md` | append `## Graph tool guidance` |
| Modify | `agents/sanity-reviewer.md` | append `## Graph tool guidance` |
| Modify | `agents/security-reviewer.md` | append `## Graph tool guidance` |
| Create | `tests/graph/test-session-state-contract.mjs` | T1 gate |
| Create | `tests/graph/test-mcp-tools-unit.mjs` | per-handler unit tests |
| Modify | `tests/graph/test-mcp-stub.mjs` | extend to 7 tools |
| Create | `tests/graph/test-mcp-metric-zerocall.mjs` | zero-call eligible session |
| Create | `tests/graph/test-mcp-metric-concurrency.mjs` | 50 parallel calls |
| Create | `tests/graph/test-mcp-metric.mjs` | reconciler + aggregator unit |
| Create | `tests/graph/test-p2-cli-back-compat.mjs` | byte-identical CLI `--json` regression |
| Create | `tests/graph/perf-mcp.mjs` | per-tool p95 latency (opt-in) |
| Create | `tests/graph/regenerate-cli-goldens.sh` | regen P2 goldens when intentionally shifting CLI output |
| Modify | `package.json` | bump `version` to `1.4.0-rc.0` (rc) → `1.4.0` at T5 |
| Create | `docs/plans/notes/2026-05-27-graph-P3-adoption-snapshot.json` | T5 captured metric output |
| Modify | `ARCHITECTURE.md` | mark P3 shipped (T5) |
| Modify | `CLAUDE.md` | P3 row in sspower-graph subsystem section (T5) |

---

# T1 — Bootstrap fix + scaffolding + session-state contract (1 task-day)

## Task 1: Bootstrap cwd-preservation fix (P3-D8)

**Files:**
- Modify: `bin/sspower-graph-bootstrap.sh:5-39`

- [ ] **Step 1: Write failing assertion**

Create `tests/graph/test-bootstrap-cwd.mjs`:

```js
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import url from 'node:url';
const PLUGIN_ROOT = path.resolve(url.fileURLToPath(import.meta.url), '../../..');
const FIXTURE = path.join(PLUGIN_ROOT, '__tests__', 'graph-fixtures', 'ts-js');
const r = spawnSync('bash', [path.join(PLUGIN_ROOT, 'bin', 'sspower-graph-bootstrap.sh'), '-p', 'process.cwd()'], {
  cwd: FIXTURE,
  env: { ...process.env, CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT, NODE: process.execPath },
  encoding: 'utf8',
});
assert.equal(r.status, 0, `bootstrap exit=${r.status} stderr=${r.stderr}`);
assert.equal(r.stdout.trim(), FIXTURE, `expected cwd preserved (${FIXTURE}) got (${r.stdout.trim()})`);
console.log('OK');
```

(`bootstrap.sh -p <expr>` exec'd via node `-p` lets us print `process.cwd()` from the spawned MCP-server cwd without touching MCP wiring.)

Wait — bootstrap exec's `node bin/sspower-graph.mjs "$@"`. We need to print cwd. Adjust: add a temporary diag verb to the CLI just for this test, OR exec a one-shot node `-p` instead of the CLI. Simpler: modify the test to invoke `NODE` directly via the bootstrap-emulated cwd-equality, using a small inline script that bootstraps just the cwd-check. The test below uses the actual MCP CLI's `status` verb and asserts the printed cwd path matches via a new internal-only flag `--print-cwd`.

Revised test approach: add a hidden CLI verb `--print-cwd` to `bin/sspower-graph.mjs` that prints `process.cwd()` and exits 0. The bootstrap test then invokes the bootstrap with that flag and asserts cwd equals the spawning cwd. The flag is documented in `bin/sspower-graph.mjs` as test-only.

- [ ] **Step 2: Add `--print-cwd` debug flag**

In `bin/sspower-graph.mjs` after `const cmd = argv[0];`:

```js
if (cmd === '--print-cwd') {
  process.stdout.write(process.cwd());
  process.exit(0);
}
```

- [ ] **Step 3: Run test — expect FAIL**

```bash
node tests/graph/test-bootstrap-cwd.mjs
```

Expected: assertion failure — stdout = `$PLUGIN_ROOT`, not `$FIXTURE`. This proves the existing `cd "$ROOT"` bug.

- [ ] **Step 4: Apply the fix**

Replace `bin/sspower-graph-bootstrap.sh` lines 5-39 with:

```bash
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

NODE_BIN="${NODE:-node}"
if ! command -v "$NODE_BIN" >/dev/null 2>&1; then
  echo "sspower-graph: node not found on PATH (need >=22.5)" >&2
  exit 127
fi
NODE_VER=$("$NODE_BIN" -p 'process.versions.node' 2>/dev/null || echo 0)
NODE_MAJOR=$("$NODE_BIN" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
NODE_MINOR=$("$NODE_BIN" -p 'process.versions.node.split(".")[1]' 2>/dev/null || echo 0)
if [ "$NODE_MAJOR" -lt 22 ] || { [ "$NODE_MAJOR" -eq 22 ] && [ "$NODE_MINOR" -lt 5 ]; }; then
  echo "sspower-graph: node v$NODE_VER too old; need >=22.5 (node:sqlite stable surface)" >&2
  exit 1
fi

if [ ! -d "$ROOT/node_modules/@modelcontextprotocol" ]; then
  if ! command -v bun >/dev/null 2>&1; then
    echo "sspower-graph: bun required for first-run install (matches bun.lock)" >&2
    echo "  install: https://bun.sh — or pre-populate node_modules from another machine" >&2
    exit 127
  fi
  ( cd "$ROOT" && \
    ( bun install --frozen-lockfile --production --silent >/dev/null 2>&1 \
      || bun install --frozen-lockfile --production >&2 ) )
fi

exec "$NODE_BIN" "$ROOT/bin/sspower-graph.mjs" "$@"
```

Difference: `cd "$ROOT"` removed from script-process level; bun install wrapped in `( … )` subshell that scopes the cd; exec runs from caller cwd.

- [ ] **Step 5: Run test — expect PASS**

```bash
node tests/graph/test-bootstrap-cwd.mjs
```

Expected: `OK`.

- [ ] **Step 6: Commit**

```bash
git add bin/sspower-graph-bootstrap.sh bin/sspower-graph.mjs tests/graph/test-bootstrap-cwd.mjs
git commit -F /tmp/commit-msg-t1-bootstrap.txt
```

Where `/tmp/commit-msg-t1-bootstrap.txt` contains:

```
fix(graph): bootstrap preserves caller cwd (P3-D8)

cd $ROOT moved into a subshell scoping the bun install only; exec
runs from caller cwd. Without this, MCP process.cwd() collapsed to
plugin root, breaking per-project session-state lookup (P3-D4).

Test tests/graph/test-bootstrap-cwd.mjs spawns the bootstrap from a
fixture project and asserts process.cwd() matches.
```

---

## Task 2: Per-project session-state file written by SessionStart hook

**Files:**
- Modify: `hooks/session-start` (existing file)
- Create: `scripts/graph/session-state.mjs`

- [ ] **Step 1: Read current hooks/session-start to find insertion point**

```bash
grep -n "session_id\|cwd\|stdin\|exit 0" hooks/session-start | head
```

- [ ] **Step 2: Write `scripts/graph/session-state.mjs`** (read + validate)

```js
// scripts/graph/session-state.mjs
// Per-project session-state file lookup; load-bearing for P3 metric.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import os from 'node:os';

export const STATE_DIR = path.join(os.homedir(), '.claude', 'state', 'sspower', 'sessions');
export const STALE_MS = 24 * 60 * 60 * 1000;

export function projectHash(cwd) {
  const real = fs.realpathSync(cwd);
  return crypto.createHash('sha256').update(real).digest('hex').slice(0, 16);
}

export function statePathFor(cwd) {
  return path.join(STATE_DIR, `${projectHash(cwd)}.json`);
}

export function readSessionState(cwd) {
  let stat, buf;
  try { stat = fs.statSync(statePathFor(cwd)); }
  catch { return { sessionId: null, source: 'missing' }; }
  if (Date.now() - stat.mtimeMs > STALE_MS) return { sessionId: null, source: 'stale' };
  try { buf = fs.readFileSync(statePathFor(cwd), 'utf8'); }
  catch { return { sessionId: null, source: 'unreadable' }; }
  let rec;
  try { rec = JSON.parse(buf); }
  catch { return { sessionId: null, source: 'bad_json' }; }
  if (!rec.session_id || !rec.cwd) return { sessionId: null, source: 'missing_fields' };
  let recReal, mcpReal;
  try { recReal = fs.realpathSync(rec.cwd); mcpReal = fs.realpathSync(cwd); }
  catch { return { sessionId: null, source: 'cwd_unresolvable' }; }
  if (recReal !== mcpReal) return { sessionId: null, source: 'cwd_mismatch' };
  return { sessionId: rec.session_id, source: 'claude_session_id', startedTs: rec.started_ts };
}
```

- [ ] **Step 3: Patch `hooks/session-start`** to write the state file

Add after sspower's existing init steps (before the final `exit 0`):

```bash
# P3: write per-project session-state file from stdin JSON payload.
# Stdin already consumed by previous steps? Check existing hook flow.
# If stdin still available — read here. Otherwise stash earlier in the hook.
if [ -n "${SSPOWER_HOOK_STDIN:-}" ]; then
  PAYLOAD="$SSPOWER_HOOK_STDIN"
else
  PAYLOAD="$(cat)"
fi
SID="$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null)"
CWD="$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty' 2>/dev/null)"
SRC="$(printf '%s' "$PAYLOAD" | jq -r '.source // \"unknown\"' 2>/dev/null)"
if [ -n "$SID" ] && [ -n "$CWD" ]; then
  STATE_DIR="$HOME/.claude/state/sspower/sessions"
  mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
  HASH="$(printf '%s' "$(realpath "$CWD" 2>/dev/null || echo "$CWD")" | shasum -a 256 | head -c 16)"
  TMP="$STATE_DIR/.$HASH.tmp.$$"
  cat > "$TMP" <<EOF
{"session_id":"$SID","cwd":"$CWD","started_ts":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","hook_event_name":"SessionStart","source":"$SRC"}
EOF
  chmod 600 "$TMP"
  mv -f "$TMP" "$STATE_DIR/$HASH.json"
fi
```

**Note:** if `hooks/session-start` already consumes stdin upstream, stash it into `SSPOWER_HOOK_STDIN` at the top of the file before any other parser uses it.

- [ ] **Step 4: Unit test for session-state.mjs**

Create `tests/graph/test-session-state-unit.mjs`:

```js
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { readSessionState, statePathFor, projectHash } from '../../scripts/graph/session-state.mjs';

const T = fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-test-'));
const realT = fs.realpathSync(T);

// 1. Missing file
let r = readSessionState(realT);
assert.equal(r.sessionId, null);
assert.equal(r.source, 'missing');

// 2. Valid file
fs.mkdirSync(path.dirname(statePathFor(realT)), { recursive: true });
fs.writeFileSync(statePathFor(realT), JSON.stringify({
  session_id: '01HXY', cwd: realT, started_ts: new Date().toISOString(),
}));
r = readSessionState(realT);
assert.equal(r.sessionId, '01HXY');
assert.equal(r.source, 'claude_session_id');

// 3. cwd mismatch
fs.writeFileSync(statePathFor(realT), JSON.stringify({
  session_id: '01HXZ', cwd: '/some/other/path', started_ts: new Date().toISOString(),
}));
r = readSessionState(realT);
assert.equal(r.sessionId, null);
assert.equal(r.source, 'cwd_unresolvable');

// 4. Stale
const valid = JSON.stringify({ session_id: '01HXX', cwd: realT, started_ts: new Date().toISOString() });
fs.writeFileSync(statePathFor(realT), valid);
const past = (Date.now() - 25 * 60 * 60 * 1000) / 1000;
fs.utimesSync(statePathFor(realT), past, past);
r = readSessionState(realT);
assert.equal(r.sessionId, null);
assert.equal(r.source, 'stale');

console.log('OK');
```

- [ ] **Step 5: Run unit test**

```bash
node tests/graph/test-session-state-unit.mjs
```

Expected: `OK`.

- [ ] **Step 6: Commit**

```
feat(graph): per-project session-state file (P3-D4)

scripts/graph/session-state.mjs reads ~/.claude/state/sspower/sessions/
<sha8(realpath(cwd))>.json with cwd-equality validation and stale-mtime
fallback. hooks/session-start writes the file from stdin JSON payload
(session_id + cwd + source). Per-project keying prevents the global-file
race when two Claude sessions run in different projects concurrently.
```

---

## Task 3: Session-state contract integration test (T2 gate)

**Files:**
- Create: `tests/graph/test-session-state-contract.mjs`

- [ ] **Step 1: Write the test** — invoke hooks/session-start with simulated CC stdin payload, then assert MCP server (via bootstrap) reads back correctly.

```js
// tests/graph/test-session-state-contract.mjs
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawnSync } from 'node:child_process';
import url from 'node:url';
import { statePathFor, readSessionState } from '../../scripts/graph/session-state.mjs';

const PLUGIN_ROOT = path.resolve(url.fileURLToPath(import.meta.url), '../../..');
const FIXTURE_A = fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-ctr-a-'));
const FIXTURE_B = fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-ctr-b-'));
fs.mkdirSync(path.join(FIXTURE_A, '.claude', 'graph'), { recursive: true });
fs.mkdirSync(path.join(FIXTURE_B, '.claude', 'graph'), { recursive: true });

function runHook(cwd, sessionId) {
  const payload = JSON.stringify({
    session_id: sessionId, cwd, source: 'startup',
    hook_event_name: 'SessionStart', transcript_path: '/dev/null',
  });
  const r = spawnSync('bash', [path.join(PLUGIN_ROOT, 'hooks', 'session-start')], {
    input: payload, encoding: 'utf8',
    env: { ...process.env, CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT },
  });
  assert.equal(r.status, 0, `session-start failed: ${r.stderr}`);
}

// 1. Single project: write + read
runHook(FIXTURE_A, '01-SESSION-A');
const realA = fs.realpathSync(FIXTURE_A);
const rA = readSessionState(realA);
assert.equal(rA.sessionId, '01-SESSION-A', `expected A; got ${JSON.stringify(rA)}`);

// 2. Two projects, no overwrite
runHook(FIXTURE_B, '01-SESSION-B');
const rA2 = readSessionState(realA);
const rB  = readSessionState(fs.realpathSync(FIXTURE_B));
assert.equal(rA2.sessionId, '01-SESSION-A', 'project A overwritten by project B');
assert.equal(rB.sessionId,  '01-SESSION-B');

// 3. MCP server spawned via bootstrap from FIXTURE_A reads project A's id
const probe = spawnSync('bash', [
  path.join(PLUGIN_ROOT, 'bin', 'sspower-graph-bootstrap.sh'),
  '--probe-session',
], {
  cwd: FIXTURE_A,
  env: { ...process.env, CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT, NODE: process.execPath },
  encoding: 'utf8',
});
assert.equal(probe.status, 0, `probe stderr=${probe.stderr}`);
assert.equal(probe.stdout.trim(), '01-SESSION-A');

console.log('OK');
```

- [ ] **Step 2: Add `--probe-session` flag to `bin/sspower-graph.mjs`** (test-only)

After `--print-cwd` handler:

```js
if (cmd === '--probe-session') {
  const { readSessionState } = await import('../scripts/graph/session-state.mjs');
  const r = readSessionState(process.cwd());
  if (!r.sessionId) { process.stderr.write(`degraded source=${r.source}\n`); process.exit(2); }
  process.stdout.write(r.sessionId);
  process.exit(0);
}
```

- [ ] **Step 3: Run — expect PASS (Task 1 + Task 2 already shipped)**

```bash
node tests/graph/test-session-state-contract.mjs
```

If fail: **STOP — fire §9 anti-goal trigger 2 (session-state hook contract failure)**. The metric harness in T2 depends on this contract.

- [ ] **Step 4: Commit**

```
test(graph): session-state contract end-to-end (T1 gate)

Asserts (1) SessionStart hook writes per-project state file,
(2) concurrent fixture projects do not overwrite each other,
(3) MCP server spawned via bootstrap from project cwd reads back
the correct session id. T2 metric harness depends on this test
passing — failure trips §9 anti-goal trigger 2.
```

---

## Task 4: Extract pure query layer (`scripts/graph/queries.mjs`)

**Files:**
- Create: `scripts/graph/queries.mjs`
- Modify: `bin/sspower-graph.mjs` (refactor `runCallers/runCallees/runTrace/runImpact/runContext/runNode/runStatus` to delegate)

- [ ] **Step 1: Inventory existing handler shape**

Each existing handler in `bin/sspower-graph.mjs` has the pattern:

```js
async function runX(opts, ...args) {
  const cwd = opts.cwd ?? process.cwd();
  const graphDir = graphDirFor(cwd);
  await withDb(graphDir, db => {
    const result = /* query logic */;
    emit(opts, result, /* pretty formatter */);
  });
}
```

We extract the *query logic* into pure functions in `queries.mjs` that return plain JSON-serializable data. Existing CLI handlers become 3 lines (resolve cwd, call query, emit).

- [ ] **Step 2: Create `scripts/graph/queries.mjs`**

**Extraction procedure** (every function follows the same pattern — extract verbatim from `bin/sspower-graph.mjs`):

| New `queries.mjs` export | Source in `bin/sspower-graph.mjs` (lines) | Extract |
|---|---|---|
| `queryStatus(cwd)` | `runStatus`, ~253-265 | the `withDb` body that computes counts + lastIndexed |
| `queryCallers(cwd, name, opts)` | `runCallers`, ~221-234 | the SELECT-build + result-shape logic |
| `queryCallees(cwd, name, opts)` | `runCallees`, ~235-243 | same shape, inverse edge direction |
| `queryTrace(cwd, from, to, opts)` | `runTrace`, ~193-201 | BFS path logic |
| `queryImpact(cwd, filePath)` | `runImpact`, ~202-211 | reverse-import closure |
| `queryNode(cwd, name)` | `runNode`, ~244-252 | symbol-source lookup |
| `queryContext(cwd, task)` | `runContext`, ~212-220 | composed search+node+callers; clamp task.length to 500 in queries.mjs (CLI never had this clamp; safe to add since field is free-form) |

Module header + first two functions concretely:

```js
// scripts/graph/queries.mjs
import { graphDirFor, withDb } from './db.mjs';

export async function queryStatus(cwd) {
  const dir = graphDirFor(cwd);
  return withDb(dir, db => {
    // Body extracted verbatim from bin/sspower-graph.mjs runStatus
    // (lines ~253-265 — the part inside withDb that computes the
    // fileCount/nodeCount/edgeCount/dirtyCount/lastIndexed object).
    // Return that object directly instead of passing to emit().
  });
}

export async function queryCallers(cwd, name, { limit = 50, disambiguate = false } = {}) {
  const dir = graphDirFor(cwd);
  return withDb(dir, db => {
    // Body extracted verbatim from bin/sspower-graph.mjs runCallers
    // (lines ~221-234). Return { name, callers, limit, disambiguate,
    // truncated } — same shape the existing emit(opts, result, ...)
    // sees in JSON mode.
  });
}

export async function queryContext(cwd, task) {
  if (typeof task !== 'string') throw new Error('task must be string');
  if (task.length > 500) task = task.slice(0, 500);  // defensive clamp
  const dir = graphDirFor(cwd);
  return withDb(dir, db => {
    // Body extracted from runContext.
  });
}
```

Repeat the same shape for `queryCallees / queryTrace / queryImpact / queryNode`. Each function returns the **exact JSON object** the existing CLI `--json` mode emits — the back-compat regression test in Task 22 is the truth oracle: any byte-diff fails the gate.

- [ ] **Step 3: Extract `scripts/graph/db.mjs`**

Promote `withDb` + `graphDirFor` from `bin/sspower-graph.mjs` into a shared module so both `queries.mjs` and `bin/sspower-graph.mjs` import the same implementation.

```js
// scripts/graph/db.mjs
import { DatabaseSync } from 'node:sqlite';
import path from 'node:path';
import fs from 'node:fs';

export function graphDirFor(cwd) {
  return path.join(cwd, '.claude', 'graph');
}

export async function withDb(graphDir, fn) {
  const dbPath = path.join(graphDir, 'index.sqlite');
  if (!fs.existsSync(dbPath)) throw new Error(`graph index missing at ${dbPath}`);
  const db = new DatabaseSync(dbPath, { readOnly: true });
  try { return await fn(db); } finally { db.close(); }
}
```

- [ ] **Step 4: Refactor existing CLI handlers in `bin/sspower-graph.mjs`**

Replace `runCallers/runCallees/...` with delegators:

```js
import { queryCallers, queryCallees, queryTrace, queryImpact, queryNode, queryContext, queryStatus } from '../scripts/graph/queries.mjs';

async function runCallers(opts, name) {
  const cwd = opts.cwd ?? process.cwd();
  const result = await queryCallers(cwd, name, { limit: opts.limit ?? 50, disambiguate: !!opts.disambiguate });
  emit(opts, result, p => p.callers.map(c => `${c.qname}\t${c.file}:${c.line}`).join('\n'));
}
// repeat for callees/trace/impact/node/context/status
```

- [ ] **Step 5: Run existing P2 CLI tests** (must stay green)

```bash
bun run graph:tests
```

Expected: 21 green.

- [ ] **Step 6: Commit**

```
refactor(graph): extract pure-data query layer (P3-D5)

scripts/graph/queries.mjs holds queryCallers/queryCallees/queryTrace/
queryImpact/queryNode/queryContext/queryStatus. No emit, no exit —
returns plain JSON. scripts/graph/db.mjs shared between CLI and MCP.
bin/sspower-graph.mjs CLI handlers become thin delegators. P2 CLI
output byte-identical (verified by existing graph:tests).
```

---

## Task 5: MCP server scaffolding refactor (dispatcher + TOOLS array)

**Files:**
- Modify: `bin/sspower-graph.mjs:267-287` (replace stub)
- Create: `scripts/graph/mcp-tools/index.mjs`

- [ ] **Step 1: Create `scripts/graph/mcp-tools/index.mjs`**

```js
// scripts/graph/mcp-tools/index.mjs
import { TOOL as statusTool,  handler as statusHandler  } from './status.mjs';
import { TOOL as callersTool, handler as callersHandler } from './callers.mjs';
import { TOOL as calleesTool, handler as calleesHandler } from './callees.mjs';
import { TOOL as traceTool,   handler as traceHandler   } from './trace.mjs';
import { TOOL as impactTool,  handler as impactHandler  } from './impact.mjs';
import { TOOL as nodeTool,    handler as nodeHandler    } from './node.mjs';
import { TOOL as ctxTool,     handler as ctxHandler     } from './context.mjs';

export const TOOLS = [statusTool, callersTool, calleesTool, traceTool, impactTool, nodeTool, ctxTool];

const HANDLERS = {
  graph_status:   statusHandler,
  graph_callers:  callersHandler,
  graph_callees:  calleesHandler,
  graph_trace:    traceHandler,
  graph_impact:   impactHandler,
  graph_node:     nodeHandler,
  graph_context:  ctxHandler,
};

export async function dispatch(name, args) {
  const fn = HANDLERS[name];
  if (!fn) throw new Error(`unknown tool: ${name}`);
  const payload = await fn(args ?? {});
  return { content: [{ type: 'text', text: JSON.stringify(payload) }] };
}
```

- [ ] **Step 2: Replace `runMcpServer()` in `bin/sspower-graph.mjs:267-287`**

```js
async function runMcpServer() {
  const { Server } = await import('@modelcontextprotocol/sdk/server/index.js');
  const { StdioServerTransport } = await import('@modelcontextprotocol/sdk/server/stdio.js');
  const { ListToolsRequestSchema, CallToolRequestSchema } = await import('@modelcontextprotocol/sdk/types.js');
  const { TOOLS, dispatch } = await import('../scripts/graph/mcp-tools/index.mjs');
  const { recordEvent } = await import('../scripts/graph/mcp-tools/metric.mjs');

  const server = new Server({ name: 'sspower-graph', version: PKG_VERSION }, { capabilities: { tools: {} } });
  server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOLS }));
  server.setRequestHandler(CallToolRequestSchema, async ({ params }) => {
    const t0 = Date.now();
    let ok = true;
    try {
      const result = await dispatch(params.name, params.arguments);
      return result;
    } catch (e) {
      ok = false;
      throw e;
    } finally {
      try { recordEvent({ tool: params.name, ok, duration_ms: Date.now() - t0, cwd: process.cwd() }); }
      catch (e) { process.stderr.write(`metric write failed: ${e.message}\n`); }
    }
  });
  await server.connect(new StdioServerTransport());
}
```

- [ ] **Step 3: Run existing MCP smoke test** (still only tests `graph_status` stub at this point, but listTools should return 7 entries now)

```bash
node tests/graph/test-mcp-stub.mjs
```

Will likely fail on `assert.equal(tools.tools[0].name, 'graph_status')` if order isn't deterministic. Either fix the assertion to be order-insensitive, or set TOOLS order with `graph_status` first. Order TOOLS array with `status` first to keep the assertion working until Task 12 rewrites this test.

- [ ] **Step 4: Commit**

```
feat(graph): MCP dispatcher scaffolding (P3-D5)

scripts/graph/mcp-tools/index.mjs registers TOOLS array and a
dispatch() function. Each tool module exports TOOL + handler. The
MCP server's CallToolRequest handler routes through dispatch and
records a metric event (best-effort, never throws). Handlers wired
in Tasks 6-11.
```

---

## Task 6: `graph_status` MCP handler

**Files:**
- Create: `scripts/graph/mcp-tools/status.mjs`
- Modify: `tests/graph/test-mcp-tools-unit.mjs` (creates it on first task)

- [ ] **Step 1: Write failing unit test**

Create `tests/graph/test-mcp-tools-unit.mjs`:

```js
import assert from 'node:assert/strict';
import path from 'node:path';
import url from 'node:url';
const PLUGIN_ROOT = path.resolve(url.fileURLToPath(import.meta.url), '../../..');
const FIXTURE = path.join(PLUGIN_ROOT, '__tests__', 'graph-fixtures', 'ts-js');

import { handler as statusHandler } from '../../scripts/graph/mcp-tools/status.mjs';
const r = await statusHandler({ cwd: FIXTURE });
assert.equal(typeof r.fileCount, 'number');
assert.ok(r.fileCount > 0, `expected fixture files in ${FIXTURE}`);
console.log('graph_status OK');
```

- [ ] **Step 2: Run — expect FAIL** (module missing)

```bash
node tests/graph/test-mcp-tools-unit.mjs
```

Expected: `ERR_MODULE_NOT_FOUND`.

- [ ] **Step 3: Implement**

```js
// scripts/graph/mcp-tools/status.mjs
import { queryStatus } from '../queries.mjs';

export const TOOL = {
  name: 'graph_status',
  description: 'Graph index freshness — node/edge counts, dirty queue size, last indexed timestamp.',
  inputSchema: {
    type: 'object',
    properties: { cwd: { type: 'string' } },
    required: [],
  },
};

export async function handler(args) {
  const cwd = args.cwd ?? process.cwd();
  return queryStatus(cwd);
}
```

- [ ] **Step 4: Run — expect PASS**

```bash
node tests/graph/test-mcp-tools-unit.mjs
```

Expected: `graph_status OK`.

- [ ] **Step 5: Commit**

```
feat(graph): graph_status MCP handler (P3-D1 first of 7)
```

---

## Task 7: `graph_callers` MCP handler

**Files:**
- Create: `scripts/graph/mcp-tools/callers.mjs`
- Modify: `tests/graph/test-mcp-tools-unit.mjs`

- [ ] **Step 1: Append to test**

```js
import { handler as callersHandler } from '../../scripts/graph/mcp-tools/callers.mjs';
const c = await callersHandler({ cwd: FIXTURE, name: 'fnA', limit: 10 });
assert.ok(Array.isArray(c.callers), 'callers array');
assert.equal(c.name, 'fnA');
assert.ok(c.limit === 10);
console.log('graph_callers OK');
```

(`fnA` is a known symbol in the ts-js fixture; verify in `__tests__/graph-fixtures/ts-js/expected/`.)

- [ ] **Step 2: Implement**

```js
// scripts/graph/mcp-tools/callers.mjs
import { queryCallers } from '../queries.mjs';

export const TOOL = {
  name: 'graph_callers',
  description: 'Callers of a function/method/class. Use qualified names ("Module.fn", "Type::method") to disambiguate.',
  inputSchema: {
    type: 'object',
    properties: {
      name: { type: 'string', minLength: 1, description: 'Symbol name; qualified preferred.' },
      limit: { type: 'integer', minimum: 1, maximum: 200, default: 50 },
      disambiguate: { type: 'boolean', default: false },
      cwd: { type: 'string' },
    },
    required: ['name'],
  },
};

export async function handler(args) {
  if (!args.name) throw new Error('graph_callers: name is required');
  const cwd = args.cwd ?? process.cwd();
  const limit = Math.min(args.limit ?? 50, 200);
  return queryCallers(cwd, args.name, { limit, disambiguate: !!args.disambiguate });
}
```

- [ ] **Step 3: Run + commit**

```bash
node tests/graph/test-mcp-tools-unit.mjs
git add -A && git commit -F /tmp/commit-msg-t7.txt
```

Commit msg:

```
feat(graph): graph_callers MCP handler
```

---

## Task 8: `graph_callees` MCP handler

**Files:**
- Create: `scripts/graph/mcp-tools/callees.mjs`

- [ ] **Step 1: Append test**

```js
import { handler as calleesHandler } from '../../scripts/graph/mcp-tools/callees.mjs';
const cc = await calleesHandler({ cwd: FIXTURE, name: 'fnA' });
assert.ok(Array.isArray(cc.callees));
console.log('graph_callees OK');
```

- [ ] **Step 2: Implement** (mirror callers, swap query function + remove `disambiguate`)

```js
import { queryCallees } from '../queries.mjs';
export const TOOL = {
  name: 'graph_callees',
  description: 'Functions called by the named symbol.',
  inputSchema: {
    type: 'object',
    properties: {
      name: { type: 'string', minLength: 1 },
      limit: { type: 'integer', minimum: 1, maximum: 200, default: 50 },
      cwd: { type: 'string' },
    },
    required: ['name'],
  },
};
export async function handler(args) {
  if (!args.name) throw new Error('graph_callees: name is required');
  const cwd = args.cwd ?? process.cwd();
  return queryCallees(cwd, args.name, { limit: Math.min(args.limit ?? 50, 200) });
}
```

- [ ] **Step 3: Run + commit**

```
feat(graph): graph_callees MCP handler
```

---

## Task 9: `graph_trace` MCP handler

**Files:**
- Create: `scripts/graph/mcp-tools/trace.mjs`

- [ ] **Step 1: Append test**

```js
import { handler as traceHandler } from '../../scripts/graph/mcp-tools/trace.mjs';
const t = await traceHandler({ cwd: FIXTURE, from: 'fnA', to: 'fnC', maxHops: 4 });
assert.ok('path' in t || 'paths' in t, 'trace returns path field');
console.log('graph_trace OK');
```

- [ ] **Step 2: Implement**

```js
import { queryTrace } from '../queries.mjs';
export const TOOL = {
  name: 'graph_trace',
  description: 'Shortest call path between two symbols (BFS, max 10 hops).',
  inputSchema: {
    type: 'object',
    properties: {
      from: { type: 'string', minLength: 1 },
      to:   { type: 'string', minLength: 1 },
      maxHops: { type: 'integer', minimum: 1, maximum: 10, default: 6 },
      cwd: { type: 'string' },
    },
    required: ['from', 'to'],
  },
};
export async function handler(args) {
  if (!args.from || !args.to) throw new Error('graph_trace: from and to are required');
  const cwd = args.cwd ?? process.cwd();
  return queryTrace(cwd, args.from, args.to, { maxHops: Math.min(args.maxHops ?? 6, 10) });
}
```

- [ ] **Step 3: Run + commit**

```
feat(graph): graph_trace MCP handler
```

---

## Task 10: `graph_impact` MCP handler

**Files:**
- Create: `scripts/graph/mcp-tools/impact.mjs`

- [ ] **Step 1: Append test**

```js
import { handler as impactHandler } from '../../scripts/graph/mcp-tools/impact.mjs';
const i = await impactHandler({ cwd: FIXTURE, file: 'src/a.ts' });
assert.ok(Array.isArray(i.symbols));
console.log('graph_impact OK');
```

- [ ] **Step 2: Implement**

```js
import { queryImpact } from '../queries.mjs';
export const TOOL = {
  name: 'graph_impact',
  description: 'Symbol-level + transitive impact for a file (reverse-import closure).',
  inputSchema: {
    type: 'object',
    properties: {
      file: { type: 'string', minLength: 1, description: 'Path relative to project cwd.' },
      cwd:  { type: 'string' },
    },
    required: ['file'],
  },
};
export async function handler(args) {
  if (!args.file) throw new Error('graph_impact: file is required');
  const cwd = args.cwd ?? process.cwd();
  return queryImpact(cwd, args.file);
}
```

- [ ] **Step 3: Run + commit**

```
feat(graph): graph_impact MCP handler
```

---

## Task 11: `graph_node` + `graph_context` MCP handlers

**Files:**
- Create: `scripts/graph/mcp-tools/node.mjs`
- Create: `scripts/graph/mcp-tools/context.mjs`

- [ ] **Step 1: Append tests**

```js
import { handler as nodeHandler } from '../../scripts/graph/mcp-tools/node.mjs';
const n = await nodeHandler({ cwd: FIXTURE, name: 'fnA' });
assert.ok(n.source && typeof n.source === 'string');
console.log('graph_node OK');

import { handler as ctxHandler } from '../../scripts/graph/mcp-tools/context.mjs';
const ctx = await ctxHandler({ cwd: FIXTURE, task: 'add caching to fnA' });
assert.ok(ctx && (Array.isArray(ctx.nodes) || Array.isArray(ctx.candidates)));
console.log('graph_context OK');

// Length clamp
let threw = false;
try { await ctxHandler({ cwd: FIXTURE, task: 'x'.repeat(501) }); } catch { threw = true; }
assert.ok(threw, 'graph_context did not clamp task length');
console.log('graph_context clamp OK');
```

- [ ] **Step 2: Implement node.mjs**

```js
import { queryNode } from '../queries.mjs';
export const TOOL = {
  name: 'graph_node',
  description: 'Full source for one symbol.',
  inputSchema: {
    type: 'object',
    properties: { name: { type: 'string', minLength: 1 }, cwd: { type: 'string' } },
    required: ['name'],
  },
};
export async function handler(args) {
  if (!args.name) throw new Error('graph_node: name is required');
  return queryNode(args.cwd ?? process.cwd(), args.name);
}
```

- [ ] **Step 3: Implement context.mjs** (with task-length clamp)

```js
import { queryContext } from '../queries.mjs';
export const TOOL = {
  name: 'graph_context',
  description: 'Compose search + node + callers for a task description. task is free-form, max 500 chars.',
  inputSchema: {
    type: 'object',
    properties: {
      task: { type: 'string', minLength: 1, maxLength: 500 },
      cwd:  { type: 'string' },
    },
    required: ['task'],
  },
};
export async function handler(args) {
  if (!args.task) throw new Error('graph_context: task is required');
  if (args.task.length > 500) throw new Error('graph_context: task length exceeds 500 chars');
  return queryContext(args.cwd ?? process.cwd(), args.task);
}
```

- [ ] **Step 4: Run + commit**

```
feat(graph): graph_node + graph_context MCP handlers

Completes the 7-tool surface (P3-D1). graph_context clamps task to
500 chars to keep caller subagent token budgets bounded.
```

T1 done. Commit checkpoint.

---

# T2 — Metric harness (1 task-day)

## Task 12: `recordEvent` (per-process spool JSONL, appendFileSync)

**Files:**
- Create: `scripts/graph/mcp-tools/metric.mjs` (first half — `recordEvent` only)

- [ ] **Step 1: Write failing test**

Create `tests/graph/test-mcp-metric.mjs`:

```js
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { recordEvent, SPOOL_DIR } from '../../scripts/graph/mcp-tools/metric.mjs';

const real = fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-metric-'));
// Inject a state file so recordEvent picks up a known session id
import { statePathFor } from '../../scripts/graph/session-state.mjs';
fs.mkdirSync(path.dirname(statePathFor(real)), { recursive: true });
fs.writeFileSync(statePathFor(real), JSON.stringify({
  session_id: 'metric-test-sid', cwd: real, started_ts: new Date().toISOString(),
}));

// Use chdir to fake MCP cwd
const orig = process.cwd();
process.chdir(real);
recordEvent({ tool: 'graph_status', ok: true, duration_ms: 12, cwd: real });
recordEvent({ tool: 'graph_callers', ok: false, duration_ms: 99, cwd: real });
process.chdir(orig);

const files = fs.readdirSync(SPOOL_DIR).filter(f => f.startsWith('metric-test-sid.'));
assert.equal(files.length, 1, `expected 1 spool file, got ${files.length}`);
const lines = fs.readFileSync(path.join(SPOOL_DIR, files[0]), 'utf8').trim().split('\n');
assert.equal(lines.length, 2);
const e1 = JSON.parse(lines[0]);
assert.equal(e1.tool, 'graph_status');
assert.equal(e1.ok, true);
assert.equal(e1.schema, 1);
console.log('recordEvent OK');
```

- [ ] **Step 2: Run — expect FAIL** (module missing)

- [ ] **Step 3: Implement**

```js
// scripts/graph/mcp-tools/metric.mjs
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { readSessionState } from '../session-state.mjs';

export const SPOOL_DIR = path.join(os.homedir(), '.claude', 'state', 'sspower', 'graph-mcp');
const MAX_RECORD_BYTES = 4096;

function ensureSpool() {
  fs.mkdirSync(SPOOL_DIR, { recursive: true, mode: 0o700 });
}

function degradedId(cwd) {
  const seed = `${process.pid}:${os.uptime()}:${cwd}`;
  return 'deg-' + crypto.createHash('sha256').update(seed).digest('hex').slice(0, 12);
}

let cachedSid = null;
let cachedSource = null;
function resolveSession(cwd) {
  // Cached per process — session id does not change inside one MCP server lifetime.
  if (cachedSid) return { sid: cachedSid, source: cachedSource };
  const r = readSessionState(cwd);
  if (r.sessionId) {
    cachedSid = r.sessionId;
    cachedSource = 'claude_session_id';
  } else {
    cachedSid = degradedId(cwd);
    cachedSource = 'degraded:' + r.source;
  }
  return { sid: cachedSid, source: cachedSource };
}

export function recordEvent({ tool, ok, duration_ms, cwd }) {
  ensureSpool();
  const { sid, source } = resolveSession(cwd);
  const record = JSON.stringify({
    ts: new Date().toISOString(),
    tool, ok: !!ok, duration_ms, cwd,
    session_source: source,
    schema: 1,
  }) + '\n';
  if (Buffer.byteLength(record, 'utf8') > MAX_RECORD_BYTES) {
    // Truncate cwd if oversized — extremely unlikely
    const trimmed = JSON.stringify({
      ts: new Date().toISOString(), tool, ok: !!ok, duration_ms,
      cwd: cwd.slice(-200), session_source: source, schema: 1, truncated: true,
    }) + '\n';
    fs.appendFileSync(path.join(SPOOL_DIR, `${sid}.${process.pid}.jsonl`), trimmed, { mode: 0o600 });
    return;
  }
  fs.appendFileSync(path.join(SPOOL_DIR, `${sid}.${process.pid}.jsonl`), record, { mode: 0o600 });
}
```

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit**

```
feat(graph): recordEvent metric writer (P3-D6)

Per-process spool ~/.claude/state/sspower/graph-mcp/<sid>.<pid>.jsonl.
appendFileSync inside the MCP single-thread event loop serializes
intra-process writes; pid suffix eliminates cross-process contention.
Session id cached per-process from session-state.mjs; falls back to
sha8(pid:uptime:cwd) prefixed "deg-" when state file unavailable.
4KB record cap with cwd truncation fallback.
```

---

## Task 13: SessionEnd reconciler hook + hooks.json registration

**Files:**
- Create: `hooks/graph-metric-reconcile.sh`
- Modify: `hooks/hooks.json:110-121`

- [ ] **Step 1: Create the hook script**

```bash
#!/usr/bin/env bash
# P3 graph-metric-reconcile: merges per-session spool jsonl into sessions.json.
set -euo pipefail
PAYLOAD="$(cat)"
SID="$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null)"
CWD="$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty' 2>/dev/null)"
END_REASON="$(printf '%s' "$PAYLOAD" | jq -r '.reason // empty' 2>/dev/null)"
[ -z "$SID" ] || [ -z "$CWD" ] && exit 0
node "$CLAUDE_PLUGIN_ROOT/scripts/graph/mcp-tools/metric.mjs" \
  reconcile --session "$SID" --cwd "$CWD" ${END_REASON:+--reason "$END_REASON"} || true
exit 0
```

Make executable: `chmod +x hooks/graph-metric-reconcile.sh`.

- [ ] **Step 2: Modify `hooks/hooks.json:110-121`**

Replace the existing `SessionEnd` array with the v2 form:

```json
"SessionEnd": [
  {
    "matcher": "*",
    "hooks": [
      {
        "type": "command",
        "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/wiki-archive.sh\"",
        "async": true
      },
      {
        "type": "command",
        "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/graph-metric-reconcile.sh\"",
        "async": false,
        "timeout": 5
      }
    ]
  }
]
```

- [ ] **Step 3: Validate JSON**

```bash
jq . hooks/hooks.json > /dev/null
```

Expected: exit 0 (valid).

- [ ] **Step 4: Commit**

```
feat(graph): SessionEnd reconciler hook + registration

hooks/graph-metric-reconcile.sh parses CC stdin payload, extracts
session_id + cwd + reason, invokes metric.mjs reconcile. hooks.json
appends the entry to the existing SessionEnd array (wiki-archive
entry preserved verbatim, matcher "*", quoted command); reconciler
is async:false with 5s timeout so the metric write completes before
session shutdown.
```

---

## Task 14: `metric.mjs reconcile` (merge spool, lock, write sessions.json)

**Files:**
- Modify: `scripts/graph/mcp-tools/metric.mjs` (append reconcile logic)

- [ ] **Step 1: Append failing test to `tests/graph/test-mcp-metric.mjs`**

```js
// Reconcile path
import { reconcile, SESSIONS_PATH } from '../../scripts/graph/mcp-tools/metric.mjs';
// Wipe sessions.json for clean test
if (fs.existsSync(SESSIONS_PATH)) fs.rmSync(SESSIONS_PATH);
await reconcile({ session: 'metric-test-sid', cwd: real, reason: 'user_exit' });
const sj = JSON.parse(fs.readFileSync(SESSIONS_PATH, 'utf8'));
assert.equal(sj.sessions.length, 1);
assert.equal(sj.sessions[0].session_id, 'metric-test-sid');
assert.equal(sj.sessions[0].tool_calls, 2);
assert.equal(sj.sessions[0].eligible, false, 'no .claude/graph/ in tmp = ineligible');
console.log('reconcile OK');
```

Then enable eligibility:

```js
fs.mkdirSync(path.join(real, '.claude', 'graph'), { recursive: true });
fs.writeFileSync(path.join(real, '.claude', 'graph', 'index.sqlite'), '');
// Reset by removing prior row's source spool and re-recording
fs.rmSync(SESSIONS_PATH);
process.chdir(real);
recordEvent({ tool: 'graph_status', ok: true, duration_ms: 1, cwd: real });
process.chdir(orig);
await reconcile({ session: 'metric-test-sid', cwd: real, reason: 'user_exit' });
const sj2 = JSON.parse(fs.readFileSync(SESSIONS_PATH, 'utf8'));
assert.equal(sj2.sessions[0].eligible, true, '.claude/graph/ present = eligible');
console.log('reconcile eligibility OK');
```

- [ ] **Step 2: Implement reconcile in `metric.mjs`**

```js
// Append below recordEvent
import { spawnSync } from 'node:child_process';

export const SESSIONS_PATH = path.join(SPOOL_DIR, 'sessions.json');
const LOCK_PATH = path.join(SPOOL_DIR, '.sessions.lock');
const MAX_SESSIONS = 500;
const ARCHIVE_RETENTION_DAYS = 60;

function isEligible(cwd) {
  return fs.existsSync(path.join(cwd, '.claude', 'graph'));
}

function withLock(fn) {
  // Reuse sspower_mem.lock.acquire_lock by spawning python; alternative is
  // node-side flock via lockfile lib. Choose the python helper to match the
  // existing pattern documented in CLAUDE.md.
  const py = `
import sys, json, os
sys.path.insert(0, os.path.join(os.environ['CLAUDE_PLUGIN_ROOT'], 'scripts', 'sspower_mem'))
from sspower_mem.lock import acquire_lock
import pathlib
lock = pathlib.Path(sys.argv[1])
with acquire_lock(lock, parent_anchor=lock.parent.parent):
    print('LOCKED')
    sys.stdin.read(1)  # block until parent signals release
`;
  // For simplicity in MVP: use a lockfile via fs.openSync with O_CREAT|O_EXCL.
  // This is sufficient under the contract that only one SessionEnd hook per
  // session fires (CC guarantees per-session SessionEnd dispatch).
  let fd;
  const tries = 10;
  for (let i = 0; i < tries; i++) {
    try { fd = fs.openSync(LOCK_PATH, fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_RDWR, 0o600); break; }
    catch (e) {
      if (e.code !== 'EEXIST') throw e;
      // Stale lock check: if older than 30s, force-remove
      try {
        const st = fs.statSync(LOCK_PATH);
        if (Date.now() - st.mtimeMs > 30_000) fs.rmSync(LOCK_PATH);
      } catch {}
      // Busy-wait briefly
      const until = Date.now() + 100;
      while (Date.now() < until) {}
    }
  }
  if (!fd) throw new Error(`metric.reconcile: could not acquire lock at ${LOCK_PATH}`);
  try { return fn(); } finally { fs.closeSync(fd); try { fs.rmSync(LOCK_PATH); } catch {} }
}

function readSessions() {
  if (!fs.existsSync(SESSIONS_PATH)) return { schema_version: 1, updated: null, sessions: [] };
  try {
    const j = JSON.parse(fs.readFileSync(SESSIONS_PATH, 'utf8'));
    if (!Array.isArray(j.sessions)) return { schema_version: 1, updated: null, sessions: [] };
    return j;
  } catch { return { schema_version: 1, updated: null, sessions: [] }; }
}

function writeSessionsAtomic(obj) {
  const tmp = SESSIONS_PATH + '.tmp.' + process.pid;
  fs.writeFileSync(tmp, JSON.stringify(obj, null, 2), { mode: 0o600 });
  fs.renameSync(tmp, SESSIONS_PATH);
}

export async function reconcile({ session, cwd, reason }) {
  ensureSpool();
  // 1. Glob spool files for this session
  const all = fs.readdirSync(SPOOL_DIR);
  const matching = all.filter(f => f.startsWith(`${session}.`) && f.endsWith('.jsonl'));
  let events = [];
  let badLines = 0, totalLines = 0;
  for (const f of matching) {
    const text = fs.readFileSync(path.join(SPOOL_DIR, f), 'utf8');
    for (const ln of text.split('\n')) {
      if (!ln) continue;
      totalLines++;
      try { events.push(JSON.parse(ln)); } catch { badLines++; }
    }
  }
  events.sort((a, b) => a.ts.localeCompare(b.ts));

  // 2. Build summary row
  const eligible = isEligible(cwd);
  const tool_calls = events.length;
  const unique_tools = [...new Set(events.map(e => e.tool))];
  const first = events[0]?.ts ?? null;
  const last  = events[events.length - 1]?.ts ?? null;
  const session_source = events[0]?.session_source ?? 'claude_session_id';
  const projectHashHex = (await import('node:crypto')).default
    .createHash('sha256').update(fs.realpathSync(cwd)).digest('hex').slice(0, 16);

  const row = {
    session_id: session,
    schema_version: 1,
    session_source,
    eligible,
    tool_calls,
    unique_tools,
    first_call_ts: first,
    last_call_ts: last,
    session_end_ts: new Date().toISOString(),
    project_hash: projectHashHex,
    cwd,
    end_reason: reason ?? null,
    zero_call_reason: tool_calls === 0 ? 'no_mcp_invocations' : null,
    degraded: session_source.startsWith('degraded'),
    bad_lines: badLines,
    total_lines: totalLines,
  };

  // 3. Acquire lock and read-modify-write
  withLock(() => {
    const j = readSessions();
    j.sessions.push(row);
    j.sessions.sort((a, b) => (b.session_end_ts ?? b.last_call_ts ?? '').localeCompare(a.session_end_ts ?? a.last_call_ts ?? ''));
    if (j.sessions.length > MAX_SESSIONS) j.sessions.length = MAX_SESSIONS;
    j.updated = new Date().toISOString();
    writeSessionsAtomic(j);
  });

  // 4. Archive spool files
  const archDir = path.join(SPOOL_DIR, 'archive', new Date().toISOString().slice(0, 7).replace('-', ''));
  fs.mkdirSync(archDir, { recursive: true, mode: 0o700 });
  for (const f of matching) {
    try { fs.renameSync(path.join(SPOOL_DIR, f), path.join(archDir, f)); } catch {}
  }

  // 5. Prune old archives (>60 days)
  try {
    const archRoot = path.join(SPOOL_DIR, 'archive');
    if (fs.existsSync(archRoot)) {
      const monthDirs = fs.readdirSync(archRoot);
      const cutoffMs = Date.now() - ARCHIVE_RETENTION_DAYS * 24 * 60 * 60 * 1000;
      for (const d of monthDirs) {
        const p = path.join(archRoot, d);
        const st = fs.statSync(p);
        if (st.mtimeMs < cutoffMs) fs.rmSync(p, { recursive: true, force: true });
      }
    }
  } catch {}

  return row;
}

// CLI surface (invoked by hook): node metric.mjs reconcile --session X --cwd Y --reason Z
if (import.meta.url === `file://${process.argv[1]}`) {
  const argv = process.argv.slice(2);
  if (argv[0] === 'reconcile') {
    const get = (k) => { const i = argv.indexOf(`--${k}`); return i > -1 ? argv[i + 1] : null; };
    const session = get('session'), cwd = get('cwd'), reason = get('reason');
    if (!session || !cwd) { process.stderr.write('reconcile: --session and --cwd required\n'); process.exit(2); }
    reconcile({ session, cwd, reason }).then(() => process.exit(0)).catch(e => {
      process.stderr.write(`reconcile error: ${e.message}\n`); process.exit(1);
    });
  } else {
    process.stderr.write(`metric.mjs: unknown command ${argv[0]}\n`); process.exit(2);
  }
}
```

- [ ] **Step 3: Run + commit**

```bash
node tests/graph/test-mcp-metric.mjs
```

Expected: `recordEvent OK / reconcile OK / reconcile eligibility OK`.

Commit:

```
feat(graph): metric.mjs reconcile + sessions.json writer

reconcile() globs <sid>.*.jsonl spool, merges events, computes
per-session row (eligible if .claude/graph/ exists in cwd, tool_calls,
unique_tools, first/last/end timestamps, end_reason). Acquires
O_EXCL file lock around read-modify-write of sessions.json (atomic
temp+rename inside lock). Archives spool to archive/<YYYYMM>/,
prunes archives >60 days. CLI surface `node metric.mjs reconcile
--session X --cwd Y --reason Z` invoked by the SessionEnd hook.
```

---

## Task 15: `sspower-graph metric` CLI aggregator

**Files:**
- Modify: `bin/sspower-graph.mjs` (add `metric` verb)
- Modify: `scripts/graph/mcp-tools/metric.mjs` (add `aggregate` export)

- [ ] **Step 1: Append failing test**

In `tests/graph/test-mcp-metric.mjs`:

```js
import { aggregate } from '../../scripts/graph/mcp-tools/metric.mjs';
// Synthesize 50 eligible sessions all with tool_calls >= 1
fs.rmSync(SESSIONS_PATH, { force: true });
const sessions = [];
for (let i = 0; i < 50; i++) {
  sessions.push({
    session_id: `synth-${i}`, schema_version: 1, session_source: 'claude_session_id',
    eligible: true, tool_calls: 1 + (i % 3),
    unique_tools: ['graph_callers'], first_call_ts: '2026-05-27T00:00:00Z',
    last_call_ts: '2026-05-27T00:01:00Z', session_end_ts: `2026-05-27T0${(i%5)+1}:00:00Z`,
    project_hash: 'aa', cwd: '/x', end_reason: 'user_exit',
    zero_call_reason: null, degraded: false, bad_lines: 0, total_lines: 1,
  });
}
fs.mkdirSync(SPOOL_DIR, { recursive: true });
fs.writeFileSync(SESSIONS_PATH, JSON.stringify({ schema_version: 1, sessions }));
const ag = aggregate({ window: 50 });
assert.equal(ag.gate_met, true);
assert.equal(ag.eligible_sessions_total, 50);
assert.equal(ag.sessions_with_call, 50);
console.log('aggregate gate OK');

// Add one zero-call eligible session at the front (most recent) → gate fails
sessions.unshift({
  session_id: 'synth-zero', eligible: true, tool_calls: 0, unique_tools: [],
  first_call_ts: null, last_call_ts: null, session_end_ts: '2026-05-27T10:00:00Z',
  session_source: 'claude_session_id', schema_version: 1, project_hash: 'aa', cwd: '/x',
  end_reason: 'user_exit', zero_call_reason: 'no_mcp_invocations', degraded: false,
  bad_lines: 0, total_lines: 0,
});
fs.writeFileSync(SESSIONS_PATH, JSON.stringify({ schema_version: 1, sessions }));
const ag2 = aggregate({ window: 50 });
assert.equal(ag2.gate_met, false);
console.log('aggregate gate-fail OK');
```

- [ ] **Step 2: Implement `aggregate` in `metric.mjs`**

```js
export function aggregate({ window = 50 } = {}) {
  const j = readSessions();
  const sorted = [...j.sessions].sort((a, b) =>
    (b.session_end_ts ?? b.last_call_ts ?? '').localeCompare(a.session_end_ts ?? a.last_call_ts ?? ''));
  const eligible = sorted.filter(s => s.eligible).slice(0, window);
  const ineligible = sorted.filter(s => !s.eligible).slice(0, window).length;
  const sessions_with_call = eligible.filter(s => s.tool_calls > 0).length;
  const eligible_sessions_total = eligible.length;
  const adoption_rate = eligible_sessions_total ? sessions_with_call / eligible_sessions_total : 0;
  const gate_met = eligible_sessions_total >= window && eligible.every(s => s.tool_calls > 0);
  const tool_histogram = {};
  const durations_by_tool = {};
  for (const s of eligible) {
    for (const t of s.unique_tools) {
      tool_histogram[t] = (tool_histogram[t] ?? 0) + 1;
    }
  }
  const degraded_session_id_count = eligible.filter(s => s.degraded).length;
  return {
    window, eligible_sessions_total, sessions_with_call, adoption_rate,
    tool_histogram, degraded_session_id_count,
    ineligible_sessions_excluded: ineligible,
    gate_met,
    sessions_total: sorted.length,
  };
}
```

- [ ] **Step 3: Wire `metric` CLI verb in `bin/sspower-graph.mjs`**

In the dispatch `switch (cmd)` block:

```js
case 'metric':
  const { aggregate } = await import('../scripts/graph/mcp-tools/metric.mjs');
  const ag = aggregate({ window: opts.window ?? 50 });
  emit(opts, ag, a => `gate_met=${a.gate_met} eligible=${a.eligible_sessions_total} with_call=${a.sessions_with_call}`);
  break;
```

Add `--window` to parseOpts already-supported flags.

- [ ] **Step 4: Run + commit**

```bash
node tests/graph/test-mcp-metric.mjs
sspower-graph metric --json
```

Commit:

```
feat(graph): sspower-graph metric aggregator CLI (P3-D3)

aggregate() filters to eligible sessions, sorts by session_end_ts
desc, applies strict gate (every one of last `window` has tool_calls
>= 1). gate_met = boolean. tool_histogram + adoption_rate as
diagnostics. CLI verb `sspower-graph metric --window 50 --json`.
```

---

## Task 16: Zero-call eligible session integration test

**Files:**
- Create: `tests/graph/test-mcp-metric-zerocall.mjs`

- [ ] **Step 1: Write the test**

```js
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawnSync } from 'node:child_process';
import url from 'node:url';
import { statePathFor } from '../../scripts/graph/session-state.mjs';
import { SESSIONS_PATH, SPOOL_DIR } from '../../scripts/graph/mcp-tools/metric.mjs';

const PLUGIN_ROOT = path.resolve(url.fileURLToPath(import.meta.url), '../../..');
const FIX = fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-zc-'));
fs.mkdirSync(path.join(FIX, '.claude', 'graph'), { recursive: true });  // eligible

// 1. session-start: write state file
const startPayload = JSON.stringify({
  session_id: 'zc-test', cwd: FIX, source: 'startup',
  hook_event_name: 'SessionStart', transcript_path: '/dev/null',
});
let r = spawnSync('bash', [path.join(PLUGIN_ROOT, 'hooks', 'session-start')], {
  input: startPayload, encoding: 'utf8', env: { ...process.env, CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT },
});
assert.equal(r.status, 0);

// 2. NO MCP calls — skip recordEvent entirely

// 3. session-end: invoke reconcile hook
fs.rmSync(SESSIONS_PATH, { force: true });
const endPayload = JSON.stringify({
  session_id: 'zc-test', cwd: FIX, reason: 'user_exit',
  hook_event_name: 'SessionEnd',
});
r = spawnSync('bash', [path.join(PLUGIN_ROOT, 'hooks', 'graph-metric-reconcile.sh')], {
  input: endPayload, encoding: 'utf8', env: { ...process.env, CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT },
});
assert.equal(r.status, 0, `reconcile stderr=${r.stderr}`);

const sj = JSON.parse(fs.readFileSync(SESSIONS_PATH, 'utf8'));
const row = sj.sessions.find(s => s.session_id === 'zc-test');
assert.ok(row, 'no row written for zero-call session');
assert.equal(row.eligible, true);
assert.equal(row.tool_calls, 0);
assert.equal(row.zero_call_reason, 'no_mcp_invocations');
console.log('zero-call eligible session OK');
```

- [ ] **Step 2: Run — expect PASS**

```bash
node tests/graph/test-mcp-metric-zerocall.mjs
```

- [ ] **Step 3: Commit**

```
test(graph): zero-call eligible session integration (denominator gate)

Fixture project with .claude/graph/ runs a complete SessionStart →
(no MCP calls) → SessionEnd flow. Asserts the reconciler emits an
eligible:true, tool_calls:0, zero_call_reason:no_mcp_invocations row
so the adoption denominator is observable per HIGH-1 fix.
```

---

## Task 17: Metric concurrency test

**Files:**
- Create: `tests/graph/test-mcp-metric-concurrency.mjs`

- [ ] **Step 1: Write the test**

```js
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import url from 'node:url';
import { recordEvent, reconcile, SESSIONS_PATH, SPOOL_DIR } from '../../scripts/graph/mcp-tools/metric.mjs';
import { statePathFor } from '../../scripts/graph/session-state.mjs';

const FIX = fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-conc-'));
fs.mkdirSync(path.join(FIX, '.claude', 'graph'), { recursive: true });
fs.mkdirSync(path.dirname(statePathFor(FIX)), { recursive: true });
fs.writeFileSync(statePathFor(FIX), JSON.stringify({
  session_id: 'conc-test', cwd: FIX, started_ts: new Date().toISOString(),
}));

const orig = process.cwd();
process.chdir(FIX);

// 50 parallel recordEvent calls
const tasks = [];
for (let i = 0; i < 50; i++) {
  tasks.push(Promise.resolve().then(() => recordEvent({
    tool: i % 2 === 0 ? 'graph_callers' : 'graph_status',
    ok: true, duration_ms: i, cwd: FIX,
  })));
}
await Promise.all(tasks);
process.chdir(orig);

// All 50 events should be in one spool file (single pid)
const spool = fs.readdirSync(SPOOL_DIR).filter(f => f.startsWith('conc-test.'));
assert.equal(spool.length, 1);
const lines = fs.readFileSync(path.join(SPOOL_DIR, spool[0]), 'utf8').trim().split('\n');
assert.equal(lines.length, 50, `expected 50 lines, got ${lines.length}`);
let parsed = 0;
for (const ln of lines) {
  try { JSON.parse(ln); parsed++; } catch {}
}
assert.equal(parsed, 50, `expected 50 parseable lines, got ${parsed}`);

// Reconcile and verify tool_calls = 50
fs.rmSync(SESSIONS_PATH, { force: true });
await reconcile({ session: 'conc-test', cwd: FIX, reason: 'user_exit' });
const row = JSON.parse(fs.readFileSync(SESSIONS_PATH, 'utf8')).sessions.find(s => s.session_id === 'conc-test');
assert.equal(row.tool_calls, 50);
console.log('concurrency 50-parallel OK');
```

- [ ] **Step 2: Run — expect PASS**

If fail: **STOP — fire §9 anti-goal trigger 3 (concurrency gate failure)**.

- [ ] **Step 3: Commit**

```
test(graph): 50-parallel metric concurrency

50 parallel recordEvent calls in one MCP server process must produce
exactly 50 parseable jsonl lines (proves appendFileSync serializes
intra-process). reconcile must report tool_calls=50.
```

T2 done.

---

# T3 — Agent .md updates (0.5 task-day)

## Task 18: `agents/code-reviewer.md` — append Graph tool guidance

**Files:**
- Modify: `agents/code-reviewer.md` (append after existing content)

- [ ] **Step 1: Append exactly the section from spec §5.2** verbatim:

```markdown

## Graph tool guidance

Before flagging "unused symbol" or "wide impact", consult sspower-graph:

- `mcp__sspower-graph__graph_callers <name>` — empty result + no exports
  list = genuinely unused. Non-empty = downgrade finding to "narrow use,
  verify intent".
- `mcp__sspower-graph__graph_impact <file>` — get the symbol-level + transitive
  reach of changed files. Use the count to justify "this PR is larger
  than it looks" verdicts.
- `mcp__sspower-graph__graph_callees <name>` — when reviewing a function
  marked "this should be small", list its callees to spot fan-out.

Hard rule: call graph tools BEFORE delegating to the Explore subagent;
never invoke graph tools from inside Explore.
```

- [ ] **Step 2: Commit**

```
docs(agents): code-reviewer graph tool guidance (P3 §5.2)
```

---

## Task 19: `agents/sanity-reviewer.md` — append Graph tool guidance

**Files:**
- Modify: `agents/sanity-reviewer.md`

- [ ] **Step 1: Append spec §5.3 verbatim** (sanity-reviewer block from spec)

- [ ] **Step 2: Commit**

```
docs(agents): sanity-reviewer graph tool guidance (P3 §5.3)
```

---

## Task 20: `agents/security-reviewer.md` — append Graph tool guidance

**Files:**
- Modify: `agents/security-reviewer.md`

- [ ] **Step 1: Append spec §5.4 verbatim**

- [ ] **Step 2: Commit**

```
docs(agents): security-reviewer graph tool guidance (P3 §5.4)
```

---

## Task 21: Agent smoke test (manual, recorded)

**Files:**
- Create: `docs/plans/notes/2026-05-27-graph-P3-agent-smoke.md`

- [ ] **Step 1: Manual procedure**

In a fixture project with `.claude/graph/` populated (use `__tests__/graph-fixtures/ts-js/`), open Claude Code, invoke each of the 3 agents with a realistic prompt:

- `Use the code-reviewer agent to review the latest commit.`
- `Use the sanity-reviewer agent on this PR.`
- `Use the security-reviewer agent on the auth module.`

For each, capture the transcript and verify the agent emitted at least one `mcp__sspower-graph__graph_*` call BEFORE any `Explore` subagent delegation.

- [ ] **Step 2: Record results**

Write `docs/plans/notes/2026-05-27-graph-P3-agent-smoke.md`:

```markdown
# P3 agent smoke results

| Agent | MCP tool called | Before Explore? | Notes |
|---|---|---|---|
| code-reviewer | graph_callers | yes | … |
| sanity-reviewer | graph_impact | yes | … |
| security-reviewer | graph_impact | yes | … |
```

- [ ] **Step 3: If any agent cannot call any MCP tool**: **fire §9 anti-goal trigger 4 (agent invocation impossibility)** unless an explicit `tools:` frontmatter add fixes it.

- [ ] **Step 4: Commit**

```
docs(agents): P3 smoke results captured

All three reviewers call graph_* before Explore. P3-D7 (no explicit
tools: frontmatter) verified — inherited toolset surfaces MCP tools
correctly.
```

T3 done.

---

# T4 — Regression + perf tests (1 task-day)

## Task 22: P2 CLI back-compat golden capture + regression test

**Files:**
- Create: `tests/graph/regenerate-cli-goldens.sh`
- Create: `tests/graph/test-p2-cli-back-compat.mjs`
- Create: `__tests__/graph-fixtures/<pack>/expected/cli-goldens/<verb>.json` × 5 fixture packs × ~8 verbs

- [ ] **Step 1: Write the golden-regen script**

```bash
#!/usr/bin/env bash
# tests/graph/regenerate-cli-goldens.sh
# Regenerate P2 CLI --json goldens. Run manually only when an INTENTIONAL
# CLI output shift is approved.
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURES_ROOT="$PLUGIN_ROOT/__tests__/graph-fixtures"
GRAPH_BIN="$PLUGIN_ROOT/bin/sspower-graph.mjs"

for pack in ts-js ts-js-multifile python go rust; do
  PACK="$FIXTURES_ROOT/$pack"
  [ -d "$PACK" ] || continue
  GOLDEN="$PACK/expected/cli-goldens"
  mkdir -p "$GOLDEN"
  # Rebuild fresh
  node "$GRAPH_BIN" build --cwd "$PACK" --json > /dev/null
  # Capture each verb
  node "$GRAPH_BIN" status  --cwd "$PACK" --json > "$GOLDEN/status.json"
  for name in fnA fnB; do
    node "$GRAPH_BIN" callers --cwd "$PACK" --json "$name" > "$GOLDEN/callers-$name.json" 2>/dev/null || true
    node "$GRAPH_BIN" callees --cwd "$PACK" --json "$name" > "$GOLDEN/callees-$name.json" 2>/dev/null || true
    node "$GRAPH_BIN" node    --cwd "$PACK" --json "$name" > "$GOLDEN/node-$name.json" 2>/dev/null || true
  done
done
echo "Regenerated CLI goldens for all fixture packs."
```

- [ ] **Step 2: Capture initial goldens against current code**

```bash
chmod +x tests/graph/regenerate-cli-goldens.sh
tests/graph/regenerate-cli-goldens.sh
```

- [ ] **Step 3: Write the regression test**

```js
// tests/graph/test-p2-cli-back-compat.mjs
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';
import { spawnSync } from 'node:child_process';

const PLUGIN_ROOT = path.resolve(url.fileURLToPath(import.meta.url), '../../..');
const FIXTURES = path.join(PLUGIN_ROOT, '__tests__', 'graph-fixtures');
const GRAPH = path.join(PLUGIN_ROOT, 'bin', 'sspower-graph.mjs');

const packs = fs.readdirSync(FIXTURES).filter(p =>
  fs.existsSync(path.join(FIXTURES, p, 'expected', 'cli-goldens')));

for (const pack of packs) {
  const goldenDir = path.join(FIXTURES, pack, 'expected', 'cli-goldens');
  for (const goldenFile of fs.readdirSync(goldenDir)) {
    const [verb, ...rest] = goldenFile.replace('.json', '').split('-');
    const arg = rest.join('-');
    const args = arg ? [verb, '--cwd', path.join(FIXTURES, pack), '--json', arg]
                     : [verb, '--cwd', path.join(FIXTURES, pack), '--json'];
    const r = spawnSync(process.execPath, [GRAPH, ...args], { encoding: 'utf8' });
    assert.equal(r.status, 0, `${pack}/${goldenFile}: exit=${r.status} stderr=${r.stderr}`);
    const expected = fs.readFileSync(path.join(goldenDir, goldenFile), 'utf8');
    assert.equal(r.stdout, expected, `${pack}/${goldenFile}: byte-diff`);
  }
}
console.log(`P2 CLI back-compat: ${packs.length} packs OK`);
```

- [ ] **Step 4: Run — expect PASS** (refactor in Task 4 must preserve byte-identical output)

```bash
node tests/graph/test-p2-cli-back-compat.mjs
```

If fail: refactor in Task 4 changed CLI output. STOP and reconcile (this is the gate per spec §6 P2-regression row).

- [ ] **Step 5: Commit**

```
test(graph): P2 CLI byte-identical back-compat regression

regenerate-cli-goldens.sh captures --json output for status/callers/
callees/node across 5 fixture packs. test-p2-cli-back-compat.mjs
asserts exact byte match. Gates the Task 4 refactor and any future
spec-incompatible change. Regenerate only on approved CLI shift.
```

---

## Task 23: Extend MCP smoke test to 7 tools

**Files:**
- Modify: `tests/graph/test-mcp-stub.mjs` → rename to `test-mcp-integration.mjs`

- [ ] **Step 1: Rewrite**

```js
// tests/graph/test-mcp-integration.mjs
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import assert from 'node:assert/strict';
import path from 'node:path';
import url from 'node:url';

const PLUGIN_ROOT = path.resolve(url.fileURLToPath(import.meta.url), '../../..');
const FIXTURE = path.join(PLUGIN_ROOT, '__tests__', 'graph-fixtures', 'ts-js');

const transport = new StdioClientTransport({
  command: path.join(PLUGIN_ROOT, 'bin', 'sspower-graph-bootstrap.sh'),
  args: ['serve', '--mcp'],
  env: { ...process.env, CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT },
  cwd: FIXTURE,
});
const client = new Client({ name: 'smoke', version: '0' }, { capabilities: {} });
await client.connect(transport);

const tools = (await client.listTools()).tools;
assert.equal(tools.length, 7, `expected 7 tools; got ${tools.length}: ${tools.map(t => t.name).join(',')}`);
const expected = ['graph_status', 'graph_callers', 'graph_callees', 'graph_trace', 'graph_impact', 'graph_node', 'graph_context'];
const names = tools.map(t => t.name).sort();
assert.deepEqual(names, [...expected].sort(), 'tool name set mismatch');

for (const name of expected) {
  const args = {
    graph_status:  {},
    graph_callers: { name: 'fnA' },
    graph_callees: { name: 'fnA' },
    graph_trace:   { from: 'fnA', to: 'fnB' },
    graph_impact:  { file: 'src/a.ts' },
    graph_node:    { name: 'fnA' },
    graph_context: { task: 'add cache to fnA' },
  }[name];
  const r = await client.callTool({ name, arguments: args });
  assert.ok(r.content?.[0]?.text, `${name}: no text content`);
  JSON.parse(r.content[0].text);  // must be valid JSON
}

await client.close();
console.log('MCP integration 7-tool smoke OK');
```

- [ ] **Step 2: Run — expect PASS**

```bash
node tests/graph/test-mcp-integration.mjs
```

- [ ] **Step 3: Commit**

```
test(graph): MCP integration smoke covers 7 tools

Spawns the real server via bootstrap.sh from a fixture project cwd,
asserts listTools returns 7 entries with expected name set, and
callTool on each returns parseable JSON.
```

---

## Task 24: Perf test (advisory p95 ≤300ms)

**Files:**
- Create: `tests/graph/perf-mcp.mjs`

- [ ] **Step 1: Write the test**

```js
// tests/graph/perf-mcp.mjs
// Opt-in: SSPOWER_GRAPH_PERF=1 node tests/graph/perf-mcp.mjs
if (!process.env.SSPOWER_GRAPH_PERF) { console.log('skip: SSPOWER_GRAPH_PERF not set'); process.exit(0); }

import assert from 'node:assert/strict';
import path from 'node:path';
import url from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const PLUGIN_ROOT = path.resolve(url.fileURLToPath(import.meta.url), '../../..');
const FIXTURE = path.join(PLUGIN_ROOT, '__tests__', 'graph-fixtures', 'ts-js');

const transport = new StdioClientTransport({
  command: path.join(PLUGIN_ROOT, 'bin', 'sspower-graph-bootstrap.sh'),
  args: ['serve', '--mcp'],
  env: { ...process.env, CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT },
  cwd: FIXTURE,
});
const client = new Client({ name: 'perf', version: '0' }, { capabilities: {} });
await client.connect(transport);

async function bench(name, args, n = 100) {
  const t = [];
  for (let i = 0; i < n; i++) {
    const t0 = Date.now();
    await client.callTool({ name, arguments: args });
    t.push(Date.now() - t0);
  }
  t.sort((a,b)=>a-b);
  return { name, p50: t[Math.floor(n*0.5)], p95: t[Math.floor(n*0.95)], max: t[n-1] };
}

const results = [
  await bench('graph_status',  {}),
  await bench('graph_callers', { name: 'fnA' }),
  await bench('graph_callees', { name: 'fnA' }),
  await bench('graph_node',    { name: 'fnA' }),
];
console.table(results);
const failures = results.filter(r => r.p95 > 300);
if (failures.length) {
  console.warn(`ADVISORY: ${failures.length} tools exceed p95 ≤300ms`);
}
await client.close();
```

- [ ] **Step 2: Run** (opt-in)

```bash
SSPOWER_GRAPH_PERF=1 node tests/graph/perf-mcp.mjs
```

If any tool's p95 > 1s: **fire §9 anti-goal trigger 6 (MCP cold-start latency)**.

- [ ] **Step 3: Commit**

```
test(graph): MCP perf bench (advisory p95)

Opt-in via SSPOWER_GRAPH_PERF=1. Benches 4 representative tools at
100 iterations. Advisory threshold p95 ≤300ms; hard fail at >1s.
```

T4 done.

---

# T5 — Ship (0.5 task-day)

## Task 25: Run full test suite

- [ ] **Step 1: All tests green**

```bash
bun run graph:tests
node tests/graph/test-bootstrap-cwd.mjs
node tests/graph/test-session-state-unit.mjs
node tests/graph/test-session-state-contract.mjs
node tests/graph/test-mcp-tools-unit.mjs
node tests/graph/test-mcp-integration.mjs
node tests/graph/test-mcp-metric.mjs
node tests/graph/test-mcp-metric-zerocall.mjs
node tests/graph/test-mcp-metric-concurrency.mjs
node tests/graph/test-p2-cli-back-compat.mjs
```

Expected: all `OK`.

- [ ] **Step 2: Vitest harness**

```bash
bun x vitest run __tests__/graph-fixtures/
```

Expected: 6 green (unchanged from P2).

---

## Task 26: Version bump + ARCHITECTURE/CLAUDE.md updates

**Files:**
- Modify: `package.json` — `version: 1.4.0-rc.0`
- Modify: `ARCHITECTURE.md` — mark P3 shipped
- Modify: `CLAUDE.md` — P3 row promoted to shipped, P4 listed as next

- [ ] **Step 1: Bump version**

Edit `package.json:3`: `"version": "1.4.0-rc.0"`.

- [ ] **Step 2: Update ARCHITECTURE.md**

Find the P3 row and change status from "next" to "shipped at 1.4.0-rc.0".

- [ ] **Step 3: Update `CLAUDE.md`** sspower-graph subsystem section: P3 promoted to shipped, P4 framed as next.

- [ ] **Step 4: Commit**

```
chore(graph): promote 1.4.0-rc.0 — P3 ship candidate

7 MCP tools + per-project session-state + adoption metric +
3 reviewer agent guidance sections + P2 CLI back-compat regression.
```

---

## Task 27: Run Codex plan-review against THIS plan

**Files:**
- Create: `docs/plans/notes/2026-05-27-graph-P3-plan-review.json`

- [ ] **Step 1: Invoke**

```bash
node scripts/codex-bridge.mjs plan-review \
  --cd /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower \
  --prompt @docs/plans/2026-05-27-codegraph-graph-P3.md \
  2>&1 | tee /tmp/p3-plan-review.log
```

- [ ] **Step 2: Cache verdict** at `docs/plans/notes/2026-05-27-graph-P3-plan-review.json`.

- [ ] **Step 3:** If `request-changes` or `needs-attention`: fix inline, re-run, up to 2 iterations. If still failing after 2: stop P3 work and escalate to user. Per the writing-plans skill HARD-GATE, do NOT proceed to T5 ship without `approve` or `approve-with-followups`.

- [ ] **Step 4: Commit**

```
docs(graph): cache P3 plan-review verdict
```

---

## Task 28: Capture adoption-metric snapshot + open PR + ship

**Files:**
- Create: `docs/plans/notes/2026-05-27-graph-P3-adoption-snapshot.json`

- [ ] **Step 1: Capture metric snapshot**

```bash
sspower-graph metric --json > docs/plans/notes/2026-05-27-graph-P3-adoption-snapshot.json
```

(At ship time the in-field 50-session window won't be filled; snapshot is committed as the baseline for week-2 observation.)

- [ ] **Step 2: Final commit + version bump to release**

Edit `package.json:3`: `"version": "1.4.0"`.

```
chore(graph): promote 1.4.0 — P3 ship
```

- [ ] **Step 3: Open PR** (standalone Bash invocation per chokepoint policy)

```bash
git push -u origin feat/graph-P3
```

Separate invocation:

```bash
gh pr create --title "feat(graph): P3 — 7-tool MCP + agent guidance + adoption metric" --body-file docs/plans/notes/p3-pr-body.md
```

PR body recap: spec link, plan link, locked decisions P3-D1..P3-D8, test gates passed, adoption-metric snapshot path.

- [ ] **Step 4: After merge, tag**

```bash
git tag graph-p3
git push origin graph-p3
```

- [ ] **Step 5: Update handoff**

In `~/.claude/docs/handoff.md`, mark P3 shipped, set next phase = P4 (hooks orchestration: `graph-orchestrator.sh` replaces `semble-context.sh`; `auto-review.sh` enrichment; Express framework P5+).

---

# Done criteria

- [ ] Bootstrap cwd-preservation fix shipped (P3-D8); contract test green
- [ ] Per-project session-state file written by SessionStart hook; unit + contract tests green
- [ ] 7 MCP handlers (`graph_status/callers/callees/trace/impact/node/context`); unit tests green; integration smoke green
- [ ] `recordEvent` + `reconcile` + `aggregate` + `sspower-graph metric` CLI; concurrency test green; zero-call gate test green
- [ ] 3 reviewer agents have `## Graph tool guidance`; manual smoke captures ≥1 MCP call per agent before any Explore delegation
- [ ] P2 CLI back-compat regression test green (5 fixture packs × ~8 verbs byte-identical)
- [ ] Plan-review verdict cached as `approve` or `approve-with-followups`
- [ ] `1.4.0` shipped on `main`, tag `graph-p3` pushed, PR merged
- [ ] Adoption snapshot committed; week-2 observation window open for the 50-session gate

If any §9 anti-goal trigger fires: STOP, draft `codegraph install` companion plan, ship that instead.
