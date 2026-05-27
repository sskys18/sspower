# sspower-graph P3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `sspower:subagent-driven-development` (recommended) or `sspower:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the P0 MCP stub with a full 7-tool MCP server, ship a per-project session-state harness + adoption-metric reconciler, update 3 reviewer agents with role-tuned graph-tool guidance.

**Architecture:** A pure-data query layer (`scripts/graph/queries.mjs`) is extracted from the existing CLI handlers. Both the CLI verbs and the per-tool MCP handlers (`scripts/graph/mcp-tools/<tool>.mjs`) call this shared layer. The MCP request handler also calls `recordEvent()` from `scripts/graph/mcp-tools/metric.mjs`, which appends to a per-process-pid spool JSONL keyed by per-project session id (read from `~/.claude/state/sspower/sessions/<sha8(realpath(cwd))>.json` written by `hooks/session-start`). A new `SessionEnd` reconciler merges spool files into `sessions.json`. The bootstrap is amended to preserve caller cwd (P3-D8).

**Tech Stack:** Node ≥22.5, `@modelcontextprotocol/sdk`, `node:sqlite`, bun (lockfile), vitest harness for fixture goldens, bash hooks, `sspower_mem.lock.acquire_lock` Python helper.

**Spec:** `docs/specs/2026-05-27-codegraph-graph-P3-design.md` @ `1af85cf` (Codex `approve`).

**Phase budget:** 5 task-days (T1..T5). Anti-goal at 10 task-days or any of 6 §9 triggers.

## Execution conventions (READ FIRST)

This plan can be executed three ways: `sspower:subagent-driven-development` (Claude subagent — can commit), `sspower:executing-plans` (Claude inline — can commit), or via Codex worker (CANNOT commit — repo `AGENTS.md` rule: Codex workers MUST leave changes uncommitted; the supervisor commits).

Every task ends with a step that:

1. Writes the suggested commit message to a temp file (`/tmp/commit-msg-<task>.txt`).
2. Stages the files via `git add <exact paths>`.
3. **If Claude (inline or subagent): runs `git commit -F /tmp/commit-msg-<task>.txt` as a standalone Bash invocation per the chokepoint policy.**
4. **If Codex: STOPS HERE. Reports `staged: <files>; commit-msg: /tmp/commit-msg-<task>.txt` and lets the supervisor run the commit.**

Task-end commit commands in this plan are written as Claude-mode (the recommended path). Codex workers must skip the `git commit` line and stop after staging.

`git push` / `gh pr ...` only appear in Task 28 and are exclusively supervisor actions regardless of executor.

## MCP↔CLI byte-identical contract (load-bearing)

The CLI's `emit(opts, payload, pretty)` calls `JSON.stringify(payload, null, 2) + '\n'` for `--json` output (2-space indent, trailing newline). The MCP dispatch in Task 5 MUST serialize identically — otherwise Task 22 byte parity fails by construction. Use `JSON.stringify(payload, null, 2)` (no trailing newline; the test trims CLI side).

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
| Create | `tests/graph/test-p2-cli-back-compat.mjs` | byte-identical CLI `--json` regression (Task 4b) |
| Create | `tests/graph/test-mcp-cli-parity.mjs` | MCP `content[0].text` ≡ CLI `--json` canonical (Task 22) |
| Create | `tests/graph/test-bootstrap-preflight.mjs` | server-key collision (Task 22b) |
| Create | `tests/graph/perf-mcp.mjs` | per-tool p95 latency (opt-in) |
| Create | `tests/graph/regenerate-cli-goldens.sh` | regen P2 goldens when intentionally shifting CLI output |
| Modify | `README.md` | document `SSPOWER_GRAPH_MCP_KEY` override (Task 22b) |
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
  return crypto.createHash('sha256').update(real).digest('hex').slice(0, 8);
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

Concrete patch: the existing `hooks/session-start` captures stdin into `hook_payload` near the top (`hook_payload="$(cat 2>/dev/null || true)"`). The P3 block REUSES that variable — DO NOT call `cat` again (stdin is drained).

Add after sspower's existing init steps (before the final `exit 0`):

```bash
# P3: write per-project session-state file. Reuses $hook_payload captured
# at the top of this hook script — do NOT re-read stdin (already drained).
if [ -n "${hook_payload:-}" ]; then
  SID="$(printf '%s' "$hook_payload" | jq -r '.session_id // empty' 2>/dev/null)"
  CWD="$(printf '%s' "$hook_payload" | jq -r '.cwd // empty' 2>/dev/null)"
  SRC="$(printf '%s' "$hook_payload" | jq -r '.source // "unknown"' 2>/dev/null)"
  if [ -n "$SID" ] && [ -n "$CWD" ]; then
    STATE_DIR="$HOME/.claude/state/sspower/sessions"
    mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
    HASH="$(printf '%s' "$(realpath "$CWD" 2>/dev/null || echo "$CWD")" | shasum -a 256 | cut -c1-8)"
    TMP="$STATE_DIR/.$HASH.tmp.$$"
    cat > "$TMP" <<EOF
{"session_id":"$SID","cwd":"$CWD","started_ts":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","hook_event_name":"SessionStart","source":"$SRC"}
EOF
    chmod 600 "$TMP"
    mv -f "$TMP" "$STATE_DIR/$HASH.json"
  fi
fi
```

**Pre-flight grep**: before applying, run `grep -n 'hook_payload' hooks/session-start` to confirm the variable exists and the capture happens before any consumer. If the variable name has drifted in a future revision, update this block's references rather than re-reading stdin.

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

## Task 4b: P2 CLI back-compat goldens + regression test (T1 gate, runs immediately after Task 4)

**Files:**
- Create: `tests/graph/regenerate-cli-goldens.sh`
- Create: `tests/graph/test-p2-cli-back-compat.mjs`
- Create: `__tests__/graph-fixtures/<pack>/expected/cli-goldens/<verb>.json` × 5 packs × ~10 verbs

**Rationale**: gate must run *immediately* after Task 4's refactor so any byte-diff blocks downstream tasks from compounding the regression. Full verb coverage per spec §6 row.

- [ ] **Step 1: Capture goldens against `bd782c3`** (pre-refactor baseline) by stashing the Task 4 changes:

```bash
git stash push -m "p3-task4-temp" -- scripts/graph/queries.mjs scripts/graph/db.mjs bin/sspower-graph.mjs
chmod +x tests/graph/regenerate-cli-goldens.sh
tests/graph/regenerate-cli-goldens.sh
git stash pop
```

The regen script:

```bash
#!/usr/bin/env bash
# tests/graph/regenerate-cli-goldens.sh — regen P2 --json goldens.
# Run only on approved CLI shifts.
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURES_ROOT="$PLUGIN_ROOT/__tests__/graph-fixtures"
GRAPH_BIN="$PLUGIN_ROOT/bin/sspower-graph.mjs"

for pack in ts-js ts-js-multifile python go rust; do
  PACK="$FIXTURES_ROOT/$pack"
  [ -d "$PACK" ] || continue
  GOLDEN="$PACK/expected/cli-goldens"
  mkdir -p "$GOLDEN"
  rm -rf "$PACK/.claude/graph"
  node "$GRAPH_BIN" build --cwd "$PACK" --json > "$GOLDEN/build.json"
  node "$GRAPH_BIN" status --cwd "$PACK" --json > "$GOLDEN/status.json"
  # Discover symbols from the expected pack manifest:
  if [ -f "$PACK/expected/symbols.txt" ]; then
    while IFS= read -r sym; do
      node "$GRAPH_BIN" callers --cwd "$PACK" --json "$sym" > "$GOLDEN/callers-$sym.json" 2>/dev/null || true
      node "$GRAPH_BIN" callees --cwd "$PACK" --json "$sym" > "$GOLDEN/callees-$sym.json" 2>/dev/null || true
      node "$GRAPH_BIN" node    --cwd "$PACK" --json "$sym" > "$GOLDEN/node-$sym.json"    2>/dev/null || true
    done < "$PACK/expected/symbols.txt"
  fi
  if [ -f "$PACK/expected/trace-pairs.txt" ]; then
    while IFS=$'\t' read -r from to; do
      node "$GRAPH_BIN" trace --cwd "$PACK" --json "$from" "$to" > "$GOLDEN/trace-$from-$to.json" 2>/dev/null || true
    done < "$PACK/expected/trace-pairs.txt"
  fi
  if [ -f "$PACK/expected/impact-files.txt" ]; then
    while IFS= read -r f; do
      node "$GRAPH_BIN" impact --cwd "$PACK" --json "$f" > "$GOLDEN/impact-$(printf '%s' "$f" | tr / _).json" 2>/dev/null || true
    done < "$PACK/expected/impact-files.txt"
  fi
  if [ -f "$PACK/expected/context-tasks.txt" ]; then
    # Build a manifest so the regression test can recover the original task arg
    # for each context-<hash>.json golden.
    : > "$GOLDEN/context-manifest.tsv"
    while IFS= read -r t; do
      hash=$(printf '%s' "$t" | shasum | cut -c1-8)
      printf '%s\t%s\n' "$hash" "$t" >> "$GOLDEN/context-manifest.tsv"
      node "$GRAPH_BIN" context --cwd "$PACK" --json "$t" > "$GOLDEN/context-$hash.json" 2>/dev/null || true
    done < "$PACK/expected/context-tasks.txt"
  fi
  node "$GRAPH_BIN" refresh --cwd "$PACK" --json > "$GOLDEN/refresh.json"
  node "$GRAPH_BIN" session-refresh --cwd "$PACK" --json --max-time 5 > "$GOLDEN/session-refresh.json"
done
echo "Regenerated CLI goldens for all fixture packs."
```

Pre-populate the per-pack hint files (`symbols.txt`, `trace-pairs.txt`, `impact-files.txt`, `context-tasks.txt`) before first run — list known good inputs per pack. Skip lines that produce errors.

- [ ] **Step 2: Write regression test**

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

let checked = 0;
for (const pack of packs) {
  const goldenDir = path.join(FIXTURES, pack, 'expected', 'cli-goldens');
  // Load context manifest if present: hash → task text
  const ctxManifest = {};
  const manifestPath = path.join(goldenDir, 'context-manifest.tsv');
  if (fs.existsSync(manifestPath)) {
    for (const line of fs.readFileSync(manifestPath, 'utf8').split('\n')) {
      if (!line.trim()) continue;
      const [hash, ...task] = line.split('\t');
      ctxManifest[hash] = task.join('\t');
    }
  }
  for (const goldenFile of fs.readdirSync(goldenDir)) {
    if (goldenFile === 'context-manifest.tsv') continue;
    const base = goldenFile.replace('.json', '');
    const [verb, ...rest] = base.split('-');
    const args = ['--cwd', path.join(FIXTURES, pack), '--json'];
    if (verb === 'trace') {
      args.unshift(verb); args.push(rest[0], rest.slice(1).join('-'));
    } else if (verb === 'impact') {
      args.unshift(verb); args.push(rest.join('-').replace(/_/g, '/'));
    } else if (verb === 'context') {
      const hash = rest.join('-');
      const task = ctxManifest[hash];
      assert.ok(task, `${pack}/${goldenFile}: no manifest entry for hash ${hash}`);
      args.unshift(verb); args.push(task);
    } else if (rest.length) {
      args.unshift(verb); args.push(rest.join('-'));
    } else {
      args.unshift(verb);
    }
    if (verb === 'session-refresh') args.push('--max-time', '5');
    const r = spawnSync(process.execPath, [GRAPH, ...args], { encoding: 'utf8' });
    assert.equal(r.status, 0, `${pack}/${goldenFile}: exit=${r.status} stderr=${r.stderr}`);
    const expected = fs.readFileSync(path.join(goldenDir, goldenFile), 'utf8');
    assert.equal(r.stdout, expected, `${pack}/${goldenFile}: --json byte-diff`);
    // Stderr should be empty for success path
    assert.equal(r.stderr, '', `${pack}/${goldenFile}: unexpected stderr "${r.stderr}"`);
    checked++;
  }
}
assert.ok(checked > 0, 'no goldens captured');
console.log(`P2 CLI back-compat: ${packs.length} packs, ${checked} cases OK`);
```

- [ ] **Step 3: Run — expect PASS** (Task 4 refactor must preserve byte-identical output)

```bash
node tests/graph/test-p2-cli-back-compat.mjs
```

If fail: **STOP. Reconcile Task 4's refactor with the golden** before any further task. Fire §9 anti-goal trigger 5 (P2 regression unresolvable) after one fix attempt.

- [ ] **Step 4: Commit**

```
test(graph): P2 CLI back-compat regression (10 verbs × 5 packs)

Goldens captured against the pre-refactor commit; test asserts
byte-identical --json + exit + empty stderr for build/refresh/
session-refresh/status/callers/callees/trace/impact/node/context.
Gates the Task 4 refactor and any future spec-incompatible change.
```

---

## Task 5: MCP server scaffolding refactor (dispatcher + TOOLS array)

**Files:**
- Modify: `bin/sspower-graph.mjs:267-287` (replace stub)
- Create: `scripts/graph/mcp-tools/index.mjs`
- Create: `scripts/graph/mcp-tools/{status,callers,callees,trace,impact,node,context}.mjs` (STUB versions; real implementations land in Tasks 6-11)

- [ ] **Step 1: Create 7 stub handler files** so Task 5's `index.mjs` static imports resolve

For each name in `[status, callers, callees, trace, impact, node, context]` create `scripts/graph/mcp-tools/<name>.mjs` containing only:

```js
// scripts/graph/mcp-tools/<name>.mjs — STUB. Real implementation in Task <N>.
export const TOOL = {
  name: 'graph_<name>',
  description: 'P3 stub — Task <N> will replace this.',
  inputSchema: { type: 'object', properties: {}, required: [] },
};
export async function handler(args) {
  throw new Error('graph_<name>: not yet implemented (P3 Task <N>)');
}
```

(Substitute `<name>` and the corresponding Task number per the table in §"File map".)

- [ ] **Step 2: Create `scripts/graph/mcp-tools/index.mjs`**

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
  const a = args ?? {};
  const effectiveCwd = a.cwd ?? process.cwd();
  const payload = await fn(a);
  // Byte-identical with CLI emit(): 2-space pretty-print, NO trailing newline.
  // The newline is CLI-only (emit appends one for terminal readability);
  // MCP content text matches the JSON body proper.
  return {
    content: [{ type: 'text', text: JSON.stringify(payload, null, 2) }],
    _effectiveCwd: effectiveCwd,
  };
}
```

- [ ] **Step 3: Replace `runMcpServer()` in `bin/sspower-graph.mjs:267-287`**

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
    let ok = true, effectiveCwd = (params.arguments?.cwd) ?? process.cwd();
    try {
      const result = await dispatch(params.name, params.arguments);
      effectiveCwd = result._effectiveCwd ?? effectiveCwd;
      // Strip internal hint before returning to client
      const { _effectiveCwd, ...client } = result;
      return client;
    } catch (e) {
      ok = false;
      throw e;
    } finally {
      try { recordEvent({ tool: params.name, ok, duration_ms: Date.now() - t0, cwd: effectiveCwd }); }
      catch (e) { process.stderr.write(`metric write failed: ${e.message}\n`); }
    }
  });
  await server.connect(new StdioServerTransport());
}
```

- [ ] **Step 4: Run existing MCP smoke test** (Task 5 stubs throw on callTool but listTools returns 7 entries)

```bash
node tests/graph/test-mcp-stub.mjs
```

The existing smoke test asserts `tools.tools[0].name === 'graph_status'` and calls `graph_status` expecting `{ok:true,stub:true}`. After Task 5, that callTool now throws (stub `handler` throws). Update the smoke test in Task 23 (rename to `test-mcp-integration.mjs`); for Task 5's verification just confirm listTools returns 7 entries:

```bash
node -e "
import('@modelcontextprotocol/sdk/client/index.js').then(async ({Client}) => {
  const { StdioClientTransport } = await import('@modelcontextprotocol/sdk/client/stdio.js');
  const t = new StdioClientTransport({
    command: process.cwd()+'/bin/sspower-graph-bootstrap.sh',
    args: ['serve','--mcp'],
    env: { ...process.env, CLAUDE_PLUGIN_ROOT: process.cwd() },
  });
  const c = new Client({name:'t',version:'0'},{capabilities:{}});
  await c.connect(t);
  const tools = (await c.listTools()).tools;
  console.assert(tools.length === 7, 'expected 7 tools');
  console.log('OK');
  await c.close();
});
"
```

Expected: `OK`.

- [ ] **Step 5: Commit**

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

- [ ] **Step 3: Run**

```bash
node tests/graph/test-mcp-tools-unit.mjs
```

- [ ] **Step 4: Stage + commit (Claude-mode)**

```bash
git add scripts/graph/mcp-tools/callers.mjs tests/graph/test-mcp-tools-unit.mjs
```

Suggested commit message at `/tmp/commit-msg-t7.txt`:

```
feat(graph): graph_callers MCP handler
```

Then (standalone Bash invocation per chokepoint policy):

```bash
git commit -F /tmp/commit-msg-t7.txt
```

Codex-mode: stop after `git add`; report `staged: scripts/graph/mcp-tools/callers.mjs tests/graph/test-mcp-tools-unit.mjs ; commit-msg: /tmp/commit-msg-t7.txt`.

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

// Cache invalidation: overwrite state with new sid, record again, expect new spool prefix
const fs2 = await import('node:fs');
await new Promise(r => setTimeout(r, 20));  // ensure mtime advances on coarse fs
fs2.default.writeFileSync(statePathFor(real), JSON.stringify({
  session_id: 'metric-test-sid-2', cwd: real, started_ts: new Date().toISOString(),
}));
process.chdir(real);
recordEvent({ tool: 'graph_status', ok: true, duration_ms: 1, cwd: real });
process.chdir(orig);
const after = fs.readdirSync(SPOOL_DIR).filter(f => f.endsWith('.jsonl'));
const sids = new Set(after.map(f => f.split('.')[0]));
assert.ok(sids.has('metric-test-sid'),   'old sid spool still present');
assert.ok(sids.has('metric-test-sid-2'), 'new sid not picked up — cache stale');
console.log('cache invalidation OK');
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

import { statePathFor } from '../session-state.mjs';
const sessionCache = new Map();  // canonical-cwd → { sid, source, stateMtimeMs }
function resolveSession(cwd) {
  let real;
  try { real = fs.realpathSync(cwd); } catch { real = cwd; }
  // Invalidate cache when the state file mtime changes (new SessionStart for
  // the same project = new session id, must rebind).
  let currentMtime = 0;
  try { currentMtime = fs.statSync(statePathFor(real)).mtimeMs; } catch {}
  const hit = sessionCache.get(real);
  if (hit && hit.stateMtimeMs === currentMtime) return hit;
  const r = readSessionState(real);
  const out = r.sessionId
    ? { sid: r.sessionId, source: 'claude_session_id', stateMtimeMs: currentMtime }
    : { sid: degradedId(real), source: 'degraded:' + r.source, stateMtimeMs: currentMtime };
  sessionCache.set(real, out);
  return out;
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
  // DECISION: Node-side O_CREAT|O_EXCL lockfile (NOT sspower_mem.lock.acquire_lock).
  //
  // Rationale: the Python helper requires spawning a subprocess per lock
  // acquisition (~30-100ms) for what is otherwise sub-ms work. The reconcile
  // critical section is small (read JSON, mutate, atomic-rename) and the
  // contention scenario is rare — CC dispatches one SessionEnd per session,
  // so concurrent reconcilers only collide if two CC instances exit at
  // approximately the same moment. Stale-lock recovery (mtime > 30s = force
  // remove) covers the orphan case.
  //
  // The Task 14 commit message must note this divergence from spec §3 which
  // calls out the Python helper as the canonical lock — Node lock is the
  // P3-D6 implementation choice and updates the spec implicitly. If spec
  // amendment is preferred, do that BEFORE Task 14 ships.
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

  // 2. Build summary row — includes per-tool call counts and duration samples
  //    so the aggregator (Task 15) can compute tool_histogram (call counts)
  //    and p95_duration_ms_by_tool over a multi-session window.
  const eligible = isEligible(cwd);
  const tool_calls = events.length;
  const unique_tools = [...new Set(events.map(e => e.tool))];
  const first = events[0]?.ts ?? null;
  const last  = events[events.length - 1]?.ts ?? null;
  const session_source = events[0]?.session_source ?? 'claude_session_id';
  const projectHashHex = (await import('node:crypto')).default
    .createHash('sha256').update(fs.realpathSync(cwd)).digest('hex').slice(0, 8);

  // Per-tool counts and per-tool duration samples (cap each sample list at 200
  // to bound row size; the cap is documented in the row schema as `duration_samples_cap`)
  const tool_counts = {};
  const tool_durations = {};
  for (const ev of events) {
    tool_counts[ev.tool] = (tool_counts[ev.tool] ?? 0) + 1;
    tool_durations[ev.tool] = tool_durations[ev.tool] ?? [];
    if (tool_durations[ev.tool].length < 200) tool_durations[ev.tool].push(ev.duration_ms);
  }

  const row = {
    session_id: session,
    schema_version: 2,                     // bumped from 1 because of tool_counts/durations
    duration_samples_cap: 200,
    session_source,
    eligible,
    tool_calls,
    tool_counts,                           // {graph_callers: N, ...}
    tool_durations,                        // {graph_callers: [12, 47, ...], ...}
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

- [ ] **Step 3: Add concurrent-reconcile test** to `tests/graph/test-mcp-metric.mjs`

```js
// Concurrent reconcilers on different sessions must not lose rows.
import { reconcile as recon2 } from '../../scripts/graph/mcp-tools/metric.mjs';
fs.rmSync(SESSIONS_PATH, { force: true });
// Spawn two real Node processes that both call reconcile concurrently:
const { spawn } = await import('node:child_process');
const sidA = 'concurrent-a', sidB = 'concurrent-b';
// Seed one event per session so both have non-empty spool
const realA = fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-conc-a-'));
const realB = fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-conc-b-'));
for (const [r, sid] of [[realA, sidA], [realB, sidB]]) {
  fs.mkdirSync(path.dirname(statePathFor(r)), { recursive: true });
  fs.writeFileSync(statePathFor(r), JSON.stringify({ session_id: sid, cwd: r, started_ts: new Date().toISOString() }));
  fs.mkdirSync(path.join(r, '.claude', 'graph'), { recursive: true });
  process.chdir(r);
  recordEvent({ tool: 'graph_status', ok: true, duration_ms: 1, cwd: r });
}
process.chdir(orig);

const PLUGIN_ROOT_STR = path.resolve(import.meta.dirname ?? path.dirname(new URL(import.meta.url).pathname), '../..');
const procs = [sidA, sidB].map(sid => spawn(process.execPath, [
  path.join(PLUGIN_ROOT_STR, 'scripts', 'graph', 'mcp-tools', 'metric.mjs'),
  'reconcile', '--session', sid, '--cwd', sid === sidA ? realA : realB,
]));
const results = await Promise.all(procs.map(p => new Promise(r => p.on('exit', c => r(c)))));
assert.deepEqual(results, [0, 0]);
const finalSess = JSON.parse(fs.readFileSync(SESSIONS_PATH, 'utf8')).sessions;
const ids = finalSess.map(s => s.session_id);
assert.ok(ids.includes(sidA), 'concurrent reconcile lost session A');
assert.ok(ids.includes(sidB), 'concurrent reconcile lost session B');
console.log('concurrent reconcile OK');
```

- [ ] **Step 4: Run + commit**

```bash
node tests/graph/test-mcp-metric.mjs
```

Expected: `recordEvent OK / cache invalidation OK / reconcile OK / reconcile eligibility OK / concurrent reconcile OK`.

Stage:

```bash
git add scripts/graph/mcp-tools/metric.mjs tests/graph/test-mcp-metric.mjs
```

Commit (Claude-mode standalone) using `/tmp/commit-msg-t14.txt`:

```
feat(graph): metric.mjs reconcile + sessions.json writer

reconcile() globs <sid>.*.jsonl spool, merges events, computes
per-session row (eligible if .claude/graph/ exists in cwd, tool_calls,
tool_counts, tool_durations, unique_tools, first/last/end timestamps,
end_reason). Acquires Node-side O_EXCL file lock around read-modify-
write of sessions.json (atomic temp+rename inside lock). Decision
note: chose Node lock over sspower_mem.lock.acquire_lock to avoid
30-100ms python subprocess spawn for sub-ms critical section; stale
lock (mtime>30s) force-removed. Concurrent-reconcile test gates this
choice. Archives spool to archive/<YYYYMM>/, prunes archives >60
days. CLI surface `node metric.mjs reconcile --session X --cwd Y
--reason Z` invoked by the SessionEnd hook.
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
    session_id: `synth-${i}`, schema_version: 2, duration_samples_cap: 200,
    session_source: 'claude_session_id',
    eligible: true, tool_calls: 1 + (i % 3),
    tool_counts: { graph_callers: 1 + (i % 3) },
    tool_durations: { graph_callers: Array.from({ length: 1 + (i % 3) }, (_, k) => 10 + k * 5) },
    unique_tools: ['graph_callers'], first_call_ts: '2026-05-27T00:00:00Z',
    last_call_ts: '2026-05-27T00:01:00Z', session_end_ts: `2026-05-27T0${(i%5)+1}:00:00Z`,
    project_hash: 'aa', cwd: '/x', end_reason: 'user_exit',
    zero_call_reason: null, degraded: false, bad_lines: 0, total_lines: 1 + (i % 3),
  });
}
fs.mkdirSync(SPOOL_DIR, { recursive: true });
fs.writeFileSync(SESSIONS_PATH, JSON.stringify({ schema_version: 1, sessions }));
const ag = aggregate({ window: 50 });
assert.equal(ag.gate_met, true);
assert.equal(ag.eligible_sessions_total, 50);
assert.equal(ag.sessions_with_call, 50);
// tool_histogram counts call counts (not session counts) → sum of tool_counts across window
const expectedCallers = sessions.reduce((a, s) => a + (s.tool_counts?.graph_callers ?? 0), 0);
assert.equal(ag.tool_histogram.graph_callers, expectedCallers, `histogram should sum call counts`);
assert.ok('graph_callers' in ag.p95_duration_ms_by_tool, 'p95 by tool present');
assert.ok(typeof ag.p95_duration_ms_by_tool.graph_callers === 'number');
assert.equal(ag.degraded_jsonl_parse_ratio, 0);
console.log('aggregate gate OK');

// Add one zero-call eligible session at the front (most recent) → gate fails
sessions.unshift({
  session_id: 'synth-zero', eligible: true, tool_calls: 0,
  tool_counts: {}, tool_durations: {}, unique_tools: [],
  first_call_ts: null, last_call_ts: null, session_end_ts: '2026-05-27T10:00:00Z',
  session_source: 'claude_session_id', schema_version: 2, duration_samples_cap: 200,
  project_hash: 'aa', cwd: '/x',
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
function p95(arr) {
  if (!arr.length) return null;
  const s = [...arr].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.floor(s.length * 0.95))];
}

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

  // tool_histogram = sum of per-session tool_counts across the window (call counts, not session counts)
  const tool_histogram = {};
  for (const s of eligible) {
    const counts = s.tool_counts ?? {};
    for (const [tool, n] of Object.entries(counts)) {
      tool_histogram[tool] = (tool_histogram[tool] ?? 0) + n;
    }
  }

  // p95_duration_ms_by_tool = p95 over pooled per-tool duration samples across window
  const p95_duration_ms_by_tool = {};
  const pooled = {};
  for (const s of eligible) {
    const td = s.tool_durations ?? {};
    for (const [tool, samples] of Object.entries(td)) {
      pooled[tool] = pooled[tool] ?? [];
      pooled[tool].push(...samples);
    }
  }
  for (const [tool, samples] of Object.entries(pooled)) {
    p95_duration_ms_by_tool[tool] = p95(samples);
  }

  // degraded_jsonl_parse_ratio = sum(bad_lines)/sum(total_lines) across window (avoid /0)
  const totBad = eligible.reduce((a, s) => a + (s.bad_lines ?? 0), 0);
  const totAll = eligible.reduce((a, s) => a + (s.total_lines ?? 0), 0);
  const degraded_jsonl_parse_ratio = totAll ? totBad / totAll : 0;

  const degraded_session_id_count = eligible.filter(s => s.degraded).length;
  return {
    window,
    eligible_sessions_total,
    sessions_with_call,
    adoption_rate,
    tool_histogram,
    p95_duration_ms_by_tool,
    degraded_session_id_count,
    degraded_jsonl_parse_ratio,
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

- [ ] **Step 1: Append exactly**

```markdown

## Graph tool guidance

Before signing off "looks fine":

- `mcp__sspower-graph__graph_impact <file>` — confirm the change radius
  matches the PR description. Mismatch (PR says "small refactor" but
  impact list is 40+ symbols) is a real blocker, not style nitpick.
- `mcp__sspower-graph__graph_trace <from> <to>` — when the diff claims
  to short-circuit a code path, trace from entry to exit and verify the
  path no longer exists.
- `mcp__sspower-graph__graph_status` — confirm the graph is fresh
  before relying on any other tool result. Stale index = no signal.

Hard rule: call graph tools BEFORE delegating to the Explore subagent;
never invoke graph tools from inside Explore.
```

- [ ] **Step 2: Commit**

```
docs(agents): sanity-reviewer graph tool guidance (P3 §5.3)
```

---

## Task 20: `agents/security-reviewer.md` — append Graph tool guidance

**Files:**
- Modify: `agents/security-reviewer.md`

- [ ] **Step 1: Append exactly**

```markdown

## Graph tool guidance

For taint analysis and auth-boundary verification:

- `mcp__sspower-graph__graph_impact <file>` — for any file touching
  auth/crypto/secrets handlers, list the transitive reach. Any
  unexpected sink (logging, telemetry, response body) is a finding.
- `mcp__sspower-graph__graph_callers <sink>` — when reviewing a known
  dangerous sink (e.g. `eval`, raw SQL exec, shell exec), enumerate all
  callers and verify each input is validated.
- `mcp__sspower-graph__graph_trace <user_input> <sink>` — confirm or
  refute the existence of a taint path from user input to the sink.

Hard rule: call graph tools BEFORE delegating to the Explore subagent;
never invoke graph tools from inside Explore.
```

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

## Task 22: MCP-vs-CLI byte-identical parity (P3-D2 hard gate)

**Files:**
- Create: `tests/graph/test-mcp-cli-parity.mjs`

**Rationale**: P3-D2 says MCP `content[0].text` must match CLI `--json` byte-identical. The integration smoke in Task 23 only checks parseability. Parity must be asserted.

- [ ] **Step 1: Write the test**

```js
// tests/graph/test-mcp-cli-parity.mjs
import assert from 'node:assert/strict';
import path from 'node:path';
import url from 'node:url';
import { spawnSync } from 'node:child_process';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const PLUGIN_ROOT = path.resolve(url.fileURLToPath(import.meta.url), '../../..');
const FIXTURE = path.join(PLUGIN_ROOT, '__tests__', 'graph-fixtures', 'ts-js');
const GRAPH = path.join(PLUGIN_ROOT, 'bin', 'sspower-graph.mjs');

function cliJson(verb, ...args) {
  const r = spawnSync(process.execPath, [GRAPH, verb, '--cwd', FIXTURE, '--json', ...args], { encoding: 'utf8' });
  assert.equal(r.status, 0, `cli ${verb} stderr=${r.stderr}`);
  return r.stdout.trimEnd();   // CLI adds a trailing newline via emit(); JSON.parse-equivalent string
}

const transport = new StdioClientTransport({
  command: path.join(PLUGIN_ROOT, 'bin', 'sspower-graph-bootstrap.sh'),
  args: ['serve', '--mcp'],
  env: { ...process.env, CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT },
  cwd: FIXTURE,
});
const client = new Client({ name: 'parity', version: '0' }, { capabilities: {} });
await client.connect(transport);

const cases = [
  ['graph_status',  {},                             []],
  ['graph_callers', { name: 'fnA' },                ['fnA']],
  ['graph_callees', { name: 'fnA' },                ['fnA']],
  ['graph_node',    { name: 'fnA' },                ['fnA']],
  ['graph_trace',   { from: 'fnA', to: 'fnB' },     ['fnA', 'fnB']],
  ['graph_impact',  { file: 'src/a.ts' },           ['src/a.ts']],
  ['graph_context', { task: 'add caching to fnA' }, ['add caching to fnA']],
];

for (const [mcpName, mcpArgs, cliArgs] of cases) {
  const r = await client.callTool({ name: mcpName, arguments: mcpArgs });
  const mcpText = r.content[0].text;
  const cliRaw = cliJson(mcpName.replace(/^graph_/, ''), ...cliArgs);
  // P3-D2 byte-identical contract. Both sides run `JSON.stringify` on the
  // SAME query function's return value (same insertion order, same nested
  // shape). Compare raw strings; any divergence is a real bug in queries.mjs
  // or the emit() path.
  assert.equal(mcpText, cliRaw, `${mcpName}: MCP/CLI raw byte mismatch\nMCP=${mcpText}\nCLI=${cliRaw}`);
}

await client.close();
console.log('MCP/CLI byte-identical parity OK (7 tools)');
```

**Note on byte vs canonical**: spec §10 P3-D2 says "byte-identical". Because both MCP and CLI call the same `queryX()` function and `JSON.stringify` is deterministic for a given input object, the output should match byte-for-byte. If this test fails, the bug is in the query layer (or the CLI's `emit()` is stripping/adding whitespace) — do NOT loosen the assertion to canonical comparison; fix the source.

**CLI trailing newline**: `emit()` in `bin/sspower-graph.mjs` appends `\n` after `JSON.stringify`. The test's `cliJson()` uses `trimEnd()` to strip it, so the comparison is against the JSON body proper. MCP content text has no trailing newline (the SDK does not add one). If `emit()` ever changes formatting, update the trim accordingly.

- [ ] **Step 2: Run — expect PASS**

```bash
node tests/graph/test-mcp-cli-parity.mjs
```

- [ ] **Step 3: Commit**

```
test(graph): MCP/CLI canonical-JSON parity (P3-D2)

Asserts each of the 7 MCP tools returns content[0].text whose
canonical (key-sorted) JSON matches the corresponding CLI --json
output for the same args. Stronger than parseability; catches any
schema drift between query() returns and CLI emit().
```

---

## Task 22b: Bootstrap server-key collision preflight (spec §8)

**Files:**
- Modify: `bin/sspower-graph-bootstrap.sh` (add preflight block)
- Modify: `README.md` (document `SSPOWER_GRAPH_MCP_KEY` override)

**Rationale**: spec §8 risks row requires the bootstrap to detect a foreign `mcpServers.sspower-graph` definition and fail loudly. Without this, a user installing both this plugin and an unrelated server using the same key gets silent breakage.

- [ ] **Step 1: Add preflight to `bin/sspower-graph-bootstrap.sh`** before the lazy install block:

```bash
SERVER_KEY="${SSPOWER_GRAPH_MCP_KEY:-sspower-graph}"
OWN_CMD_ABS="$ROOT/bin/sspower-graph-bootstrap.sh"
OWN_CMD_TEMPLATE='${CLAUDE_PLUGIN_ROOT}/bin/sspower-graph-bootstrap.sh'
OWN_MCP_JSON="$ROOT/.mcp.json"

for CFG in "$HOME/.claude.json" "$PWD/.mcp.json"; do
  [ -f "$CFG" ] || continue
  # Skip our own packaged .mcp.json: it lives at $ROOT/.mcp.json and uses the
  # unexpanded ${CLAUDE_PLUGIN_ROOT} template — comparing it to the absolute
  # OWN_CMD_ABS would always false-positive.
  if [ "$CFG" = "$OWN_MCP_JSON" ]; then continue; fi
  if command -v jq >/dev/null 2>&1; then
    FOREIGN=$(jq -r \
      --arg key "$SERVER_KEY" \
      --arg own_abs "$OWN_CMD_ABS" \
      --arg own_tpl "$OWN_CMD_TEMPLATE" '
      (.mcpServers // {}) | to_entries[]?
      | select(.key == $key)
      | select((.value.command // "") != $own_abs
            and (.value.command // "") != $own_tpl)
      | "\($key) in '"$CFG"' is owned by " + (.value.command // "<unset>")
    ' "$CFG" 2>/dev/null || true)
    if [ -n "$FOREIGN" ]; then
      echo "sspower-graph: MCP server key collision: $FOREIGN" >&2
      echo "  override with SSPOWER_GRAPH_MCP_KEY=<unique-key> in the foreign config" >&2
      exit 78
    fi
  fi
done
```

Exit code `78` (EX_CONFIG from sysexits.h) signals "the user must reconfigure". Accepts BOTH the absolute path AND the literal template string as "own command", and explicitly skips the plugin's own packaged `.mcp.json` to avoid the false-positive Codex flagged.

- [ ] **Step 2: Document override in `README.md`**

Add a paragraph under sspower-graph install instructions:

> If you already have an MCP server registered under the key `sspower-graph` from another plugin or your own config, set `SSPOWER_GRAPH_MCP_KEY=sspower-graph-v2` (or any unique key) in the foreign config's `command` env to disambiguate. The sspower bootstrap detects collisions at startup and exits 78 if found.

- [ ] **Step 3: Write contract test — both negative and positive paths**

```js
// tests/graph/test-bootstrap-preflight.mjs
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawnSync } from 'node:child_process';
import url from 'node:url';
const PLUGIN_ROOT = path.resolve(url.fileURLToPath(import.meta.url), '../../..');

// --- Case 1: foreign config in tmp cwd → exit 78
const tmp1 = fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-pre-foreign-'));
fs.writeFileSync(path.join(tmp1, '.mcp.json'), JSON.stringify({
  mcpServers: { 'sspower-graph': { command: '/usr/bin/some-other-tool' } },
}));
let r = spawnSync('bash', [path.join(PLUGIN_ROOT, 'bin', 'sspower-graph-bootstrap.sh'), '--print-cwd'], {
  cwd: tmp1,
  env: { ...process.env, CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT, NODE: process.execPath, HOME: tmp1 },
  encoding: 'utf8',
});
assert.equal(r.status, 78, `case 1 expected 78, got ${r.status} stderr=${r.stderr}`);
assert.ok(r.stderr.includes('collision'), 'case 1 stderr mentions collision');
console.log('preflight foreign collision OK');

// --- Case 2: plugin's own .mcp.json template → MUST NOT trip
// Spawn bootstrap from the plugin root itself; PWD/.mcp.json == $ROOT/.mcp.json.
r = spawnSync('bash', [path.join(PLUGIN_ROOT, 'bin', 'sspower-graph-bootstrap.sh'), '--print-cwd'], {
  cwd: PLUGIN_ROOT,
  env: { ...process.env, CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT, NODE: process.execPath, HOME: fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-pre-home-')) },
  encoding: 'utf8',
});
assert.equal(r.status, 0, `case 2 (own .mcp.json) expected 0, got ${r.status} stderr=${r.stderr}`);
console.log('preflight own-config skip OK');

// --- Case 3: matching template in foreign location → MUST NOT trip
const tmp3 = fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-pre-tpl-'));
fs.writeFileSync(path.join(tmp3, '.mcp.json'), JSON.stringify({
  mcpServers: { 'sspower-graph': { command: '${CLAUDE_PLUGIN_ROOT}/bin/sspower-graph-bootstrap.sh' } },
}));
r = spawnSync('bash', [path.join(PLUGIN_ROOT, 'bin', 'sspower-graph-bootstrap.sh'), '--print-cwd'], {
  cwd: tmp3,
  env: { ...process.env, CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT, NODE: process.execPath, HOME: tmp3 },
  encoding: 'utf8',
});
assert.equal(r.status, 0, `case 3 (template match) expected 0, got ${r.status} stderr=${r.stderr}`);
console.log('preflight template-match accept OK');
```

- [ ] **Step 4: Run + commit**

```
feat(graph): bootstrap MCP server-key collision preflight (spec §8)

If ~/.claude.json or <cwd>/.mcp.json defines mcpServers.sspower-graph
with a command that is not our bootstrap, exit 78 (EX_CONFIG) with a
clear stderr pointer to SSPOWER_GRAPH_MCP_KEY override. README updated.
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
node tests/graph/test-bootstrap-preflight.mjs
node tests/graph/test-session-state-unit.mjs
node tests/graph/test-session-state-contract.mjs
node tests/graph/test-p2-cli-back-compat.mjs
node tests/graph/test-mcp-tools-unit.mjs
node tests/graph/test-mcp-integration.mjs
node tests/graph/test-mcp-cli-parity.mjs
node tests/graph/test-mcp-metric.mjs
node tests/graph/test-mcp-metric-zerocall.mjs
node tests/graph/test-mcp-metric-concurrency.mjs
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
- [ ] Bootstrap server-key collision preflight green (Task 22b)
- [ ] Per-project session-state file written by SessionStart hook (P3-D4, sha8 8-hex); unit + contract tests green
- [ ] 7 MCP handlers (`graph_status/callers/callees/trace/impact/node/context`); unit tests green; integration smoke green; MCP/CLI parity green (Task 22)
- [ ] `recordEvent` (per-cwd session cache) + `reconcile` (schema_version:2 with `tool_counts` + `tool_durations`) + `aggregate` (computes `tool_histogram` as call counts, `p95_duration_ms_by_tool`, `degraded_jsonl_parse_ratio`) + `sspower-graph metric` CLI; concurrency test green; zero-call gate test green
- [ ] 3 reviewer agents have `## Graph tool guidance` (verbatim §5.2/§5.3/§5.4); manual smoke captures ≥1 MCP call per agent before any Explore delegation
- [ ] P2 CLI back-compat regression test green — all P2 verbs (build/refresh/session-refresh/status/callers/callees/trace/impact/context/node) × 5 fixture packs, byte-identical `--json`, empty stderr, exit 0
- [ ] Plan-review verdict cached as `approve` or `approve-with-followups`
- [ ] `1.4.0` shipped on `main`, tag `graph-p3` pushed, PR merged
- [ ] Adoption snapshot committed; week-2 observation window open for the 50-session gate

If any §9 anti-goal trigger fires: STOP, draft `codegraph install` companion plan, ship that instead.
