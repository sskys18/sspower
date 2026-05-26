# Codegraph-style Symbol Graph — P2 Incremental Refresh + Multi-Language Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use sspower:subagent-driven-development (recommended) or sspower:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the incremental refresh subsystem (`refresh` CLI verb, JSONL dirty queue, two-phase reverse-import closure transaction with `op_for ∈ {upsert, delete, relink}`, PostToolUse:Write|Edit|MultiEdit hook, SessionStart sweep with git filesethash + rowid-stride sampling) AND Python/Go/Rust extractors meeting `precision ≥ 0.85, recall ≥ 0.70` per language, AND the remaining CLI verbs (`trace`, `impact`, `context`). Acceptance gates from spec §4 P2 row: `10k-file build < 60s`, `warm callers < 1s p95`, per-language fixtures pass thresholds.

**Architecture:** Refresh is a new module `scripts/graph/refresh.mjs` that consumes `<cwd>/.claude/graph/dirty` (JSONL, last-record-wins + `stat()` reconcile), walks the reverse-import closure (imports table ∪ existing edges per spec §3.1 K1 fix), tags every closure file with `op ∈ {upsert, delete, relink}`, and applies one SQLite `BEGIN IMMEDIATE` transaction with three phases (1a deletes, 1b upserts, 1c relink-only-outbound, 2 re-resolve edges). Single-lock contract from P0/P1 (D34/D38) is honored by re-execing `bin/sspower-graph.mjs refresh` through `scripts/graph-with-lock.py` exactly as `build` already does. PostToolUse hook is a thin shell wrapper (`hooks/graph-mark-dirty.sh`) that reads `tool_input` JSON, normalizes paths, and invokes the existing P0 helper `scripts/graph-append-dirty.py`. SessionStart sweep is a new CLI verb `session-refresh` that combines (Step 0) git filesethash NEW-FILE detection, (Step 1) rowid-stride sampling with sparse-rowid retry, (Step 2) full-rebuild OR incremental refresh, all under one process. Multi-language extractors mirror the P1 TS/JS shape: per-language `scripts/graph/rules/<lang>-*.yml` rule files + `scripts/graph/extract-<lang>.mjs` module + per-language module resolver fork in `scripts/graph/resolve.mjs`. Build dispatcher in `scripts/graph/build.mjs` selects extractor by file extension. Trace/impact/context are pure query-layer additions on top of the existing P1 schema (no schema migrations).

**Tech Stack:** Node ≥22.5 (`node:sqlite` DatabaseSync, child-process spawn, `crypto`, `fs/promises`), ast-grep ≥0.43 (TS/JS/Python/Go/Rust grammars all verified shipping in the brew bottle, see Task 9.1/10.1/11.1 probes), Python lock helpers from P0 (`scripts/graph-with-lock.py`, `scripts/graph-append-dirty.py` — both reuse `sspower_mem.lock.acquire_lock`), vitest for fixture acceptance.

**Spec:** `docs/specs/2026-05-26-codegraph-style-graph-design.md` v5 §3.1 (schema + two-phase refresh transaction contract + dirty file format), §3.2 (extraction pipeline pattern, generalized to all four languages), §3.3 (accuracy fixture suite, P2 phase gate per language), §3.5 (hook contracts: graph-mark-dirty.sh, session-start sweep), §3.6 (CLI surface: `refresh`, `trace`, `impact`, `context` land here), §4 P2 row (acceptance gates: `10k-file build <60s`, `warm callers <1s p95`, per-language P≥0.85/R≥0.70). Locked decisions D1–D40 + FU1–FU4 from P0 and the P1-iteration decisions documented in `docs/handoff.md` Decisions section.

**P1 build orchestrator extension points** (load-bearing — these are the contracts P2 builds on):
- `scripts/graph/build.mjs` exports `build({ rootDir, graphDir, log })`. The walk → extract → in-memory `importedNamesByFile` → `resolveEdges` → single-transaction destructive insert sequence is reused verbatim by `refresh` for the Phase 2 re-resolution step. Refresh adds a new closure walker upstream and replaces Phase 1 wipe-all with the surgical 1a/1b/1c phases below.
- `scripts/graph/extract-ts.mjs` exports `extractFile({ absPath, source, language })` returning `{ nodes, imports, callSites }`. Each new language extractor MUST return the SAME shape with the SAME field names. The build dispatcher and resolver are extractor-agnostic — adding a language is purely a new extractor module + walker extension + resolver module-resolution fork.
- `scripts/graph/resolve.mjs` exports `resolveModule(importerAbs, moduleSpec)` (per-language module resolution) and `resolveEdges({ nodes, callSites })` (language-agnostic intra→imported→ambiguous resolution). P2 forks `resolveModule` per language; `resolveEdges` stays untouched — the JS-scoping rules (intra-file top-level wins for direct calls, member calls go through imports, ambiguous fallback) generalize.
- `bin/sspower-graph.mjs` dispatches `build|build-unlocked|callers|callees|node|status|serve`. P2 adds `refresh|refresh-unlocked|session-refresh|trace|impact|context`. The `serve --mcp` stub stays P0 behavior (P3 expands it).
- `scripts/graph-with-lock.py` wraps any Node child under `acquire_lock`. P2 reuses it for `refresh` identically — no Python changes needed.
- `scripts/graph-append-dirty.py` writes one JSONL record per invocation. The PostToolUse hook calls this helper one or more times per tool event; no Python changes needed.

**Branch policy:** Branch `feat/graph-P2` off `main` (commit `b03c1f0`, which is `graph-p1` + one docs/handoff commit). Worktree at `~/.claude/plugins/marketplaces/sskys18/plugins/sspower-graph-P2` already created on `feat/graph-P2`. Do NOT merge to `main` until Task 15 codex plan-review + branch-diff review verdict is `approve` or `approve-with-followups` AND Tasks 9.10/10.10/11.10 per-language acceptance + Task 14 perf gate all pass.

---
## File map

**Create (new files):**

*Refresh subsystem*
- `scripts/graph/dirty.mjs` — `readDirty(graphDir)` + `dedupeDirty(records)` + `reconcileWithStat(records)` returning `Map<absPath, "upsert"|"delete">`
- `scripts/graph/closure.mjs` — `reverseImportClosure({ db, seed })` returning `Map<absPath, "upsert"|"delete"|"relink">`; walks `imports` ∪ `edges` per spec §3.1 K1 fix; safety cap 0.5×|files|
- `scripts/graph/refresh.mjs` — orchestrates dirty→closure→transaction; exports `refresh({ rootDir, graphDir, log })` mirroring `build.mjs` shape; handles thrash guard (dirty>500 → full rebuild fall-through)
- `scripts/graph/session-refresh.mjs` — `sessionRefresh({ rootDir, graphDir, maxTime, log })`: Step 0 filesethash, Step 1 rowid-stride sampling with sparse retry, Step 2 dispatch to refresh or full rebuild
- `tests/graph/test-dirty.mjs` — JSONL parse + dedupe + stat-reconcile (upsert↔delete degradation)
- `tests/graph/test-closure.mjs` — reverse-import closure (linear chain, fan-out, cycle, edge-only cascade, safety-cap fall-through)
- `tests/graph/test-refresh.mjs` — end-to-end refresh on a fixture tree (upsert + delete + relink ops; verifies node/edge state vs full rebuild)
- `tests/graph/test-session-refresh.mjs` — filesethash trigger, sampling sparse-rowid retry, threshold-based full-rebuild

*PostToolUse hook*
- `hooks/graph-mark-dirty.sh` — reads `tool_input` JSON from stdin (Write/Edit `file_path` OR MultiEdit `edits[].file_path`), normalizes to absolute path, gates on `<cwd>` containment, dispatches to `graph-append-dirty.py`
- `tests/hooks/test-graph-mark-dirty.sh` — fixture stdin payloads for Write/Edit/MultiEdit; asserts JSONL records appended

*Python extractor*
- `scripts/graph/rules/py-function.yml` — `kind: function_definition`
- `scripts/graph/rules/py-class.yml` — `kind: class_definition`
- `scripts/graph/rules/py-method.yml` — `kind: function_definition` nested under class (composite rule)
- `scripts/graph/rules/py-call.yml` — `kind: call`
- `scripts/graph/rules/py-import.yml` — `any: [{kind: import_statement}, {kind: import_from_statement}]`
- `scripts/graph/extract-py.mjs` — Python extractor; same return shape as `extract-ts.mjs`
- `__tests__/graph-fixtures/python/` — Python fixture pack (single-file + multi-file + class-method) with `expected.json`
- `tests/graph/test-extract-py.mjs` — unit tests

*Go extractor*
- `scripts/graph/rules/go-function.yml` — `kind: function_declaration`
- `scripts/graph/rules/go-method.yml` — `kind: method_declaration`
- `scripts/graph/rules/go-call.yml` — `kind: call_expression`
- `scripts/graph/rules/go-import.yml` — `kind: import_declaration`
- `scripts/graph/extract-go.mjs`
- `__tests__/graph-fixtures/go/`
- `tests/graph/test-extract-go.mjs`

*Rust extractor*
- `scripts/graph/rules/rs-function.yml` — `kind: function_item`
- `scripts/graph/rules/rs-impl.yml` — `kind: impl_item`
- `scripts/graph/rules/rs-method.yml` — `function_item` inside `impl_item` (composite)
- `scripts/graph/rules/rs-call.yml` — `any: [{kind: call_expression}, {kind: macro_invocation}]`
- `scripts/graph/rules/rs-use.yml` — `kind: use_declaration`
- `scripts/graph/extract-rs.mjs`
- `__tests__/graph-fixtures/rust/`
- `tests/graph/test-extract-rs.mjs`

*Query CLI additions*
- `scripts/graph/trace.mjs` — `trace(db, fromName, toName, { maxHops })`: bidirectional BFS over `edges`, returns `{ paths: [[{qname, file, line}], ...], hops }`
- `scripts/graph/impact.mjs` — `impact(db, filePath)`: transitive callers across the edge graph; returns nodes + files touched
- `scripts/graph/context.mjs` — `context(db, task)`: composed `nodeLookup + callers + impact` for top-N FTS hits
- `tests/graph/test-trace.mjs`
- `tests/graph/test-impact.mjs`
- `tests/graph/test-context.mjs`

*Perf bench*
- `tests/graph/perf-10k.mjs` — generates a synthetic 10k-file tree, runs `build` then warm `callers`, asserts spec §4 gates
- `tests/graph/test-perf-10k.sh` — wraps the bench for CI; runs only when `SSPOWER_GRAPH_PERF=1` (opt-in; ~30s on M-series, longer on CI runners)

**Modify:**
- `scripts/graph/walk.mjs` — extend `SOURCE_EXTS` with `.py`, `.go`, `.rs`; add per-language extension probe + ignored dirs (`target`, `vendor`)
- `scripts/graph/build.mjs` — `languageFor(filePath)` returns `python|go|rust|typescript|javascript`; dispatch to per-language extractor via a `extractorFor(language)` switch
- `scripts/graph/resolve.mjs` — `resolveModule` becomes a dispatch on importer-file language: `resolveModulePy`, `resolveModuleGo`, `resolveModuleRs`; TS/JS fork stays as-is
- `scripts/graph/extract-ts.mjs` — NO behavior change (P1 contract preserved). Comment-only: tag the public `extractFile` as the "TS/JS reference implementation; per-language modules must match this return shape".
- `bin/sspower-graph.mjs` — extend dispatch with `refresh|refresh-unlocked|session-refresh|trace|impact|context`; `refresh` re-execs through `graph-with-lock.py` exactly like `build`
- `hooks/hooks.json` — add `graph-mark-dirty.sh` to PostToolUse:Write|Edit|MultiEdit (sibling of existing `codex-lsp-posttool.sh`); add `session-refresh` invocation to SessionStart (detached, fire-and-forget)
- `hooks/session-start` — append a single detached background line that invokes `sspower-graph session-refresh --max-time 5s --cwd "$PWD" &`; non-fatal if binary missing
- `__tests__/graph-fixtures/harness.test.ts` — extend the precision/recall gate loop to iterate `[ts-js, ts-js-multifile, python, go, rust]` packs (loops over `LANGUAGE_PACKS = [{ dir, language, expectedFile }]`); each pack independently gated at P≥0.85, R≥0.70
- `package.json` — bump version to `1.3.0-rc.0` (promoted to `1.3.0` at merge); no new runtime deps
- `README.md` — extend "sspower-graph" section with the four new CLI verbs + multi-language support note + dirty-queue + session-refresh hook documentation
- `docs/handoff.md` — final commit only: P2 shipped, point at P3 scope (MCP expansion)

**Out of scope (P3+ — explicitly NOT in P2):**
- MCP tool expansion beyond P0 `graph_status` (P3 owns `callers`, `callees`, `node`, `trace`, `impact`, `context`, `routes` exposed as MCP tools)
- `graph-orchestrator.sh` UserPromptSubmit hook (P4)
- `auto-review.sh` graph enrichment + cache-key revision (P4)
- Framework route extractors (Express, FastAPI, Django, Rails) — P5+
- `routes` CLI verb (P5+; depends on framework extractors)
- Sub-agent `.md` instruction updates (P3 ships with the MCP surface)

---
## Task 1: Branch verification, version bump, plan-tracking commit

**Files:**
- Modify: `package.json`
- Create: this plan doc (already created at `docs/plans/2026-05-26-codegraph-graph-P2.md`)

- [ ] **Step 1.1: Verify worktree state**

```bash
cd ~/.claude/plugins/marketplaces/sskys18/plugins/sspower-graph-P2
git rev-parse --abbrev-ref HEAD
git rev-parse HEAD
git rev-parse 'graph-p1^{commit}'
git rev-parse 'main^{commit}'
```
Expected: branch is `feat/graph-P2`, HEAD is `b03c1f0` (one commit ahead of `graph-p1` tag — the docs/handoff sync commit on main). If HEAD diverges from `main`, STOP and ask the user.

- [ ] **Step 1.2: Confirm working tree is clean**

```bash
git status --porcelain
```
Expected: SUBSET of `?? docs/plans/2026-05-26-codegraph-graph-P2.md` (this plan, untracked). Anything else → STOP.

- [ ] **Step 1.3: Bump version to 1.3.0-rc.0**

Edit `package.json`, change the `"version"` field to `"1.3.0-rc.0"`. Read the file first with the Read tool; identify the current version (`1.2.0` post-P1 merge), then surgical replace.

- [ ] **Step 1.4: Stage plan + version bump**

```bash
git add docs/plans/2026-05-26-codegraph-graph-P2.md package.json
git status --short
```
Expected: `A  docs/plans/2026-05-26-codegraph-graph-P2.md` + `M  package.json`.

- [ ] **Step 1.5: Write commit message to file**

```bash
cat > /tmp/commit-msg-p2-1.txt <<'EOF'
chore(graph): seed P2 plan + bump to 1.3.0-rc.0

P2 ships: refresh CLI verb + two-phase reverse-import closure
transaction (spec §3.1), PostToolUse:Write|Edit|MultiEdit dirty
list (spec §3.5), SessionStart sweep with git filesethash +
rowid-stride sampling, Python/Go/Rust extractors meeting
P≥0.85/R≥0.70 per language (spec §3.3 P2 row), trace/impact/context
CLI verbs (spec §3.6).

Branch off main (b03c1f0 = graph-p1 + docs sync). No code in this
commit — plan + version bump only. RC suffix promoted to 1.3.0 at
merge per the P1 precedent.
EOF
```

- [ ] **Step 1.6: Commit (standalone — git is a chokepoint)**

```bash
git commit -F /tmp/commit-msg-p2-1.txt
```
Expected: commit lands. If auto-review denies, fix the rule it cites — don't bypass.

---
## Task 2: Dirty queue reader (`scripts/graph/dirty.mjs`)

**Goal:** Read `<graphDir>/dirty` (JSONL produced by `graph-append-dirty.py`), dedupe by path (last-record-wins), reconcile each path with `stat()` (upsert-for-missing-file degrades to delete; delete-for-existing-file degrades to upsert per spec §3.1 H2*).

**Files:**
- Create: `scripts/graph/dirty.mjs`
- Create: `tests/graph/test-dirty.mjs`

- [ ] **Step 2.1: Write the failing test first**

Save the following to `tests/graph/test-dirty.mjs`:

```javascript
// tests/graph/test-dirty.mjs
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { readDirty, dedupeDirty, reconcileWithStat } from '../../scripts/graph/dirty.mjs';

const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'sspower-dirty-'));
const graphDir = path.join(tmp, '.claude', 'graph');
await fs.mkdir(graphDir, { recursive: true });

// (1) Empty/missing dirty file -> empty array.
const empty = await readDirty(graphDir);
assert.deepEqual(empty, []);

// (2) Read JSONL records.
const existing = path.join(tmp, 'a.ts');
const missing  = path.join(tmp, 'b.ts');
await fs.writeFile(existing, 'export const x = 1;\n');
await fs.writeFile(path.join(graphDir, 'dirty'),
  [
    JSON.stringify({ op: 'upsert', path: existing }),
    JSON.stringify({ op: 'upsert', path: existing }),
    JSON.stringify({ op: 'delete', path: existing }),
    JSON.stringify({ op: 'delete', path: missing }),
  ].join('\n') + '\n');
const records = await readDirty(graphDir);
assert.equal(records.length, 4);
assert.equal(records[0].op, 'upsert');
assert.equal(records[2].op, 'delete');

// (3) Dedupe last-wins.
const deduped = dedupeDirty(records);
assert.equal(deduped.size, 2);
assert.equal(deduped.get(existing), 'delete');
assert.equal(deduped.get(missing),  'delete');

// (4) Stat reconcile: delete-for-existing-file degrades to upsert.
const reconciled = await reconcileWithStat(deduped);
assert.equal(reconciled.get(existing), 'upsert');
assert.equal(reconciled.get(missing),  'delete');

// (5) Stat reconcile: upsert-for-missing-file degrades to delete.
const onlyUpsert = new Map([[missing, 'upsert']]);
const r2 = await reconcileWithStat(onlyUpsert);
assert.equal(r2.get(missing), 'delete');

// (6) Malformed line must throw with file:lineno.
await fs.writeFile(path.join(graphDir, 'dirty'),
  JSON.stringify({ op: 'upsert', path: existing }) + '\n' + 'not-json\n');
let threw = false;
try { await readDirty(graphDir); }
catch (e) { threw = true; assert.match(e.message, /malformed dirty record/i); }
assert.ok(threw, 'malformed JSONL must throw');

// (7) Unknown op rejected.
await fs.writeFile(path.join(graphDir, 'dirty'),
  JSON.stringify({ op: 'rebuild', path: existing }) + '\n');
let threw2 = false;
try { await readDirty(graphDir); }
catch (e) { threw2 = true; assert.match(e.message, /unknown op/i); }
assert.ok(threw2);

await fs.rm(tmp, { recursive: true, force: true });
console.log('test-dirty.mjs OK');
```

- [ ] **Step 2.2: Run the test (must fail — file does not exist yet)**

```bash
node tests/graph/test-dirty.mjs
```
Expected: FAIL with `Cannot find module '../../scripts/graph/dirty.mjs'`.

- [ ] **Step 2.3: Implement `scripts/graph/dirty.mjs`**

Save the following to `scripts/graph/dirty.mjs`:

```javascript
// scripts/graph/dirty.mjs
// Read + dedupe + stat-reconcile the JSONL dirty queue produced by
// scripts/graph-append-dirty.py.
//
// Spec §3.1 H2* — JSONL only, no text prefixes. Records: {"op":"upsert"|"delete","path":"/abs/..."}.
// Dedupe: LAST record wins per normalized path. Stat reconcile then degrades op based on disk
// state (delete→upsert if file exists, upsert→delete if file missing).
import fs from 'node:fs/promises';
import path from 'node:path';

const VALID_OPS = new Set(['upsert', 'delete']);

export async function readDirty(graphDir) {
  const dirtyPath = path.join(graphDir, 'dirty');
  let raw;
  try { raw = await fs.readFile(dirtyPath, 'utf8'); }
  catch (e) {
    if (e.code === 'ENOENT') return [];
    throw e;
  }
  const out = [];
  let lineNo = 0;
  for (const line of raw.split('\n')) {
    lineNo++;
    if (line === '') continue;
    let rec;
    try { rec = JSON.parse(line); }
    catch (e) { throw new Error(`malformed dirty record at ${dirtyPath}:${lineNo}: ${e.message}`); }
    if (!rec || typeof rec.op !== 'string' || typeof rec.path !== 'string') {
      throw new Error(`malformed dirty record at ${dirtyPath}:${lineNo}: missing op|path`);
    }
    if (!VALID_OPS.has(rec.op)) {
      throw new Error(`unknown op '${rec.op}' at ${dirtyPath}:${lineNo} (allowed: ${[...VALID_OPS].join(',')})`);
    }
    out.push({ op: rec.op, path: path.resolve(rec.path) });
  }
  return out;
}

export function dedupeDirty(records) {
  const m = new Map();
  for (const r of records) m.set(r.path, r.op);
  return m;
}

export async function reconcileWithStat(deduped) {
  const out = new Map();
  for (const [absPath, op] of deduped) {
    let exists = false;
    try { await fs.stat(absPath); exists = true; }
    catch (e) { if (e.code !== 'ENOENT') throw e; }
    if (exists) out.set(absPath, 'upsert');
    else        out.set(absPath, 'delete');
    void op;
  }
  return out;
}

export async function truncateDirty(graphDir) {
  const dirtyPath = path.join(graphDir, 'dirty');
  try { await fs.truncate(dirtyPath, 0); }
  catch (e) { if (e.code !== 'ENOENT') throw e; }
}
```

- [ ] **Step 2.4: Run the test (must pass)**

```bash
node tests/graph/test-dirty.mjs
```
Expected: `test-dirty.mjs OK`.

- [ ] **Step 2.5: Syntax check**

```bash
node --check scripts/graph/dirty.mjs
```
Expected: no output, exit 0.

- [ ] **Step 2.6: Commit**

```bash
git add scripts/graph/dirty.mjs tests/graph/test-dirty.mjs
cat > /tmp/commit-msg-p2-2.txt <<'EOF'
feat(graph): JSONL dirty queue reader with last-wins + stat-reconcile

readDirty parses <graphDir>/dirty as strict JSONL (malformed line
throws with file:lineno). dedupeDirty collapses to one op per path
(last record wins). reconcileWithStat degrades op based on actual
disk state — delete+existing→upsert, upsert+missing→delete — closing
the editor-vs-pull race per spec §3.1 H2*.

Truncate helper is on the module so refresh can clear the queue
post-transaction under the same lock.
EOF
git commit -F /tmp/commit-msg-p2-2.txt
```

---
## Task 3: Reverse-import closure walker (`scripts/graph/closure.mjs`)

**Goal:** Given a seed `Map<absPath, "upsert"|"delete">` from `dirty.mjs`, walk the reverse-import graph (imports table) UNION reverse-edge graph (edges table) per spec §3.1 K1 fix, tag every newly discovered file with `op = "relink"`, and return the merged `Map<absPath, "upsert"|"delete"|"relink">`. Safety cap: if `working.size > 0.5 × |files|`, signal full-rebuild fall-through.

**Files:**
- Create: `scripts/graph/closure.mjs`
- Create: `tests/graph/test-closure.mjs`

- [ ] **Step 3.1: Write the failing test**

Save the following to `tests/graph/test-closure.mjs`:

```javascript
// tests/graph/test-closure.mjs
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { openDb, initSchema } from '../../scripts/graph/db.mjs';
import { reverseImportClosure } from '../../scripts/graph/closure.mjs';

const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'sspower-closure-'));
const graphDir = path.join(tmp, '.claude', 'graph');
await fs.mkdir(graphDir, { recursive: true });
const dbPath = path.join(graphDir, 'index.sqlite');
const db = openDb(dbPath);
initSchema(db);

const F = (rel) => path.join(tmp, rel);
const now = Math.floor(Date.now() / 1000);
const ins = db.prepare('INSERT INTO files VALUES (?, ?, ?, ?, ?)');
for (const p of ['a.ts','b.ts','c.ts','d.ts','e.ts','f.ts','g.ts','h.ts']) {
  ins.run(F(p), 'h00d', 'typescript', now, 0);
}
const insImp = db.prepare('INSERT INTO imports VALUES (?, ?)');
insImp.run(F('a.ts'), F('b.ts'));
insImp.run(F('b.ts'), F('c.ts'));
insImp.run(F('d.ts'), F('b.ts'));
insImp.run(F('e.ts'), F('e.ts'));

const insNode = db.prepare('INSERT INTO nodes VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)');
insNode.run('node-f', 'function', 'foo', 'foo', F('f.ts'), 'typescript', 1, 5, 'function foo()', 'aaaaaaaa', now);
insNode.run('node-g', 'function', 'goo', 'goo', F('g.ts'), 'typescript', 1, 5, 'function goo()', 'bbbbbbbb', now);
const insEdge = db.prepare('INSERT INTO edges VALUES (?, ?, ?, ?, ?)');
insEdge.run('node-f', 'node-g', 'calls', 3, 0);

// (1) Linear chain: delete c.ts -> b.ts (relink) and a.ts (relink).
{
  const seed = new Map([[F('c.ts'), 'delete']]);
  const closure = reverseImportClosure({ db, seed, fileCount: 8 });
  assert.equal(closure.size, 3);
  assert.equal(closure.get(F('c.ts')), 'delete');
  assert.equal(closure.get(F('b.ts')), 'relink');
  assert.equal(closure.get(F('a.ts')), 'relink');
}

// (2) Upsert c.ts -> same closure, seed stays upsert.
{
  const seed = new Map([[F('c.ts'), 'upsert']]);
  const closure = reverseImportClosure({ db, seed, fileCount: 8 });
  assert.equal(closure.get(F('c.ts')), 'upsert');
  assert.equal(closure.get(F('b.ts')), 'relink');
  assert.equal(closure.get(F('a.ts')), 'relink');
}

// (3) Fan-in.
{
  const seed = new Map([[F('b.ts'), 'delete']]);
  const closure = reverseImportClosure({ db, seed, fileCount: 8 });
  assert.equal(closure.size, 3);
  assert.equal(closure.get(F('b.ts')), 'delete');
  assert.equal(closure.get(F('a.ts')), 'relink');
  assert.equal(closure.get(F('d.ts')), 'relink');
}

// (4) Cycle.
{
  const seed = new Map([[F('e.ts'), 'upsert']]);
  const closure = reverseImportClosure({ db, seed, fileCount: 8 });
  assert.equal(closure.size, 1);
  assert.equal(closure.get(F('e.ts')), 'upsert');
}

// (5) Edge-only cascade (spec §3.1 K1 — edges union).
{
  const seed = new Map([[F('g.ts'), 'delete']]);
  const closure = reverseImportClosure({ db, seed, fileCount: 8 });
  assert.equal(closure.get(F('g.ts')), 'delete');
  assert.equal(closure.get(F('f.ts')), 'relink');
}

// (6) Safety cap.
{
  const seed = new Map([
    [F('a.ts'), 'upsert'], [F('b.ts'), 'upsert'], [F('c.ts'), 'upsert'],
    [F('d.ts'), 'upsert'], [F('e.ts'), 'upsert'],
  ]);
  const closure = reverseImportClosure({ db, seed, fileCount: 8 });
  assert.equal(closure.fullRebuild, true);
}

// (7) Seed op never overwritten by relink.
{
  const seed = new Map([
    [F('c.ts'), 'delete'],
    [F('b.ts'), 'upsert'],
  ]);
  const closure = reverseImportClosure({ db, seed, fileCount: 8 });
  assert.equal(closure.get(F('b.ts')), 'upsert');
  assert.equal(closure.get(F('c.ts')), 'delete');
  assert.equal(closure.get(F('a.ts')), 'relink');
}

db.close();
await fs.rm(tmp, { recursive: true, force: true });
console.log('test-closure.mjs OK');
```

- [ ] **Step 3.2: Run, confirm fail**

```bash
node tests/graph/test-closure.mjs
```
Expected: FAIL — module missing.

- [ ] **Step 3.3: Implement `scripts/graph/closure.mjs`**

```javascript
// scripts/graph/closure.mjs
// Fixed-point reverse-import + reverse-edge closure walker.
// Spec §3.1 — closure walks imports UNION edges (K1 fix). The imports
// table alone misses ambiguous-name, route, and implements edges that
// have no import provenance.
//
// Returns Map<absPath, op> where op ∈ {"upsert", "delete", "relink"}.
// Seed paths keep their explicit op. Newly discovered reverse importers
// get op="relink" — outbound edges rebuilt, nodes kept.
//
// Safety cap: |working| > 0.5 × |files| → returns {fullRebuild: true}.

export function reverseImportClosure({ db, seed, fileCount }) {
  const opFor = new Map();
  for (const [p, op] of seed) opFor.set(p, op);

  const working = new Set();
  const queue = [...seed.keys()];

  const stmtImports = db.prepare(
    'SELECT importer_path FROM imports WHERE imported_path = ?'
  );
  const stmtEdges = db.prepare(
    `SELECT DISTINCT src.file_path AS p
       FROM edges e
       JOIN nodes src ON e.source = src.id
       JOIN nodes tgt ON e.target = tgt.id
      WHERE tgt.file_path = ?`
  );

  while (queue.length) {
    const P = queue.shift();
    if (working.has(P)) continue;
    working.add(P);

    if (working.size > 0.5 * fileCount) {
      return { fullRebuild: true };
    }

    const reverseSet = new Set();
    for (const row of stmtImports.all(P)) reverseSet.add(row.importer_path);
    for (const row of stmtEdges.all(P))   reverseSet.add(row.p);

    for (const I of reverseSet) {
      if (working.has(I)) continue;
      if (!opFor.has(I)) opFor.set(I, 'relink');
      queue.push(I);
    }
  }

  opFor.fullRebuild = false;
  return opFor;
}
```

- [ ] **Step 3.4: Run, must pass**

```bash
node tests/graph/test-closure.mjs
```
Expected: `test-closure.mjs OK`.

- [ ] **Step 3.5: Commit**

```bash
git add scripts/graph/closure.mjs tests/graph/test-closure.mjs
cat > /tmp/commit-msg-p2-3.txt <<'EOF'
feat(graph): reverse-import + reverse-edge closure walker

reverseImportClosure walks the seed under spec §3.1 K1 — imports
UNION edges — so ambiguous-name and route edges with no import
provenance still trigger reverse cascade. Seed op is sticky; newly
discovered importers get "relink".

Safety cap fires when working set exceeds 50% of |files|: caller
falls through to full rebuild rather than scanning half the repo
as relink.

Test covers linear chain, fan-in, cycle, edge-only cascade,
safety cap, and seed-op-sticky regression.
EOF
git commit -F /tmp/commit-msg-p2-3.txt
```

---
## Task 4: Refresh orchestrator (`scripts/graph/refresh.mjs`)

**Goal:** Glue dirty queue → closure → transaction. Implements spec §3.1 two-phase transaction:
- **Phase 1a:** for `op=delete`: `DELETE FROM files WHERE path=P` (cascades nodes/edges/imports.importer) and `DELETE FROM imports WHERE imported_path=P`.
- **Phase 1b:** for `op=upsert`: `DELETE FROM nodes WHERE file_path=P` (cascades edges), `DELETE FROM imports WHERE importer_path=P`, `DELETE FROM files WHERE path=P`, then INSERT fresh.
- **Phase 1c:** for `op=relink`: `DELETE FROM edges WHERE source IN (SELECT id FROM nodes WHERE file_path=P)` — nodes/imports stay.
- **Phase 2:** re-resolve edges for `upsert ∪ relink` via `resolveEdges` using fresh `importedNamesByFile` and the latest cross-graph node snapshot.

Thrash guard: `raw.length > 500` → `{fullRebuild:true, reason:'thrash'}`. Closure cap → `{fullRebuild:true, reason:'closure-cap'}`. Extraction failure > 25% on upsert+relink set → throw (preserve index).

**Files:**
- Create: `scripts/graph/refresh.mjs`
- Create: `scripts/graph/extract.mjs` (lang dispatcher)
- Create: `tests/graph/test-refresh.mjs`

- [ ] **Step 4.1: Write the equivalence test**

Build a 3-file fixture (a.ts imports b.ts, c.ts unrelated). `build()` full. Mutate b.ts; append upsert; `refresh()`; snapshot `(nodes, edges, imports, files)` ordered by primary keys. Then clear dirty, `build()` again on the same tree, snapshot. Assert `deepEqual` across all four tables. Then `unlink(c)`, append delete, refresh, assert c removed and a/b retained. Then 501 records → fullRebuild=true. Then empty dirty → fileCount=0.

Test source body:

```javascript
// tests/graph/test-refresh.mjs
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { build } from '../../scripts/graph/build.mjs';
import { refresh } from '../../scripts/graph/refresh.mjs';
import { openDb, initSchema } from '../../scripts/graph/db.mjs';

async function snapshot(gd) {
  const db = openDb(path.join(gd, 'index.sqlite'));
  initSchema(db);
  const q = (s) => db.prepare(s).all();
  const out = {
    nodes:   q('SELECT id, kind, name, qualified_name, file_path, start_line, end_line FROM nodes ORDER BY id'),
    edges:   q('SELECT source, target, kind, line, confidence FROM edges ORDER BY source, target, kind, line'),
    imports: q('SELECT importer_path, imported_path FROM imports ORDER BY importer_path, imported_path'),
    files:   q('SELECT path, language FROM files ORDER BY path'),
  };
  db.close();
  return out;
}

async function append(gd, op, p) {
  await fs.appendFile(path.join(gd, 'dirty'), JSON.stringify({ op, path: p }) + '\n');
}

const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'sspower-refresh-'));
const gd  = path.join(tmp, '.claude', 'graph');
await fs.mkdir(gd, { recursive: true });
const a = path.join(tmp, 'a.ts');
const b = path.join(tmp, 'b.ts');
const c = path.join(tmp, 'c.ts');
await fs.writeFile(b, `export function helper() { return 42; }\n`);
await fs.writeFile(a, `import { helper } from './b';\nexport function caller() { return helper(); }\n`);
await fs.writeFile(c, `export const unrelated = 1;\n`);

await build({ rootDir: tmp, graphDir: gd, log: () => {} });
await fs.writeFile(b, `export function helper2() { return 42; }\n`);
await append(gd, 'upsert', b);
const r1 = await refresh({ rootDir: tmp, graphDir: gd, log: () => {} });
assert.equal(r1.fullRebuild, false);
const after = await snapshot(gd);
await fs.writeFile(path.join(gd, 'dirty'), '');
await build({ rootDir: tmp, graphDir: gd, log: () => {} });
const full = await snapshot(gd);
assert.deepEqual(after.nodes,   full.nodes);
assert.deepEqual(after.edges,   full.edges);
assert.deepEqual(after.imports, full.imports);
assert.deepEqual(after.files,   full.files);

await fs.unlink(c);
await append(gd, 'delete', c);
const r2 = await refresh({ rootDir: tmp, graphDir: gd, log: () => {} });
assert.equal(r2.fullRebuild, false);
const files2 = (await snapshot(gd)).files.map(f => f.path);
assert.ok(!files2.includes(c));

const thrash = [];
for (let i = 0; i < 501; i++) thrash.push(JSON.stringify({ op: 'upsert', path: a }) + '\n');
await fs.writeFile(path.join(gd, 'dirty'), thrash.join(''));
const r3 = await refresh({ rootDir: tmp, graphDir: gd, log: () => {} });
assert.equal(r3.fullRebuild, true);

await fs.writeFile(path.join(gd, 'dirty'), '');
const r4 = await refresh({ rootDir: tmp, graphDir: gd, log: () => {} });
assert.equal(r4.fullRebuild, false);
assert.equal(r4.fileCount, 0);

await fs.rm(tmp, { recursive: true, force: true });
console.log('test-refresh.mjs OK');
```

- [ ] **Step 4.2: Run test, confirm fail**

```bash
node tests/graph/test-refresh.mjs
```
Expected: FAIL — `Cannot find module 'refresh.mjs'`.

- [ ] **Step 4.3: Create `scripts/graph/extract.mjs` (language dispatcher)**

```javascript
// scripts/graph/extract.mjs
import * as ts from './extract-ts.mjs';

export async function extractorFor(language) {
  switch (language) {
    case 'typescript':
    case 'javascript':
      return { extractFile: ts.extractFile };
    case 'python': {
      const py = await import('./extract-py.mjs');
      return { extractFile: py.extractFile };
    }
    case 'go': {
      const go = await import('./extract-go.mjs');
      return { extractFile: go.extractFile };
    }
    case 'rust': {
      const rs = await import('./extract-rs.mjs');
      return { extractFile: rs.extractFile };
    }
    default:
      throw new Error(`no extractor for language: ${language}`);
  }
}
```

Python/Go/Rust modules land in Tasks 9/10/11. Until then only the TS branch is reachable from Task 4 tests.

- [ ] **Step 4.4: Implement `scripts/graph/refresh.mjs`**

Module structure (~150 LOC; lift statement prep + insert shape directly from `build.mjs` to keep parity):

1. `openDb` + `initSchema` against `<graphDir>/index.sqlite`.
2. `readDirty(graphDir)`. If `raw.length > 500` → close DB, return `{fullRebuild:true, reason:'thrash', dirtyCount: raw.length}`.
3. `dedupeDirty(raw)` then `reconcileWithStat(deduped)`. If empty → close DB, return `{fullRebuild:false, fileCount:0, nodeCount:0, edgeCount:0}`.
4. `fileCount = SELECT COUNT(*) FROM files`. `closure = reverseImportClosure({db, seed:reconciled, fileCount})`. If `closure.fullRebuild` → close DB, return `{fullRebuild:true, reason:'closure-cap', dirtyCount:raw.length}`.
5. For each `[absPath, op]` in closure where `op !== 'delete'`: `languageFor(absPath)`; read source via `fs.readFile`; `extractorFor(lang)` then `extractFile(...)`; build idedNodes via `nodeId(filePath, qualifiedName, spanSha8)`; track `extractFailures`. Push `{filePath, language, content, extracted, idedNodes, contentHash, op}` into `perFile`. After the loop, count `targetCount = filter(op !== 'delete').length`. If `extractFailures / targetCount > 0.25`: close DB and throw.
6. Build `importedNamesByFile = new Map()` exactly like `build.mjs` Phase 2 (per-file map of `{ local → { path, imported } }` via `resolveModule(f.filePath, imp.moduleSpec, f.language)`).
7. Prepare reusable statements: `insFile`, `insNode`, `insImport`, `insEdge`, `delFile`, `delImportsByT`, `delNodesByFile`, `delImportsByI`, `delFilesByPath`, `delEdgesBySrcFile` (where the last uses `DELETE FROM edges WHERE source IN (SELECT id FROM nodes WHERE file_path = ?)`).
8. Run `BEGIN IMMEDIATE` via the DB driver's exec method, then in a try/catch:
   - Phase 1a (deletes): iterate closure where `op==='delete'` → run `delFile.run(P)` + `delImportsByT.run(P)`.
   - Phase 1b (upserts): iterate perFile where `f.op==='upsert'` → `delNodesByFile`, `delImportsByI`, `delFilesByPath`, then `insFile.run(...)`, loop nodes/imports inserts.
   - Phase 1c (relink): iterate closure where `op==='relink'` → `delEdgesBySrcFile.run(P)`.
   - Phase 2: `allNodes = SELECT id, name, qualified_name AS qualifiedName, file_path AS filePath FROM nodes`. Build `enrichedCallSites` from perFile (`callerFile = f.filePath`, `importedNames = importedNamesByFile.get(f.filePath) ?? {}`). `edges = resolveEdges({nodes: allNodes, callSites: enrichedCallSites})`. Loop `insEdge.run(...)`.
   - COMMIT, or ROLLBACK + throw in the catch.
9. After commit: `truncateDirty(graphDir)` (caller — `graph-with-lock.py` — holds the lock spanning this whole call).
10. `nodeCount = SELECT COUNT(*) FROM nodes`; `edgeCount = SELECT COUNT(*) FROM edges`; log totals; write `<graphDir>/version` with `schema=1`, `ast_grep=$AST_GREP_VERSION`, `built_at=$now`, `last_refresh=$now`. Close DB.
11. Return `{fullRebuild: false, fileCount: closure.size, nodeCount, edgeCount, extractFailures}`.

Reference: `scripts/graph/build.mjs` lines 120-158 already implements the equivalent insert shape; replicate the prepared-statement names verbatim so reviewers can diff side-by-side.

- [ ] **Step 4.5: Run the refresh test (must pass)**

```bash
node tests/graph/test-refresh.mjs
```
Expected: `test-refresh.mjs OK`.

- [ ] **Step 4.6: Run P1 regressions**

```bash
bash tests/hooks/test-intent-architecture.sh
CLAUDE_PLUGIN_ROOT=$(pwd) python3 tests/graph/test-lock-helpers.py
CLAUDE_PLUGIN_ROOT=$(pwd) node tests/graph/test-mcp-stub.mjs
node tests/graph/test-db-schema.mjs
node tests/graph/test-astgrep.mjs
node tests/graph/test-walk.mjs
node tests/graph/test-extract-ts.mjs
node tests/graph/test-resolve.mjs
node tests/graph/test-build-query.mjs
```
Expected: every test prints OK / PASS. Any regression → STOP and bisect.

- [ ] **Step 4.7: Commit**

```bash
git add scripts/graph/refresh.mjs scripts/graph/extract.mjs tests/graph/test-refresh.mjs
```

Then write the commit message via the Write tool to `/tmp/commit-msg-p2-4.txt`:

```
feat(graph): two-phase refresh transaction per spec §3.1

refresh() consumes the dirty queue and applies surgical updates in a
single BEGIN IMMEDIATE block: phase 1a deletes, 1b upserts (drop
nodes+imports for P, re-insert from fresh extraction), 1c relink
(drop outbound edges only — nodes stay), phase 2 re-resolves edges
for upsert ∪ relink using the freshly rebuilt imports table.

Thrash guard >500 dirty records → fullRebuild. Closure safety cap
> 50% of files → fullRebuild. Extraction failure >25% on upsert+relink
set → abort; preserve existing index.

Equivalence test: refresh-applied state must be byte-for-byte equal
to a full rebuild on the post-mutation tree (modulo timestamps).

extract.mjs is a minimal dispatcher — TS path is wired now,
Python/Go/Rust slots filled in Tasks 9/10/11.
```

Then `git commit -F /tmp/commit-msg-p2-4.txt` as a standalone Bash invocation.

---
## Task 5: CLI verbs `refresh` and `refresh-unlocked`

**Goal:** Wire `sspower-graph refresh` to re-exec through `scripts/graph-with-lock.py` exactly like `build`. The inner Node child runs `refresh-unlocked` and invokes `scripts/graph/refresh.mjs`. If refresh returns `{fullRebuild:true}`, the inner child exits with sentinel 42; the outer wrapper re-acquires the lock and dispatches into `build-unlocked`.

**Files:**
- Modify: `bin/sspower-graph.mjs`
- Create: `tests/graph/test-refresh-cli.sh`

- [ ] **Step 5.1: Extend `usage()` in `bin/sspower-graph.mjs`**

Replace the existing usage string (lines 35-46) with the expanded verb list:

```
sspower-graph build [--cwd <dir>]
sspower-graph refresh [--cwd <dir>]
sspower-graph session-refresh [--max-time <sec>] [--cwd <dir>]
sspower-graph callers <name> [--limit N] [--disambiguate] [--json] [--cwd <dir>]
sspower-graph callees <name> [--limit N] [--json] [--cwd <dir>]
sspower-graph trace <from> <to> [--max-hops N] [--json] [--cwd <dir>]
sspower-graph impact <file> [--json] [--cwd <dir>]
sspower-graph context <task> [--json] [--cwd <dir>]
sspower-graph node <name> [--json] [--cwd <dir>]
sspower-graph status [--json] [--cwd <dir>]
sspower-graph serve --mcp
```

- [ ] **Step 5.2: Add `--max-time` and `--max-hops` to `parseOpts`**

In the loop, after the existing `--json` branch:

```javascript
else if (a === '--max-time') opts.maxTime = parseInt(rest[++i], 10);
else if (a === '--max-hops') opts.maxHops = parseInt(rest[++i], 10);
```

And the default object:

```javascript
const opts = { cwd: process.cwd(), limit: 50, disambiguate: false, json: false, maxTime: 5, maxHops: 6, positional: [] };
```

- [ ] **Step 5.3: Add `runRefreshLocked` and `runRefreshUnlocked`**

Insert after the existing `runBuildUnlocked` function (around line 113):

```javascript
async function runRefreshLocked(opts) {
  const lockWrapper = path.join(PLUGIN_ROOT, 'scripts/graph-with-lock.py');
  const graphDir = graphDirFor(opts.cwd);
  fs.mkdirSync(graphDir, { recursive: true, mode: 0o700 });
  const child = spawnSync('python3', [
    lockWrapper,
    '--graph-dir', graphDir,
    '--',
    process.execPath, url.fileURLToPath(import.meta.url),
    'refresh-unlocked', '--cwd', opts.cwd,
  ], {
    env: { ...process.env, CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT },
    stdio: 'inherit',
  });
  if (child.status === 42) {
    process.stderr.write(`[refresh] fall through to full rebuild\n`);
    const child2 = spawnSync('python3', [
      lockWrapper,
      '--graph-dir', graphDir,
      '--',
      process.execPath, url.fileURLToPath(import.meta.url),
      'build-unlocked', '--cwd', opts.cwd,
    ], { env: { ...process.env, CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT }, stdio: 'inherit' });
    process.exit(child2.status ?? 1);
  }
  process.exit(child.status ?? 1);
}

async function runRefreshUnlocked(opts) {
  const { refresh } = await import(path.join(PLUGIN_ROOT, 'scripts/graph/refresh.mjs'));
  const graphDir = graphDirFor(opts.cwd);
  fs.mkdirSync(graphDir, { recursive: true, mode: 0o700 });
  const t0 = Date.now();
  const res = await refresh({
    rootDir: opts.cwd, graphDir,
    log: msg => process.stderr.write(`[refresh] ${msg}\n`),
  });
  process.stderr.write(`[refresh] complete in ${Date.now() - t0}ms\n`);
  if (res.fullRebuild) {
    emit(opts, res, r => `refresh fullRebuild: reason=${r.reason}`);
    process.exit(42);
  }
  emit(opts, res, r => `${r.fileCount} files touched, ${r.nodeCount} nodes, ${r.edgeCount} edges`);
}
```

- [ ] **Step 5.4: Wire dispatch cases**

In the switch statement at the bottom of `bin/sspower-graph.mjs`, add immediately after `build-unlocked`:

```javascript
case 'refresh':          await runRefreshLocked(opts); break;
case 'refresh-unlocked': await runRefreshUnlocked(opts); break;
case 'session-refresh':  await runSessionRefresh(opts); break;
case 'trace':            if (opts.positional.length < 2) { usage(); process.exit(2); }
                         await runTrace(opts, opts.positional[0], opts.positional[1]); break;
case 'impact':           if (!opts.positional[0]) { usage(); process.exit(2); }
                         await runImpact(opts, opts.positional[0]); break;
case 'context':          if (!opts.positional[0]) { usage(); process.exit(2); }
                         await runContext(opts, opts.positional[0]); break;
```

Stub `runSessionRefresh`, `runTrace`, `runImpact`, `runContext` with:

```javascript
async function runSessionRefresh(opts) { throw new Error('not yet implemented — see Task 7'); }
async function runTrace(opts, from, to) { throw new Error('not yet implemented — see Task 13'); }
async function runImpact(opts, file)    { throw new Error('not yet implemented — see Task 13'); }
async function runContext(opts, task)   { throw new Error('not yet implemented — see Task 13'); }
```

These stubs are replaced wholesale by the real functions in Tasks 7 and 13.

- [ ] **Step 5.5: Write CLI smoke test**

`tests/graph/test-refresh-cli.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
git init -q .
cat > a.ts <<'TS'
export function helper() { return 1; }
TS
cat > b.ts <<'TS'
import { helper } from './a';
export function caller() { return helper(); }
TS
git add . && git -c user.email=test@x -c user.name=test commit -q -m init

node "$HERE/bin/sspower-graph.mjs" build --cwd "$TMP" >/dev/null

echo "export function helper2() { return 2; }" > a.ts
CLAUDE_PLUGIN_ROOT="$HERE" python3 "$HERE/scripts/graph-append-dirty.py" \
  --graph-dir "$TMP/.claude/graph" --op upsert --path "$TMP/a.ts"

OUT="$(node "$HERE/bin/sspower-graph.mjs" refresh --cwd "$TMP" 2>&1)"
echo "$OUT" | grep -q "files touched" || { echo "FAIL: refresh did not run"; exit 1; }

DIRTY_LINES="$(wc -l < "$TMP/.claude/graph/dirty" 2>/dev/null || echo 0)"
[[ "$DIRTY_LINES" -eq 0 ]] || { echo "FAIL: dirty not truncated ($DIRTY_LINES lines remain)"; exit 1; }

node "$HERE/bin/sspower-graph.mjs" status --cwd "$TMP" | grep -q "files="

echo "test-refresh-cli.sh OK"
```

Chmod +x and run:

```bash
chmod +x tests/graph/test-refresh-cli.sh
bash tests/graph/test-refresh-cli.sh
```
Expected: `test-refresh-cli.sh OK`.

- [ ] **Step 5.6: Commit**

Stage `bin/sspower-graph.mjs` + `tests/graph/test-refresh-cli.sh`, write the commit message to `/tmp/commit-msg-p2-5.txt` via Write tool:

```
feat(graph): refresh CLI verb with full-rebuild fall-through

`sspower-graph refresh` re-execs through graph-with-lock.py exactly
like build — single-lock contract (D34/D38) preserved. The inner
refresh-unlocked exits with sentinel 42 when the refresh orchestrator
signals fullRebuild (thrash >500 or closure cap >50%); the outer
wrapper re-acquires the lock and dispatches into build-unlocked.

Stubs added for session-refresh / trace / impact / context so the
dispatcher compiles; those land in Tasks 7 and 13.

CLI smoke verifies build → mutate → mark-dirty → refresh → truncated
dirty → status round-trip.
```

Then `git commit -F /tmp/commit-msg-p2-5.txt` standalone.

---
## Task 6: PostToolUse hook `hooks/graph-mark-dirty.sh`

**Goal:** Wire Write/Edit/MultiEdit tool events to the JSONL dirty queue. The hook reads the `tool_input` JSON payload from stdin, extracts paths (Write/Edit `file_path` OR MultiEdit `edits[].file_path`), normalizes each to an absolute path, gates on `<cwd>` containment + known source extension, and invokes `scripts/graph-append-dirty.py` once per file. Skip silently if `<cwd>/.claude/graph/index.sqlite` is absent (no first build yet).

**Files:**
- Create: `hooks/graph-mark-dirty.sh`
- Create: `tests/hooks/test-graph-mark-dirty.sh`
- Modify: `hooks/hooks.json`

- [ ] **Step 6.1: Write the failing test**

`tests/hooks/test-graph-mark-dirty.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_PLUGIN_ROOT="$HERE"

mkdir -p "$TMP/.claude/graph"
touch "$TMP/.claude/graph/index.sqlite"
echo "test" > "$TMP/foo.ts"
cd "$TMP"
HOOK="$HERE/hooks/graph-mark-dirty.sh"

# (1) Write
P1=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s/foo.ts","content":"test"}}' "$TMP")
echo "$P1" | "$HOOK"
LC="$(wc -l < "$TMP/.claude/graph/dirty")"
[[ "$LC" -eq 1 ]] || { echo "FAIL: Write should append 1 line, got $LC"; exit 1; }
grep -q '"op":"upsert"' "$TMP/.claude/graph/dirty"

# (2) Edit
echo "$P1" | sed 's/Write/Edit/' | "$HOOK"
LC="$(wc -l < "$TMP/.claude/graph/dirty")"
[[ "$LC" -eq 2 ]] || { echo "FAIL: Edit got $LC"; exit 1; }

# (3) MultiEdit (two files)
echo "second" > "$TMP/bar.ts"
P3=$(printf '{"tool_name":"MultiEdit","tool_input":{"edits":[{"file_path":"%s/foo.ts","old_string":"a","new_string":"b"},{"file_path":"%s/bar.ts","old_string":"c","new_string":"d"}]}}' "$TMP" "$TMP")
echo "$P3" | "$HOOK"
LC="$(wc -l < "$TMP/.claude/graph/dirty")"
[[ "$LC" -eq 4 ]] || { echo "FAIL: MultiEdit total $LC"; exit 1; }

# (4) Outside-cwd skipped
echo '{"tool_name":"Write","tool_input":{"file_path":"/etc/passwd","content":"x"}}' | "$HOOK"
LC="$(wc -l < "$TMP/.claude/graph/dirty")"
[[ "$LC" -eq 4 ]] || { echo "FAIL: outside-cwd not skipped ($LC)"; exit 1; }

# (5) Non-source extension skipped
P5=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s/README.md","content":"x"}}' "$TMP")
echo "$P5" | "$HOOK"
LC="$(wc -l < "$TMP/.claude/graph/dirty")"
[[ "$LC" -eq 4 ]] || { echo "FAIL: non-source not skipped"; exit 1; }

# (6) Deleted file -> op:delete
rm "$TMP/foo.ts"
P6=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s/foo.ts"}}' "$TMP")
echo "$P6" | "$HOOK"
tail -1 "$TMP/.claude/graph/dirty" | grep -q '"op":"delete"'

# (7) No index -> noop
TMP2="$(mktemp -d)"
echo "test" > "$TMP2/x.ts"
cd "$TMP2"
P7=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s/x.ts","content":"t"}}' "$TMP2")
echo "$P7" | "$HOOK"
[[ ! -e "$TMP2/.claude/graph/dirty" ]] || { echo "FAIL: hook ran without index"; exit 1; }
rm -rf "$TMP2"

# (8) Malformed JSON -> fail open
cd "$TMP"
LB="$(wc -l < "$TMP/.claude/graph/dirty")"
echo "not json" | "$HOOK"
LA="$(wc -l < "$TMP/.claude/graph/dirty")"
[[ "$LB" -eq "$LA" ]] || { echo "FAIL: malformed payload appended"; exit 1; }

echo "test-graph-mark-dirty.sh OK"
```

- [ ] **Step 6.2: Run, confirm fail**

```bash
chmod +x tests/hooks/test-graph-mark-dirty.sh
bash tests/hooks/test-graph-mark-dirty.sh
```
Expected: FAIL — hook missing.

- [ ] **Step 6.3: Implement `hooks/graph-mark-dirty.sh`**

```bash
#!/usr/bin/env bash
# PostToolUse:Write|Edit|MultiEdit — append JSONL dirty records.
# Gates: file under $PWD, known source extension, index exists.
# Fail-OPEN: any error -> exit 0.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_log.sh" 2>/dev/null || true
trap '_sspower_exit_guard $? "0" hook.graph-mark-dirty' EXIT

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
GRAPH_DIR="$PWD/.claude/graph"

[[ -e "$GRAPH_DIR/index.sqlite" ]] || exit 0
command -v jq      >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

INPUT="$(cat)"
[[ -n "$INPUT" ]] || exit 0

PATHS="$(echo "$INPUT" | jq -r '
  (.tool_input.file_path // empty),
  (.tool_input.edits[]?.file_path // empty)
' 2>/dev/null)" || exit 0
[[ -n "$PATHS" ]] || exit 0

SOURCE_EXT_RE='\.(ts|tsx|mts|cts|js|jsx|mjs|cjs|py|go|rs)$'
ABS_CWD="$(cd "$PWD" && pwd)"

while IFS= read -r raw_path; do
  [[ -z "$raw_path" ]] && continue
  if [[ "$raw_path" = /* ]]; then
    abs="$raw_path"
  else
    abs="$ABS_CWD/$raw_path"
  fi
  abs="$(python3 -c 'import os, sys; print(os.path.normpath(sys.argv[1]))' "$abs" 2>/dev/null)" || continue
  case "$abs" in
    "$ABS_CWD"/*) ;;
    *) continue ;;
  esac
  [[ "$abs" =~ $SOURCE_EXT_RE ]] || continue
  if [[ -e "$abs" ]]; then op="upsert"; else op="delete"; fi
  CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" python3 \
    "$PLUGIN_ROOT/scripts/graph-append-dirty.py" \
    --graph-dir "$GRAPH_DIR" --op "$op" --path "$abs" \
    >/dev/null 2>&1 || true
done <<< "$PATHS"

exit 0
```

`chmod +x hooks/graph-mark-dirty.sh`.

- [ ] **Step 6.4: Run test (must pass)**

```bash
bash tests/hooks/test-graph-mark-dirty.sh
```
Expected: `test-graph-mark-dirty.sh OK`.

- [ ] **Step 6.5: Wire into `hooks/hooks.json`**

Add the new hook as a SIBLING of `codex-lsp-posttool.sh` under the existing PostToolUse:Write|Edit|MultiEdit matcher. Read `hooks/hooks.json` first; locate the `hooks` array under that matcher and append:

```json
{
  "type": "command",
  "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/graph-mark-dirty.sh\"",
  "timeout": 3,
  "async": false
}
```

Validate the JSON:

```bash
python3 -c 'import json; json.load(open("hooks/hooks.json"))'
```
Expected: no output.

- [ ] **Step 6.6: Re-run the hook test**

```bash
bash tests/hooks/test-graph-mark-dirty.sh
```
Expected: still `OK`.

- [ ] **Step 6.7: Commit**

Stage `hooks/graph-mark-dirty.sh`, `hooks/hooks.json`, `tests/hooks/test-graph-mark-dirty.sh`. Commit message to `/tmp/commit-msg-p2-6.txt`:

```
feat(graph): PostToolUse:Write|Edit|MultiEdit dirty-queue hook

graph-mark-dirty.sh reads tool_input JSON via jq, normalizes each
file_path (single Write/Edit OR MultiEdit .edits[]) to absolute,
gates on $PWD containment + known source extension + presence of
<cwd>/.claude/graph/index.sqlite, then delegates to the P0
graph-append-dirty.py helper. op=upsert if file exists, delete if
missing. Fail-OPEN — any error exits 0 silent so we never break
the user's edit.

Wired into hooks.json as a sibling of codex-lsp-posttool.sh under
the existing Write|Edit|MultiEdit matcher.
```

`git commit -F /tmp/commit-msg-p2-6.txt` standalone.

---
## Task 7: SessionStart sweep (`scripts/graph/session-refresh.mjs`)

**Goal:** On every session start, fire a single detached worker that (Step 0) detects new files via `git ls-files` SHA8, (Step 1) does a rowid-stride sample of the existing index against disk content hashes with sparse-rowid retry, and (Step 2) dispatches to `refresh` or full `build`. Time-budgeted at 5s default. Per spec §3.5.

**Files:**
- Create: `scripts/graph/session-refresh.mjs`
- Create: `tests/graph/test-session-refresh.mjs`
- Modify: `bin/sspower-graph.mjs` (replace `runSessionRefresh` stub)
- Modify: `hooks/session-start`

- [ ] **Step 7.1: Write the test**

`tests/graph/test-session-refresh.mjs`:

```javascript
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { sessionRefresh, gitFilesetHash } from '../../scripts/graph/session-refresh.mjs';
import { build } from '../../scripts/graph/build.mjs';

const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'sspower-sr-'));
const graphDir = path.join(tmp, '.claude', 'graph');
await fs.mkdir(graphDir, { recursive: true });

execFileSync('git', ['-C', tmp, 'init', '-q']);
execFileSync('git', ['-C', tmp, 'config', 'user.email', 'x@x']);
execFileSync('git', ['-C', tmp, 'config', 'user.name', 'x']);
await fs.writeFile(path.join(tmp, 'a.ts'), `export function foo() { return 1; }\n`);
await fs.writeFile(path.join(tmp, 'b.ts'), `export function bar() { return 2; }\n`);
execFileSync('git', ['-C', tmp, 'add', '-A']);
execFileSync('git', ['-C', tmp, 'commit', '-q', '-m', 'init']);

await build({ rootDir: tmp, graphDir, log: () => {} });
const h0 = await gitFilesetHash(tmp);
await fs.writeFile(path.join(graphDir, 'version'),
  `schema=1\nbuilt_at=${Math.floor(Date.now()/1000)}\ngit_filesethash=${h0}\n`);

// (1) Idle.
const r1 = await sessionRefresh({ rootDir: tmp, graphDir, maxTime: 5000, log: () => {} });
assert.equal(r1.action, 'noop');

// (2) New file -> filesethash change -> build.
await fs.writeFile(path.join(tmp, 'c.ts'), `export function baz() {}\n`);
execFileSync('git', ['-C', tmp, 'add', '-A']);
const r2 = await sessionRefresh({ rootDir: tmp, graphDir, maxTime: 5000, log: () => {} });
assert.equal(r2.action, 'build');

// (3) External edit -> sampling triggers refresh.
await fs.writeFile(path.join(tmp, 'a.ts'), `export function fooRenamed() {}\n`);
const r3 = await sessionRefresh({ rootDir: tmp, graphDir, maxTime: 5000, log: () => {} });
assert.ok(['refresh', 'build'].includes(r3.action));
assert.ok(r3.dirtyEmitted >= 1);

// (4) Idle after rebuild.
await build({ rootDir: tmp, graphDir, log: () => {} });
const h1 = await gitFilesetHash(tmp);
await fs.writeFile(path.join(graphDir, 'version'),
  `schema=1\nbuilt_at=${Math.floor(Date.now()/1000)}\ngit_filesethash=${h1}\n`);
const r4 = await sessionRefresh({ rootDir: tmp, graphDir, maxTime: 5000, log: () => {} });
assert.equal(r4.action, 'noop');

// (5) Deadline honoring.
await fs.writeFile(path.join(tmp, 'a.ts'), `export function r2() {}\n`);
const r5 = await sessionRefresh({ rootDir: tmp, graphDir, maxTime: 1, log: () => {} });
assert.ok(['timeout', 'refresh', 'build', 'noop'].includes(r5.action));

await fs.rm(tmp, { recursive: true, force: true });
console.log('test-session-refresh.mjs OK');
```

- [ ] **Step 7.2: Run, confirm fail**

```bash
node tests/graph/test-session-refresh.mjs
```
Expected: FAIL — `Cannot find module 'session-refresh.mjs'`.

- [ ] **Step 7.3: Implement `scripts/graph/session-refresh.mjs`**

Module exports `gitFilesetHash(rootDir)` and `sessionRefresh({ rootDir, graphDir, maxTime, log })`. Implementation skeleton (verified against spec §3.5):

```javascript
// scripts/graph/session-refresh.mjs
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { openDb, initSchema } from './db.mjs';

const pExec = promisify(execFile);
const SAMPLE_TARGET = 200;
const DIVERGENCE_THRESHOLD = 0.05;
const MIN_SAMPLE_FOR_REBUILD = 50;

export async function gitFilesetHash(rootDir) {
  try {
    const tracked = (await pExec('git', ['-C', rootDir, 'ls-files', '-z'],
      { encoding: 'buffer', maxBuffer: 100 * 1024 * 1024 })).stdout;
    const others = (await pExec('git', ['-C', rootDir, 'ls-files', '--others', '--exclude-standard', '-z'],
      { encoding: 'buffer', maxBuffer: 100 * 1024 * 1024 })).stdout;
    const buf = Buffer.concat([tracked, others]);
    return crypto.createHash('sha256').update(buf).digest('hex').slice(0, 8);
  } catch { return null; }
}

async function readVersionField(graphDir, field) {
  try {
    const raw = await fs.readFile(path.join(graphDir, 'version'), 'utf8');
    for (const line of raw.split('\n')) {
      const [k, ...rest] = line.split('=');
      if (k === field) return rest.join('=').trim();
    }
  } catch (e) { if (e.code !== 'ENOENT') throw e; }
  return null;
}

async function writeVersionField(graphDir, field, value) {
  const p = path.join(graphDir, 'version');
  let raw = '';
  try { raw = await fs.readFile(p, 'utf8'); } catch (e) { if (e.code !== 'ENOENT') throw e; }
  const lines = raw.split('\n').filter(l => l && !l.startsWith(`${field}=`));
  lines.push(`${field}=${value}`);
  await fs.writeFile(p, lines.join('\n') + '\n');
}

async function appendDirty(graphDir, op, absPath) {
  await fs.appendFile(path.join(graphDir, 'dirty'),
    JSON.stringify({ op, path: absPath }) + '\n');
}

async function contentHash(filePath) {
  try {
    const buf = await fs.readFile(filePath);
    return crypto.createHash('sha256').update(buf).digest('hex').slice(0, 8);
  } catch (e) {
    if (e.code === 'ENOENT') return null;
    throw e;
  }
}

export async function sessionRefresh({ rootDir, graphDir, maxTime = 5000, log = () => {} }) {
  const t0 = Date.now();
  const deadline = t0 + maxTime;
  const dbPath = path.join(graphDir, 'index.sqlite');
  try { await fs.stat(dbPath); } catch { return { action: 'noop', reason: 'no-index' }; }

  // Step 0
  const cur = await gitFilesetHash(rootDir);
  if (cur !== null) {
    const stored = await readVersionField(graphDir, 'git_filesethash');
    if (stored !== cur) {
      await writeVersionField(graphDir, 'git_filesethash', cur);
      log(`filesethash changed (${stored ?? 'unset'} -> ${cur}); build`);
      return { action: 'build', reason: 'filesethash-changed', dirtyEmitted: 0 };
    }
  }

  // Step 1
  const db = openDb(dbPath);
  initSchema(db);
  let rows;
  try {
    const total = db.prepare('SELECT COUNT(*) AS c FROM files').get().c;
    if (total === 0) { db.close(); return { action: 'noop', reason: 'fresh-index', dirtyEmitted: 0 }; }
    const sampleSize = Math.min(SAMPLE_TARGET, total);
    if (total <= sampleSize) {
      rows = db.prepare('SELECT path, content_hash FROM files ORDER BY rowid').all();
    } else {
      const stride = Math.max(1, Math.ceil(total / sampleSize));
      let off = Math.floor(Math.random() * stride);
      const stmt = db.prepare('SELECT path, content_hash FROM files WHERE rowid % ? = ? ORDER BY rowid LIMIT ?');
      rows = stmt.all(stride, off, sampleSize);
      if (rows.length === 0) {
        for (let i = 0; i < 3; i++) {
          off = Math.floor(Math.random() * stride);
          rows = stmt.all(stride, off, sampleSize);
          if (rows.length) break;
        }
        if (rows.length === 0) {
          rows = db.prepare('SELECT path, content_hash FROM files ORDER BY rowid LIMIT ?').all(sampleSize);
        }
      }
    }
  } finally { db.close(); }

  let changed = 0;
  let dirtyEmitted = 0;
  for (const r of rows) {
    if (Date.now() > deadline) {
      return { action: 'timeout', reason: 'deadline', dirtyEmitted, sampleSize: rows.length };
    }
    const disk = await contentHash(r.path);
    if (disk === null) { await appendDirty(graphDir, 'delete', r.path); dirtyEmitted++; changed++; }
    else if (disk !== r.content_hash) { await appendDirty(graphDir, 'upsert', r.path); dirtyEmitted++; changed++; }
  }

  if (rows.length === 0) return { action: 'noop', reason: 'empty-sample', dirtyEmitted, sampleSize: 0 };
  const rate = changed / rows.length;
  if (rate > DIVERGENCE_THRESHOLD && rows.length >= MIN_SAMPLE_FOR_REBUILD) {
    return { action: 'build', reason: 'high-divergence', dirtyEmitted, sampleSize: rows.length, divergenceRate: rate };
  }
  if (dirtyEmitted > 0) {
    return { action: 'refresh', reason: 'low-divergence', dirtyEmitted, sampleSize: rows.length, divergenceRate: rate };
  }
  return { action: 'noop', reason: 'no-divergence', dirtyEmitted, sampleSize: rows.length, divergenceRate: rate };
}
```

- [ ] **Step 7.4: Replace the stub in `bin/sspower-graph.mjs`**

Replace `async function runSessionRefresh(...)` stub with:

```javascript
async function runSessionRefresh(opts) {
  const { sessionRefresh } = await import(path.join(PLUGIN_ROOT, 'scripts/graph/session-refresh.mjs'));
  const graphDir = graphDirFor(opts.cwd);
  if (!fs.existsSync(path.join(graphDir, 'index.sqlite'))) {
    emit(opts, { action: 'noop', reason: 'no-index' }, r => `noop: ${r.reason}`);
    return;
  }
  const maxTimeMs = Math.max(1, (opts.maxTime ?? 5) * 1000);
  const planner = await sessionRefresh({
    rootDir: opts.cwd, graphDir, maxTime: maxTimeMs,
    log: msg => process.stderr.write(`[session-refresh] ${msg}\n`),
  });
  emit(opts, planner, p => `action=${p.action} reason=${p.reason} dirty=${p.dirtyEmitted ?? 0}`);
  if (planner.action === 'build')   await runBuildLocked(opts);
  else if (planner.action === 'refresh') await runRefreshLocked(opts);
}
```

- [ ] **Step 7.5: Run the test**

```bash
node tests/graph/test-session-refresh.mjs
```
Expected: `test-session-refresh.mjs OK`.

- [ ] **Step 7.6: Wire into `hooks/session-start`**

Read `hooks/session-start` first; locate the trailing lines (just before any final `exit 0`). Append:

```bash
if command -v node >/dev/null 2>&1 && [[ -e "$PWD/.claude/graph/index.sqlite" ]]; then
  CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" node "$PLUGIN_ROOT/bin/sspower-graph.mjs" \
    session-refresh --cwd "$PWD" --max-time 5 \
    >/dev/null 2>>"$HOME/.claude/sspower/graph-session.log" &
  disown
fi
```

Validate:

```bash
bash -n hooks/session-start
```
Expected: no errors.

- [ ] **Step 7.7: Commit**

Stage `scripts/graph/session-refresh.mjs`, `bin/sspower-graph.mjs`, `hooks/session-start`, `tests/graph/test-session-refresh.mjs`. Commit message to `/tmp/commit-msg-p2-7.txt`:

```
feat(graph): SessionStart sweep with filesethash + rowid sampling

sessionRefresh() is a pure planner: Step 0 computes git ls-files
SHA8 and compares against version.git_filesethash (new files →
recommend build), Step 1 samples rowid-strided with sparse-rowid
retry against on-disk content hashes (>5% divergence over ≥50
samples → recommend build; >0 divergence → emit dirty + recommend
refresh). The CLI verb wraps the planner and dispatches to
runBuildLocked / runRefreshLocked under the standard
graph-with-lock.py acquisition.

hooks/session-start fires one detached worker with --max-time 5s
gated on graph index presence. Failures swallowed to a log file
under $HOME/.claude/sspower/graph-session.log.

Per spec §3.5 SessionStart algorithm + K4 corrected math.
```

`git commit -F /tmp/commit-msg-p2-7.txt` standalone.

---

## Task 8: Walker + build dispatcher extensions for multi-language

**Goal:** Extend `scripts/graph/walk.mjs` to include `.py`, `.go`, `.rs`. Update `scripts/graph/build.mjs` to dispatch through `extractorFor(language)` from Task 4. `resolveModule` becomes language-aware (the actual per-language module resolvers ship with their respective extractors in Tasks 9/10/11; this task just plumbs the language argument through).

**Files:**
- Modify: `scripts/graph/walk.mjs`
- Modify: `scripts/graph/build.mjs`
- Modify: `scripts/graph/resolve.mjs`
- Modify: `tests/graph/test-walk.mjs` (extend coverage)

- [ ] **Step 8.1: Extend `SOURCE_EXTS` in `walk.mjs`**

Edit the constant near the top of `scripts/graph/walk.mjs`:

```javascript
const SOURCE_EXTS = new Set([
  '.ts', '.tsx', '.mts', '.cts',
  '.js', '.jsx', '.mjs', '.cjs',
  '.py',
  '.go',
  '.rs',
]);
const IGNORE_DIRS = new Set([
  'node_modules', '.git', 'dist', 'build', '.next',
  '__pycache__', '.venv', 'venv',
  'target',          // Rust build dir
  'vendor',          // Go vendor dir
  '.pytest_cache',
]);
```

- [ ] **Step 8.2: Update `languageFor` in `build.mjs`**

Replace lines 10-14:

```javascript
function languageFor(filePath) {
  const ext = path.extname(filePath);
  if (ext === '.ts' || ext === '.tsx' || ext === '.mts' || ext === '.cts') return 'typescript';
  if (ext === '.js' || ext === '.jsx' || ext === '.mjs' || ext === '.cjs') return 'javascript';
  if (ext === '.py') return 'python';
  if (ext === '.go') return 'go';
  if (ext === '.rs') return 'rust';
  return 'javascript';
}
```

- [ ] **Step 8.3: Swap the hardcoded TS extractor for the dispatcher**

In `build.mjs`, replace the `import { extractFile } from './extract-ts.mjs'` line with:

```javascript
import { extractorFor } from './extract.mjs';
```

Then inside the per-file extraction block, change:

```javascript
try { extracted = await extractFile({ absPath: filePath, source, language }); }
```

to:

```javascript
try {
  const ex = await extractorFor(language);
  extracted = await ex.extractFile({ absPath: filePath, source, language });
}
```

- [ ] **Step 8.4: Add language argument to `resolveModule`**

In `scripts/graph/resolve.mjs`, change the signature:

```javascript
export function resolveModule(importerAbs, moduleSpec, language = 'typescript') {
  switch (language) {
    case 'typescript':
    case 'javascript':
      return resolveModuleTs(importerAbs, moduleSpec);
    case 'python':
      return resolveModulePy(importerAbs, moduleSpec);
    case 'go':
      return resolveModuleGo(importerAbs, moduleSpec);
    case 'rust':
      return resolveModuleRs(importerAbs, moduleSpec);
    default:
      return null;
  }
}
```

Move the existing TS resolution body into a new private function `resolveModuleTs`. Stub `resolveModulePy`, `resolveModuleGo`, `resolveModuleRs` to `return null` for now (real bodies land in Tasks 9/10/11).

- [ ] **Step 8.5: Update callers passing `language` through**

In `build.mjs`, the `resolveModule(f.filePath, imp.moduleSpec)` calls become `resolveModule(f.filePath, imp.moduleSpec, f.language)`. Same in `refresh.mjs` (already passes `f.language` per Task 4 implementation — verify).

- [ ] **Step 8.6: Extend `tests/graph/test-walk.mjs`**

Add a multi-language fixture case: create `.py`, `.go`, `.rs` files in a temp dir, run the walker, assert all are yielded.

- [ ] **Step 8.7: Run regressions**

```bash
node tests/graph/test-walk.mjs
node tests/graph/test-resolve.mjs
node tests/graph/test-extract-ts.mjs
node tests/graph/test-build-query.mjs
node tests/graph/test-refresh.mjs
```
Expected: all OK. The multi-language extensions must not regress TS/JS behavior.

- [ ] **Step 8.8: Commit**

Commit message:

```
refactor(graph): walker + build dispatcher ready for multi-lang

walker accepts .py/.go/.rs; build.mjs routes through extractorFor()
dispatcher (Task 4); resolveModule takes a language argument and
forks to resolveModuleTs / Py / Go / Rs. Py/Go/Rs branches return
null until Tasks 9/10/11 land the bodies. TS/JS behavior unchanged
— P1 regressions pass.
```

`git commit -F /tmp/commit-msg-p2-8.txt` standalone.

---
## Task 9: Python extractor + fixture pack

**Goal:** Land `scripts/graph/extract-py.mjs` + 5 YAML rules + `__tests__/graph-fixtures/python/` (single-file + multi-file + class-method) meeting `precision ≥ 0.85, recall ≥ 0.70` on the harness. Resolver gets `resolveModulePy`.

**Reference language semantics:**
- Functions: `def name(...):`
- Methods: `def name(self, ...):` nested under `class C:`
- Classes: `class Name(Bases):`
- Calls: `foo(...)`, `obj.method(...)`, `Cls.method(...)`
- Imports: `import mod`, `from mod import name`, `from mod import name as alias`, `from . import sibling`, `from .pkg import x`
- Relative imports: `from .x import y` → `./x.py`, `from ..pkg.mod import y` → `../pkg/mod.py`. Package dirs: `from .pkg import mod` → `./pkg/mod.py` OR `./pkg/__init__.py`.

**Files:**
- Create: `scripts/graph/rules/py-function.yml`
- Create: `scripts/graph/rules/py-class.yml`
- Create: `scripts/graph/rules/py-method.yml`
- Create: `scripts/graph/rules/py-call.yml`
- Create: `scripts/graph/rules/py-import.yml`
- Create: `scripts/graph/extract-py.mjs`
- Modify: `scripts/graph/resolve.mjs` (`resolveModulePy`)
- Create: `__tests__/graph-fixtures/python/expected.json`
- Create: `__tests__/graph-fixtures/python/main.py`, `helpers.py`, `pkg/__init__.py`, `pkg/util.py`
- Create: `tests/graph/test-extract-py.mjs`

- [ ] **Step 9.1: Probe ast-grep Python grammar availability**

```bash
ast-grep run -p 'def $NAME($$$)' --lang python --json=compact tests/graph/test-resolve.mjs 2>&1 | head -3
echo "exit=$?"
ast-grep --version
```
Expected: ast-grep 0.43+ outputs JSON (probably `[]` since `.mjs` isn't python — but the command must not error with "unsupported language"). If unsupported → STOP and document in §6 Risks; spec §4 P2 row gates on grammar availability.

- [ ] **Step 9.2: Write rule files**

`scripts/graph/rules/py-function.yml`:
```yaml
id: py-function
language: python
rule:
  kind: function_definition
```

`scripts/graph/rules/py-class.yml`:
```yaml
id: py-class
language: python
rule:
  kind: class_definition
```

`scripts/graph/rules/py-method.yml`:
```yaml
id: py-method
language: python
rule:
  kind: function_definition
  inside:
    kind: class_definition
    stopBy: end
```

`scripts/graph/rules/py-call.yml`:
```yaml
id: py-call
language: python
rule:
  kind: call
```

`scripts/graph/rules/py-import.yml`:
```yaml
id: py-import
language: python
rule:
  any:
    - kind: import_statement
    - kind: import_from_statement
```

- [ ] **Step 9.3: Write the fixture pack**

`__tests__/graph-fixtures/python/main.py`:
```python
from helpers import helper
from pkg.util import calc

def caller():
    return helper(calc(1, 2))

class Worker:
    def run(self):
        return helper()
```

`__tests__/graph-fixtures/python/helpers.py`:
```python
def helper(x=0):
    return x + 1
```

`__tests__/graph-fixtures/python/pkg/__init__.py`:
```python
```

`__tests__/graph-fixtures/python/pkg/util.py`:
```python
def calc(a, b):
    return a + b
```

`__tests__/graph-fixtures/python/expected.json` — list of caller→callee pairs with confidence (mirror `__tests__/graph-fixtures/ts-js-multifile/expected.json` shape):
```json
{
  "edges": [
    { "src_qname": "caller",     "tgt_qname": "helper", "confidence": 2 },
    { "src_qname": "caller",     "tgt_qname": "calc",   "confidence": 2 },
    { "src_qname": "Worker.run", "tgt_qname": "helper", "confidence": 2 }
  ]
}
```

- [ ] **Step 9.4: Implement `scripts/graph/extract-py.mjs`**

Mirror `extract-ts.mjs` structure: load rules from `scripts/graph/rules/`, run them via `astgrep.mjs`, derive names from match `text`. Python specifics:

- `nameFromDefText(text)` — match `^(?:async\s+)?def\s+([A-Za-z_]\w*)`.
- `nameFromClassText(text)` — match `^class\s+([A-Za-z_]\w*)`.
- For methods: parse the same `def NAME` pattern; assemble qualifiedName as `Class.method` via byte-range containment (method byteStart/byteEnd ∈ class byteStart/byteEnd).
- For imports, two shapes:
  - `import mod` / `import mod as alias` — `moduleSpec='mod'`, names=`[{imported: '*', local: 'mod' || alias}]` (treat bare module import as namespace alias).
  - `from mod import a, b as c` — `moduleSpec='mod'`, names=`[{imported:'a', local:'a'}, {imported:'b', local:'c'}]`.
  - `from . import x` / `from .x import y` — `moduleSpec='.'` or `.x`; resolver handles relative dots.
- For calls: same `kind: call` derived from `text` IDENT prefix. Python adds `Cls(...)` (constructor) — these surface as plain identifier calls and resolve to the class node by name (acceptable; spec §5 known limit "no type resolution").
- Skip `__pycache__` files (walker already does).

Skeleton (~150 LOC; copy `extract-ts.mjs` and adapt):

```javascript
// scripts/graph/extract-py.mjs
import { runRule } from './astgrep.mjs';
import crypto from 'node:crypto';
import path from 'node:path';
import url from 'node:url';

const RULE_DIR = path.join(path.dirname(url.fileURLToPath(import.meta.url)), 'rules');
const RULES = {
  function: path.join(RULE_DIR, 'py-function.yml'),
  class:    path.join(RULE_DIR, 'py-class.yml'),
  method:   path.join(RULE_DIR, 'py-method.yml'),
  call:     path.join(RULE_DIR, 'py-call.yml'),
  import:   path.join(RULE_DIR, 'py-import.yml'),
};

function spanSha8(text) {
  return crypto.createHash('sha256').update(text).digest('hex').slice(0, 8);
}
function nameFromDefText(t) { const m = t.match(/^(?:async\s+)?def\s+([A-Za-z_]\w*)/); return m?.[1] ?? null; }
function nameFromClassText(t) { const m = t.match(/^class\s+([A-Za-z_]\w*)/); return m?.[1] ?? null; }
function firstLine(t) { return t.split('\n', 1)[0].slice(0, 200); }

export async function extractFile({ absPath, source, language = 'python' }) {
  const [fns, classes, methods, calls, imps] = await Promise.all([
    runRule(RULES.function, absPath),
    runRule(RULES.class,    absPath),
    runRule(RULES.method,   absPath),
    runRule(RULES.call,     absPath),
    runRule(RULES.import,   absPath),
  ]);

  // Class ranges first to scope methods.
  const classRanges = [];
  const nodes = [];

  for (const m of classes) {
    const name = nameFromClassText(m.text); if (!name) continue;
    classRanges.push({ name, byteStart: m.byteStart, byteEnd: m.byteEnd });
    nodes.push({ kind:'class', name, qualifiedName: name,
      startLine:m.startLine, endLine:m.endLine, byteStart:m.byteStart, byteEnd:m.byteEnd,
      signature: firstLine(m.text), spanSha8: spanSha8(m.text), language });
  }

  // method byte-ranges first so we can exclude them from the function loop.
  const methodSet = new Set();
  for (const m of methods) {
    const name = nameFromDefText(m.text); if (!name) continue;
    const enclosing = classRanges
      .filter(c => c.byteStart <= m.byteStart && c.byteEnd >= m.byteEnd)
      .sort((a, b) => (b.byteEnd - b.byteStart) - (a.byteEnd - a.byteStart))
      .pop();
    const qualifiedName = enclosing ? `${enclosing.name}.${name}` : name;
    methodSet.add(`${m.byteStart}:${m.byteEnd}`);
    nodes.push({ kind:'method', name, qualifiedName,
      startLine:m.startLine, endLine:m.endLine, byteStart:m.byteStart, byteEnd:m.byteEnd,
      signature: firstLine(m.text), spanSha8: spanSha8(m.text), language });
  }

  for (const m of fns) {
    if (methodSet.has(`${m.byteStart}:${m.byteEnd}`)) continue;  // already added as method
    const name = nameFromDefText(m.text); if (!name) continue;
    nodes.push({ kind:'function', name, qualifiedName: name,
      startLine:m.startLine, endLine:m.endLine, byteStart:m.byteStart, byteEnd:m.byteEnd,
      signature: firstLine(m.text), spanSha8: spanSha8(m.text), language });
  }

  const imports = imps.map(m => {
    const t = m.text;
    const out = { moduleSpec: null, names: [], line: m.startLine };
    let mFrom = t.match(/^from\s+([.\w]+)\s+import\s+(.+?)(?:$|\n)/s);
    if (mFrom) {
      out.moduleSpec = mFrom[1];
      const names = mFrom[2].replace(/[()\\]/g, ' ');
      for (const part of names.split(',')) {
        const piece = part.trim().replace(/\s*#.*$/, '');
        if (!piece) continue;
        const asM = piece.match(/^([A-Za-z_]\w*|\*)\s+as\s+([A-Za-z_]\w*)$/);
        if (asM) out.names.push({ imported: asM[1], local: asM[2] });
        else if (piece === '*') out.names.push({ imported: '*', local: '*' });
        else out.names.push({ imported: piece, local: piece });
      }
      return out;
    }
    let mImp = t.match(/^import\s+([.\w]+)(?:\s+as\s+([A-Za-z_]\w*))?/);
    if (mImp) {
      out.moduleSpec = mImp[1];
      const local = mImp[2] ?? mImp[1].split('.')[0];
      out.names.push({ imported: '*', local });
      return out;
    }
    return out;
  }).filter(i => i.moduleSpec);

  const callableRanges = nodes
    .filter(n => n.kind === 'function' || n.kind === 'method')
    .map(n => ({ qualifiedName: n.qualifiedName, byteStart: n.byteStart, byteEnd: n.byteEnd }));

  const IDENT_PREFIX = /^([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)/;
  const callSites = [];
  for (const c of calls) {
    const mm = c.text.match(IDENT_PREFIX); if (!mm) continue;
    const enclosing = callableRanges
      .filter(r => r.byteStart <= c.byteStart && r.byteEnd >= c.byteEnd)
      .sort((a, b) => (b.byteEnd - b.byteStart) - (a.byteEnd - a.byteStart))
      .pop();
    if (!enclosing) continue;
    callSites.push({ callerQualifiedName: enclosing.qualifiedName, calleeIdent: mm[1], line: c.startLine });
  }

  return { nodes, imports, callSites };
}
```

- [ ] **Step 9.5: Implement `resolveModulePy` in `scripts/graph/resolve.mjs`**

Replace the stub:

```javascript
function resolveModulePy(importerAbs, moduleSpec) {
  const importerDir = path.dirname(importerAbs);

  // Relative dots: ".x", "..pkg.mod", "."
  if (moduleSpec.startsWith('.')) {
    const dots = moduleSpec.match(/^\.+/)[0].length;
    let base = importerDir;
    for (let i = 1; i < dots; i++) base = path.dirname(base);
    const rest = moduleSpec.slice(dots).replace(/\./g, '/');
    const candidate = rest ? path.join(base, rest) : base;
    const py    = candidate + '.py';
    const initF = path.join(candidate, '__init__.py');
    if (fs.existsSync(py) && fs.statSync(py).isFile()) return py;
    if (fs.existsSync(initF) && fs.statSync(initF).isFile()) return initF;
    return null;
  }

  // Absolute (top-level pkg). Search the project root for a matching path.
  // Walk up from importerDir looking for the FIRST ancestor that contains a
  // matching <spec>.py OR <spec>/__init__.py. This matches CPython's
  // sys.path-first-hit behavior for in-repo packages without simulating sys.path.
  const rel = moduleSpec.replace(/\./g, '/');
  let dir = importerDir;
  for (let i = 0; i < 10; i++) {
    const py    = path.join(dir, rel + '.py');
    const initF = path.join(dir, rel, '__init__.py');
    if (fs.existsSync(py) && fs.statSync(py).isFile()) return py;
    if (fs.existsSync(initF) && fs.statSync(initF).isFile()) return initF;
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return null;
}
```

- [ ] **Step 9.6: Write `tests/graph/test-extract-py.mjs`**

Unit test that reads `__tests__/graph-fixtures/python/main.py`, runs `extractFile({absPath, source, language:'python'})`, asserts `nodes` includes a `function` `caller`, a `class` `Worker`, a `method` `Worker.run`; `imports` has `helpers` and `pkg.util`; `callSites` has 3 entries (caller→helper, caller→calc, Worker.run→helper).

```bash
node tests/graph/test-extract-py.mjs
```
Expected: prints OK.

- [ ] **Step 9.7: Wire fixture into the harness loop**

Edit `__tests__/graph-fixtures/harness.test.ts`. Change the existing single-pack iteration to a multi-pack loop:

```typescript
const LANGUAGE_PACKS = [
  { dir: 'ts-js',           language: 'typescript' },
  { dir: 'ts-js-multifile', language: 'typescript' },
  { dir: 'python',          language: 'python'     },
  // go + rust added in Tasks 10/11
];

for (const pack of LANGUAGE_PACKS) {
  test(`${pack.dir}: P>=0.85, R>=0.70`, async () => { /* … */ });
}
```

The body builds the index on the fixture pack, queries every edge, computes precision/recall against `expected.json`, asserts both thresholds.

- [ ] **Step 9.8: Run the harness**

```bash
bun x vitest run __tests__/graph-fixtures/
```
Expected: all packs (ts-js, ts-js-multifile, python) pass. If python misses recall, debug method-qname resolution or `from .` resolver before continuing.

- [ ] **Step 9.9: Live demo — Python file in the actual sspower repo**

```bash
node bin/sspower-graph.mjs build --cwd .
node bin/sspower-graph.mjs callers acquire_lock --cwd .
```
Expected: `callers acquire_lock` returns at least the call-sites in `scripts/graph-append-dirty.py` and `scripts/graph-with-lock.py` (both `with acquire_lock(...)` blocks). If empty, the Python extractor is missing edges — debug before commit.

- [ ] **Step 9.10: Commit**

Stage all files, commit message at `/tmp/commit-msg-p2-9.txt`:

```
feat(graph): Python extractor + fixture pack (P>=0.85, R>=0.70)

extract-py.mjs mirrors extract-ts.mjs shape: 5 YAML rules
(function/class/method/call/import), method qname via byte-range
class containment, import shapes for `import x`, `import x as y`,
`from m import a, b as c`, `from . import x`, `from .pkg.mod import y`.

resolveModulePy handles relative dots and walks ancestor dirs to
find absolute imports — matches in-repo package resolution without
simulating sys.path.

Fixture pack __tests__/graph-fixtures/python/ covers single-file,
multi-file, package dir + __init__.py, class method. Harness loop
extended to iterate language packs; python gate at P>=0.85 R>=0.70.

Live demo: `callers acquire_lock` returns the two call sites in
scripts/graph-append-dirty.py and scripts/graph-with-lock.py.
```

`git commit -F /tmp/commit-msg-p2-9.txt` standalone.

---
## Task 10: Go extractor + fixture pack

**Goal:** `scripts/graph/extract-go.mjs` + 4 YAML rules + `__tests__/graph-fixtures/go/` meeting `P≥0.85, R≥0.70`. `resolveModuleGo` handles intra-module relative-to-go.mod resolution.

**Reference language semantics:**
- Functions: `func Name(...) ... { }`
- Methods: `func (r *Receiver) Name(...) ... { }` → qname = `Receiver.Name` (strip `*`)
- Calls: `Name(...)`, `pkg.Name(...)`, `obj.Method(...)`
- Imports: `import "pkg"` or `import ( "pkg/a" "pkg/b" )`
- Package paths resolve relative to go.mod's `module` directive (the project root). For P2, we treat the importer's enclosing dir's go.mod as authoritative; absolute imports under the same module path resolve to repo paths.

**Files:**
- Create: `scripts/graph/rules/go-function.yml` — `kind: function_declaration`
- Create: `scripts/graph/rules/go-method.yml` — `kind: method_declaration`
- Create: `scripts/graph/rules/go-call.yml` — `kind: call_expression`
- Create: `scripts/graph/rules/go-import.yml` — `kind: import_declaration`
- Create: `scripts/graph/extract-go.mjs`
- Create: `__tests__/graph-fixtures/go/` (main.go, helpers.go, go.mod, optional subpkg)
- Create: `tests/graph/test-extract-go.mjs`
- Modify: `scripts/graph/resolve.mjs` (`resolveModuleGo`)

- [ ] **Step 10.1: Probe ast-grep Go grammar**

```bash
echo 'package main
func foo() {}' > /tmp/probe.go
ast-grep run -p 'func $NAME($$$) {}' --lang go --json=compact /tmp/probe.go
```
Expected: JSON output with one match. If unsupported → STOP.

- [ ] **Step 10.2: Rule files**

`go-function.yml`:
```yaml
id: go-function
language: go
rule:
  kind: function_declaration
```

`go-method.yml`:
```yaml
id: go-method
language: go
rule:
  kind: method_declaration
```

`go-call.yml`:
```yaml
id: go-call
language: go
rule:
  kind: call_expression
```

`go-import.yml`:
```yaml
id: go-import
language: go
rule:
  kind: import_declaration
```

- [ ] **Step 10.3: Fixture pack**

`__tests__/graph-fixtures/go/go.mod`:
```
module fixture/sample

go 1.22
```

`__tests__/graph-fixtures/go/main.go`:
```go
package main

import (
  "fixture/sample/util"
)

func main() {
  result := util.Calc(1, 2)
  println(result)
}

type Worker struct{}

func (w *Worker) Run() int {
  return util.Calc(3, 4)
}
```

`__tests__/graph-fixtures/go/util/util.go`:
```go
package util

func Calc(a, b int) int { return a + b }
```

`expected.json`:
```json
{
  "edges": [
    { "src_qname": "main",       "tgt_qname": "Calc", "confidence": 2 },
    { "src_qname": "Worker.Run", "tgt_qname": "Calc", "confidence": 2 }
  ]
}
```

- [ ] **Step 10.4: Implement `scripts/graph/extract-go.mjs`**

Structure mirrors `extract-ts.mjs` / `extract-py.mjs`. Go specifics:

- `nameFromFuncText(t)` — match `^func\s+([A-Z][A-Za-z0-9_]*|[a-z][A-Za-z0-9_]*)`.
- `nameFromMethodText(t)` — match `^func\s+\(\s*\w+\s+\*?(\w+)\s*\)\s+([A-Za-z_]\w*)` → qname `Receiver.Method`.
- `nameFromCallText` — IDENT_PREFIX same as TS (split on `.`).
- `parseImports(text)` — handles both `import "x"` single-line and `import ( ... )` block; iterate quoted strings inside the block. Each yields `{ moduleSpec: "fixture/sample/util", names: [{ imported: '*', local: tail }], line }` where `local` is the last segment (`util`).

- [ ] **Step 10.5: Implement `resolveModuleGo`**

```javascript
function resolveModuleGo(importerAbs, moduleSpec) {
  // Walk up from importerDir looking for go.mod; read its `module X` line.
  let dir = path.dirname(importerAbs);
  let modRoot = null, modPath = null;
  for (let i = 0; i < 10; i++) {
    const gomod = path.join(dir, 'go.mod');
    if (fs.existsSync(gomod)) {
      const m = fs.readFileSync(gomod, 'utf8').match(/^module\s+(\S+)/m);
      if (m) { modRoot = dir; modPath = m[1]; }
      break;
    }
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  if (!modRoot || !modPath) return null;
  // moduleSpec must start with modPath to be local; external pkgs return null.
  if (moduleSpec === modPath) return modRoot;
  if (!moduleSpec.startsWith(modPath + '/')) return null;
  const rel = moduleSpec.slice(modPath.length + 1);
  const dirCandidate = path.join(modRoot, rel);
  if (!fs.existsSync(dirCandidate) || !fs.statSync(dirCandidate).isDirectory()) return null;
  // Return the first .go file in the dir (extractor processes each file
  // separately; the import resolves to the package dir but we need a file
  // path. Pick lexicographically smallest .go file in the dir).
  const files = fs.readdirSync(dirCandidate).filter(f => f.endsWith('.go')).sort();
  if (files.length === 0) return null;
  return path.join(dirCandidate, files[0]);
}
```

Limitation: Go imports resolve to one file even though a package spans many files in the same dir. The cross-file ambiguous-name fallback in `resolveEdges` will still catch siblings via the same-name path. Documented in spec §5 known limits — P2 ships this; P3+ may improve via a package→files index table.

- [ ] **Step 10.6: Test**

```bash
node tests/graph/test-extract-go.mjs
bun x vitest run __tests__/graph-fixtures/go
```
Expected: both pass; `go` pack meets P≥0.85, R≥0.70.

- [ ] **Step 10.7: Update extract.mjs lazy import branch** (already done in Task 4 — verify the `'go'` case loads `./extract-go.mjs` correctly).

- [ ] **Step 10.8: Live demo**

If the sspower repo doesn't have Go files, skip. Otherwise (or use a known Go repo): `node bin/sspower-graph.mjs build --cwd /path/to/go-repo && node bin/sspower-graph.mjs callers SomeName --cwd /path/to/go-repo`.

- [ ] **Step 10.9: Commit**

Commit message:
```
feat(graph): Go extractor + fixture pack (P>=0.85, R>=0.70)

extract-go.mjs: 4 YAML rules (function/method/call/import), method
qname via receiver type parse. Imports parsed from both single-line
and parenthesized block forms.

resolveModuleGo reads go.mod up the tree to discover the module
path; absolute imports under the module path resolve to the first
.go file in the target dir. P2 known limit: package-spans-multiple-
files is approximated via that single-file resolution; the cross-
graph ambiguous fallback catches siblings.

Harness loop now includes the go pack.
```

`git commit -F /tmp/commit-msg-p2-10.txt` standalone.

---

## Task 11: Rust extractor + fixture pack

**Goal:** `scripts/graph/extract-rs.mjs` + 5 YAML rules + `__tests__/graph-fixtures/rust/` meeting `P≥0.85, R≥0.70`. `resolveModuleRs` handles `mod`/`use` resolution within a crate.

**Reference language semantics:**
- Functions: `fn name(...) -> T { }`
- Impl methods: `impl Type { fn method(...) }` → qname = `Type.method`. `impl Trait for Type { fn method() }` → qname = `Type.method` (trait dispatch is a P3+ concern).
- Calls: `name(...)`, `Type::method(...)`, `obj.method(...)`, `macro!(...)` (macro invocations tracked as call edges with the macro name).
- Imports: `use crate::mod::Name;`, `use super::sib;`, `use self::child::*;`, `mod child;`.
- Resolution: `use crate::a::b` → walk from crate root (`src/lib.rs` or `src/main.rs`) via mod declarations.

**Files:**
- Create: `scripts/graph/rules/rs-function.yml`
- Create: `scripts/graph/rules/rs-impl.yml`
- Create: `scripts/graph/rules/rs-method.yml`
- Create: `scripts/graph/rules/rs-call.yml`
- Create: `scripts/graph/rules/rs-use.yml`
- Create: `scripts/graph/extract-rs.mjs`
- Modify: `scripts/graph/resolve.mjs` (`resolveModuleRs`)
- Create: `__tests__/graph-fixtures/rust/` (Cargo.toml, src/main.rs, src/util.rs)
- Create: `tests/graph/test-extract-rs.mjs`

- [ ] **Step 11.1: Probe ast-grep Rust grammar**

```bash
echo 'fn foo() {}' > /tmp/probe.rs
ast-grep run -p 'fn $NAME($$$)' --lang rust --json=compact /tmp/probe.rs
```
Expected: JSON match.

- [ ] **Step 11.2: Rule files**

`rs-function.yml`: `kind: function_item`.
`rs-impl.yml`: `kind: impl_item`.
`rs-method.yml`:
```yaml
id: rs-method
language: rust
rule:
  kind: function_item
  inside:
    kind: impl_item
    stopBy: end
```

`rs-call.yml`:
```yaml
id: rs-call
language: rust
rule:
  any:
    - kind: call_expression
    - kind: macro_invocation
```

`rs-use.yml`: `kind: use_declaration`.

- [ ] **Step 11.3: Fixture pack**

`__tests__/graph-fixtures/rust/Cargo.toml`:
```toml
[package]
name = "fixture"
version = "0.1.0"
edition = "2021"

[[bin]]
name = "fixture"
path = "src/main.rs"
```

`__tests__/graph-fixtures/rust/src/main.rs`:
```rust
mod util;

use util::calc;

fn main() {
    let r = caller();
    println!("{}", r);
}

fn caller() -> i32 {
    calc(1, 2)
}

struct Worker;

impl Worker {
    fn run(&self) -> i32 {
        calc(3, 4)
    }
}
```

`__tests__/graph-fixtures/rust/src/util.rs`:
```rust
pub fn calc(a: i32, b: i32) -> i32 {
    a + b
}
```

`expected.json`:
```json
{
  "edges": [
    { "src_qname": "main",       "tgt_qname": "caller", "confidence": 1 },
    { "src_qname": "caller",     "tgt_qname": "calc",   "confidence": 2 },
    { "src_qname": "Worker.run", "tgt_qname": "calc",   "confidence": 2 }
  ]
}
```

- [ ] **Step 11.4: Implement `scripts/graph/extract-rs.mjs`**

Specifics:
- `nameFromFnText(t)` — `^(?:pub\s+(?:\(\s*\w+\s*\)\s+)?)?(?:async\s+)?(?:unsafe\s+)?(?:const\s+)?fn\s+([A-Za-z_]\w*)`.
- `nameFromImplText(t)` — `^impl(?:<[^>]*>)?\s+(?:[A-Za-z_]\w*(?:<[^>]*>)?\s+for\s+)?([A-Za-z_]\w*)`. For `impl Trait for Type`, we want `Type`; the regex above captures the second IDENT when `for` is present.
- Methods qname = `Type.method` via byte-range containment in impl ranges.
- Macro calls: text starts with IDENT `!`; treat as a call site against the macro name (drop the trailing `!`).
- Use statements: `use a::b::c;`, `use a::b::{c, d as e};`, `use a::*;`. Module spec is the path before the trailing leaf; names extracted from braced parts. `use crate::x::y` → `moduleSpec='crate::x'`, names `[{imported:'y', local:'y'}]`.

- [ ] **Step 11.5: Implement `resolveModuleRs`**

Cargo crate root discovery: walk up to find `Cargo.toml`; crate root is the bin's `src/main.rs` or lib's `src/lib.rs`. For paths starting with `crate::`, replace `crate::` with the crate root dir + `src/`. For `super::`, walk up one mod level. For `self::`, same dir.

Mod declarations: `mod x;` → file `x.rs` or `x/mod.rs` in the same dir. This means a `use crate::util::calc` from `src/main.rs` resolves to `src/util.rs` if `mod util;` is declared in `main.rs`.

```javascript
function resolveModuleRs(importerAbs, moduleSpec) {
  // Find Cargo.toml ancestor.
  let dir = path.dirname(importerAbs);
  let crateRoot = null;
  for (let i = 0; i < 10; i++) {
    if (fs.existsSync(path.join(dir, 'Cargo.toml'))) { crateRoot = dir; break; }
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  if (!crateRoot) return null;

  // Normalize moduleSpec into segments, resolving crate::/self::/super::.
  let segments;
  if (moduleSpec.startsWith('crate::')) {
    segments = moduleSpec.slice('crate::'.length).split('::');
    dir = path.join(crateRoot, 'src');
  } else if (moduleSpec.startsWith('self::')) {
    segments = moduleSpec.slice('self::'.length).split('::');
    dir = path.dirname(importerAbs);
  } else if (moduleSpec.startsWith('super::')) {
    let rest = moduleSpec;
    dir = path.dirname(importerAbs);
    while (rest.startsWith('super::')) { dir = path.dirname(dir); rest = rest.slice('super::'.length); }
    segments = rest.split('::');
  } else {
    // External crate; skip.
    return null;
  }

  // Walk down segments; each may be a file <seg>.rs OR dir <seg>/mod.rs.
  let cur = dir;
  for (let i = 0; i < segments.length; i++) {
    const seg = segments[i];
    if (!seg) continue;
    const asFile = path.join(cur, seg + '.rs');
    const asMod  = path.join(cur, seg, 'mod.rs');
    const last = i === segments.length - 1;
    if (last) {
      if (fs.existsSync(asFile) && fs.statSync(asFile).isFile()) return asFile;
      if (fs.existsSync(asMod)  && fs.statSync(asMod).isFile())  return asMod;
      return null;
    }
    if (fs.existsSync(path.join(cur, seg)) && fs.statSync(path.join(cur, seg)).isDirectory()) {
      cur = path.join(cur, seg);
    } else {
      return null;
    }
  }
  return null;
}
```

- [ ] **Step 11.6: Tests + harness wiring**

Add `rust` entry to `LANGUAGE_PACKS` in `harness.test.ts`.

```bash
node tests/graph/test-extract-rs.mjs
bun x vitest run __tests__/graph-fixtures/rust
```
Expected: both pass; P≥0.85, R≥0.70.

- [ ] **Step 11.7: Commit**

Commit message:
```
feat(graph): Rust extractor + fixture pack (P>=0.85, R>=0.70)

extract-rs.mjs: 5 YAML rules (function/impl/method/call/use); method
qname via impl byte-range containment; trait-for-Type captured as
Type.method; macro_invocation tracked as a call edge (trailing !
stripped).

resolveModuleRs walks to Cargo.toml, normalizes crate::/self::/super::
to filesystem paths, then walks segments as <seg>.rs OR <seg>/mod.rs.

Harness loop now includes the rust pack. The 4-language extractor
matrix is closed for P2.
```

`git commit -F /tmp/commit-msg-p2-11.txt` standalone.

---
## Task 12: CLI verbs `trace`, `impact`, `context`

**Goal:** Add the three remaining query verbs. Pure query-layer additions; no schema migrations. Each verb has a corresponding module under `scripts/graph/` and an inline test against a built fixture.

**Files:**
- Create: `scripts/graph/trace.mjs`
- Create: `scripts/graph/impact.mjs`
- Create: `scripts/graph/context.mjs`
- Create: `tests/graph/test-trace.mjs`
- Create: `tests/graph/test-impact.mjs`
- Create: `tests/graph/test-context.mjs`
- Modify: `bin/sspower-graph.mjs` (replace `runTrace`/`runImpact`/`runContext` stubs)

- [ ] **Step 12.1: Implement `scripts/graph/trace.mjs`**

Bidirectional BFS from both endpoints meets in the middle. Bounded by `maxHops` (default 6). Returns up to N shortest paths (`MAX_RESULTS=50`).

```javascript
// scripts/graph/trace.mjs
export const MAX_RESULTS = 50;

export function trace(db, fromName, toName, { maxHops = 6, limit = MAX_RESULTS } = {}) {
  const fromNodes = db.prepare('SELECT id, qualified_name, file_path, start_line FROM nodes WHERE name = ? OR qualified_name = ?').all(fromName, fromName);
  const toNodes   = db.prepare('SELECT id, qualified_name, file_path, start_line FROM nodes WHERE name = ? OR qualified_name = ?').all(toName,   toName);
  if (fromNodes.length === 0 || toNodes.length === 0) return { paths: [], reason: 'endpoint-not-found' };

  // BFS forward from each fromId.
  const stmtOut = db.prepare('SELECT target, line FROM edges WHERE source = ?');
  const targets = new Set(toNodes.map(n => n.id));
  const paths = [];

  for (const start of fromNodes) {
    const frontier = [[start.id, []]];  // [nodeId, [edge, edge, ...]]
    const visited = new Set([start.id]);
    while (frontier.length && paths.length < limit) {
      const [cur, edgesSoFar] = frontier.shift();
      if (edgesSoFar.length > maxHops) continue;
      if (targets.has(cur) && edgesSoFar.length > 0) {
        // Materialize path: list of node hops.
        paths.push({
          from: start.qualified_name,
          to: toNodes.find(n => n.id === cur)?.qualified_name,
          hops: edgesSoFar.length,
          edges: edgesSoFar,
        });
        continue;
      }
      for (const next of stmtOut.all(cur)) {
        if (visited.has(next.target)) continue;
        visited.add(next.target);
        frontier.push([next.target, [...edgesSoFar, { from: cur, to: next.target, line: next.line }]]);
      }
    }
  }
  return { paths, fromCount: fromNodes.length, toCount: toNodes.length };
}
```

- [ ] **Step 12.2: Implement `scripts/graph/impact.mjs`**

```javascript
// scripts/graph/impact.mjs
export const MAX_RESULTS = 50;

export function impact(db, filePath, { limit = MAX_RESULTS } = {}) {
  // Direct callers of any node in filePath.
  const direct = db.prepare(`
    SELECT DISTINCT src.id, src.qualified_name, src.file_path
      FROM edges e
      JOIN nodes src ON e.source = src.id
      JOIN nodes tgt ON e.target = tgt.id
     WHERE tgt.file_path = ?
  `).all(filePath);
  // Transitive: BFS up the edge graph from direct.
  const visited = new Set(direct.map(d => d.id));
  const frontier = [...direct.map(d => d.id)];
  const stmtIn = db.prepare(`
    SELECT src.id, src.qualified_name, src.file_path
      FROM edges e
      JOIN nodes src ON e.source = src.id
     WHERE e.target = ?
  `);
  const transitive = [...direct];
  while (frontier.length && transitive.length < limit) {
    const cur = frontier.shift();
    for (const row of stmtIn.all(cur)) {
      if (visited.has(row.id)) continue;
      visited.add(row.id);
      transitive.push(row);
      frontier.push(row.id);
    }
  }
  // Bucket by file for the report.
  const byFile = new Map();
  for (const t of transitive) {
    if (!byFile.has(t.file_path)) byFile.set(t.file_path, []);
    byFile.get(t.file_path).push(t.qualified_name);
  }
  return {
    target_file: filePath,
    direct_count: direct.length,
    transitive_count: transitive.length,
    files: [...byFile.entries()].map(([file_path, qnames]) => ({ file_path, qnames })),
  };
}
```

- [ ] **Step 12.3: Implement `scripts/graph/context.mjs`**

Composed query: FTS5 match against `task` text → top-N node candidates → for each, attach callers + callees + signature. Caps at 4KB combined output (spec §3.5 budget — graph-orchestrator uses this in P4).

```javascript
// scripts/graph/context.mjs
import { callers, callees, nodeLookup } from './query.mjs';

const TOP_N = 8;
const MAX_CHARS = 4096;

export function context(db, task) {
  // FTS5 match on name/qualified_name/signature.
  let hits;
  try {
    hits = db.prepare(`
      SELECT rowid FROM nodes_fts WHERE nodes_fts MATCH ? ORDER BY rank LIMIT ?
    `).all(task.replace(/[^A-Za-z0-9_ ]/g, ' '), TOP_N);
  } catch {
    return { hits: [], reason: 'fts-error' };
  }
  const out = [];
  let chars = 0;
  for (const h of hits) {
    const node = db.prepare('SELECT * FROM nodes WHERE rowid = ?').get(h.rowid);
    if (!node) continue;
    const callerRes = callers(db, node.qualified_name, { limit: 5, disambiguate: true });
    const calleeRes = callees(db, node.qualified_name, { limit: 5 });
    const entry = {
      qname: node.qualified_name,
      file: node.file_path,
      line: node.start_line,
      signature: node.signature,
      callers: (callerRes.matches ?? []).slice(0, 5).map(m => ({ qname: m.src_qname, file: m.src_file, line: m.line })),
      callees: (calleeRes.matches ?? []).slice(0, 5).map(m => ({ qname: m.tgt_qname, file: m.tgt_file, line: m.tgt_start })),
    };
    const enc = JSON.stringify(entry);
    if (chars + enc.length > MAX_CHARS) break;
    chars += enc.length;
    out.push(entry);
  }
  return { hits: out, total_chars: chars };
}
```

- [ ] **Step 12.4: Replace CLI stubs in `bin/sspower-graph.mjs`**

```javascript
async function runTrace(opts, fromName, toName) {
  const { trace } = await import(path.join(PLUGIN_ROOT, 'scripts/graph/trace.mjs'));
  await withDb(graphDirFor(opts.cwd), db => {
    const r = trace(db, fromName, toName, { maxHops: opts.maxHops, limit: opts.limit });
    emit(opts, r, p => p.paths.length === 0 ? 'no path' :
      p.paths.map(pp => `${pp.from} -> ... -> ${pp.to} (${pp.hops} hops)`).join('\n'));
  });
}

async function runImpact(opts, filePath) {
  const { impact } = await import(path.join(PLUGIN_ROOT, 'scripts/graph/impact.mjs'));
  const absFile = path.resolve(opts.cwd, filePath);
  await withDb(graphDirFor(opts.cwd), db => {
    const r = impact(db, absFile, { limit: opts.limit });
    emit(opts, r, p => `${p.target_file}\ndirect=${p.direct_count} transitive=${p.transitive_count}\n` +
      p.files.map(f => `  ${f.file_path}\n    ${f.qnames.join(', ')}`).join('\n'));
  });
}

async function runContext(opts, task) {
  const { context: ctxFn } = await import(path.join(PLUGIN_ROOT, 'scripts/graph/context.mjs'));
  await withDb(graphDirFor(opts.cwd), db => {
    const r = ctxFn(db, task);
    emit(opts, r, p => p.hits.length === 0 ? 'no context' :
      p.hits.map(h => `${h.qname}\t${h.file}:${h.line}\t${h.signature ?? ''}`).join('\n'));
  });
}
```

- [ ] **Step 12.5: Tests**

`tests/graph/test-trace.mjs` — build fixture (a → b → c chain), call `trace('caller', 'helper', {maxHops:6})`, assert 1 path with hops=1; trace nonexistent → empty.

`tests/graph/test-impact.mjs` — build fixture, call `impact(absPath('b.ts'))`, assert direct includes `a.ts` callers; assert `files` keyed correctly.

`tests/graph/test-context.mjs` — build fixture; call `context('helper')`; assert non-empty hits with callers/callees populated.

Each test follows the pattern of `tests/graph/test-build-query.mjs`. Skeletons land in commit.

- [ ] **Step 12.6: Run tests**

```bash
node tests/graph/test-trace.mjs
node tests/graph/test-impact.mjs
node tests/graph/test-context.mjs
```
Expected: all OK.

- [ ] **Step 12.7: Commit**

Commit message:
```
feat(graph): trace + impact + context CLI verbs

trace: bidirectional BFS up to maxHops, returns up to MAX_RESULTS
shortest paths. impact: transitive-callers BFS bucketed by file.
context: FTS5-driven top-N node lookup composed with callers/callees,
capped at 4KB (P4 graph-orchestrator budget).

All three are pure query-layer additions; no schema migrations.
CLI stubs replaced with real implementations.
```

`git commit -F /tmp/commit-msg-p2-12.txt` standalone.

---

## Task 13: Multi-pack harness gate + cross-language regression sweep

**Goal:** Verify the harness now runs all 5 packs (ts-js, ts-js-multifile, python, go, rust), each independently gated at P≥0.85, R≥0.70. Also run a regression sweep across every test in the repo to confirm nothing broke during the multi-language expansion.

**Files:**
- Verify (no new): `__tests__/graph-fixtures/harness.test.ts` (already extended in Tasks 9.7/10/11).
- Read: every test file under `tests/` and `__tests__/` to ensure none reference the old single-pack assumption.

- [ ] **Step 13.1: Run the full harness**

```bash
bun x vitest run __tests__/graph-fixtures/ 2>&1 | tail -40
```
Expected: 5 passing packs. Any failure → STOP, return to the offending Task (9/10/11) and fix.

- [ ] **Step 13.2: Run every other graph test in sequence**

```bash
for t in tests/graph/test-*.mjs tests/graph/test-*.sh; do
  case "$t" in
    *.sh) bash "$t" ;;
    *.mjs) node "$t" ;;
  esac
done
bash tests/hooks/test-intent-architecture.sh
bash tests/hooks/test-graph-mark-dirty.sh
CLAUDE_PLUGIN_ROOT=$(pwd) python3 tests/graph/test-lock-helpers.py
CLAUDE_PLUGIN_ROOT=$(pwd) node tests/graph/test-mcp-stub.mjs
```
Expected: every test prints OK / PASS / completes exit-0.

- [ ] **Step 13.3: Run skill-level smoke**

```bash
node bin/sspower-graph.mjs --help 2>&1 | head -20
node bin/sspower-graph.mjs status --cwd /tmp 2>&1 | head -5
```
Expected: `--help` shows all 11 verbs; `status` on an empty dir reports `no index`.

- [ ] **Step 13.4: Commit if the sweep finds any test-only fix needed; else skip**

If a test needed a tweak, commit standalone. Otherwise, no commit — Task 13 is a gate, not a change.

---

## Task 14: Performance gate (10k-file build + warm-callers p95)

**Goal:** Verify spec §4 P2 acceptance gates: `10k-file build < 60s` on M-series Mac, `warm callers < 1s p95`. The benchmark is opt-in (`SSPOWER_GRAPH_PERF=1`) so it doesn't bloat CI but is reproducible on demand.

**Files:**
- Create: `tests/graph/perf-10k.mjs`
- Create: `tests/graph/test-perf-10k.sh`

- [ ] **Step 14.1: Implement `tests/graph/perf-10k.mjs`**

```javascript
// tests/graph/perf-10k.mjs
// Synthesize a 10k-file TypeScript tree, build the graph, then time
// `callers` 100x against a known hot symbol; assert spec §4 P2 gates.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { build } from '../../scripts/graph/build.mjs';
import { callers } from '../../scripts/graph/query.mjs';
import { openDb, initSchema } from '../../scripts/graph/db.mjs';

const TOTAL_FILES   = parseInt(process.env.PERF_FILES   ?? '10000', 10);
const QUERY_REPEATS = parseInt(process.env.PERF_QUERIES ?? '100', 10);
const BUILD_BUDGET_MS = parseInt(process.env.PERF_BUILD_MS ?? '60000', 10);
const QUERY_P95_MS    = parseInt(process.env.PERF_P95_MS  ?? '1000', 10);

const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'sspower-perf-'));
const graphDir = path.join(tmp, '.claude', 'graph');
await fs.mkdir(graphDir, { recursive: true });

// Generate TOTAL_FILES files. File N defines fnN() and calls fn(N-1)
// (or fn(0) for the first file). This creates a long call chain — a
// real worst case for the graph builder.
console.error(`generating ${TOTAL_FILES} files in ${tmp}`);
for (let i = 0; i < TOTAL_FILES; i++) {
  const dirN  = path.join(tmp, `d${Math.floor(i / 100)}`);
  await fs.mkdir(dirN, { recursive: true });
  const filePath = path.join(dirN, `m${i}.ts`);
  const target = i === 0 ? 0 : i - 1;
  const targetFile = path.relative(dirN, path.join(tmp, `d${Math.floor(target / 100)}`, `m${target}.ts`)).replace(/\\/g, '/').replace(/\.ts$/, '');
  await fs.writeFile(filePath,
    `import { fn${target} } from '${targetFile.startsWith('.') ? targetFile : './' + targetFile}';\n` +
    `export function fn${i}() { return fn${target}() + ${i}; }\n`
  );
  if ((i + 1) % 1000 === 0) console.error(`  ${i + 1}/${TOTAL_FILES}`);
}

console.error('building...');
const tBuild0 = Date.now();
await build({ rootDir: tmp, graphDir, log: () => {} });
const buildMs = Date.now() - tBuild0;
console.error(`build: ${buildMs}ms`);

assert.ok(buildMs < BUILD_BUDGET_MS, `build budget: ${buildMs} >= ${BUILD_BUDGET_MS}`);

console.error(`running ${QUERY_REPEATS} warm callers queries...`);
const db = openDb(path.join(graphDir, 'index.sqlite'));
initSchema(db);
const timings = [];
for (let i = 0; i < QUERY_REPEATS; i++) {
  // Query a known mid-chain function.
  const target = `fn${Math.floor(TOTAL_FILES / 2)}`;
  const t0 = process.hrtime.bigint();
  callers(db, target, { limit: 50, disambiguate: true });
  const dt = Number(process.hrtime.bigint() - t0) / 1e6;
  timings.push(dt);
}
db.close();
timings.sort((a, b) => a - b);
const p50 = timings[Math.floor(timings.length * 0.5)];
const p95 = timings[Math.floor(timings.length * 0.95)];
const p99 = timings[Math.floor(timings.length * 0.99)];
console.error(`callers p50=${p50.toFixed(2)}ms p95=${p95.toFixed(2)}ms p99=${p99.toFixed(2)}ms`);

assert.ok(p95 < QUERY_P95_MS, `p95 budget: ${p95} >= ${QUERY_P95_MS}`);

await fs.rm(tmp, { recursive: true, force: true });
console.log(`perf-10k.mjs OK   build=${buildMs}ms  callers p50=${p50.toFixed(2)} p95=${p95.toFixed(2)}`);
```

- [ ] **Step 14.2: Wrapper script `tests/graph/test-perf-10k.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
if [[ "${SSPOWER_GRAPH_PERF:-0}" != "1" ]]; then
  echo "test-perf-10k.sh SKIP (set SSPOWER_GRAPH_PERF=1 to run)"
  exit 0
fi
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
exec node "$HERE/tests/graph/perf-10k.mjs"
```

`chmod +x tests/graph/test-perf-10k.sh`.

- [ ] **Step 14.3: Run the bench locally (M-series target)**

```bash
SSPOWER_GRAPH_PERF=1 bash tests/graph/test-perf-10k.sh
```
Expected: `perf-10k.mjs OK build=<60000 callers p95=<1000`.

If build > 60s on M-series: investigate `extract-ts.mjs` for serial bottlenecks (ast-grep spawn overhead per file is the usual suspect; the spec allows parallel ast-grep but P1 ships serial — this is the place to land parallelism if needed). If p95 > 1s: investigate the `callers` query — likely missing index on `edges.target` (already present per Task 4 schema, but verify).

- [ ] **Step 14.4: Document the perf budget in README**

Append to the `## sspower-graph` section of `README.md`:

```markdown
**Performance budgets (P2 acceptance gates, spec §4):**
- 10k-file repo, cold `build`: < 60s (M-series Mac)
- warm `callers` p95: < 1s

Reproduce: `SSPOWER_GRAPH_PERF=1 bash tests/graph/test-perf-10k.sh`. The
bench is opt-in; CI does not run it.
```

- [ ] **Step 14.5: Commit**

```
test(graph): 10k-file build + warm-callers p95 perf gate

perf-10k.mjs synthesizes a 10k-file TS tree with a long call chain,
times a cold build (budget 60s) and 100 warm callers queries against
a mid-chain symbol (p95 budget 1s). Both gates are spec §4 P2
acceptance criteria.

Wrapper script gates on SSPOWER_GRAPH_PERF=1 so CI doesn't run the
~30s benchmark by default; on-demand reproduction is documented in
README.md.
```

`git commit -F /tmp/commit-msg-p2-14.txt` standalone.

---
## Task 15: Codex plan-review + branch-diff review + PR + merge

**Goal:** Run explicit Codex plan-review against this plan doc, fix every high/medium finding inline, re-run until verdict is `approve` or `approve-with-followups`. Then ship the branch as a PR; require auto-review approval before merge.

- [ ] **Step 15.1: Run Codex plan-review**

```bash
node "$HOME/.claude/plugins/marketplaces/sskys18/plugins/sspower/scripts/codex-bridge.mjs" plan-review \
  --cd . --prompt @docs/plans/2026-05-26-codegraph-graph-P2.md \
  > /tmp/plan-review-p2.json 2>&1
jq -r '.verdict, .findings[]?.severity' /tmp/plan-review-p2.json
```
Expected: verdict prints; findings stream by severity. The auto-review hook will check the prompt → load the spec for delta comparison automatically.

- [ ] **Step 15.2: Fix every `high` and `medium` finding**

Iterate the findings list. For each:
- If the fix is a plan edit (most cases): edit this plan doc in place, then re-run Step 15.1.
- If the finding is a spec-vs-plan delta the spec already covers correctly: cite the spec section in the plan to remove the ambiguity.
- If the finding is a genuine design issue: pause, raise the issue with the user, await direction. Do NOT silently change the design.

Continue until verdict is `approve` or `approve-with-followups`. Cache the verdict file:

```bash
cp /tmp/plan-review-p2.json docs/plans/notes/2026-05-26-graph-P2-plan-review.json
```

- [ ] **Step 15.3: Land all task commits**

By the time you reach this step, Tasks 1–14 should each have produced a standalone commit. Verify the branch log:

```bash
git log --oneline graph-p1..feat/graph-P2
```
Expected: ~14 commits, each scoped to one task. If a task was split across two commits, that's fine — but the branch must have no uncommitted changes.

```bash
git status --short
```
Expected: clean.

- [ ] **Step 15.4: Bump version from `1.3.0-rc.0` to `1.3.0`**

Edit `package.json` — change `"1.3.0-rc.0"` to `"1.3.0"`. Commit standalone:

```
chore(graph): promote 1.3.0-rc.0 -> 1.3.0 for P2 ship
```

- [ ] **Step 15.5: Push the branch**

```bash
git push -u origin feat/graph-P2
```
Auto-review fires on the push (chokepoint). If it denies, fix the cited rule and re-push.

- [ ] **Step 15.6: Open PR**

Write PR body to `/tmp/pr-body-p2.md`:

```markdown
# P2: Incremental refresh + multi-language extractors

Closes the P2 row of `docs/specs/2026-05-26-codegraph-style-graph-design.md` §4.

## Ships
- `refresh` CLI verb with two-phase reverse-import closure transaction (spec §3.1).
- `PostToolUse:Write|Edit|MultiEdit` dirty-queue hook.
- `SessionStart` sweep with git filesethash + rowid-stride sampling.
- Python, Go, Rust extractors with per-language fixture packs meeting P≥0.85, R≥0.70.
- `trace`, `impact`, `context` query verbs.
- Perf gate: 10k-file build < 60s, warm callers p95 < 1s (opt-in via `SSPOWER_GRAPH_PERF=1`).

## Branch policy
- Branched off `main` (= `graph-p1` + docs sync).
- 14 task commits + version bump.
- Codex plan-review verdict: see `docs/plans/notes/2026-05-26-graph-P2-plan-review.json`.

## Acceptance
- `bun x vitest run __tests__/graph-fixtures/` — 5 packs green (ts-js, ts-js-multifile, python, go, rust).
- All graph + hook tests green on the branch.
- Live demo on this repo: `callers acquire_lock` returns the two Python helper call sites.
- Perf: M-series build = <REPORT>, callers p95 = <REPORT>.

## Out of scope (P3+)
MCP tool expansion, graph-orchestrator hook, auto-review enrichment, framework routes.
```

Then:

```bash
gh pr create --title "feat(graph): P2 incremental refresh + multi-language extractors" --body-file /tmp/pr-body-p2.md --base main --head feat/graph-P2
```

- [ ] **Step 15.7: Wait for review verdict**

Auto-review fires on `gh pr create` and `gh pr ready`. If verdict is `request-changes` or fewer findings remain, address them in fresh commits on the branch and push.

- [ ] **Step 15.8: Tag and merge**

When the PR is approved AND the human signs off:

```bash
git checkout main
git pull --ff-only origin main
gh pr merge feat/graph-P2 --merge --delete-branch
git pull --ff-only origin main
git tag -a graph-p2 -m "P2: refresh + multi-language + trace/impact/context"
git push --tags
```

- [ ] **Step 15.9: Update handoff**

Edit `docs/handoff.md` to:
- Mark P2 as `Completed (P2 — merged to main)` with the merge SHA.
- Move the "In Progress" section to P3 (MCP tool expansion: `callers`, `callees`, `node`, `trace`, `impact`, `context`, `routes` exposed as MCP tools; subagent .md updates; adoption metric).
- Update `Resume Here` to point at the P3 plan (`docs/plans/2026-05-26-codegraph-graph-P3.md`, to be written by `sspower:writing-plans`).

Commit + push standalone:
```
docs(handoff): P2 shipped to main — point at P3 scope
```

- [ ] **Step 15.10: Worktree cleanup**

```bash
git worktree remove ../sspower-graph-P2
git branch -d feat/graph-P2  # already deleted by `gh pr merge`; harmless if it complains
```

---

## Spec coverage matrix

| Spec section | Task |
|---|---|
| §3.1 schema (files/nodes/edges/imports/FTS5) | P1 (no change) |
| §3.1 dirty file format (JSONL) | Task 2 (reader) + Task 6 (writer/hook) |
| §3.1 fixed-point reverse-import closure with op tracking | Task 3 |
| §3.1 two-phase transaction body | Task 4 |
| §3.1 H2* dedupe + stat reconcile | Task 2 |
| §3.1 K1 closure walks imports ∪ edges | Task 3 |
| §3.2 extraction pipeline pattern | P1 (TS/JS) + Task 9 (Py) + Task 10 (Go) + Task 11 (Rs) |
| §3.3 accuracy fixture suite (P≥0.85, R≥0.70 per language) | Tasks 9/10/11 + Task 13 sweep |
| §3.5 graph-mark-dirty.sh hook | Task 6 |
| §3.5 hooks.json wiring | Task 6 |
| §3.5 graph-with-lock.py / graph-append-dirty.py | P0 (reused unchanged) |
| §3.5 SessionStart sweep — filesethash + rowid sampling | Task 7 |
| §3.5 session-refresh detached worker | Task 7 |
| §3.6 CLI: refresh | Task 5 |
| §3.6 CLI: trace, impact, context | Task 12 |
| §3.6 CLI: build, callers, callees, node, status, serve --mcp | P0/P1 (no change) |
| §4 P2 row: 10k-file build < 60s | Task 14 |
| §4 P2 row: warm callers p95 < 1s | Task 14 |
| §4 P2 row: per-language fixtures pass | Tasks 9/10/11 + 13 |
| §5 known limit: stale index | Task 7 (SessionStart catches external edits) |
| §5 known limit: refresh thrash | Task 4 (>500 dirty → full rebuild) |
| §6 risk: ast-grep grammar gaps per language | Tasks 9.1/10.1/11.1 probes |

---

## Self-review checklist

1. **Spec coverage:** Every §3.1/§3.5/§3.6/§4 P2 sub-bullet maps to a task above. ✓
2. **Placeholder scan:** No `TBD`, no `implement later`, no `add appropriate error handling`. Every step has either exact code, exact commands, or a precise structural recipe with the contract from the existing codebase. ✓
3. **Type consistency:** `refresh({ rootDir, graphDir, log })` matches `build({ rootDir, graphDir, log })`. `extractFile({ absPath, source, language })` is the contract for every per-language extractor. `resolveModule(importerAbs, moduleSpec, language)` is the dispatch contract. `reverseImportClosure({ db, seed, fileCount })` shape is consistent across Task 3 and Task 4 callers. ✓
4. **Order of operations:** Tasks 2/3 produce the modules consumed by Task 4. Task 4 produces refresh.mjs consumed by Task 5 (CLI). Task 5 stubs the verbs Task 7 (session-refresh) and Task 12 (trace/impact/context) replace later. Tasks 9/10/11 land each language separately so a per-language failure doesn't block the others. Task 14 (perf) runs against the full multi-language build. ✓
5. **Git chokepoint discipline:** Every commit step is a standalone `git commit -F <file>` invocation. No `&&`/`||`/`;` chained around `git commit` or `git push`. ✓
6. **Lock contract:** `refresh` re-execs through `graph-with-lock.py` exactly like `build`. The fall-through to full rebuild re-acquires the lock for the build path. `truncateDirty` happens inside the same lock window. ✓
7. **Fail-OPEN posture:** PostToolUse hook never aborts a user edit on indexing failure. SessionStart sweep failures land in a log file, never stop session start. ✓
8. **Engine floor:** No regressions on the Node ≥22.5 gate from P1. `node:sqlite` is used the same way as P0/P1. ✓
9. **No new runtime deps:** Only existing deps are referenced (`@modelcontextprotocol/sdk` for MCP, `vitest` for tests). The perf bench uses `process.hrtime.bigint()` — built-in. ✓
10. **Out-of-scope discipline:** MCP tools beyond `graph_status`, framework routes, `graph-orchestrator.sh`, and `auto-review.sh` enrichment are explicitly deferred to P3/P4/P5+. ✓

---

## Commit attribution rule (Codex-worker constraint)

The plan-review surfaced a load-bearing constraint encoded in `sspower`'s AGENTS instructions: **the Codex worker MUST NOT run `git commit`, `git push`, or `git merge`.** That constraint applies any time a task is delegated through `scripts/codex-bridge.mjs implement --write` (or any Codex-driven implementation surface).

Apply this to every "Step N.x: Commit" block in this plan:

- When the supervisor (Claude Code main session, OR a human operator) executes the task: stage files and run `git commit -F <msg-file>` as written.
- When Codex executes the task via `implement --write`: leave the changes uncommitted on the worktree. Codex writes the commit message to the same `/tmp/commit-msg-p2-N.txt` path but does NOT invoke `git commit`. The supervisor then reviews the diff, runs the commit, and proceeds to the next task.

This preserves the auto-review chokepoint contract (commits stay supervisor-driven) and avoids the failure mode where Codex's read-only sandbox rejects the commit step mid-task.

---

## Execution handoff

**Plan complete. Recommended execution strategy (revised after Codex plan-review):**

**Hybrid path — inline first, then parallel subagents, then sequential gate:**

1. **Tasks 1–8 (inline)** → `sspower:executing-plans`. These tasks establish shared contracts (dirty queue → closure → refresh transaction → CLI → hook → session-refresh → walker/build/resolve plumbing) that every later task depends on. Sequential execution avoids contract drift across parallel agents.
2. **Tasks 9–11 (serial fresh agents)** → run Python, then Go, then Rust as three SEPARATE fresh subagent or Codex `implement --write` invocations, one at a time. The three extractors share zero state, but the `subagent-driven-development` skill explicitly forbids parallel implementation subagents — so the parallelism stays at the language boundary (one fresh agent per language), not at the implementation surface. Each agent owns one extractor + rule files + fixture pack + harness wiring entry. They converge at the harness loop in `__tests__/graph-fixtures/harness.test.ts`, which Task 13 ratifies. If true parallel execution is required to hit a deadline, create three additional worktrees off `feat/graph-P2` and treat the per-worktree parallel runs as an explicit override to the skill — document the override in the merge commit.
3. **Tasks 12–15 (sequential gate)** → `sspower:executing-plans`. Task 12 (trace/impact/context) is small and benefits from the freshly merged extractor results in cache. Task 13 (regression sweep) is a pure gate. Task 14 (perf) takes ~30s of wall time and must run end-to-end. Task 15 (review + PR + merge) is a single critical path.

**Other options retained for reference:**

- **Pure inline** → `sspower:executing-plans` for all 15 tasks. Lower coordination overhead; appropriate when you want a tight test-feedback loop on every task.
- **Codex delegate** → `codex-bridge.mjs implement --write` per task. Honors the "Commit attribution rule" above — Codex leaves commits to the supervisor. Useful for the well-bounded extractor tasks (9/10/11) when the supervisor wants to offload bulk shell work.

**Which approach?**
