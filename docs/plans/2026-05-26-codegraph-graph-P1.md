# Codegraph-style Symbol Graph — P1 TS/JS Extractor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use sspower:subagent-driven-development (recommended) or sspower:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the TS/JS extractor, full SQLite schema §3.1, and the five P1 CLI commands (`build`, `callers`, `callees`, `node`, `status`) so the P0 fixture harness flips from goldens-only mode into a real precision/recall gate, and `sspower-graph callers cmdImplement` returns the call-site at `scripts/codex-bridge.mjs:2061` (the `main()` dispatcher).

**Architecture:** Extractor is pure Node 22 (`node:sqlite` + `crypto`) calling `ast-grep scan -r <yaml-rule>` per-file via `child_process.spawn`. Schema lands COMPLETE in P1 (including `imports` table + FTS triggers) so P2 refresh has zero migrations to perform. The single-lock contract from P0 (D34/D38) is honored by re-execing `bin/sspower-graph.mjs build` through `scripts/graph-with-lock.py`; the inner Node process runs as `build-unlocked` and the Python wrapper holds `fcntl.flock` across the entire SQLite transaction. P1 does NOT touch `refresh`, hooks, MCP expansion, or non-TS languages — those gate later phases.

**Tech Stack:** Node 22 (`node:sqlite`, `crypto`, `child_process`, `fs/promises`), ast-grep ≥0.43 invoked via YAML rule files under `scripts/graph/rules/`, Python lock helpers from P0 (`scripts/graph-with-lock.py`), vitest for the rewired fixture harness.

**Spec:** `docs/specs/2026-05-26-codegraph-style-graph-design.md` v5 §3.1 schema, §3.2 extraction pipeline, §3.6 CLI, §4 P1 row, §5 known limits. Locked decisions D1–D40 + FU1–FU4. **Followups already inline-resolved in spec v5.1** — no spec edits required for P1.

**Spec line correction (load-bearing):** The handoff and spec §4 P1 row cite `cmdImplement` "at `scripts/codex-bridge.mjs:1519`". The function declaration has since moved to **line 1553** and the call-site is at **line 2061** (inside `async function main()` starting at line 2010). P1 acceptance uses these current line numbers; the spec text is stale but the symbol name is the contract — the line move is not a spec violation, but Task 9 verifies both.

**Branch policy:** Branch `feat/graph-P1` off tag `graph-p0` (HEAD as of 2026-05-26). Do NOT merge to `main` until Task 13 codex-review verdict is `approve` or `approve-with-followups` AND Task 9 acceptance demo passes.

---

## File map

**Create (new files):**
- `scripts/graph/db.mjs` — `openDb(path)` + `initSchema(db)` (full §3.1 schema, idempotent via `CREATE TABLE IF NOT EXISTS`)
- `scripts/graph/walk.mjs` — `walkSources(rootDir)` async iterator over TS/JS files, respects `git ls-files` when available
- `scripts/graph/rules/ts-function.yml` — ast-grep rule, kind=function_declaration
- `scripts/graph/rules/ts-arrow.yml` — ast-grep rule, kind=variable_declarator with arrow_function value
- `scripts/graph/rules/ts-class.yml` — ast-grep rule, kind=class_declaration
- `scripts/graph/rules/ts-method.yml` — ast-grep rule, kind=method_definition
- `scripts/graph/rules/ts-call.yml` — ast-grep rule, kind=call_expression
- `scripts/graph/rules/ts-import.yml` — ast-grep rule, kind=import_statement
- `scripts/graph/astgrep.mjs` — `runRule(rulePath, file)` thin spawn wrapper, returns parsed JSON array; 0→1 line offset normalization
- `scripts/graph/extract-ts.mjs` — `extractFile({path, source})` returns `{nodes, imports, callSites}`; assembles qualified names; computes `span_sha8`
- `scripts/graph/resolve.mjs` — `resolveModule(importerAbs, spec)` + `resolveEdges({nodes, callSites})` (intra→1, imported→2, ambiguous→0)
- `scripts/graph/build.mjs` — orchestrates walk → extract → resolve → batched insert; called by `bin/sspower-graph.mjs build-unlocked`
- `scripts/graph/query.mjs` — `callers(db,name,opts)` / `callees(db,name,opts)` / `nodeLookup(db,name)` / `status(db,graphDir)`; MAX_RESULTS=50
- `tests/graph/test-db-schema.mjs` — schema test (idempotent init, FK on, WAL on)
- `tests/graph/test-astgrep.mjs` — spawn wrapper test, line-offset normalization
- `tests/graph/test-extract-ts.mjs` — extractor unit test against ts-js fixture
- `tests/graph/test-resolve.mjs` — resolver test (intra/imported/ambiguous confidence)
- `tests/graph/test-walk.mjs` — walker test (git + non-git paths)
- `tests/graph/test-build-query.mjs` — end-to-end test (fixture + live cmdImplement demo)
- `__tests__/graph-fixtures/ts-js-multifile/` — second fixture pack proving cross-file `confidence=2`

**Modify:**
- `bin/sspower-graph.mjs` — extend argv dispatcher: `build|build-unlocked|callers|callees|node|status|serve`; keep `serve --mcp` P0 behavior
- `__tests__/graph-fixtures/harness.test.ts` — replace goldens-only mode with extractor-comparison + precision/recall (P=0.85, R=0.70 thresholds)
- `__tests__/graph-fixtures/ts-js/expected.json` — re-baseline to match what the extractor produces (intra-file caller→helper is confidence=1, not 2; add class nodes)
- `package.json` — no new deps; bump `version` to `1.2.0-rc.0` (promoted to `1.2.0` at merge)
- `README.md` — add CLI usage block under `## sspower-graph` (create heading if absent)

**Out of scope (P2+ — explicitly NOT in P1):**
- `refresh` / dirty-queue processing
- PostToolUse:Write|Edit|MultiEdit hook (`graph-mark-dirty.sh`)
- SessionStart sweep / external-edit scan
- Trace, impact, context, routes commands
- Python, Go, Rust extractors
- MCP tool expansion beyond P0 `graph_status` (P3 owns full MCP surface)
- `graph-orchestrator.sh` and `auto-review.sh` enrichment (P4)
- Framework route extractors (P5+)

---

## Task 1: Branch off graph-p0, bump version, create plan-tracking commit

**Files:**
- Modify: `package.json`
- Create: this plan doc (already created)

- [ ] **Step 1.1: Verify we're at the right starting point**

```bash
cd /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower
git fetch --tags
git rev-parse 'graph-p0^{commit}'
git rev-parse 'main^{commit}'
```
Expected: both print the same commit SHA. `graph-p0` is an annotated tag — `git rev-parse graph-p0` without `^{commit}` returns the tag-object SHA, NOT the commit, so always use `^{commit}` when comparing tags to branch HEADs. If the resolved commit SHAs differ, branch from `graph-p0^{commit}` anyway and surface the divergence to the user in the Task 1.6 commit message.

- [ ] **Step 1.2: Confirm working tree clean of unrelated changes**

```bash
git status --porcelain
```
Expected: a SUBSET of (a) the 3 dirty files originally noted in `docs/handoff.md` (`hooks/auto-review.sh`, `scripts/codex-bridge.mjs`, `scripts/mcp-lsp-client.mjs`) — INTENTIONALLY UNTOUCHED by P1; these may have been committed in the interim, in which case `git status` will show none of them, which is also fine. PLUS (b) the untracked plan file `?? docs/plans/2026-05-26-codegraph-graph-P1.md` (this file, created before branching). If anything ELSE is dirty (a path not in either group), STOP and ask the user.

- [ ] **Step 1.3: Create P1 branch off the tag**

```bash
git checkout -b feat/graph-P1 graph-p0
```
Expected: `Switched to a new branch 'feat/graph-P1'`.

- [ ] **Step 1.4: Bump package.json version**

Read `package.json` first, then change `"version": "1.1.1"` → `"version": "1.2.0-rc.0"` (rc until P1 merges, then Task 13.3 promotes to `1.2.0`).

- [ ] **Step 1.5: Pin Node engine to ≥22.5 (node:sqlite API floor)**

Spec D7 picks `node:sqlite`. The `DatabaseSync` constructor + multi-statement `exec` API used by Task 2 stabilized in Node 22.5 (earlier 22.x ships a partial surface and `--experimental-sqlite` flag is required). Update `package.json` `engines.node` from the P0 value `>=22.0.0` to **`>=22.5.0`** in the same Task 1.4 edit (do both version bump + engine bump in one shot so the commit message in Task 1.6 covers both).

Also add a startup gate at the top of `bin/sspower-graph.mjs` (you'll already be modifying this file in Task 9, but the gate is small enough to land here):
```js
const [major, minor] = process.versions.node.split('.').map(Number);
if (major < 22 || (major === 22 && minor < 5)) {
  console.error(`error: sspower-graph requires Node >=22.5 (node:sqlite stable surface). Current: ${process.versions.node}`);
  process.exit(2);
}
```
This gate runs BEFORE any `node:sqlite` import so users on Node 22.0–22.4 get a clean error instead of a stack trace.

- [ ] **Step 1.6: Run the existing P0 test suite to confirm baseline GREEN**

```bash
bash tests/hooks/test-intent-architecture.sh
CLAUDE_PLUGIN_ROOT="$(pwd)" python3 tests/graph/test-lock-helpers.py
CLAUDE_PLUGIN_ROOT="$(pwd)" node tests/graph/test-mcp-stub.mjs
bun x vitest run __tests__/graph-fixtures/ --reporter=basic
```
Expected: all four green. If any fail, STOP — P1 cannot start on a broken P0.

- [ ] **Step 1.7: Commit plan + version bump + engine bump**

Write `/tmp/commit-msg-p1-1.txt`:
```
chore(graph): cut P1 development branch, rc.0 marker, engine bump

Plan: docs/plans/2026-05-26-codegraph-graph-P1.md.
Branched off graph-p0^{commit}. Version 1.1.1 → 1.2.0-rc.0; engines.node
floor 22.0.0 → 22.5.0 (node:sqlite stable surface required by P1
extractor). Promotion to 1.2.0 happens at merge time.
```

```bash
git add package.json docs/plans/2026-05-26-codegraph-graph-P1.md
git commit -F /tmp/commit-msg-p1-1.txt
```

---

## Task 2: SQLite schema landing (full §3.1, idempotent)

**Files:**
- Create: `scripts/graph/db.mjs`
- Test: `tests/graph/test-db-schema.mjs`

- [ ] **Step 2.1: Confirm `node:sqlite` available on the pinned Node version**

Engine floor is `>=22.5.0` (Task 1.5). On Node 22.5+ the `node:sqlite` module is auto-loaded without the `--experimental-sqlite` flag, though `ExperimentalWarning` still prints to stderr — that is expected (spec D7) and does NOT need to be silenced.

```bash
node -e \
  "import('node:sqlite').then(m => { const db = new m.DatabaseSync(':memory:'); db.exec('CREATE TABLE t(x)'); console.log('OK', !!db); })"
```
Expected: `OK true` on stdout. If Node version is below 22.5, the startup gate from Task 1.5 will already have failed earlier — do NOT add `--experimental-sqlite` as a workaround; bump the runtime instead.

- [ ] **Step 2.2: Write the schema test first (red)**

Create `tests/graph/test-db-schema.mjs`:
```js
#!/usr/bin/env node
import { openDb, initSchema } from '../../scripts/graph/db.mjs';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'sspower-graph-'));
const dbPath = path.join(tmp, 'index.sqlite');

const db = openDb(dbPath);
initSchema(db);

const tables = db.prepare(
  "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
).all().map(r => r.name);
assert.deepEqual(
  tables.filter(t => !t.startsWith('nodes_fts') && !t.startsWith('sqlite_')),
  ['edges', 'files', 'imports', 'nodes'],
  `tables=${JSON.stringify(tables)}`
);

const fts = db.prepare(
  "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'nodes_fts%'"
).all().map(r => r.name);
assert.ok(fts.includes('nodes_fts'), `fts tables=${JSON.stringify(fts)}`);

const triggers = db.prepare(
  "SELECT name FROM sqlite_master WHERE type='trigger' ORDER BY name"
).all().map(r => r.name);
assert.deepEqual(triggers, ['nodes_ad', 'nodes_ai', 'nodes_au']);

initSchema(db);  // idempotency

const mode = db.prepare('PRAGMA journal_mode').get().journal_mode;
assert.equal(mode, 'wal');

const fk = db.prepare('PRAGMA foreign_keys').get().foreign_keys;
assert.equal(fk, 1);

db.close();
fs.rmSync(tmp, { recursive: true });
console.log('OK schema test');
```

- [ ] **Step 2.3: Run the test — expect failure**

```bash
node tests/graph/test-db-schema.mjs
```
Expected: `Cannot find module '.../scripts/graph/db.mjs'`.

- [ ] **Step 2.4: Implement `scripts/graph/db.mjs`**

```js
// scripts/graph/db.mjs
import { DatabaseSync } from 'node:sqlite';
import fs from 'node:fs';
import path from 'node:path';

export function openDb(dbPath) {
  fs.mkdirSync(path.dirname(dbPath), { recursive: true, mode: 0o700 });
  const db = new DatabaseSync(dbPath);
  db.exec('PRAGMA journal_mode=WAL');
  db.exec('PRAGMA foreign_keys=ON');
  db.exec('PRAGMA synchronous=NORMAL');
  return db;
}

const SCHEMA = `
CREATE TABLE IF NOT EXISTS files (
  path            TEXT PRIMARY KEY,
  content_hash    TEXT NOT NULL,
  language        TEXT NOT NULL,
  indexed_at      INTEGER NOT NULL,
  node_count      INTEGER DEFAULT 0
);
CREATE TABLE IF NOT EXISTS nodes (
  id              TEXT PRIMARY KEY,
  kind            TEXT NOT NULL,
  name            TEXT NOT NULL,
  qualified_name  TEXT NOT NULL,
  file_path       TEXT NOT NULL REFERENCES files(path) ON DELETE CASCADE,
  language        TEXT NOT NULL,
  start_line      INTEGER NOT NULL,
  end_line        INTEGER NOT NULL,
  signature       TEXT,
  span_sha8       TEXT NOT NULL,
  updated_at      INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS edges (
  source          TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
  target          TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
  kind            TEXT NOT NULL,
  line            INTEGER,
  confidence      INTEGER NOT NULL,
  PRIMARY KEY (source, target, kind, line)
);
CREATE TABLE IF NOT EXISTS imports (
  importer_path   TEXT NOT NULL REFERENCES files(path) ON DELETE CASCADE,
  imported_path   TEXT NOT NULL,
  PRIMARY KEY (importer_path, imported_path)
);
CREATE INDEX IF NOT EXISTS idx_imports_imported ON imports(imported_path);
CREATE INDEX IF NOT EXISTS idx_nodes_name        ON nodes(name);
CREATE INDEX IF NOT EXISTS idx_nodes_qname       ON nodes(qualified_name);
CREATE INDEX IF NOT EXISTS idx_nodes_file        ON nodes(file_path);
CREATE INDEX IF NOT EXISTS idx_edges_target_kind ON edges(target, kind);
`;

const FTS = `
CREATE VIRTUAL TABLE IF NOT EXISTS nodes_fts USING fts5(
  name, qualified_name, signature,
  content='nodes', content_rowid='rowid'
);
`;

const TRIGGERS = `
CREATE TRIGGER IF NOT EXISTS nodes_ai AFTER INSERT ON nodes BEGIN
  INSERT INTO nodes_fts(rowid, name, qualified_name, signature)
  VALUES (new.rowid, new.name, new.qualified_name, new.signature);
END;
CREATE TRIGGER IF NOT EXISTS nodes_ad AFTER DELETE ON nodes BEGIN
  INSERT INTO nodes_fts(nodes_fts, rowid, name, qualified_name, signature)
  VALUES('delete', old.rowid, old.name, old.qualified_name, old.signature);
END;
CREATE TRIGGER IF NOT EXISTS nodes_au AFTER UPDATE ON nodes BEGIN
  INSERT INTO nodes_fts(nodes_fts, rowid, name, qualified_name, signature)
  VALUES('delete', old.rowid, old.name, old.qualified_name, old.signature);
  INSERT INTO nodes_fts(rowid, name, qualified_name, signature)
  VALUES (new.rowid, new.name, new.qualified_name, new.signature);
END;
`;

export function initSchema(db) {
  db.exec(SCHEMA);
  db.exec(FTS);
  db.exec(TRIGGERS);
}

export function nodeId(filePath, qualifiedName, spanSha8) {
  return `${filePath}#${qualifiedName}#${spanSha8}`;
}
```

- [ ] **Step 2.5: Run the test — expect pass**

```bash
node tests/graph/test-db-schema.mjs
```
Expected: `OK schema test`.

- [ ] **Step 2.6: Commit**

Write `/tmp/commit-msg-p1-2.txt`:
```
feat(graph): land full §3.1 SQLite schema with FTS + triggers

Spec v5 D2, D17 (FK cascade), D18 (imports table). All CREATE TABLE
statements use IF NOT EXISTS so initSchema is idempotent — important
for repeated build calls on the same index without a drop step.
nodeId helper centralizes the stable-ID format <file>#<qname>#<span_sha8>
so the extractor and resolver never disagree on canonical form.
```

```bash
git add scripts/graph/db.mjs tests/graph/test-db-schema.mjs
git commit -F /tmp/commit-msg-p1-2.txt
```

---

## Task 3: ast-grep YAML rules + spawn wrapper

**Files:**
- Create: `scripts/graph/rules/ts-{function,arrow,class,method,call,import}.yml`
- Create: `scripts/graph/astgrep.mjs`
- Test: `tests/graph/test-astgrep.mjs`

**Why YAML rules and not pattern-mode (`-p`):** verified during plan authoring (2026-05-26): pattern-mode with `$$$` placeholders for body returns empty on TS function declarations in ast-grep 0.43.0, while `kind: function_declaration` rule scans return the expected nodes. Rule files are also reusable across multi-file scans.

- [ ] **Step 3.1: Verify ast-grep + tree-sitter-typescript work**

```bash
ast-grep --version
```
Expected: `ast-grep 0.43.0` or newer.

- [ ] **Step 3.2: Create the six rule files**

`scripts/graph/rules/ts-function.yml`:
```yaml
id: ts-function
language: typescript
rule:
  kind: function_declaration
```

`scripts/graph/rules/ts-arrow.yml`:
```yaml
id: ts-arrow
language: typescript
rule:
  all:
    - kind: variable_declarator
    - has:
        kind: arrow_function
```

`scripts/graph/rules/ts-class.yml`:
```yaml
id: ts-class
language: typescript
rule:
  kind: class_declaration
```

`scripts/graph/rules/ts-method.yml`:
```yaml
id: ts-method
language: typescript
rule:
  kind: method_definition
```

`scripts/graph/rules/ts-call.yml`:
```yaml
id: ts-call
language: typescript
rule:
  kind: call_expression
```

`scripts/graph/rules/ts-import.yml`:
```yaml
id: ts-import
language: typescript
rule:
  kind: import_statement
```

- [ ] **Step 3.3: Smoke-test each rule against the existing fixture**

```bash
for r in scripts/graph/rules/ts-*.yml; do
  echo "=== $r ==="
  ast-grep scan -r "$r" __tests__/graph-fixtures/ts-js/sample-input.ts --json=compact 2>&1 \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'matches={len(d)}')"
done
```
Expected (against the existing fixture):
- ts-function → 3 (helper, caller, ambiguous)
- ts-arrow → 0 (fixture has no arrow assignments)
- ts-class → 2 (A, B)
- ts-method → 2 (A.shared, B.shared)
- ts-call → 3 (helper(42), a.shared(), b.shared())
- ts-import → 0 (fixture has no imports)

If any count is off, fix the rule before continuing — Task 4 depends on these counts.

- [ ] **Step 3.4: Write the spawn-wrapper test first (red)**

Create `tests/graph/test-astgrep.mjs`:
```js
#!/usr/bin/env node
import { runRule } from '../../scripts/graph/astgrep.mjs';
import assert from 'node:assert/strict';
import path from 'node:path';

const ROOT = path.resolve(import.meta.dirname, '..', '..');
const fixture = path.join(ROOT, '__tests__', 'graph-fixtures', 'ts-js', 'sample-input.ts');

const fns = await runRule(path.join(ROOT, 'scripts/graph/rules/ts-function.yml'), fixture);
assert.equal(fns.length, 3, `expected 3 functions, got ${fns.length}`);

const helper = fns.find(n => n.text.startsWith('function helper'));
assert.equal(helper.startLine, 5, `helper.startLine=${helper.startLine}`);
assert.equal(helper.endLine, 7);
assert.ok(typeof helper.byteStart === 'number');
assert.ok(typeof helper.byteEnd === 'number');

const calls = await runRule(path.join(ROOT, 'scripts/graph/rules/ts-call.yml'), fixture);
assert.equal(calls.length, 3);

console.log('OK astgrep wrapper');
```

- [ ] **Step 3.5: Run the test — expect failure**

```bash
node tests/graph/test-astgrep.mjs
```
Expected: `Cannot find module '.../scripts/graph/astgrep.mjs'`.

- [ ] **Step 3.6: Implement `scripts/graph/astgrep.mjs`**

```js
// scripts/graph/astgrep.mjs
import { spawn } from 'node:child_process';

const BIN = process.env.SSPOWER_AST_GREP_BIN ?? 'ast-grep';

export function runRule(rulePath, filePath, { timeoutMs = 10_000 } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(BIN, ['scan', '-r', rulePath, filePath, '--json=compact'], {
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    const timer = setTimeout(() => {
      child.kill('SIGKILL');
      reject(new Error(`ast-grep timeout after ${timeoutMs}ms: ${rulePath} ${filePath}`));
    }, timeoutMs);
    child.stdout.on('data', c => { stdout += c; });
    child.stderr.on('data', c => { stderr += c; });
    child.on('error', e => { clearTimeout(timer); reject(e); });
    child.on('close', code => {
      clearTimeout(timer);
      if (code !== 0 && stdout.trim() === '') {
        return reject(new Error(`ast-grep exit ${code}: ${stderr.trim()}`));
      }
      let parsed;
      try {
        parsed = stdout.trim() === '' ? [] : JSON.parse(stdout);
      } catch (e) {
        return reject(new Error(`ast-grep json parse failed: ${e.message}; stdout=${stdout.slice(0, 200)}`));
      }
      resolve(parsed.map(normalize));
    });
  });
}

function normalize(m) {
  // Verified shape for ast-grep 0.43.0 `scan --json=compact`:
  // { text, range: { start:{line,column}, end:{line,column}, byteOffset:{start,end} }, ... }
  // Fail loud if the shape drifts in a future ast-grep release rather than
  // silently producing nodes with NaN line numbers.
  if (!m.range?.start || !m.range?.end || !m.range?.byteOffset) {
    throw new Error(`ast-grep JSON shape changed: missing range.{start,end,byteOffset} on ${JSON.stringify(m).slice(0, 200)}`);
  }
  return {
    text: m.text,
    startLine: m.range.start.line + 1,
    endLine: m.range.end.line + 1,
    startCol: m.range.start.column + 1,
    endCol: m.range.end.column + 1,
    byteStart: m.range.byteOffset.start,
    byteEnd: m.range.byteOffset.end,
  };
}
```

- [ ] **Step 3.7: Run the test — expect pass**

```bash
node tests/graph/test-astgrep.mjs
```
Expected: `OK astgrep wrapper`.

- [ ] **Step 3.8: Commit**

Write `/tmp/commit-msg-p1-3.txt`:
```
feat(graph): add ast-grep YAML rules and spawn wrapper

Six TS rules cover function_declaration, lexical-declarator+arrow,
class_declaration, method_definition, call_expression, and
import_statement — the full surface the P1 extractor needs.
runRule() normalizes ast-grep's 0-indexed wire format to 1-indexed
line numbers up-front so the rest of the pipeline never has to
remember the off-by-one.

Pattern-mode ($$$) was tried first and silently returned [] for
function bodies in ast-grep 0.43; YAML kind rules are the correct
surface for declaration extraction.
```

```bash
git add scripts/graph/rules/ scripts/graph/astgrep.mjs tests/graph/test-astgrep.mjs
git commit -F /tmp/commit-msg-p1-3.txt
```

---

## Task 4: TS/JS node extractor

**Files:**
- Create: `scripts/graph/extract-ts.mjs`
- Test: `tests/graph/test-extract-ts.mjs`

- [ ] **Step 4.1: Write the extractor test first (red)**

Create `tests/graph/test-extract-ts.mjs`:
```js
#!/usr/bin/env node
import { extractFile } from '../../scripts/graph/extract-ts.mjs';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';

const ROOT = path.resolve(import.meta.dirname, '..', '..');
const fixture = path.join(ROOT, '__tests__', 'graph-fixtures', 'ts-js', 'sample-input.ts');
const source = await fs.readFile(fixture, 'utf8');

const { nodes, imports, callSites } = await extractFile({
  absPath: fixture,
  source,
  language: 'typescript',
});

const names = nodes.map(n => n.qualifiedName).sort();
assert.deepEqual(names, ['A', 'A.shared', 'B', 'B.shared', 'ambiguous', 'caller', 'helper']);

const helper = nodes.find(n => n.qualifiedName === 'helper');
assert.equal(helper.kind, 'function');
assert.equal(helper.startLine, 5);
assert.equal(helper.endLine, 7);
assert.equal(helper.spanSha8.length, 8);
assert.ok(helper.signature.startsWith('function helper'));

const aShared = nodes.find(n => n.qualifiedName === 'A.shared');
assert.equal(aShared.kind, 'method');
assert.equal(aShared.name, 'shared');
assert.equal(aShared.startLine, 14);

assert.equal(imports.length, 0);

const inAmbiguous = callSites.filter(c => c.callerQualifiedName === 'ambiguous');
assert.equal(inAmbiguous.length, 2);
assert.deepEqual(inAmbiguous.map(c => c.calleeIdent).sort(), ['a.shared', 'b.shared']);

const inCaller = callSites.filter(c => c.callerQualifiedName === 'caller');
assert.equal(inCaller.length, 1);
assert.equal(inCaller[0].calleeIdent, 'helper');
assert.equal(inCaller[0].line, 10);

console.log('OK extract-ts');
```

- [ ] **Step 4.2: Run — expect failure**

```bash
node tests/graph/test-extract-ts.mjs
```
Expected: `Cannot find module '.../extract-ts.mjs'`.

- [ ] **Step 4.3: Implement `scripts/graph/extract-ts.mjs`**

```js
// scripts/graph/extract-ts.mjs
import { runRule } from './astgrep.mjs';
import crypto from 'node:crypto';
import path from 'node:path';
import url from 'node:url';

const RULE_DIR = path.join(path.dirname(url.fileURLToPath(import.meta.url)), 'rules');
const RULES = {
  function: path.join(RULE_DIR, 'ts-function.yml'),
  arrow:    path.join(RULE_DIR, 'ts-arrow.yml'),
  class:    path.join(RULE_DIR, 'ts-class.yml'),
  method:   path.join(RULE_DIR, 'ts-method.yml'),
  call:     path.join(RULE_DIR, 'ts-call.yml'),
  import:   path.join(RULE_DIR, 'ts-import.yml'),
};

export function spanSha8(text) {
  return crypto.createHash('sha256').update(text).digest('hex').slice(0, 8);
}

function nameFromFunctionText(text) {
  // `async function NAME` is a single function_declaration node whose text
  // starts with `async`, so the regex MUST tolerate an optional async prefix
  // — every `cmd*` in codex-bridge.mjs is `async function`, and the P1
  // acceptance demo depends on extracting `cmdImplement` correctly.
  const m = text.match(/^(?:async\s+)?function\s+\*?\s*([A-Za-z_$][\w$]*)/);
  return m ? m[1] : null;
}

function nameFromMethodText(text) {
  const MODIFIERS = new Set(['async', 'static', 'get', 'set', 'public', 'private', 'protected', 'readonly', '*']);
  const tokens = text.split(/[\s(*]+/).filter(Boolean);
  for (const t of tokens) {
    if (!MODIFIERS.has(t)) return t.replace(/^\*/, '');
  }
  return null;
}

function nameFromClassText(text) {
  const m = text.match(/^class\s+([A-Za-z_$][\w$]*)/);
  return m ? m[1] : null;
}

function nameFromArrowDeclarator(text) {
  const m = text.match(/^([A-Za-z_$][\w$]*)/);
  return m ? m[1] : null;
}

function firstLineOf(text) {
  return text.split('\n', 1)[0].slice(0, 200);
}

// The YAML rules under scripts/graph/rules/ all pin `language: typescript`.
// ast-grep refuses to apply those rules to .js / .mjs / .cjs source even
// though TypeScript grammar is a JavaScript superset. Cheapest fix for P1
// is to materialize JavaScript sources as a temp .ts file before scanning,
// then delete it. P2 cleanup: add parallel js-*.yml rules instead.
async function scanPathFor({ absPath, source, language }) {
  if (language !== 'javascript') return { scanPath: absPath, cleanup: async () => {} };
  const fs = await import('node:fs/promises');
  const os = await import('node:os');
  const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'sspower-graph-'));
  const scanPath = path.join(tmpDir, `${path.basename(absPath)}.ts`);
  await fs.writeFile(scanPath, source, 'utf8');
  return {
    scanPath,
    cleanup: async () => {
      await fs.unlink(scanPath).catch(() => {});
      await fs.rmdir(tmpDir).catch(() => {});
    },
  };
}

export async function extractFile({ absPath, source, language = 'typescript' }) {
  const { scanPath, cleanup } = await scanPathFor({ absPath, source, language });
  let fns, arrows, classes, methods, calls, imps;
  try {
    [fns, arrows, classes, methods, calls, imps] = await Promise.all([
      runRule(RULES.function, scanPath),
      runRule(RULES.arrow,    scanPath),
      runRule(RULES.class,    scanPath),
      runRule(RULES.method,   scanPath),
      runRule(RULES.call,     scanPath),
      runRule(RULES.import,   scanPath),
    ]);
  } finally {
    await cleanup();
  }

  const nodes = [];

  for (const m of fns) {
    const name = nameFromFunctionText(m.text);
    if (!name) continue;
    nodes.push({
      kind: 'function', name, qualifiedName: name,
      startLine: m.startLine, endLine: m.endLine,
      byteStart: m.byteStart, byteEnd: m.byteEnd,
      signature: firstLineOf(m.text),
      spanSha8: spanSha8(m.text),
      language,
    });
  }

  for (const m of arrows) {
    const name = nameFromArrowDeclarator(m.text);
    if (!name) continue;
    nodes.push({
      kind: 'function', name, qualifiedName: name,
      startLine: m.startLine, endLine: m.endLine,
      byteStart: m.byteStart, byteEnd: m.byteEnd,
      signature: firstLineOf(m.text),
      spanSha8: spanSha8(m.text),
      language,
    });
  }

  const classRanges = [];
  for (const m of classes) {
    const name = nameFromClassText(m.text);
    if (!name) continue;
    classRanges.push({ name, byteStart: m.byteStart, byteEnd: m.byteEnd });
    nodes.push({
      kind: 'class', name, qualifiedName: name,
      startLine: m.startLine, endLine: m.endLine,
      byteStart: m.byteStart, byteEnd: m.byteEnd,
      signature: firstLineOf(m.text),
      spanSha8: spanSha8(m.text),
      language,
    });
  }

  for (const m of methods) {
    const name = nameFromMethodText(m.text);
    if (!name) continue;
    const enclosing = classRanges
      .filter(c => c.byteStart <= m.byteStart && c.byteEnd >= m.byteEnd)
      .sort((a, b) => (b.byteEnd - b.byteStart) - (a.byteEnd - a.byteStart))
      .pop();
    const qualifiedName = enclosing ? `${enclosing.name}.${name}` : name;
    nodes.push({
      kind: 'method', name, qualifiedName,
      startLine: m.startLine, endLine: m.endLine,
      byteStart: m.byteStart, byteEnd: m.byteEnd,
      signature: firstLineOf(m.text),
      spanSha8: spanSha8(m.text),
      language,
    });
  }

  const imports = imps.map(m => {
    const specMatch = m.text.match(/from\s+['"]([^'"]+)['"]/) || m.text.match(/import\s+['"]([^'"]+)['"]/);
    const moduleSpec = specMatch ? specMatch[1] : null;
    const names = [];
    const braced = m.text.match(/\{([^}]*)\}/);
    if (braced) {
      for (const part of braced[1].split(',')) {
        const t = part.trim();
        if (!t) continue;
        const asMatch = t.match(/^(\S+)\s+as\s+(\S+)$/);
        names.push(asMatch ? { imported: asMatch[1], local: asMatch[2] } : { imported: t, local: t });
      }
    }
    const defMatch = m.text.match(/^import\s+([A-Za-z_$][\w$]*)\s*[,{]/) ||
                     m.text.match(/^import\s+([A-Za-z_$][\w$]*)\s+from/);
    if (defMatch) names.push({ imported: 'default', local: defMatch[1] });
    const nsMatch = m.text.match(/import\s+\*\s+as\s+([A-Za-z_$][\w$]*)/);
    if (nsMatch) names.push({ imported: '*', local: nsMatch[1] });
    return { moduleSpec, names, line: m.startLine };
  }).filter(i => i.moduleSpec);

  const callableRanges = nodes
    .filter(n => n.kind === 'function' || n.kind === 'method')
    .map(n => ({ qualifiedName: n.qualifiedName, byteStart: n.byteStart, byteEnd: n.byteEnd }));

  // ts-call.yml is a plain `kind: call_expression` rule with NO metavariable
  // captures, so derive the callee identifier from the matched text. Handles:
  //   foo(...)                  → 'foo'
  //   ns.helper(...)            → 'ns.helper'   (member call; resolver splits)
  //   this.method(...)          → 'this.method' (treated like member; bareName='method')
  //   await foo(...)            → 'foo' (matched node text starts at call_expression, not the await)
  //   new Foo(...)              → 'Foo' (constructor; tracked as a call edge)
  //   foo?.bar(...)             → 'foo?.bar' (optional chaining preserved; bareName='bar')
  // Anything that doesn't start with an identifier (computed member, IIFE,
  // template call) is dropped — P1 known limit, documented in §5.
  const IDENT_PREFIX = /^([A-Za-z_$][\w$]*(?:\??\.[A-Za-z_$][\w$]*)*)/;
  const callSites = [];
  for (const c of calls) {
    const callMatch = c.text.match(IDENT_PREFIX);
    if (!callMatch) continue;
    const effectiveIdent = callMatch[1];
    const enclosing = callableRanges
      .filter(r => r.byteStart <= c.byteStart && r.byteEnd >= c.byteEnd)
      .sort((a, b) => (b.byteEnd - b.byteStart) - (a.byteEnd - a.byteStart))
      .pop();
    if (!enclosing) continue;  // top-level call → no source node (P1: skip)
    callSites.push({
      callerQualifiedName: enclosing.qualifiedName,
      calleeIdent: effectiveIdent,
      line: c.startLine,
    });
  }

  return { nodes, imports, callSites };
}
```

- [ ] **Step 4.4: Run — expect pass**

```bash
node tests/graph/test-extract-ts.mjs
```
Expected: `OK extract-ts`.

- [ ] **Step 4.5: Run extractor against codex-bridge.mjs (smoke real-world)**

```bash
node -e "
import('./scripts/graph/extract-ts.mjs').then(async ({ extractFile }) => {
  const fs = await import('node:fs/promises');
  const source = await fs.readFile('scripts/codex-bridge.mjs', 'utf8');
  const r = await extractFile({ absPath: '$(pwd)/scripts/codex-bridge.mjs', source, language: 'javascript' });
  const cmdImpl = r.nodes.find(n => n.qualifiedName === 'cmdImplement');
  console.log('cmdImplement startLine =', cmdImpl?.startLine);
  const callers = r.callSites.filter(c => c.calleeIdent === 'cmdImplement');
  console.log('cmdImplement call-sites:', callers.length, callers.map(c => '\\n  ' + c.callerQualifiedName + '@line:' + c.line).join(''));
});
"
```
Expected: `cmdImplement startLine = 1553` AND `cmdImplement call-sites: 1` from `main@line:2061`. If either is off, fix the extractor before continuing — Task 9 depends on this.

- [ ] **Step 4.6: Commit**

Write `/tmp/commit-msg-p1-4.txt`:
```
feat(graph): TS/JS node extractor (functions, classes, methods, arrows)

Pure-function module: given source + path, returns nodes + imports +
call-sites. No DB writes. Class methods get qualified_name "Class.method"
via tightest-enclosing-class byte-range matching. Call-sites are
attached to their tightest enclosing function/method; top-level calls
(no source node) are dropped in P1 as documented in §5 known limits.

Verified end-to-end: extractor finds cmdImplement at codex-bridge.mjs:1553
and its single call-site in main() at line 2061 — the P1 acceptance demo target.
```

```bash
git add scripts/graph/extract-ts.mjs tests/graph/test-extract-ts.mjs
git commit -F /tmp/commit-msg-p1-4.txt
```

---

## Task 5: Import resolution + edge resolver

**Files:**
- Create: `scripts/graph/resolve.mjs`
- Test: `tests/graph/test-resolve.mjs`

- [ ] **Step 5.1: Write the resolver test first (red)**

Create `tests/graph/test-resolve.mjs`:
```js
#!/usr/bin/env node
import { resolveModule, resolveEdges } from '../../scripts/graph/resolve.mjs';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

// resolveModule: relative + extension search
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'sspower-resolve-'));
fs.writeFileSync(path.join(tmp, 'util.ts'), '');
fs.writeFileSync(path.join(tmp, 'index.ts'), '');
fs.mkdirSync(path.join(tmp, 'lib'));
fs.writeFileSync(path.join(tmp, 'lib', 'index.ts'), '');

assert.equal(
  resolveModule(path.join(tmp, 'app.ts'), './util'),
  path.join(tmp, 'util.ts')
);
assert.equal(
  resolveModule(path.join(tmp, 'app.ts'), './lib'),
  path.join(tmp, 'lib', 'index.ts')
);
assert.equal(
  resolveModule(path.join(tmp, 'app.ts'), 'react'),
  null  // bare module → external
);
fs.rmSync(tmp, { recursive: true });

// resolveEdges: confidence assignment
const intraFile = '/tmp/a.ts';
const otherFile = '/tmp/b.ts';
const nodes = [
  { id: 'a#caller#11111111', name: 'caller', qualifiedName: 'caller', filePath: intraFile },
  { id: 'a#helper#22222222', name: 'helper', qualifiedName: 'helper', filePath: intraFile },
  { id: 'b#helper#33333333', name: 'helper', qualifiedName: 'helper', filePath: otherFile },
];
const callSites = [
  { callerQualifiedName: 'caller', calleeIdent: 'helper', line: 10, callerFile: intraFile, importedNames: {} },
];
const intraEdges = resolveEdges({ nodes, callSites });
assert.equal(intraEdges.length, 1);
assert.equal(intraEdges[0].confidence, 1, `expected intra=1, got ${intraEdges[0].confidence}`);
assert.equal(intraEdges[0].source, 'a#caller#11111111');
assert.equal(intraEdges[0].target, 'a#helper#22222222');

// Imported (conf=2): caller in b.ts calls something imported from a.ts
const importedCall = [{
  callerQualifiedName: 'main', calleeIdent: 'helper', line: 3, callerFile: otherFile,
  importedNames: { helper: { path: intraFile, imported: 'helper' } },
}];
const nodes2 = [
  ...nodes,
  { id: 'b#main#44444444', name: 'main', qualifiedName: 'main', filePath: otherFile },
];
const importedEdges = resolveEdges({ nodes: nodes2, callSites: importedCall });
assert.equal(importedEdges.length, 1);
assert.equal(importedEdges[0].confidence, 2);
assert.equal(importedEdges[0].target, 'a#helper#22222222');

// Imported with alias (conf=2): `import { helper as h } from './a'; h()`.
// callerIdent='h' but resolver MUST look up by imported='helper' in a.ts.
const aliasCall = [{
  callerQualifiedName: 'main', calleeIdent: 'h', line: 7, callerFile: otherFile,
  importedNames: { h: { path: intraFile, imported: 'helper' } },
}];
const aliasEdges = resolveEdges({ nodes: nodes2, callSites: aliasCall });
assert.equal(aliasEdges.length, 1, `alias should resolve, got ${aliasEdges.length} edges`);
assert.equal(aliasEdges[0].confidence, 2);
assert.equal(aliasEdges[0].target, 'a#helper#22222222');

// Ambiguous via cross-graph fallback (conf=0): caller in c.ts has no import → fall back to all-same-name nodes
const ambigCall = [{
  callerQualifiedName: 'caller2', calleeIdent: 'helper', line: 5, callerFile: '/tmp/c.ts',
  importedNames: {},
}];
const nodes3 = [
  ...nodes,
  { id: 'c#caller2#55555555', name: 'caller2', qualifiedName: 'caller2', filePath: '/tmp/c.ts' },
];
const ambigEdges = resolveEdges({ nodes: nodes3, callSites: ambigCall });
// helper exists in BOTH a.ts and b.ts → 2 ambiguous edges
assert.equal(ambigEdges.length, 2, `expected 2 ambiguous edges, got ${ambigEdges.length}`);
for (const e of ambigEdges) assert.equal(e.confidence, 0);

// Ambiguous via intra-file multi-match (conf=0): two methods named `shared` in
// the same file (the ts-js fixture case). Single-file lookup yields >1 → conf=0.
const sharedFile = '/tmp/shared.ts';
const nodes4 = [
  { id: 'sh#caller#aaaaaaaa', name: 'caller', qualifiedName: 'caller', filePath: sharedFile },
  { id: 'sh#A.shared#bbbbbbbb', name: 'shared', qualifiedName: 'A.shared', filePath: sharedFile },
  { id: 'sh#B.shared#cccccccc', name: 'shared', qualifiedName: 'B.shared', filePath: sharedFile },
];
const multiCall = [
  { callerQualifiedName: 'caller', calleeIdent: 'a.shared', line: 10, callerFile: sharedFile, importedNames: {} },
];
const multiEdges = resolveEdges({ nodes: nodes4, callSites: multiCall });
assert.equal(multiEdges.length, 2, `intra-file multi-match should emit 2 edges, got ${multiEdges.length}`);
for (const e of multiEdges) assert.equal(e.confidence, 0, `intra-file multi-match must be ambiguous (conf=0), got ${e.confidence}`);

console.log('OK resolve');
```

- [ ] **Step 5.2: Run — expect failure**

```bash
node tests/graph/test-resolve.mjs
```
Expected: `Cannot find module '.../resolve.mjs'`.

- [ ] **Step 5.3: Implement `scripts/graph/resolve.mjs`**

```js
// scripts/graph/resolve.mjs
import fs from 'node:fs';
import path from 'node:path';

const TS_EXTS = ['.ts', '.tsx', '.mts', '.cts'];
const JS_EXTS = ['.js', '.jsx', '.mjs', '.cjs'];
const ALL_EXTS = [...TS_EXTS, ...JS_EXTS];

export function resolveModule(importerAbs, moduleSpec) {
  if (!moduleSpec.startsWith('./') && !moduleSpec.startsWith('../') && !moduleSpec.startsWith('/')) {
    return null;  // bare module (npm pkg etc.) — external
  }
  const importerDir = path.dirname(importerAbs);
  const base = path.resolve(importerDir, moduleSpec);
  if (fs.existsSync(base) && fs.statSync(base).isFile()) return base;
  for (const ext of ALL_EXTS) {
    const candidate = base + ext;
    if (fs.existsSync(candidate) && fs.statSync(candidate).isFile()) return candidate;
  }
  for (const ext of ALL_EXTS) {
    const candidate = path.join(base, `index${ext}`);
    if (fs.existsSync(candidate) && fs.statSync(candidate).isFile()) return candidate;
  }
  return null;
}

export function resolveEdges({ nodes, callSites }) {
  const byQualified = new Map();
  const byName = new Map();
  const byFileAndName = new Map();
  const byFileAndQualified = new Map();  // import-resolution uses qname to avoid
                                          // matching class methods that share a
                                          // bare name with a top-level export.
  for (const n of nodes) {
    pushMap(byQualified, n.qualifiedName, n);
    pushMap(byName, n.name, n);
    pushMap(byFileAndName, `${n.filePath}::${n.name}`, n);
    pushMap(byFileAndQualified, `${n.filePath}::${n.qualifiedName}`, n);
  }

  const edges = [];
  for (const cs of callSites) {
    const callerNode = byQualified.get(cs.callerQualifiedName)?.find(n => n.filePath === cs.callerFile);
    if (!callerNode) continue;
    const bareName = cs.calleeIdent.split('.').pop();

    // Step 1: intra-file. Single match → confidence=1. Multiple matches
    // (e.g., two methods named `shared` in classes A and B sharing the same
    // file) → ambiguous, emit confidence=0 for each — the resolver cannot
    // pick without type information.
    const intra = byFileAndName.get(`${cs.callerFile}::${bareName}`) ?? [];
    if (intra.length === 1) {
      edges.push(edge(callerNode.id, intra[0].id, cs.line, 1));
      continue;
    }
    if (intra.length > 1) {
      for (const target of intra) {
        edges.push(edge(callerNode.id, target.id, cs.line, 0));
      }
      continue;
    }

    // Resolution order (JS scoping):
    //   Direct call `foo()`:
    //     1. Same-file local definition of `foo` (could be a nested function
    //        shadowing an outer import) -> wins over import.
    //     2. Imported binding `foo` -> conf=2.
    //     3. Cross-graph same-name fallback -> conf=0.
    //   Member call `foo.bar()`:
    //     1. Namespace/default import on `foo` -> resolve `bar` in that path,
    //        conf=2. NEVER use intra-file by bareName for member calls
    //        (`foo.bar` is NOT method `bar` defined in the same file).
    //     2. Cross-graph same-name fallback on `bar` -> conf=0.
    //
    // The intra-file step (below) runs FIRST for direct calls so a local
    // shadow wins over an import — matches JS scoping. Member calls skip
    // the intra step because property-name lookup in the caller's file
    // would manufacture false edges to unrelated same-name top-level fns.
    const parts = cs.calleeIdent.split('.');
    const receiverName = parts[0].replace(/\?$/, '');
    const isMemberCall = parts.length > 1;
    let entry;
    if (isMemberCall) {
      const receiver = cs.importedNames?.[receiverName];
      if (receiver && (receiver.imported === '*' || receiver.imported === 'default')) {
        entry = receiver;
      }
    } else {
      entry = cs.importedNames?.[receiverName];
    }
    if (entry) {
      const lookupName = (entry.imported === '*' || entry.imported === 'default')
        ? bareName  // namespace member calls (`ns.foo()` with bareName='foo')
        : entry.imported;
      // Match by qualified_name so `import { helper }` resolves to the top-
      // level `helper` export, NOT every class method named `helper`.
      const imported = byFileAndQualified.get(`${entry.path}::${lookupName}`) ?? [];
      if (imported.length > 0) {
        for (const target of imported) {
          edges.push(edge(callerNode.id, target.id, cs.line, 2));
        }
        continue;
      }
    }

    // Step 3: ambiguous same-name fallback across the entire graph.
    const ambiguous = byName.get(bareName) ?? [];
    for (const target of ambiguous) {
      if (target.id === callerNode.id) continue;
      edges.push(edge(callerNode.id, target.id, cs.line, 0));
    }
  }
  return edges;
}

function edge(source, target, line, confidence) {
  return { source, target, kind: 'calls', line, confidence };
}

function pushMap(map, key, value) {
  const arr = map.get(key);
  if (arr) arr.push(value);
  else map.set(key, [value]);
}
```

- [ ] **Step 5.4: Run — expect pass**

```bash
node tests/graph/test-resolve.mjs
```
Expected: `OK resolve`.

- [ ] **Step 5.5: Commit**

Write `/tmp/commit-msg-p1-5.txt`:
```
feat(graph): import resolution and three-confidence edge resolver

resolveModule walks relative/absolute specs with TS/JS extension and
index.* fallback; bare modules (npm) return null and are dropped per
P1 scope (no node_modules scanning).

resolveEdges implements the spec §3.2 three-tier confidence:
  intra-file single match → 1
  intra-file multi-match  → 0 (ambiguous, e.g. two `shared()` methods
                              in classes A and B in the same file —
                              the resolver cannot pick without types)
  cross-file via import   → 2
  cross-graph same-name   → 0 (ambiguous fallback)
Ambiguous edges are stored (not collapsed) so `callers --disambiguate`
in the query layer can present them as a choice list per spec §3.3.
```

```bash
git add scripts/graph/resolve.mjs tests/graph/test-resolve.mjs
git commit -F /tmp/commit-msg-p1-5.txt
```

---

## Task 6: File walker (respects `git ls-files` when in a repo)

**Files:**
- Create: `scripts/graph/walk.mjs`
- Test: `tests/graph/test-walk.mjs`

- [ ] **Step 6.1: Write the walker test first (red)**

Create `tests/graph/test-walk.mjs`:
```js
#!/usr/bin/env node
import { walkSources } from '../../scripts/graph/walk.mjs';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

// Case A: non-git directory — recursive walk with sensible filters.
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'sspower-walk-'));
fs.writeFileSync(path.join(tmp, 'a.ts'), '');
fs.writeFileSync(path.join(tmp, 'b.js'), '');
fs.writeFileSync(path.join(tmp, 'c.md'), '');
fs.mkdirSync(path.join(tmp, 'node_modules'));
fs.writeFileSync(path.join(tmp, 'node_modules', 'x.ts'), '');
fs.mkdirSync(path.join(tmp, '.git'));
fs.writeFileSync(path.join(tmp, '.git', 'config'), '');

const got = [];
for await (const p of walkSources(tmp)) got.push(p);
const rels = got.map(p => path.relative(tmp, p)).sort();
assert.deepEqual(rels, ['a.ts', 'b.js'], `got ${JSON.stringify(rels)}`);
fs.rmSync(tmp, { recursive: true });

// Case B: real git repo — uses `git ls-files`.
const repo = fs.mkdtempSync(path.join(os.tmpdir(), 'sspower-walk-git-'));
execFileSync('git', ['init', '-q'], { cwd: repo });
execFileSync('git', ['config', 'user.email', 't@t'], { cwd: repo });
execFileSync('git', ['config', 'user.name', 't'], { cwd: repo });
fs.writeFileSync(path.join(repo, 'x.ts'), '');
fs.writeFileSync(path.join(repo, 'y.js'), '');
fs.writeFileSync(path.join(repo, 'untracked.ts'), '');
execFileSync('git', ['add', 'x.ts', 'y.js'], { cwd: repo });
execFileSync('git', ['commit', '-q', '-m', 'init'], { cwd: repo });

const gotGit = [];
for await (const p of walkSources(repo)) gotGit.push(p);
const relsGit = gotGit.map(p => path.relative(repo, p)).sort();
assert.deepEqual(relsGit, ['untracked.ts', 'x.ts', 'y.js'], `git case got ${JSON.stringify(relsGit)}`);
fs.rmSync(repo, { recursive: true });

console.log('OK walk');
```

- [ ] **Step 6.2: Run — expect failure**

```bash
node tests/graph/test-walk.mjs
```
Expected: `Cannot find module '.../walk.mjs'`.

- [ ] **Step 6.3: Implement `scripts/graph/walk.mjs`**

```js
// scripts/graph/walk.mjs
import fs from 'node:fs/promises';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const SOURCE_EXTS = new Set(['.ts', '.tsx', '.mts', '.cts', '.js', '.jsx', '.mjs', '.cjs']);
const IGNORE_DIRS = new Set(['node_modules', '.git', 'dist', 'build', '.next', '__pycache__', '.venv', 'venv']);

function isGitRepo(dir) {
  try {
    const top = execFileSync('git', ['-C', dir, 'rev-parse', '--show-toplevel'], {
      stdio: ['ignore', 'pipe', 'ignore'],
    }).toString().trim();
    return top.length > 0 ? top : null;
  } catch {
    return null;
  }
}

export async function* walkSources(rootDir) {
  const absRoot = path.resolve(rootDir);
  const top = isGitRepo(absRoot);
  if (top) {
    const tracked = execFileSync('git', ['-C', absRoot, 'ls-files', '-z'], { maxBuffer: 100 * 1024 * 1024 });
    const others  = execFileSync('git', ['-C', absRoot, 'ls-files', '--others', '--exclude-standard', '-z'], { maxBuffer: 100 * 1024 * 1024 });
    const buf = Buffer.concat([tracked, others]);
    const rels = buf.toString('utf8').split('\0').filter(Boolean);
    for (const rel of rels) {
      if (!SOURCE_EXTS.has(path.extname(rel))) continue;
      const abs = path.join(top, rel);
      if (!abs.startsWith(absRoot + path.sep) && abs !== absRoot) continue;
      yield abs;
    }
    return;
  }
  yield* walkFs(absRoot);
}

async function* walkFs(dir) {
  let entries;
  try {
    entries = await fs.readdir(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const e of entries) {
    if (e.isDirectory()) {
      if (IGNORE_DIRS.has(e.name)) continue;
      yield* walkFs(path.join(dir, e.name));
    } else if (e.isFile()) {
      if (SOURCE_EXTS.has(path.extname(e.name))) {
        yield path.join(dir, e.name);
      }
    }
  }
}
```

- [ ] **Step 6.4: Run — expect pass**

```bash
node tests/graph/test-walk.mjs
```
Expected: `OK walk`.

- [ ] **Step 6.5: Smoke against the plugin repo**

```bash
node -e "
import('./scripts/graph/walk.mjs').then(async ({ walkSources }) => {
  let n = 0;
  for await (const p of walkSources('$(pwd)')) n++;
  console.log('TS/JS files:', n);
});
"
```
Expected: dozens, not thousands. MUST NOT include anything under `node_modules/` or `.git/`. If count > 500, inspect — probably failed to exclude something.

- [ ] **Step 6.6: Commit**

Write `/tmp/commit-msg-p1-6.txt`:
```
feat(graph): source file walker with git-aware traversal

Uses git ls-files (tracked + untracked-not-ignored) when inside a
repo, falls back to filtered recursive readdir otherwise. Mirrors
FU3's filesethash construction — both paths surface the same set so
the P2 SessionStart NEW-file detector stays consistent with build.
```

```bash
git add scripts/graph/walk.mjs tests/graph/test-walk.mjs
git commit -F /tmp/commit-msg-p1-6.txt
```

---

## Task 7: Build orchestrator (extract → resolve → insert in one transaction)

**Files:**
- Create: `scripts/graph/build.mjs`

- [ ] **Step 7.1: Implement `scripts/graph/build.mjs`**

```js
// scripts/graph/build.mjs
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { walkSources } from './walk.mjs';
import { extractFile } from './extract-ts.mjs';
import { resolveModule, resolveEdges } from './resolve.mjs';
import { openDb, initSchema, nodeId } from './db.mjs';

function languageFor(filePath) {
  const ext = path.extname(filePath);
  if (ext === '.ts' || ext === '.tsx' || ext === '.mts' || ext === '.cts') return 'typescript';
  return 'javascript';
}

function sha8File(content) {
  return crypto.createHash('sha256').update(content).digest('hex').slice(0, 8);
}

export async function build({ rootDir, graphDir, log = () => {} }) {
  const dbPath = path.join(graphDir, 'index.sqlite');
  const db = openDb(dbPath);
  initSchema(db);

  const allNodes = [];
  const perFile = [];

  // Phase 1: walk + extract per file (no DB writes — pure in-memory).
  let fileCount = 0;
  for await (const filePath of walkSources(rootDir)) {
    fileCount++;
    let source;
    try { source = await fs.readFile(filePath, 'utf8'); }
    catch (e) { log(`skip read ${filePath}: ${e.message}`); continue; }
    const language = languageFor(filePath);
    let extracted;
    try { extracted = await extractFile({ absPath: filePath, source, language }); }
    catch (e) { log(`skip extract ${filePath}: ${e.message}`); continue; }

    const idedNodes = extracted.nodes.map(n => ({
      ...n,
      id: nodeId(filePath, n.qualifiedName, n.spanSha8),
      filePath,
    }));
    allNodes.push(...idedNodes);
    perFile.push({
      filePath, language, content: source, extracted,
      idedNodes,
      contentHash: sha8File(source),
    });
    if (fileCount % 100 === 0) log(`extracted ${fileCount} files`);
  }
  log(`extract done: ${fileCount} files, ${allNodes.length} nodes`);

  // Phase 2: build import maps in memory (no DB writes).
  // Map shape: local-name → { path, imported }.
  //   `import { greet } from './u'`        → { greet: { path:'/abs/u.ts', imported:'greet' } }
  //   `import { greet as g } from './u'`   → { g:     { path:'/abs/u.ts', imported:'greet' } }
  //   `import x from './u'`                → { x:     { path:'/abs/u.ts', imported:'default' } }
  //   `import * as ns from './u'`          → { ns:    { path:'/abs/u.ts', imported:'*' } }
  // The resolver uses `imported` (the upstream name) for the cross-file
  // lookup, NOT `local` — so aliasing doesn't break attribution.
  const importedNamesByFile = new Map();
  for (const f of perFile) {
    const map = {};
    for (const imp of f.extracted.imports) {
      const resolved = resolveModule(f.filePath, imp.moduleSpec);
      if (!resolved) continue;
      for (const n of imp.names) {
        map[n.local] = { path: resolved, imported: n.imported };
      }
    }
    importedNamesByFile.set(f.filePath, map);
  }

  const enrichedCallSites = [];
  for (const f of perFile) {
    for (const cs of f.extracted.callSites) {
      enrichedCallSites.push({
        ...cs,
        callerFile: f.filePath,
        importedNames: importedNamesByFile.get(f.filePath) ?? {},
      });
    }
  }
  const edges = resolveEdges({ nodes: allNodes, callSites: enrichedCallSites });

  // Phase 3: SINGLE transaction — destructive wipe + insert. On crash, DB
  // reverts to the previous full-build state. Without this, an interrupted
  // build leaves an empty index.
  const now = Math.floor(Date.now() / 1000);
  const insFile = db.prepare(
    'INSERT INTO files(path, content_hash, language, indexed_at, node_count) VALUES (?, ?, ?, ?, ?)'
  );
  const insNode = db.prepare(
    'INSERT INTO nodes(id, kind, name, qualified_name, file_path, language, start_line, end_line, signature, span_sha8, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)'
  );
  const insImport = db.prepare(
    'INSERT OR IGNORE INTO imports(importer_path, imported_path) VALUES (?, ?)'
  );
  const insEdge = db.prepare(
    'INSERT OR IGNORE INTO edges(source, target, kind, line, confidence) VALUES (?, ?, ?, ?, ?)'
  );

  db.exec('BEGIN IMMEDIATE');
  try {
    db.exec('DELETE FROM edges');
    db.exec('DELETE FROM imports');
    db.exec('DELETE FROM nodes');
    db.exec('DELETE FROM files');

    for (const f of perFile) {
      insFile.run(f.filePath, f.contentHash, f.language, now, f.idedNodes.length);
      for (const n of f.idedNodes) {
        insNode.run(n.id, n.kind, n.name, n.qualifiedName, f.filePath, n.language, n.startLine, n.endLine, n.signature, n.spanSha8, now);
      }
      for (const imp of f.extracted.imports) {
        const resolved = resolveModule(f.filePath, imp.moduleSpec);
        if (resolved) insImport.run(f.filePath, resolved);
      }
    }
    for (const e of edges) {
      insEdge.run(e.source, e.target, e.kind, e.line, e.confidence);
    }
    db.exec('COMMIT');
  } catch (e) {
    db.exec('ROLLBACK');
    throw e;
  }
  log(`build done: ${fileCount} files, ${allNodes.length} nodes, ${edges.length} edges`);

  await fs.writeFile(
    path.join(graphDir, 'version'),
    `schema=1\nast_grep=${process.env.AST_GREP_VERSION ?? 'unknown'}\nbuilt_at=${now}\n`,
    'utf8'
  );

  db.close();
  return { fileCount, nodeCount: allNodes.length, edgeCount: edges.length };
}
```

- [ ] **Step 7.2: Commit (no test yet — Task 8 lands the e2e test against build+query together)**

Write `/tmp/commit-msg-p1-7.txt`:
```
feat(graph): build orchestrator — walk, extract, resolve, insert

Three-phase build:
  1. walk + per-file extract (no DB writes; pure in-memory)
  2. resolve edges in memory using per-file import maps
  3. SINGLE BEGIN IMMEDIATE transaction wraps the destructive wipe
     (DELETE * from edges/imports/nodes/files) AND every insert so
     an interrupted build reverts to the previous full-build state
     instead of leaving an empty index

P2 owns the incremental refresh path; P1 ships only full builds.
```

```bash
git add scripts/graph/build.mjs
git commit -F /tmp/commit-msg-p1-7.txt
```

---

## Task 8: Query API + end-to-end build+query test

**Files:**
- Create: `scripts/graph/query.mjs`
- Create: `tests/graph/test-build-query.mjs`
- Modify: `__tests__/graph-fixtures/ts-js/expected.json`
- Create: `__tests__/graph-fixtures/ts-js-multifile/{app.ts,util.ts,expected.json}`

- [ ] **Step 8.1: Implement `scripts/graph/query.mjs`**

```js
// scripts/graph/query.mjs
import fs from 'node:fs';
import path from 'node:path';

export const MAX_RESULTS = 50;

export function status(db, graphDir) {
  const dbPath = path.join(graphDir, 'index.sqlite');
  const exists = fs.existsSync(dbPath);
  if (!exists) return { ok: false, reason: 'no-index', dbPath };
  const fileCount = db.prepare('SELECT COUNT(*) AS c FROM files').get().c;
  const nodeCount = db.prepare('SELECT COUNT(*) AS c FROM nodes').get().c;
  const edgeCount = db.prepare('SELECT COUNT(*) AS c FROM edges').get().c;
  const lastIndexed = db.prepare('SELECT MAX(indexed_at) AS m FROM files').get().m;
  const dirtyPath = path.join(graphDir, 'dirty');
  let dirtyCount = 0;
  if (fs.existsSync(dirtyPath)) {
    dirtyCount = fs.readFileSync(dirtyPath, 'utf8').split('\n').filter(Boolean).length;
  }
  return { ok: true, fileCount, nodeCount, edgeCount, lastIndexed, dirtyCount };
}

export function nodeLookup(db, name) {
  const rows = db.prepare(
    `SELECT * FROM nodes WHERE name = ? OR qualified_name = ? ORDER BY file_path, start_line LIMIT ?`
  ).all(name, name, MAX_RESULTS);
  return rows;
}

export function callers(db, name, { limit = MAX_RESULTS, disambiguate = false } = {}) {
  const targets = db.prepare(
    `SELECT id, name, qualified_name, file_path, start_line FROM nodes
       WHERE name = ? OR qualified_name = ?`
  ).all(name, name);
  if (targets.length === 0) return { matches: [], targets: [] };
  if (targets.length > 1 && !disambiguate) {
    return { matches: [], targets, ambiguous: true };
  }
  const targetIds = targets.map(t => t.id);
  const placeholders = targetIds.map(() => '?').join(',');
  const rows = db.prepare(
    `SELECT e.source, e.target, e.line, e.confidence,
            src.qualified_name AS src_qname, src.file_path AS src_file, src.start_line AS src_start,
            tgt.qualified_name AS tgt_qname, tgt.file_path AS tgt_file, tgt.start_line AS tgt_start
       FROM edges e
       JOIN nodes src ON e.source = src.id
       JOIN nodes tgt ON e.target = tgt.id
       WHERE e.target IN (${placeholders})
       ORDER BY src.file_path, e.line
       LIMIT ?`
  ).all(...targetIds, Math.min(limit, MAX_RESULTS));
  return { matches: rows, targets };
}

export function callees(db, name, { limit = MAX_RESULTS } = {}) {
  const sources = db.prepare(
    `SELECT id FROM nodes WHERE name = ? OR qualified_name = ?`
  ).all(name, name);
  if (sources.length === 0) return { matches: [], sources: [] };
  const ids = sources.map(s => s.id);
  const placeholders = ids.map(() => '?').join(',');
  const rows = db.prepare(
    `SELECT e.source, e.target, e.line, e.confidence,
            src.qualified_name AS src_qname, src.file_path AS src_file,
            tgt.qualified_name AS tgt_qname, tgt.file_path AS tgt_file, tgt.start_line AS tgt_start
       FROM edges e
       JOIN nodes src ON e.source = src.id
       JOIN nodes tgt ON e.target = tgt.id
       WHERE e.source IN (${placeholders})
       ORDER BY tgt.file_path, e.line
       LIMIT ?`
  ).all(...ids, Math.min(limit, MAX_RESULTS));
  return { matches: rows, sources };
}
```

- [ ] **Step 8.2: Write the e2e test**

Create `tests/graph/test-build-query.mjs`:
```js
#!/usr/bin/env node
import { build } from '../../scripts/graph/build.mjs';
import { openDb, initSchema } from '../../scripts/graph/db.mjs';
import { callers, callees, nodeLookup, status } from '../../scripts/graph/query.mjs';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const ROOT = path.resolve(import.meta.dirname, '..', '..');

// Case A: fixture pack ts-js
{
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'sspower-build-'));
  const fixtureSrc = path.join(ROOT, '__tests__/graph-fixtures/ts-js');
  fs.cpSync(fixtureSrc, tmp, { recursive: true });

  const graphDir = path.join(tmp, '.claude', 'graph');
  const result = await build({ rootDir: tmp, graphDir, log: () => {} });
  assert.ok(result.nodeCount >= 5, `nodes=${result.nodeCount}`);

  const db = openDb(path.join(graphDir, 'index.sqlite'));
  initSchema(db);

  const r = callers(db, 'helper');
  assert.equal(r.targets.length, 1);
  assert.equal(r.matches.length, 1, `helper callers=${JSON.stringify(r)}`);
  assert.equal(r.matches[0].src_qname, 'caller');
  assert.equal(r.matches[0].confidence, 1);

  const amb = nodeLookup(db, 'ambiguous');
  assert.equal(amb.length, 1);
  assert.equal(amb[0].qualified_name, 'ambiguous');

  const s = status(db, graphDir);
  assert.equal(s.ok, true);
  assert.ok(s.fileCount >= 1);
  assert.ok(s.nodeCount >= 5);

  db.close();
  fs.rmSync(tmp, { recursive: true });
  console.log('OK build+query on ts-js fixture');
}

// Case B: P1 acceptance — build the live plugin repo, callers of cmdImplement
{
  const graphDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sspower-graph-live-'));
  const result = await build({ rootDir: ROOT, graphDir, log: () => {} });
  assert.ok(result.nodeCount > 100, `expected many nodes, got ${result.nodeCount}`);

  const db = openDb(path.join(graphDir, 'index.sqlite'));
  initSchema(db);
  const r = callers(db, 'cmdImplement');
  assert.ok(r.matches.length >= 1, `cmdImplement callers=${JSON.stringify(r.matches)}`);
  const fromMainAt2061 = r.matches.find(m =>
    m.src_qname === 'main' && m.src_file.endsWith('codex-bridge.mjs') && m.line === 2061);
  assert.ok(fromMainAt2061, `expected main@codex-bridge.mjs:2061, got: ${JSON.stringify(r.matches.map(m => `${m.src_qname}@${m.src_file}:${m.line}`))}`);
  console.log('OK live-repo cmdImplement callers contain main@codex-bridge.mjs:2061');

  db.close();
  fs.rmSync(graphDir, { recursive: true });
}

console.log('OK build+query');
```

- [ ] **Step 8.3: Run the e2e test**

```bash
node tests/graph/test-build-query.mjs
```
Expected: `OK build+query on ts-js fixture`, `OK live-repo cmdImplement callers contain main@codex-bridge.mjs:2061`, `OK build+query`. If the live-repo test fails the line-number check, STOP and verify whether codex-bridge.mjs changed since this plan was written; update the assertion or fix the extractor.

- [ ] **Step 8.4: Re-baseline `__tests__/graph-fixtures/ts-js/expected.json`**

The existing goldens claim cross-file `confidence=2` edges for `caller→helper`, but the fixture is single-file — true confidence is `1`. Replace file contents with:
```json
{
  "language": "typescript",
  "nodes": [
    { "name": "helper", "qualifiedName": "helper", "kind": "function", "start_line": 5, "end_line": 7 },
    { "name": "caller", "qualifiedName": "caller", "kind": "function", "start_line": 9, "end_line": 11 },
    { "name": "shared", "qualifiedName": "A.shared", "kind": "method", "start_line": 14, "end_line": 14 },
    { "name": "shared", "qualifiedName": "B.shared", "kind": "method", "start_line": 17, "end_line": 17 },
    { "name": "A", "qualifiedName": "A", "kind": "class", "start_line": 13, "end_line": 15 },
    { "name": "B", "qualifiedName": "B", "kind": "class", "start_line": 16, "end_line": 18 },
    { "name": "ambiguous", "qualifiedName": "ambiguous", "kind": "function", "start_line": 20, "end_line": 22 }
  ],
  "edges": [
    { "source": "caller", "target": "helper", "kind": "calls", "confidence": 1 },
    { "source": "ambiguous", "target": "A.shared", "kind": "calls", "confidence": 0 },
    { "source": "ambiguous", "target": "B.shared", "kind": "calls", "confidence": 0 }
  ]
}
```
Spec §3.3 is silent on whether goldens lock confidence values; Task 10 harness compares pairs, not confidence.

- [ ] **Step 8.5: Add cross-file fixture pack `ts-js-multifile/`**

Create `__tests__/graph-fixtures/ts-js-multifile/util.ts`:
```typescript
export function greet(name: string): string {
  return `hello ${name}`;
}
```

Create `__tests__/graph-fixtures/ts-js-multifile/app.ts`:
```typescript
import { greet } from './util';

function main(): string {
  return greet('world');
}

export { main };
```

Create `__tests__/graph-fixtures/ts-js-multifile/expected.json`:
```json
{
  "language": "typescript",
  "nodes": [
    { "name": "greet", "qualifiedName": "greet", "kind": "function", "file": "util.ts", "start_line": 1, "end_line": 3 },
    { "name": "main",  "qualifiedName": "main",  "kind": "function", "file": "app.ts",  "start_line": 3, "end_line": 5 }
  ],
  "edges": [
    { "source": "main", "target": "greet", "kind": "calls", "confidence": 2 }
  ]
}
```

- [ ] **Step 8.6: Commit**

Write `/tmp/commit-msg-p1-8.txt`:
```
feat(graph): query API + cross-file fixture + e2e test

callers / callees / node / status implement the four P1 read verbs.
MAX_RESULTS=50 cap matches codegraph issue #296 mitigation. Ambiguous
target name returns the disambiguation list when --disambiguate is
NOT passed, per spec §3.3.

Re-baselines ts-js goldens (caller→helper is intra-file confidence=1,
not 2) and adds ts-js-multifile pack proving cross-file confidence=2
resolution works. E2e test exercises the P1 acceptance demo:
`callers cmdImplement` against the live plugin repo must return
`main@codex-bridge.mjs:2061`.
```

```bash
git add scripts/graph/query.mjs tests/graph/test-build-query.mjs __tests__/graph-fixtures/ts-js/expected.json __tests__/graph-fixtures/ts-js-multifile/
git commit -F /tmp/commit-msg-p1-8.txt
```

---

## Task 9: CLI dispatcher — extend `bin/sspower-graph.mjs`

**Files:**
- Modify: `bin/sspower-graph.mjs`

- [ ] **Step 9.1: Read current P0 stub**

```bash
sed -n '1,60p' bin/sspower-graph.mjs
```
Note structure: argv guard at top, single `serve --mcp` handler. Extend by adding new verbs BEFORE the serve guard.

- [ ] **Step 9.2: Replace `bin/sspower-graph.mjs`**

```js
#!/usr/bin/env node
// sspower-graph CLI + MCP server.
// P0: graph_status MCP tool. P1: build/build-unlocked/callers/callees/node/status CLI verbs.
//
// `build` re-execs through scripts/graph-with-lock.py so the single-lock
// contract (spec D34/D38) brackets the SQLite transaction across the
// cross-language boundary.

// Runtime gate — must run BEFORE any node:sqlite import (Task 1.5).
// Engine floor 22.5: the node:sqlite module auto-loads from 22.5 without
// `--experimental-sqlite`. On 22.0-22.4 the dynamic import fails — surface
// a clean message instead of a stack trace.
{
  const [major, minor] = process.versions.node.split('.').map(Number);
  if (major < 22 || (major === 22 && minor < 5)) {
    console.error(`error: sspower-graph requires Node >=22.5 (node:sqlite stable surface). Current: ${process.versions.node}`);
    process.exit(2);
  }
}

import path from 'node:path';
import url from 'node:url';
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';

// Read version from package.json for MCP server identity (avoid drift between
// the npm package and the MCP banner).
const HERE = path.dirname(url.fileURLToPath(import.meta.url));
const PLUGIN_ROOT = path.resolve(HERE, '..');
const PKG_VERSION = JSON.parse(fs.readFileSync(path.join(PLUGIN_ROOT, 'package.json'), 'utf8')).version;

const argv = process.argv.slice(2);
const cmd = argv[0];

function usage() {
  console.error(`sspower-graph — symbol graph CLI + MCP server

Usage:
  sspower-graph build [--cwd <dir>]
  sspower-graph callers <name> [--limit N] [--disambiguate] [--json] [--cwd <dir>]
  sspower-graph callees <name> [--limit N] [--json] [--cwd <dir>]
  sspower-graph node <name> [--json] [--cwd <dir>]
  sspower-graph status [--json] [--cwd <dir>]
  sspower-graph serve --mcp
`);
}

function parseOpts(rest) {
  const opts = { cwd: process.cwd(), limit: 50, disambiguate: false, json: false, positional: [] };
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    if (a === '--cwd') opts.cwd = path.resolve(rest[++i]);
    else if (a === '--limit') opts.limit = parseInt(rest[++i], 10);
    else if (a === '--disambiguate') opts.disambiguate = true;
    else if (a === '--json') opts.json = true;
    else opts.positional.push(a);
  }
  return opts;
}

function graphDirFor(cwd) {
  return path.join(cwd, '.claude', 'graph');
}

async function withDb(graphDir, fn) {
  const { openDb, initSchema } = await import(path.join(PLUGIN_ROOT, 'scripts/graph/db.mjs'));
  const dbPath = path.join(graphDir, 'index.sqlite');
  if (!fs.existsSync(dbPath)) {
    console.error(`error: no graph index at ${dbPath}. Run \`sspower-graph build\` first.`);
    process.exit(1);
  }
  const db = openDb(dbPath);
  initSchema(db);
  try { return await fn(db); } finally { db.close(); }
}

function emit(opts, payload, pretty) {
  if (opts.json) {
    process.stdout.write(JSON.stringify(payload, null, 2) + '\n');
  } else {
    process.stdout.write(pretty(payload) + '\n');
  }
}

async function runBuildLocked(opts) {
  const lockWrapper = path.join(PLUGIN_ROOT, 'scripts/graph-with-lock.py');
  const graphDir = graphDirFor(opts.cwd);
  fs.mkdirSync(graphDir, { recursive: true, mode: 0o700 });
  const child = spawnSync('python3', [
    lockWrapper,
    '--graph-dir', graphDir,
    '--',
    process.execPath, url.fileURLToPath(import.meta.url),
    'build-unlocked', '--cwd', opts.cwd,
  ], {
    env: { ...process.env, CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT },
    stdio: 'inherit',
  });
  process.exit(child.status ?? 1);
}

async function runBuildUnlocked(opts) {
  const { build } = await import(path.join(PLUGIN_ROOT, 'scripts/graph/build.mjs'));
  const graphDir = graphDirFor(opts.cwd);
  fs.mkdirSync(graphDir, { recursive: true, mode: 0o700 });
  const t0 = Date.now();
  const res = await build({
    rootDir: opts.cwd, graphDir,
    log: msg => process.stderr.write(`[build] ${msg}\n`),
  });
  process.stderr.write(`[build] complete in ${Date.now() - t0}ms\n`);
  emit(opts, res, r => `${r.fileCount} files, ${r.nodeCount} nodes, ${r.edgeCount} edges`);
}

async function runCallers(opts, name) {
  const { callers } = await import(path.join(PLUGIN_ROOT, 'scripts/graph/query.mjs'));
  await withDb(graphDirFor(opts.cwd), db => {
    const r = callers(db, name, { limit: opts.limit, disambiguate: opts.disambiguate });
    if (r.ambiguous) {
      emit(opts, r, p => `ambiguous: ${p.targets.length} targets — pass --disambiguate or query a more specific name\n` +
        p.targets.map(t => `  ${t.qualified_name} (${t.file_path}:${t.start_line})`).join('\n'));
      return;
    }
    emit(opts, r, p => p.matches.length === 0 ? 'no callers' :
      p.matches.map(m => `${m.src_file}:${m.line}\t${m.src_qname}\t-> ${m.tgt_qname}\t(conf=${m.confidence})`).join('\n'));
  });
}

async function runCallees(opts, name) {
  const { callees } = await import(path.join(PLUGIN_ROOT, 'scripts/graph/query.mjs'));
  await withDb(graphDirFor(opts.cwd), db => {
    const r = callees(db, name, { limit: opts.limit });
    emit(opts, r, p => p.matches.length === 0 ? 'no callees' :
      p.matches.map(m => `${m.tgt_file}:${m.tgt_start}\t${m.tgt_qname}\t<- ${m.src_qname}\t(conf=${m.confidence})`).join('\n'));
  });
}

async function runNode(opts, name) {
  const { nodeLookup } = await import(path.join(PLUGIN_ROOT, 'scripts/graph/query.mjs'));
  await withDb(graphDirFor(opts.cwd), db => {
    const rows = nodeLookup(db, name);
    emit(opts, rows, p => p.length === 0 ? 'not found' :
      p.map(n => `${n.file_path}:${n.start_line}-${n.end_line}\t${n.qualified_name}\t${n.kind}\t${n.signature ?? ''}`).join('\n'));
  });
}

async function runStatus(opts) {
  const { status } = await import(path.join(PLUGIN_ROOT, 'scripts/graph/query.mjs'));
  const graphDir = graphDirFor(opts.cwd);
  const dbPath = path.join(graphDir, 'index.sqlite');
  if (!fs.existsSync(dbPath)) {
    emit(opts, { ok: false, reason: 'no-index', dbPath }, p => `no index: ${p.dbPath}`);
    return;
  }
  await withDb(graphDir, db => {
    const s = status(db, graphDir);
    emit(opts, s, p => `files=${p.fileCount} nodes=${p.nodeCount} edges=${p.edgeCount} dirty=${p.dirtyCount} last=${p.lastIndexed}`);
  });
}

async function runMcpServer() {
  const { Server } = await import('@modelcontextprotocol/sdk/server/index.js');
  const { StdioServerTransport } = await import('@modelcontextprotocol/sdk/server/stdio.js');
  const { ListToolsRequestSchema, CallToolRequestSchema } = await import('@modelcontextprotocol/sdk/types.js');

  const server = new Server({ name: 'sspower-graph', version: PKG_VERSION }, { capabilities: { tools: {} } });
  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: [{
      name: 'graph_status',
      description: 'Graph index freshness (P0 stub — always returns {ok:true,stub:true,phase:"P0"}).',
      inputSchema: { type: 'object', properties: {}, required: [] },
    }],
  }));
  server.setRequestHandler(CallToolRequestSchema, async ({ params }) => {
    if (params.name === 'graph_status') {
      return { content: [{ type: 'text', text: JSON.stringify({ ok: true, stub: true, phase: 'P0' }) }] };
    }
    throw new Error(`unknown tool: ${params.name}`);
  });
  await server.connect(new StdioServerTransport());
}

const rest = argv.slice(1);
const opts = parseOpts(rest);

try {
  switch (cmd) {
    case 'build':           await runBuildLocked(opts); break;
    case 'build-unlocked':  await runBuildUnlocked(opts); break;
    case 'callers':         if (!opts.positional[0]) { usage(); process.exit(2); }
                            await runCallers(opts, opts.positional[0]); break;
    case 'callees':         if (!opts.positional[0]) { usage(); process.exit(2); }
                            await runCallees(opts, opts.positional[0]); break;
    case 'node':            if (!opts.positional[0]) { usage(); process.exit(2); }
                            await runNode(opts, opts.positional[0]); break;
    case 'status':          await runStatus(opts); break;
    case 'serve':           if (argv[1] === '--mcp') { await runMcpServer(); }
                            else { usage(); process.exit(2); }
                            break;
    default:                usage(); process.exit(2);
  }
} catch (e) {
  process.stderr.write(`error: ${e.message}\n`);
  process.exit(1);
}
```

- [ ] **Step 9.3: Smoke each verb against the live repo**

```bash
bin/sspower-graph.mjs build --cwd "$(pwd)"
bin/sspower-graph.mjs callers cmdImplement --cwd "$(pwd)"
bin/sspower-graph.mjs callees cmdImplement --cwd "$(pwd)" --limit 5
bin/sspower-graph.mjs node cmdImplement --cwd "$(pwd)"
bin/sspower-graph.mjs status --cwd "$(pwd)" --json
```
Expected `callers cmdImplement`: at least one line containing `codex-bridge.mjs:2061` with src_qname=`main`. All five must produce non-empty output. `--json` mode verified on `status`.

- [ ] **Step 9.4: P0 MCP smoke MUST still pass**

```bash
CLAUDE_PLUGIN_ROOT="$(pwd)" node tests/graph/test-mcp-stub.mjs
```
Expected: `OK MCP stub smoke passed`. If this fails, the CLI dispatcher accidentally broke the serve path — fix before continuing.

- [ ] **Step 9.5: Commit**

Write `/tmp/commit-msg-p1-9.txt`:
```
feat(graph): CLI dispatcher for build, callers, callees, node, status

Single binary dispatches all P1 verbs plus the P0 MCP serve. build
re-execs through scripts/graph-with-lock.py so the cross-language
single-lock contract (spec D34/D38) brackets the SQLite transaction.

`build-unlocked` is the inner verb the Python wrapper invokes; the
user-facing `build` does the re-exec dance. Same pattern P2 refresh
will use.

Smoke-verified: `callers cmdImplement` on the live plugin repo
returns main@codex-bridge.mjs:2061 — the P1 acceptance demo.
```

```bash
git add bin/sspower-graph.mjs
git commit -F /tmp/commit-msg-p1-9.txt
```

---

## Task 10: Rewire fixture harness — extractor comparison + precision/recall gate

**Files:**
- Modify: `__tests__/graph-fixtures/harness.test.ts`

- [ ] **Step 10.1: Rewrite harness**

```typescript
// @ts-nocheck
import { describe, expect, it } from 'vitest';
import { existsSync, readFileSync, readdirSync, mkdtempSync, rmSync, cpSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { build } from '../../scripts/graph/build.mjs';
import { openDb, initSchema } from '../../scripts/graph/db.mjs';

const FIXTURES_DIR = path.resolve(import.meta.dirname);
const FIXTURE_PACKS = readdirSync(FIXTURES_DIR, { withFileTypes: true })
  .filter((d) => d.isDirectory())
  .map((d) => d.name);

const P_THRESHOLD = 0.85;
const R_THRESHOLD = 0.70;

// Edge tokens encode (src, tgt) by default. If the golden specifies a
// confidence for an edge, the token includes it — so P/R drops when the
// extractor classifies a known edge with the wrong confidence.
function edgeTokens(rows, requireConfidence) {
  return new Set(rows.map(r => requireConfidence.has(`${r.src_qname}->${r.tgt_qname}`)
    ? `${r.src_qname}->${r.tgt_qname}@c${r.confidence}`
    : `${r.src_qname}->${r.tgt_qname}`));
}
function expectedEdgeTokens(expected) {
  const requireConfidence = new Set(
    expected.edges
      .filter(e => typeof e.confidence === 'number')
      .map(e => `${e.source}->${e.target}`)
  );
  const tokens = new Set(expected.edges.map(e => typeof e.confidence === 'number'
    ? `${e.source}->${e.target}@c${e.confidence}`
    : `${e.source}->${e.target}`));
  return { tokens, requireConfidence };
}
function nodeSet(rows) {
  return new Set(rows.map(r => r.qualified_name));
}
function expectedNodeSet(expected) {
  return new Set(expected.nodes.map((n) => n.qualifiedName ?? n.name));
}

describe('graph-fixtures extractor accuracy', () => {
  for (const pack of FIXTURE_PACKS) {
    const packDir = path.join(FIXTURES_DIR, pack);
    const expectedPath = path.join(packDir, 'expected.json');
    if (!existsSync(expectedPath)) continue;
    const expected = JSON.parse(readFileSync(expectedPath, 'utf8'));

    it(`pack '${pack}' meets P=${P_THRESHOLD}, R=${R_THRESHOLD}`, async () => {
      const tmp = mkdtempSync(path.join(os.tmpdir(), `fixture-${pack}-`));
      cpSync(packDir, tmp, { recursive: true });
      const graphDir = path.join(tmp, '.claude', 'graph');
      mkdirSync(graphDir, { recursive: true });
      await build({ rootDir: tmp, graphDir, log: () => {} });

      const db = openDb(path.join(graphDir, 'index.sqlite'));
      initSchema(db);
      const nodes = db.prepare('SELECT * FROM nodes').all();
      const edges = db.prepare(
        `SELECT src.qualified_name AS src_qname, tgt.qualified_name AS tgt_qname, e.confidence AS confidence
           FROM edges e
           JOIN nodes src ON e.source = src.id
           JOIN nodes tgt ON e.target = tgt.id`
      ).all();
      db.close();

      const gotNodes = nodeSet(nodes);
      const wantNodes = expectedNodeSet(expected);
      const { tokens: wantEdges, requireConfidence } = expectedEdgeTokens(expected);
      const gotEdges = edgeTokens(edges, requireConfidence);

      const got = new Set([...gotNodes, ...[...gotEdges].map(e => `edge:${e}`)]);
      const want = new Set([...wantNodes, ...[...wantEdges].map(e => `edge:${e}`)]);

      const tp = [...got].filter(x => want.has(x)).length;
      const precision = got.size === 0 ? 0 : tp / got.size;
      const recall    = want.size === 0 ? 1 : tp / want.size;

      const detail = {
        pack, precision, recall,
        missing: [...want].filter(x => !got.has(x)),
        extra: [...got].filter(x => !want.has(x)),
      };
      expect(precision, `P=${precision.toFixed(3)} ${JSON.stringify(detail)}`).toBeGreaterThanOrEqual(P_THRESHOLD);
      expect(recall, `R=${recall.toFixed(3)} ${JSON.stringify(detail)}`).toBeGreaterThanOrEqual(R_THRESHOLD);

      rmSync(tmp, { recursive: true });
    }, 30_000);
  }

  it('at least one fixture pack present', () => {
    expect(FIXTURE_PACKS.length).toBeGreaterThan(0);
  });
});
```

- [ ] **Step 10.2: Run vitest — expect pass**

```bash
bun x vitest run __tests__/graph-fixtures/ --reporter=basic
```
Expected: both fixture packs (`ts-js`, `ts-js-multifile`) pass with P ≥ 0.85 and R ≥ 0.70. If either fails, the detail block in the assertion message lists missing/extra symbols — fix extractor (preferred) or rebaseline goldens with explicit reason.

- [ ] **Step 10.3: Commit**

Write `/tmp/commit-msg-p1-10.txt`:
```
test(graph): flip fixture harness to extractor-comparison mode

P0 shipped goldens-only stub. P1 wires the real extractor — each
fixture pack is built into a sandbox SQLite index, then compared
against expected.json on the (qualified_name, qualified_name) edge
pair set plus the qualified_name node set. Precision ≥ 0.85 and
recall ≥ 0.70 thresholds per spec v5 §3.3 P1 gate.

Failure message embeds the missing/extra set so the next reviewer
can see exactly which pair is wrong without re-running the build.
```

```bash
git add __tests__/graph-fixtures/harness.test.ts
git commit -F /tmp/commit-msg-p1-10.txt
```

---

## Task 11: README CLI usage section

**Files:**
- Modify: `README.md`

- [ ] **Step 11.1: Locate or create the sspower-graph section**

```bash
grep -nE "^## .*sspower-graph|^### .*sspower-graph" README.md || echo MISSING
```
If MISSING, append `## sspower-graph` heading under the existing "Symbol graph" / "Components" area.

- [ ] **Step 11.2: Add CLI usage block**

Insert under the section heading:
````markdown
### CLI (P1)

```
sspower-graph build [--cwd <dir>]
sspower-graph callers <name> [--limit N] [--disambiguate] [--json]
sspower-graph callees <name> [--limit N] [--json]
sspower-graph node <name> [--json]
sspower-graph status [--json]
sspower-graph serve --mcp                # P0 stub MCP server
```

`build` indexes the current working directory (or `--cwd`) into
`<cwd>/.claude/graph/index.sqlite`. The current build is full-only;
incremental refresh ships in P2.

`callers <name>` returns the call-sites that target `<name>`. If
multiple symbols match by name, pass `--disambiguate` (or query with
a `Class.method` form). Output line shape:

```
<file>:<line>\t<caller_qname>\t-> <target_qname>\t(conf=<0|1|2>)
```

Confidence: `1` = intra-file qname match, `2` = cross-file via
resolved import, `0` = ambiguous same-name fallback.
````

- [ ] **Step 11.3: Commit**

Write `/tmp/commit-msg-p1-11.txt`:
```
docs(graph): document P1 CLI surface in README

build/callers/callees/node/status with the output shape so users can
grep the result without --json. Notes the P2 boundary (full builds
only in P1; incremental refresh comes later).
```

```bash
git add README.md
git commit -F /tmp/commit-msg-p1-11.txt
```

---

## Task 12: Self-review pass

- [ ] **Step 12.1: Confirm all expected files exist**

```bash
for f in scripts/graph/db.mjs scripts/graph/walk.mjs scripts/graph/astgrep.mjs \
         scripts/graph/extract-ts.mjs scripts/graph/resolve.mjs \
         scripts/graph/build.mjs scripts/graph/query.mjs \
         scripts/graph/rules/ts-function.yml scripts/graph/rules/ts-arrow.yml \
         scripts/graph/rules/ts-class.yml scripts/graph/rules/ts-method.yml \
         scripts/graph/rules/ts-call.yml scripts/graph/rules/ts-import.yml \
         tests/graph/test-db-schema.mjs tests/graph/test-astgrep.mjs \
         tests/graph/test-extract-ts.mjs tests/graph/test-resolve.mjs \
         tests/graph/test-walk.mjs tests/graph/test-build-query.mjs \
         __tests__/graph-fixtures/ts-js-multifile/app.ts \
         __tests__/graph-fixtures/ts-js-multifile/util.ts \
         __tests__/graph-fixtures/ts-js-multifile/expected.json; do
  test -f "$f" && echo "OK $f" || echo "MISSING $f"
done
```
Expected: all `OK`.

- [ ] **Step 12.2: Run every test in one shot**

```bash
set -e
echo "--- db schema ---"
node tests/graph/test-db-schema.mjs
echo "--- ast-grep wrapper ---"
node tests/graph/test-astgrep.mjs
echo "--- walker ---"
node tests/graph/test-walk.mjs
echo "--- extractor ---"
node tests/graph/test-extract-ts.mjs
echo "--- resolver ---"
node tests/graph/test-resolve.mjs
echo "--- build+query (incl. live cmdImplement) ---"
node tests/graph/test-build-query.mjs
echo "--- fixture harness (vitest) ---"
bun x vitest run __tests__/graph-fixtures/ --reporter=basic
echo "--- P0 regression suite ---"
bash tests/hooks/test-intent-architecture.sh
CLAUDE_PLUGIN_ROOT="$(pwd)" python3 tests/graph/test-lock-helpers.py
CLAUDE_PLUGIN_ROOT="$(pwd)" node tests/graph/test-mcp-stub.mjs
echo "--- ALL PASS ---"
```
Expected: `--- ALL PASS ---`. Any failure: STOP, fix, re-run.

- [ ] **Step 12.3: Spec traceability**

Cross-check `docs/specs/2026-05-26-codegraph-style-graph-design.md` decisions:
- D2 stable IDs `<file>#<qname>#<span_sha8>` → `db.mjs:nodeId` + `extract-ts.mjs:spanSha8` ✓
- D3 ast-grep direct invocation → `astgrep.mjs` spawn wrapper ✓
- D4 P1 language = TS/JS only → only `extract-ts.mjs`; no Python/Go/Rust extractor ✓
- D7 node:sqlite → `db.mjs` uses `node:sqlite` ✓
- D17 FK cascade on `nodes.file_path` → `db.mjs` SCHEMA ✓
- D18 imports table → `db.mjs` SCHEMA + `build.mjs` populates ✓
- D19 P1 acceptance = `cmdImplement` (line in spec 1519 is stale; symbol contract preserved at current line 1553) → `tests/graph/test-build-query.mjs` Case B + Task 9.3 ✓
- D22 Node ≥22 → already pinned in P0 `package.json` ✓
- D34 single lock contract → `bin/sspower-graph.mjs` build re-execs through `graph-with-lock.py` ✓
- D38 graph-with-lock.py wrapper → reused from P0 ✓
- spec §3.3 P1 gate P ≥ 0.85, R ≥ 0.70 → `__tests__/graph-fixtures/harness.test.ts` ✓

Decisions deferred (NOT P1): D11, D12, D13, D16 (P0 done), D23, D24, D28-D31, D33, D35-D37, D40.

- [ ] **Step 12.4: Confirm no stray edits outside the P1 surface**

```bash
git diff --stat graph-p0..HEAD | tail -30
```
Expected: only the file map files modified/created. NO changes to `hooks/`, `agents/`, `commands/`, `bin/sspower-mem`, `scripts/codex-bridge.mjs`, `scripts/sspower_mem/`. If diff touches anything else, investigate before continuing.

---

## Task 13: Codex plan-review + branch-diff review + ship

Plan-level review runs **after Task 1** (catch design flaws before implementing) AND **after Task 12** (against realized diff).

- [ ] **Step 13.1: Plan-review pass (before Task 2 work begins)**

```bash
node "/Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower/scripts/codex-bridge.mjs" plan-review \
  --cd . --prompt @docs/plans/2026-05-26-codegraph-graph-P1.md
```
Expected: verdict ∈ {`approve`, `approve-with-followups`}. Fix every `high`/`medium` finding inline in this plan, then re-run. Cap at 3 iterations; if still `needs-attention` after 3, escalate via `sspower:second-opinion`.

- [ ] **Step 13.2: Branch-diff review after Task 12 ALL PASS**

```bash
node "/Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower/scripts/codex-bridge.mjs" review \
  --cd /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower
```
Expected: verdict ∈ {`approve`, `approve-with-followups`}. Fix `high`/`medium` findings as new commits (NOT amends). Cap at 3 iterations.

- [ ] **Step 13.3: Promote version + tag P1**

Edit `package.json`: version → `"1.2.0"`. Then:

Write `/tmp/commit-msg-p1-promote.txt`:
```
chore(graph): promote 1.2.0-rc.0 → 1.2.0 for P1 ship

P1 acceptance demo passes (callers of cmdImplement returns main()
at codex-bridge.mjs:2061). Fixture harness P=0.85+, R=0.70+ on
both ts-js and ts-js-multifile packs.
```

```bash
git add package.json
git commit -F /tmp/commit-msg-p1-promote.txt
```

- [ ] **Step 13.4: Merge to main + tag**

```bash
git checkout main
git merge --no-ff feat/graph-P1
git tag -a graph-p1 -m "sspower-graph P1: TS/JS extractor + schema + CLI verbs"
```

If remote exists:

```bash
git push -u origin feat/graph-P1 2>&1 | tail -20
```
Then `gh pr create` standalone with title `feat(graph): P1 TS/JS extractor + CLI` and a body summarizing the file map + acceptance demo + test plan.

- [ ] **Step 13.5: Update `docs/handoff.md`**

Replace "Resume Here" block with a P2-pointing handoff:
```markdown
## Resume Here
1. **P2 scope:** incremental refresh — `refresh` CLI, dirty-queue
   processing, two-phase transaction with reverse-import closure,
   PostToolUse:Write|Edit|MultiEdit hook, SessionStart sweep.
   Plus Python/Go/Rust extractors.
2. **If user says go on P2:** invoke `sspower:writing-plans` with
   spec §3.5, §4 P2 row, and the P1 build orchestrator as the
   extension point. Branch off `graph-p1` tag.
```

Write `/tmp/commit-msg-p1-handoff.txt`:
```
docs(handoff): P1 shipped — point to P2 scope (refresh + multi-lang)
```

```bash
git add docs/handoff.md
git commit -F /tmp/commit-msg-p1-handoff.txt
```

---

## Acceptance summary

P1 SHIPPED when:
- All 11 implementation/test commits landed (Tasks 1-11) plus Task 13.3 version promote + Task 13.5 handoff update
- Task 12.2 prints `--- ALL PASS ---`
- Task 13.2 codex review verdict ∈ {approve, approve-with-followups}
- `sspower-graph callers cmdImplement --cwd $(pwd)` against the live plugin repo lists `main@codex-bridge.mjs:2061` (the spec §4 P1 demo target)
- Fixture harness: both `ts-js` and `ts-js-multifile` packs meet P ≥ 0.85 and R ≥ 0.70
- Tag `graph-p1` at HEAD of main
- No regressions in P0 tests (intent classifier, lock helpers, MCP smoke, vitest harness)

P1 does NOT ship:
- `refresh` / dirty queue (P2)
- `trace`, `impact`, `context`, `routes` (P2/P4/P5)
- Python, Go, Rust extractors (P2)
- PostToolUse hooks, SessionStart sweep (P2)
- MCP tools beyond `graph_status` (P3)
- `graph-orchestrator.sh`, `auto-review.sh` enrichment (P4)
- Framework route extractors (P5+)

P1 unblocks:
- P2 incremental refresh (schema is already complete; just adds the two-phase transaction and dirty-queue consumer)
- P3 MCP expansion (CLI verbs map 1:1 to MCP tool wrappers)
- P4 hook enrichment (build fast enough to bootstrap on first prompt)
