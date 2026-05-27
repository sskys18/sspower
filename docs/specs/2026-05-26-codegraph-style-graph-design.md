# Codegraph-style Symbol Graph for sspower — Design Spec

> Status: **APPROVED v5 with followups** (2026-05-26). Author: Claude (Opus 4.7).
> v0→v5 plan-review trend: 12→7→6→8→5→4 findings.
> v5 = `approve-with-followups` (3M + 1L, all inline-fixed in v5.1; see §17).
> Implementation may begin from this spec; followups are inline-resolved.
> Topic: add cached call-graph + framework-route intelligence to sspower,
> exposed as CLI + MCP + hook injection, built on ast-grep primitives.
> Adjacent: `2026-05-19-semble-rewrite-ownership-design.md`,
> `2026-05-13-index-backend-integration-design.md` (both unrelated; cited
> for hook-chaining / spec-process precedent only).

## 0. Why now (unchanged from v0)

semble_rs gives orientation + embedding search; tokens-saved counter shows
~16.6M saved all-time [High]. Gaps:

1. **No cached symbol-level call graph** — `find-pattern` is on-demand
   ast-grep; every prompt re-pays the cost.
2. **No MCP surface for sub-agents** — only the main thread sees hook
   injection. `code-reviewer`, `sanity-reviewer`, `security-reviewer`
   sub-agents must re-discover via grep/Read.

Codegraph (MIT) closes both but bundles a parallel Node/SQLite/tree-sitter
stack and forces a per-project `codegraph init`. This spec: smaller,
sspower-native, with codegraph anti-goal circuit-breaker (§1, §6).

## 1. Goals / non-goals / success criteria

### Goals
- `sspower-graph` CLI: `build`, `refresh`, `callers`, `callees`, `trace`,
  `routes`, `context`, `impact`, `node`, `serve --mcp`, `status`.
- Per-project SQLite cache `<cwd>/.claude/graph/index.sqlite`.
- MCP stdio server wired via **`.mcp.json` at plugin root** (verified
  pattern; see §3.4 evidence). Tool namespace `mcp__sspower-graph__*`.
- Hook injection: one **orchestrator hook** runs semble + graph concurrently
  under shared timeout (§3.5). No "parallel race" between sibling hooks.
- Incremental refresh via PostToolUse:Write|Edit|MultiEdit + SessionStart sweep.
- Accuracy fixture suite landed in **P0** (not deferred).

### Non-goals
- Replacing semble_rs embedding search. Keep.
- Type-resolved dispatch. Documented ceiling = same as codegraph (§5).
- Cross-repo, cross-language graphs.
- Bundled installer for non-sspower users.
- Vendoring codegraph's Node runtime. We borrow tree-sitter / ast-grep
  patterns only, not their resolution/ TypeScript code.

### Success criteria (measurable, distinct from speed-only)

| Metric | Target | Phase gate |
|---|---|---|
| **Precision** on accuracy fixture suite | ≥ 0.85 per language | P1 (TS/JS), P2 (Python+Go+Rust), P5+ (per framework). P0 ships fixtures + harness only — no extractor to measure against. |
| **Recall** on accuracy fixture suite | ≥ 0.70 per language | same as precision |
| Initial `build` on 10k-file repo | < 60s p95 | P2 |
| Warm `callers <symbol>` | < 1s p95 | P2 |
| Sub-agent MCP tool adoption (code-reviewer, sanity-reviewer, security-reviewer) | ≥ 1 graph tool call per session in 50-session sample | P3 |
| Hook injection size (graph contribution) | ≤ 1.5KB additionalContext | P4 |
| Head-to-head **token-budget delta** vs `semble_rs plan` alone | net positive on 20-prompt eval set | P4 |
| New external deps (P0–P2) | 3 = ast-grep ≥0.43 (brew), `@modelcontextprotocol/sdk` (npm), `vitest` (npm devDep). Updated from "1" after v2 review identified MCP server can't be hand-rolled cheaply and fixture suite needs a test runner. | P0 |
| Sub-agent contracts changed | code-reviewer.md, sanity-reviewer.md, security-reviewer.md tool lists updated | P3 |

### Anti-goal flag (sunk-cost circuit-breaker)
If P3 (MCP packaging + sub-agent integration) exceeds **2 weeks of effort**,
STOP. Ship `codegraph install` as optional companion via sspower installer.
Don't sink-cost a MIT-licensed product rebuild.

## 2. Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  USER PROMPT  ──► UserPromptSubmit hook (sspower)                │
│    semble-context.sh                  (existing)                 │
│    graph-orchestrator.sh (NEW)        runs semble + graph        │
│        concurrently, single timeout, merged additionalContext    │
├──────────────────────────────────────────────────────────────────┤
│  CLAUDE + SUB-AGENTS ──► MCP stdio (NEW: sspower-graph)          │
│  Tools: graph_callers, graph_callees, graph_trace, graph_routes, │
│         graph_context, graph_impact, graph_node, graph_status    │
├──────────────────────────────────────────────────────────────────┤
│  PreToolUse:Bash ──► auto-review.sh                              │
│    NEW: include graph index version-hash in cache key (F9).      │
│    Enrichment runs on cache miss only; reads graph_impact for    │
│    each changed file extracted from diff.                        │
├──────────────────────────────────────────────────────────────────┤
│  PostToolUse:Write|Edit|MultiEdit ──► graph-mark-dirty.sh (NEW)  │
│    Atomic-append normalized path; dedupe; handle rename/delete   │
├──────────────────────────────────────────────────────────────────┤
│  SessionStart ──► session-start hook                             │
│    NEW: if dirty non-empty AND age > 5min, async refresh         │
├──────────────────────────────────────────────────────────────────┤
│  Storage:  <cwd>/.claude/graph/                                  │
│            ├── index.sqlite       (WAL mode, see §3.1)           │
│            ├── dirty              (newline-delimited, locked)    │
│            ├── version            (schema + ast-grep version)    │
│            └── .lock              (flock(1) write-lock)          │
└──────────────────────────────────────────────────────────────────┘
```

Single-hook orchestration (F4): UserPromptSubmit hooks run sequentially in
`hooks/hooks.json` (verified — all `async:false`, see `2026-05-19-semble-rewrite-ownership-design.md`).
We do NOT add a sibling hook. Instead, **`graph-orchestrator.sh` replaces
the semble-context call site**, forks two child processes (`semble_rs plan`
+ `sspower-graph context`), waits with shared timeout, merges output, emits
once. Old `semble-context.sh` becomes a backend invocation under the
orchestrator.

## 3. Component contracts

### 3.1 Index schema (revised per F7)

```sql
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE files (
  path            TEXT PRIMARY KEY,
  content_hash    TEXT NOT NULL,
  language        TEXT NOT NULL,
  indexed_at      INTEGER NOT NULL,
  node_count      INTEGER DEFAULT 0
);
CREATE TABLE nodes (
  id              TEXT PRIMARY KEY,            -- stable: <file>#<qualname>#<span_sha8>
  kind            TEXT NOT NULL,               -- function|method|class|route|module
  name            TEXT NOT NULL,
  qualified_name  TEXT NOT NULL,
  file_path       TEXT NOT NULL REFERENCES files(path) ON DELETE CASCADE,
  language        TEXT NOT NULL,
  start_line      INTEGER NOT NULL,
  end_line        INTEGER NOT NULL,
  signature       TEXT,
  span_sha8       TEXT NOT NULL,               -- first 8 hex of sha256(span text)
  updated_at      INTEGER NOT NULL
);
CREATE TABLE edges (
  source          TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
  target          TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
  kind            TEXT NOT NULL,               -- calls|references|routes|implements
  line            INTEGER,
  confidence      INTEGER NOT NULL,            -- 0=ambiguous-name 1=intra-file 2=imported
  PRIMARY KEY (source, target, kind, line)
);
CREATE TABLE imports (                         -- reverse-imports index (G3)
  importer_path   TEXT NOT NULL REFERENCES files(path) ON DELETE CASCADE,
  imported_path   TEXT NOT NULL,                -- resolved abs path; may be ext lib
  PRIMARY KEY (importer_path, imported_path)
);
CREATE INDEX idx_imports_imported ON imports(imported_path);

CREATE INDEX idx_nodes_name        ON nodes(name);
CREATE INDEX idx_nodes_qname       ON nodes(qualified_name);
CREATE INDEX idx_nodes_file        ON nodes(file_path);
CREATE INDEX idx_edges_target_kind ON edges(target, kind);

-- FTS with sync triggers (F7 fix)
CREATE VIRTUAL TABLE nodes_fts USING fts5(name, qualified_name, signature,
                                          content='nodes', content_rowid='rowid');
CREATE TRIGGER nodes_ai AFTER INSERT ON nodes BEGIN
  INSERT INTO nodes_fts(rowid, name, qualified_name, signature)
  VALUES (new.rowid, new.name, new.qualified_name, new.signature);
END;
CREATE TRIGGER nodes_ad AFTER DELETE ON nodes BEGIN
  INSERT INTO nodes_fts(nodes_fts, rowid, name, qualified_name, signature)
  VALUES('delete', old.rowid, old.name, old.qualified_name, old.signature);
END;
CREATE TRIGGER nodes_au AFTER UPDATE ON nodes BEGIN
  INSERT INTO nodes_fts(nodes_fts, rowid, name, qualified_name, signature)
  VALUES('delete', old.rowid, old.name, old.qualified_name, old.signature);
  INSERT INTO nodes_fts(rowid, name, qualified_name, signature)
  VALUES (new.rowid, new.name, new.qualified_name, new.signature);
END;
```

**Refresh transaction contract (G2, G3, H1, H2 fix):**

**Dirty file format** (H2 fix, H2* tighten): newline-delimited JSON (JSONL).
Each line is one of:
```
{"op":"upsert","path":"/abs/path/foo.ts"}
{"op":"delete","path":"/abs/path/bar.ts"}
```
No legacy text prefixes anywhere (the v2 `D <path>` form is REMOVED from
§3.5 below — H2* fix). The PostToolUse hook emits one line per dirtied
file; refresh reads with `jq -c .` per line. The `op` is parsed BEFORE
closure expansion. Dedupe rule: when multiple records share the same
normalized `path`, the LAST record wins, then refresh `stat()`s the path
immediately before applying — a `delete` for an existing file degrades to
`upsert`, and an `upsert` for a missing file degrades to `delete`.

**Fixed-point reverse-import closure with op tracking (H1, H1* fix):**

The seed has ops `upsert` or `delete` from the dirty file. Reverse importers
discovered during closure get a NEW op = `relink` — they need their outbound
edges re-resolved but NOT their nodes deleted.

```
op_for[path] = op   # from dirty JSONL, only for seed paths
working = ∅
queue = seed.keys()
WHILE queue non-empty:
  P = queue.pop()
  IF P ∈ working: continue
  working.add(P)
  # K1 fix: closure walks BOTH imports AND existing edges (the edges table
  # is the source of truth for what cascades on node delete). The imports
  # table alone misses ambiguous-name + route + implements edges that have
  # no import provenance.
  reverse_paths = SELECT importer_path FROM imports WHERE imported_path=P
  reverse_paths ∪= SELECT DISTINCT src.file_path
                     FROM edges
                     JOIN nodes src ON edges.source = src.id
                     JOIN nodes tgt ON edges.target = tgt.id
                     WHERE tgt.file_path = P
  FOR each I in reverse_paths:
    IF I ∉ working:
      IF I ∉ op_for: op_for[I] = "relink"
      queue.push(I)
# Bound: working ≤ |files|. Cycles converge: each file enters working
# at most once (visited-set semantics). Cost: O(E_imports + E_edges) over
# reverse traversals.
# Safety cap: if |working| > 0.5 × |files|, fall through to full rebuild.
```

**Transaction body (H1* relink action):**
```
BEGIN IMMEDIATE;
  -- Phase 1a: deletes first (frees inbound edges that would otherwise survive).
  FOR each P WHERE op_for[P]=delete:
    DELETE FROM files WHERE path=P;            -- cascades to nodes, imports.importer
    DELETE FROM imports WHERE imported_path=P; -- imported_path is not FK (intentional)
  -- Phase 1b: rebuild upserts.
  FOR each P WHERE op_for[P]=upsert:
    DELETE FROM nodes WHERE file_path=P;       -- cascades outbound + inbound edges
    DELETE FROM imports WHERE importer_path=P;
    INSERT OR REPLACE INTO files VALUES (P, hash, lang, now(), count);
    INSERT nodes from extraction (P);
    INSERT imports from extraction (P);
  -- Phase 1c: relink targets — nodes UNCHANGED, only outbound edges rebuilt.
  FOR each P WHERE op_for[P]=relink:
    DELETE FROM edges WHERE source IN
      (SELECT id FROM nodes WHERE file_path=P);  -- drop only outbound edges
    -- (nodes, imports rows for P stay; they are still valid for THIS file)
  -- Phase 2: re-resolve edges for both upsert AND relink.
  FOR each P WHERE op_for[P] IN (upsert, relink):
    INSERT edges from extraction (P), using fresh `imports` table for
    cross-file lookups.
COMMIT;
```

Convergence proof sketch (H1*-corrected): every node deletion happens to
files with `op=upsert` or `op=delete`. Reverse importers get `op=relink`,
which deletes only their outbound edges (no node deletion). Phase 2
re-emits edges for both `upsert` and `relink` files using the freshly
rebuilt `imports` table. An edge F1→F2 survives iff (a) F2 exists post-
transaction, AND (b) F1 is in `working` (so it's either `upsert` or
`relink`) OR F1 is outside `working` (so its edges were never deleted).
Edge loss requires F1 NOT in `working` AND F2 deleted — impossible because
F2 in `delete` set would have been imported by F1, and F1 would have been
discovered via reverse-imports.
Locks: Python `fcntl.flock` on `<cwd>/.claude/graph/.lock` via the safe
`sspower_mem.lock.acquire_lock` helper (M1*/M2* — single lock contract;
no shell `flock(1)` anywhere in the write path). Readers use WAL —
never blocked.

### 3.2 Extraction pipeline (revised per F1)

**Hard dep, verified P0:**
- `ast-grep ≥ 0.43` (verified `brew install ast-grep` → `/opt/homebrew/bin/ast-grep`, JSON output via `--json=compact` returns per-match `{file, range.start.line, range.end.line, metaVariables.single.NAME.text, ...}`)
- `sqlite3 ≥ 3.40` (verified system has 3.51 + FTS5)
- `semble_rs ≥ 0.9` (already installed)

We call **ast-grep directly**, NOT through `semble_rs find-pattern`. Reason:
semble_rs is a thin wrapper that aborts when ast-grep is missing, has no
`--json` flag of its own, and adds no value over direct invocation for the
indexing path. semble_rs stays as the search/plan backend (different role).

Per-file extraction sequence (P1 target = TS/JS first):
```
1. ast-grep run -p '<lang-fn-pattern>' --lang typescript --json=compact <file>
   → list of {name, line range, signature_via_range}
2. For each function/method node, ast-grep run -p '$IDENT($$$)' --lang typescript
   --json=compact <file> within line range  (post-filter on byteOffset)
   → call-site identifiers
3. Resolve callee → node_id:
   a) Intra-file lookup by exact qualified_name (confidence=1)
   b) Cross-file lookup by import-aware resolution:
      - parse imports from file (separate ast-grep pass for `import` patterns)
      - resolve identifier to module; lookup nodes WHERE file_path=resolved_path
        AND name=ident (confidence=2)
   c) Else: same-name lookup across all nodes (confidence=0, "ambiguous")
4. Insert edges. Ambiguous (confidence=0) edges are PRESERVED but flagged
   in API response so callers can choose to ignore.
```

### 3.3 Accuracy fixture suite (revised per F8 — moved to P0)

`__tests__/graph-fixtures/` ships in P0 with cases:
- TS/JS: imports, aliases, default exports, JSX handlers, arrow functions,
  method shorthand, class methods with shadowed names
- Python: local shadowing, `getattr`, class methods with identical names
  across classes, `from X import Y as Z`
- Go: method receivers, package-level vs file-level scope
- Rust: `impl` blocks, trait methods, `use` aliases
- Routes: Express `app.get`, FastAPI `@app.get`, Django `path(...)`,
  Rails `get '/x', to: 'c#a'`

For each fixture, golden `expected.json` lists ground-truth caller/callee
pairs. CI runs `vitest run __tests__/graph-fixtures/`. **P0 gate:**
fixtures + harness present and runnable (goldens-only mode passes).
**P1 gate:** precision ≥ 0.85, recall ≥ 0.70 on TS/JS fixtures (once
extractor lands). P2/P5+ phase-gated per-language and per-framework.

Ambiguous-name handling: `callers <name>` returns **disambiguation list**
when ≥2 nodes match by name, not a single blended graph.

### 3.4 MCP packaging (revised per F5, verified pattern)

Evidence — Claude Code plugin MCP precedent (live filesystem inspection,
2026-05-26):

| Plugin | File | Shape |
|---|---|---|
| `context7` | `.mcp.json` at plugin root | `{"context7": {"command": "npx", "args": [...]}}` |
| `discord` | `.mcp.json` at plugin root | `{"mcpServers": {"discord": {"command": "bun", "args": ["...", "${CLAUDE_PLUGIN_ROOT}", ...]}}}` |
| `terraform`, `gitlab`, `linear` | `.mcp.json` at plugin root | same shape |

**Our `.mcp.json` (plugin root, sibling of `.claude-plugin/`, K3 fix —
direct `node` cannot resolve `@modelcontextprotocol/sdk` on a fresh
install; need a bootstrap that lazily installs deps before launching):**
```json
{
  "mcpServers": {
    "sspower-graph": {
      "command": "${CLAUDE_PLUGIN_ROOT}/bin/sspower-graph-bootstrap.sh",
      "args": ["serve", "--mcp"]
    }
  }
}
```
`bin/sspower-graph-bootstrap.sh` (~15 LOC):
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
# Lazy install on first run; idempotent + offline if cache is warm.
# Marker file avoids the npm cost on every spawn.
if [ ! -d "$ROOT/node_modules/@modelcontextprotocol" ]; then
  npm install --omit=dev --no-audit --no-fund --silent --prefer-offline \
    >/dev/null 2>&1 || npm install --omit=dev --no-audit --no-fund --silent
fi
exec node "$ROOT/bin/sspower-graph.mjs" "$@"
```
Pattern matches `fakechat` precedent (its `start` script does
`bun install --no-summary && bun server.ts`). The marker check makes
steady-state launches no-op fast. Offline-cache preference keeps
network-isolated installs working when deps are already in `~/.npm`.

**MCP server implementation (H3 fix):** use `@modelcontextprotocol/sdk`
(official, MIT, npm). Hand-rolling JSON-RPC + Content-Length framing +
`initialize`/`tools/list`/`tools/call` was the original plan; v2 review
flagged this is ~200+ LOC of error-prone protocol work. SDK collapses it
to ~30 LOC. Updated dep budget (§1, success criteria): "3 = ast-grep, sdk,
vitest" — explicitly tracked.

Minimal P0 stub server (H3* — corrected SDK API, verified against
`@modelcontextprotocol/sdk` examples in the `fakechat` plugin in this
marketplace):
```js
// bin/sspower-graph.mjs (P0: only graph_status; expands in P1+)
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';

const server = new Server(
  { name: 'sspower-graph', version: '0.0.1' },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [{
    name: 'graph_status',
    description: 'Graph index freshness',
    inputSchema: { type: 'object', properties: {}, required: [] }
  }]
}));

server.setRequestHandler(CallToolRequestSchema, async ({ params }) => {
  if (params.name === 'graph_status') {
    return { content: [{ type: 'text',
                          text: JSON.stringify({ ok: true, stub: true }) }] };
  }
  throw new Error(`unknown tool: ${params.name}`);
});

await server.connect(new StdioServerTransport());
```

Smoke test (H3* — real MCP client harness, NOT bg-process+pipe which
doesn't work with stdio transport): `tests/graph/test-mcp-stub.mjs`
spawns the server as a child process and uses `StdioClientTransport`:
```js
// tests/graph/test-mcp-stub.mjs (smoke test goes through bootstrap.sh —
// covers the K3 fresh-install code path, NOT direct node)
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import assert from 'node:assert/strict';
import path from 'node:path';

const pluginRoot = process.env.CLAUDE_PLUGIN_ROOT
  ?? path.resolve(import.meta.dirname, '..', '..');
const transport = new StdioClientTransport({
  command: path.join(pluginRoot, 'bin', 'sspower-graph-bootstrap.sh'),
  args: ['serve', '--mcp'],
  env: { ...process.env, CLAUDE_PLUGIN_ROOT: pluginRoot }
});
const client = new Client({ name: 'smoke', version: '0' }, { capabilities: {} });
await client.connect(transport);

const tools = await client.listTools();
assert.equal(tools.tools[0].name, 'graph_status');

const result = await client.callTool({ name: 'graph_status', arguments: {} });
const payload = JSON.parse(result.content[0].text);
assert.equal(payload.ok, true);
assert.equal(payload.stub, true);

await client.close();
console.log('OK');
```
Run: `node tests/graph/test-mcp-stub.mjs`. Step 1-3 of v3's spec is
replaced by this single executable assertion. Plus a separate Claude Code
integration test: install plugin in fixture, restart, ask sub-agent to
call `mcp__sspower-graph__graph_status`. If the Node-client smoke passes
but the Claude smoke fails, manifest discovery is the issue → STOP and
investigate before P3.

### 3.5 Hook contracts (revised per F3, F4, F10)

**`hooks/_intent.sh` extension (P0):** new class `architecture`.
- Classifies prompts starting with "how does X reach", "what calls",
  "where is X used", "trace X", "callers of", "callees of",
  "show the path", "어떻게" + 함수명 패턴.
- Stays distinct from `qa` (no read-only suppression) and from
  `simple-coding`/`multi-step` (no coding-skill route).

**`hooks/graph-orchestrator.sh` (UserPromptSubmit, REPLACES `semble-context.sh` invocation site):**
```bash
# Single orchestrator hook; fires for coding-intent OR architecture-intent.
# Forks two children with EXTERNAL timeout wrappers (G5 — semble_rs has
# no --timeout flag; we use `timeout`/`gtimeout`/Perl alarm pattern from
# semble-context.sh:80-93):
#   timeout 4s semble_rs plan "<prompt>" "<cwd>" --json
#   timeout 4s sspower-graph context "<prompt>" --cwd <cwd> --json
# wait with overall 6s budget; merge results; cap combined at 4KB.
# Emits ONE additionalContext block. Fail-open like semble-context.sh.
```
`semble-context.sh` retained as the semble-only fallback when graph index
absent. Decision: do not delete it in P4 — it's the fallback.

**`hooks/graph-mark-dirty.sh` (PostToolUse:Write|Edit|MultiEdit):**
- Matchers verified against existing `hooks/hooks.json` (Write|Edit|MultiEdit pattern in use today).
- Read `tool_input.file_path` (Write/Edit) OR iterate `tool_input.edits[].file_path` (MultiEdit).
- For each: normalize to absolute path; if outside `cwd`, skip; if file
  no longer exists, emit `{"op":"delete","path":"..."}`; else
  `{"op":"upsert","path":"..."}` (H2* — no text prefixes, JSONL only).
- Atomic append (G6 + M1 + M1* fix — `flock(1)` not on macOS verified;
  M1* — symlink-attack defense via the existing `sspower_mem/lock.py`
  pattern, not a hand-rolled helper). The graph dirty append uses the
  **same** safe-lock pattern as `scripts/sspower_mem/sspower_mem/lock.py`:
  `_open_lock_file` walks the path with `O_DIRECTORY|O_NOFOLLOW`,
  validates anchored-relative components against traversal, opens the
  lock file with `O_NOFOLLOW|O_CREAT|O_RDWR|O_NONBLOCK` mode `0600`, and
  asserts regular-file via `_assert_regular_private_file`. The graph
  helper imports from `sspower_mem.lock`:
  ```python
  # scripts/graph-append-dirty.py (~25 LOC; reuses existing safe lock)
  import argparse, json, os, pathlib, sys
  sys.path.insert(0, os.path.join(os.environ["CLAUDE_PLUGIN_ROOT"],
                                  "scripts", "sspower_mem"))
  from sspower_mem.lock import acquire_lock
  from sspower_mem.io import safe_makedirs_strict, safe_append_strict

  ap = argparse.ArgumentParser()
  ap.add_argument("--graph-dir", required=True)
  ap.add_argument("--op", required=True, choices=["upsert","delete"])
  ap.add_argument("--path", required=True)
  args = ap.parse_args()

  graph_dir = pathlib.Path(args.graph_dir).resolve()
  trust_root = graph_dir.parent.parent          # <cwd> as anchor
  safe_makedirs_strict(graph_dir, trust_root, mode=0o700)
  lock_path  = graph_dir / ".lock"
  dirty_path = graph_dir / "dirty"
  record = json.dumps({"op": args.op, "path": args.path}) + "\n"

  with acquire_lock(lock_path, parent_anchor=trust_root):
      safe_append_strict(dirty_path, record, trust_root=trust_root)
  ```
  Refresh (`sspower-graph refresh`) runs inside a Python wrapper that
  holds `acquire_lock` for the entire critical section (K2 fix — a
  short-lived Python helper exits and releases `fcntl.flock` immediately,
  defeating the purpose). The wrapper is `scripts/graph-with-lock.py`:
  it parses `--graph-dir` and a trailing command list, acquires the lock
  via the same `sspower_mem.lock.acquire_lock` context manager, runs the
  child command with `subprocess.run(argv_list, env=os.environ)` (list
  form — no shell), and propagates the child's exit code on context
  release. Refresh invocation:
  ```bash
  python3 "$CLAUDE_PLUGIN_ROOT/scripts/graph-with-lock.py" \
    --graph-dir "$CWD/.claude/graph" -- \
    node "$CLAUDE_PLUGIN_ROOT/bin/sspower-graph.mjs" refresh-unlocked
  ```
  The Node binary exposes `refresh-unlocked` (skips lock acquisition; caller
  is responsible). The user-facing `sspower-graph refresh` is a shell shim
  that delegates to `graph-with-lock.py` with proper args. Single lock
  owner (Python) brackets the SQLite transaction (Node) end-to-end. Append
  uses the same helper independently — both contend on the same lock file.
- Refresh dedupes by path before processing.

**`hooks/auto-review.sh` modifications (per F9):**
- Cache key revised: `DIFF_HASH || GRAPH_VERSION || GRAPH_HASH` (where
  `GRAPH_VERSION` = schema rev, `GRAPH_HASH` = sha8 of
  `<cwd>/.claude/graph/version`). If graph absent, omit terms (cache stays
  diff-only — pre-graph behavior preserved).
- Enrichment runs **only on cache miss**: extract changed files from diff
  → `sspower-graph impact <file> --json --timeout 3s` per file (parallel,
  cap 8 files) → append condensed text to Codex prompt under `# Graph
  impact` header. Skip silently on per-file timeout.

**`hooks/session-start` (existing, modified, M3 + M3* + M4* fix):**
- After other init steps, **one detached worker** runs:
  `sspower-graph session-refresh --max-time 5s &`. The CLI subcommand
  chains scan + refresh under one process so detected edits land before
  the next user action (M3* — v3 had scan and refresh as separate
  detached tasks, with detected changes only applied on the next trigger).
  Algorithm:
  ```python
  # Step 0: NEW-FILE detection via git index hash (followup-3 fix).
  # Sampling alone misses files that exist on disk but have no `files` row.
  # Cheap proxy: SHA8 of `git ls-files -z | sha256sum`. Stored in
  # <cwd>/.claude/graph/version line "git_filesethash=<sha>".
  current_hash = sha8(subprocess.run(["git","ls-files","-z"]).stdout
                      + subprocess.run(["git","ls-files","--others","--exclude-standard","-z"]).stdout)
  stored_hash = read_version_field("git_filesethash")
  IF stored_hash != current_hash:
    full_rebuild = true   # set; falls through to build at step 2
    write_version_field("git_filesethash", current_hash)
    # build will re-discover all new files; skip sampling
  ELSE:
    # Step 1: external-edit scan (rowid stride sampling, K4 corrected math)
    import math, random
  total = SELECT COUNT(*) FROM files
  IF total == 0: skip scan (fresh project; nothing to verify)
  sample_size = min(200, total)
  IF total <= sample_size:
    rows = SELECT path, content_hash FROM files ORDER BY rowid
  ELSE:
    stride = max(1, math.ceil(total / sample_size))     # integer math
    offset = random.randrange(stride)                   # 0..stride-1
    rows = SELECT path, content_hash FROM files
           WHERE rowid % ? = ?
           ORDER BY rowid LIMIT ?                       # bind (stride, offset, sample_size)
    # Sparse-rowid retry: if rowids have large gaps, sample may be empty.
    IF len(rows) == 0:
      FOR retry in range(3):                            # try other offsets
        offset = random.randrange(stride)
        rows = SELECT ... WHERE rowid % ? = ? LIMIT ?
        IF len(rows) > 0: break
      IF len(rows) == 0:
        rows = SELECT path, content_hash FROM files
               ORDER BY rowid LIMIT ?                   # final fallback
  changed = 0; full_rebuild = false
  FOR each (path, stored_hash) in rows:
    IF NOT exists(path): emit_dirty(op=delete, path); changed++
    ELSE: disk_hash = sha8(read(path))
          IF disk_hash != stored_hash: emit_dirty(op=upsert, path); changed++
    IF time_elapsed >= max_time: break
  IF len(rows) == 0:                                    # empty after retries
    log "scan-skip: empty sample"; full_rebuild = false
  ELSE:
    divergence_rate = changed / len(rows)
    IF divergence_rate > 0.05 AND len(rows) >= 50:
      full_rebuild = true   # statistically significant sample
  # Step 2: if dirty or full_rebuild, refresh in same worker
  IF full_rebuild: sspower-graph build
  ELIF dirty non-empty: sspower-graph refresh
  ```
  Sampling is rowid-stride (cheap, no `ORDER BY RANDOM()` table-sort).
  Threshold uses actual sample size — divergence_rate is `changed/len(rows)`,
  not `changed/200`. Minimum-sample guard (50) prevents false full-rebuilds
  on tiny projects where one stale file = 100% divergence rate.

### 3.6 `sspower-graph` CLI

```
sspower-graph build [PATH]                  one-shot full index
sspower-graph refresh [PATH]                incremental, reads dirty file
sspower-graph callers <name> [--limit N] [--disambiguate]
sspower-graph callees <name> [--limit N]
sspower-graph trace <from> <to> [--max-hops 6]
sspower-graph routes [--framework F]
sspower-graph impact <file>                 symbol-level + transitive
sspower-graph node <name>                   full source for one symbol
sspower-graph context "<task>"              composed: search + node + callers
sspower-graph serve --mcp                   MCP stdio server
sspower-graph status                        node count, last index time, dirty count
```
All commands accept `--json`, `--timeout <sec>`, `--cwd <path>`.

## 4. Phasing (revised per F11)

| Phase | Ships | Gates passed |
|---|---|---|
| **P0** | (a) ast-grep pinned via brew formula in install docs; (b) `package.json` updated with `engines.node ≥22`, `dependencies.@modelcontextprotocol/sdk`, `devDependencies.vitest`, lockfile generated (H4* fix); (c) `hooks/_intent.sh` `architecture` class shipped + tests; (d) `__tests__/graph-fixtures/` scaffolding (golden JSONs + vitest harness — no extractor; harness exits 0 by reading goldens, fails red once P1 extractor lands and produces mismatching output); (e) MCP stub `bin/sspower-graph.mjs` (~50 LOC, uses `ListToolsRequestSchema`/`CallToolRequestSchema` from `@modelcontextprotocol/sdk/types.js` — H3* corrected SDK API); (f) `tests/graph/test-mcp-stub.mjs` using `StdioClientTransport` (executable MCP smoke); (g) `.mcp.json` at plugin root; (h) `scripts/graph-append-dirty.py` (reuses `sspower_mem.lock`, no symlink-attack surface — M1* fix) | (a)–(c) merged; (d) `vitest run __tests__/graph-fixtures/` exits 0 with goldens-only mode; (e)–(f) `node tests/graph/test-mcp-stub.mjs` prints `OK`; (g) Claude Code integration test: sub-agent in fixture project calls `mcp__sspower-graph__graph_status` and receives `{ok:true,stub:true}` |
| **P1** | TS/JS extractor (ast-grep direct invocation). Schema §3.1. CLI: `build`, `callers`, `callees`, `node`, `status`. Fixture suite (P0 harness) wired to extractor. P1 acceptance target: callers of `cmdImplement` in `scripts/codex-bridge.mjs:1519` (Node fn, verified to exist; G4) | precision ≥0.85 / recall ≥0.70 on TS/JS fixtures; manual run lists callers of `cmdImplement` correctly |
| **P2** | Add Python, Go, Rust extractors. CLI: `trace`, `impact`, `context`, `refresh`. PostToolUse:Write\|Edit\|MultiEdit dirty list. SessionStart sweep. Two-phase refresh (§3.1) verified on test repo. | 10k-file build < 60s; warm callers < 1s p95; per-language fixtures pass thresholds |
| **P3** | Full MCP server (replaces P0 stub). `code-reviewer.md`, `sanity-reviewer.md`, `security-reviewer.md` tool lists updated. `codex-rescue.md` **deferred** (D10). | sub-agent MCP adoption metric (≥1 call per session × 50 sessions) |
| **P4** | `graph-orchestrator.sh` replaces `semble-context.sh` call site. `auto-review.sh` enrichment + cache-key revision. **One framework: Express.** | head-to-head token-budget delta net-positive on 20-prompt eval |
| **P5+** | ~~One framework per phase: FastAPI → Django → Rails → NestJS → Laravel → Spring → Gin → Axum.~~ **DEFERRED INDEFINITELY (2026-05-27).** Native Claude Code LSP plugins (`typescript-lsp`, `rust-analyzer-lsp`, `pyright-lsp`, `gopls-lsp`, `swift-lsp`, `clangd-lsp`, etc., distributed via `claude-plugins-official` marketplace) supersede the symbol-level work the framework extractors were aiming at, AND the user's actual repo corpus (TS/Node + Python tooling, no Rails/Spring/Gin/Axum) makes coverage breadth pay near-zero. See "P5+ kill rationale" below. | n/a |

**P5+ kill rationale (2026-05-27):**
1. **Native LSP supersedes half the graph MCP surface.** Claude Code ships a built-in `LSP` tool with operations `incomingCalls`, `outgoingCalls`, `goToDefinition`, `findReferences`, `workspaceSymbol`, `hover`, `documentSymbol`, `goToImplementation`, `prepareCallHierarchy`. Per-language LSP plugins (`typescript-lsp@claude-plugins-official`, `rust-analyzer-lsp`, `clangd-lsp`, `swift-lsp` — all enabled in `~/.claude/settings.json`; `pyright-lsp`/`gopls-lsp`/`jdtls-lsp`/`ruby-lsp`/`csharp-lsp`/`kotlin-lsp`/`lua-lsp`/`php-lsp` available, one flag away) route the built-in tool to the matching language server. This makes `graph_callers`/`graph_callees`/`graph_node` redundant — LSP is type-resolved where graph is name-resolved with `confidence=0` fallback. Three of four sspower sub-agents (`code-reviewer`, `sanity-reviewer`, `security-reviewer`) inherit the LSP tool by virtue of having no explicit `tools:` whitelist in their frontmatter; `codex-rescue` is the only restricted agent.
2. **Graph's unique value lives in trace/impact/routes/status, not callers/callees.** `graph_trace A B` (call-path BFS), `graph_impact <file>` (precomputed reverse-import closure), `graph_routes` (HTTP route nodes, Express today), and `graph_status` have no LSP equivalent and remain valuable. These are the bulk/aggregate/framework-aware operations LSP does not cover. P4 hook orchestration (`graph-orchestrator.sh` UserPromptSubmit chain + `auto-review.sh` enrichment via `graph_impact`) consumes those specifically and continues to pay off.
3. **Framework breadth pays near-zero against actual corpus.** The 8 backend frameworks listed (FastAPI/Django/Rails/NestJS/Laravel/Spring/Gin/Axum) describe stacks the user does not write code in. Express (P4) was the only one with real coverage potential, and even that is a thin proof-of-concept. Each subsequent extractor = ~1 PR-cycle of effort (~500-1000 LOC ast-grep rules + ~20 fixture files + eval gate) for zero MCP-call activity post-merge. Coverage breadth is product thinking; sspower-graph is personal tooling.
4. **No phase compounds.** Even if frameworks mattered, P5-P12 would each ship the same shape — rules + fixtures + gate — with no new architectural capability per phase. The spine is done at P4.

**Conditions to revisit:** a query-precision pain point appears that LSP plugins cannot solve (e.g., a workflow needs bulk symbol queries across N files faster than per-position LSP calls allow), OR a new unique-to-graph capability is identified (e.g., test↔source mapping, semantic similarity, dependency-tree visualization). Until then, sspower-graph is terminal at P4: extractors and MCP surface stay as shipped; no new development.

Each phase ships behind `SSPOWER_GRAPH=on|off` (default `off` through P2,
`on` after P3). One PR per phase, individual Codex `plan-review` against
this spec.

## 5. Known limitations (documented, F8 reinforced)

1. **No type resolution.** Same syntactic ceiling as codegraph. Their
   "follows dynamic dispatch grep can't" claim is heuristic, not
   type-resolved (verified by reading `src/resolution/name-matcher.ts` in
   their MIT codebase — it's name-based with import resolution).
2. **ast-grep grammar gaps.** Languages without solid ast-grep grammars
   degrade to no-edge mode (extract function names only). Documented per
   language in P0 fixture matrix.
3. **Stale index between refreshes.** `dirty` queue + `refresh` covers
   PostToolUse-mediated edits. External edits (`git pull`, IDE) caught by
   SessionStart `content_hash` check.
4. **Subagent token budget.** All MCP tools cap output at `MAX_RESULTS=50`
   (mirror codegraph issue #296 fix).
5. **Ambiguous-name confidence.** `confidence=0` (ambiguous) edges are
   stored but flagged in API output. `callers --disambiguate` collapses
   to a single best-match by default.

## 6. Risks (revised per F4, F12 — removed false mitigations)

| Risk | Mitigation |
|---|---|
| ast-grep grammar gaps for a target language | P0 fixture suite gates each language; missing grammar → defer the language to a later phase, never a half-supported P1 |
| Refresh thrash on `npm install` (10k files touched at once) | Dirty file > 500 lines → fall through to full rebuild (one ast-grep pass, parallelized) instead of per-file refresh |
| MCP tools called inside `Explore` subagent loops → cost spike | Sub-agent `.md` instructions explicitly say "use graph tools BEFORE delegating to Explore, never from within Explore" — same guidance codegraph documents |
| Hook latency stacks | Single orchestrator hook (§3.5); no sibling-race fantasy. Total budget 6s under one `flock`-free coordinator. |
| Codegraph adds real type resolution and we look behind | Quarterly re-check; if codegraph ships type-resolved graphs and beats our fixture suite by ≥10pp recall, fire §1 anti-goal — switch to `codegraph install` shim |
| semble_rs overlap unproven net-new | P4 gate: head-to-head 20-prompt eval. Net-negative → kill graph-orchestrator, keep CLI + MCP only. |

## 7. Open questions (decisions to lock before P0 starts)

1. **SQLite driver in MCP server**: `better-sqlite3` (sync, native build,
   fast) vs `node:sqlite` (Node ≥22 builtin, no native build, slower
   startup, currently ExperimentalWarning).
   **Decision: `node:sqlite`. P0 prerequisite (G7):** add
   `"engines": {"node": ">=22"}` to `package.json` (currently absent),
   document Node ≥22 in `README.md` install section, fail the install
   script if `node --version` < 22. Revisit at P2 if startup latency
   fails MCP budget or if `ExperimentalWarning` causes hook stderr noise.
2. **Borrowing codegraph queries**: MIT permits with attribution. We
   borrow only the **ast-grep patterns + framework route shapes** (small,
   well-defined). We do NOT vendor their tree-sitter wasms or
   resolution/ TS code — different design. Attribution in `NOTICE.md`.
3. **Versioning**: bumped with sspower plugin semver (one moving part).
4. **Codex spec gates per phase**: each phase PR runs `bridge plan-review`
   against this spec. Phase ships only on `approve` verdict.

## 8. Out of scope (explicit)

- Replacing `sspower-mem` (memory layer, different concern).
- Replacing `semble_rs find-related`, `digest`, `tree`. They stay.
- Web UI for graph browsing.
- Hot-reload via FSEvents/inotify daemon.
- Cross-language call resolution.
- Including `codex-rescue` in MCP subagent adoption (F6 — agent contract
  explicitly forbids self-inspection; injecting graph context into the
  bridge prompt is a separate spec).

## 9. Migration path for sspower users

P0–P3 ship invisible (default `off`). P4 flips default `on`; users can
`export SSPOWER_GRAPH=off`. No breaking change to `sspower-mem`,
`semble_rs`, `codex-bridge`. No re-install. Plugin update is in-place.

## 10. Locked decisions

- D1: storage `<cwd>/.claude/graph/`
- D2: schema §3.1 (stable IDs = `path#qname#span_sha8`)
- D3: ast-grep ≥0.43 hard dep; called directly (not through semble_rs find-pattern)
- D4: P1 language = TS/JS only; +Python+Go+Rust at P2
- D5: MCP tool naming = `mcp__sspower-graph__graph_*`
- D6: MCP packaging via `.mcp.json` at plugin root with `${CLAUDE_PLUGIN_ROOT}`
- D7: `node:sqlite` (Node ≥22 builtin); revisit at P2 if too slow
- D8: codegraph patterns borrowed, code not vendored; `NOTICE.md` attribution
- D9: anti-goal hard stop — if P3 > 2 weeks, ship `codegraph install` shim
- D10: codex-rescue deferred from MCP scope (locked tool set; F6)
- D11: single orchestrator hook in P4 (no sibling-race; F4)
- D12: auto-review cache key includes graph version hash (F9)
- D13: PostToolUse matches Write|Edit|MultiEdit (F10)
- D14: accuracy fixture suite in P0 with precision/recall thresholds (F8)
- D15: `architecture` intent class added to `_intent.sh` (F3)
- D16: P0 ships fixture harness + MCP stub server so phase-gate metrics
  are measurable in the phase they're claimed (G1)
- D17: `nodes.file_path` has FK to `files.path` ON DELETE CASCADE (G2)
- D18: refresh is two-phase with reverse-imports closure (G3)
- D19: P1 acceptance target is `cmdImplement` at `scripts/codex-bridge.mjs:1519`, verified present (G4)
- D20: `semble_rs` calls wrapped by external `timeout` (G5)
- D21: dirty-file append uses FD-based flock; no shell interpolation (G6)
- D22: `engines.node ≥22` declared in `package.json`; install fails on older Node (G7)
- D23: fixed-point reverse-import closure with safety cap at `0.5 × |files|` (H1)
- D24: dirty file = JSONL with `{op,path}`; parsed before closure expansion (H2)
- D25: MCP server uses `@modelcontextprotocol/sdk` (npm dep added to budget); P0 stub ~50 LOC (H3)
- D26: dirty append uses Python `fcntl.flock` helper, not shell `flock(1)` (M1)
- D27: `vitest` added to devDependencies; dep count = 3 in §1 success criteria (M2)
- D28: SessionStart runs random-sample external-edit scan (200 files, 3s budget) with `divergence_rate > 0.05` → full-rebuild trigger (M3)
- D29: Refresh closure tracks `op ∈ {upsert, delete, relink}`; relink rebuilds only outbound edges without deleting nodes (H1*)
- D30: Dirty file is JSONL exclusively; no text prefixes; dedupe = last-record-wins with `stat()` reconciliation at refresh (H2*)
- D31: MCP stub imports `ListToolsRequestSchema`/`CallToolRequestSchema` from `@modelcontextprotocol/sdk/types.js`; smoke test uses `StdioClientTransport` (H3*)
- D32: `package.json` updated in P0 with `engines.node ≥22`, `dependencies.@modelcontextprotocol/sdk`, `devDependencies.vitest`, lockfile (H4*)
- D33: Graph dirty-append helper reuses `sspower_mem.lock.acquire_lock` (anchored, O_NOFOLLOW, regular-file-checked); no hand-rolled lock (M1*)
- D34: Single lock contract — Python `fcntl.flock` on `<cwd>/.claude/graph/.lock` for BOTH dirty-append AND SQLite refresh; no shell `flock(1)` (M2*)
- D35: SessionStart runs ONE detached worker `sspower-graph session-refresh` that chains scan→refresh under one process (M3*)
- D36: External-edit sampling uses rowid-stride; divergence-rate computed as `changed / len(rows)` with minimum-sample guard of 50 (M4*)

## 11. v0 plan-review traceability (Codex 2026-05-26)

| Finding | Severity | Where addressed |
|---|---|---|
| F1 ast-grep contract falsified | High | §3.2 — call ast-grep directly, P0 install verification |
| F2 P1 acceptance is Bash | High | §4 P1 target = `cmdImplement` at `scripts/codex-bridge.mjs:1519` (corrected from `runImplement` in v3; see G4/D19 below) |
| F3 hook gating skips architecture prompts | High | §3.5 new `architecture` class in `_intent.sh`; D15 |
| F4 sibling-hook race impossible | High | §2 §3.5 single orchestrator hook; D11 |
| F5 MCP packaging unspecified | High | §3.4 verified `.mcp.json` precedent + smoke test; D6 |
| F6 codex-rescue can't use MCP | High | §4 P3 explicit list (code-reviewer, sanity-reviewer, security-reviewer); §8 explicit out-of-scope; D10 |
| F7 unstable IDs, FTS unsync'd | Medium | §3.1 stable IDs + sync triggers + refresh transaction; D2 |
| F8 accuracy hand-wavy | Medium | §3.3 fixture suite in P0 with precision/recall thresholds; D14 |
| F9 auto-review cache key | Medium | §3.5 cache key includes graph version+hash; D12 |
| F10 dirty tracking unsafe | Medium | §3.5 atomic-append, mkdir, MultiEdit, rename/delete; D13 |
| F11 P4 scope leak | Medium | §4 P4=hooks+one framework; P5+ one framework per phase |
| F12 semble_rs overlap unproven | Medium | §6 P4 gate = net-positive head-to-head; otherwise kill orchestrator |

## 12. v1 plan-review traceability (Codex 2026-05-26, 7 findings)

| Finding | Severity | Where addressed |
|---|---|---|
| G1 P0 gates require components shipping later | High | §4 P0 now ships extractor stub + MCP stub-server; precision/recall gates moved to P1 with TS/JS fixtures wired; D16 |
| G2 no FK = stale nodes on file delete | High | §3.1 `nodes.file_path REFERENCES files(path) ON DELETE CASCADE`; D17 |
| G3 incremental refresh corrupts inbound edges | High | §3.1 two-phase refresh with reverse-imports closure (`imports` table); D18 |
| G4 `runImplement` doesn't exist | High | §4 P1 target → `cmdImplement` at codex-bridge.mjs:1519 (verified by Codex grep); D19 |
| G5 `semble_rs plan --timeout` invalid | Medium | §3.5 external `timeout` wrap; D20 |
| G6 `flock -c` shell injection on `$path` | Medium | §3.5 FD-based flock with quoted printf; D21 |
| G7 Node ≥22 implicit dep undeclared | Medium | §7 Q1 explicit `engines.node ≥22` in package.json + install gate; D22 |

## 13. v2 plan-review traceability (Codex 2026-05-26, 6 findings)

| Finding | Severity | Where addressed |
|---|---|---|
| H1 reverse-import closure is one-hop only | High | §3.1 fixed-point BFS with cycle protection (file enters working once) + safety cap; D23 |
| H2 deleted-file dirty records mis-parsed | High | §3.1 dirty file = JSONL; op parsed before closure; D24 |
| H3 P0 MCP stub not a real MCP server | High | §3.4 use `@modelcontextprotocol/sdk`; concrete 50-LOC stub + executable smoke without Claude Code; dep budget updated to 3; D25 |
| M1 `flock(1)` not on macOS | Medium | §3.5 Python `fcntl.flock` helper modeled on `scripts/sspower_mem/sspower_mem/lock.py`; D26 |
| M2 vitest undeclared | Medium | §1 success criteria dep count = 3 (incl. vitest devDep); D27 |
| M3 SessionStart external-edit scan unspecified | Medium | §3.5 random-sample 200/3s + divergence-rate full-rebuild trigger; D28 |

## 14. v3 plan-review traceability (Codex 2026-05-26, 8 findings)

| Finding | Severity | Where addressed |
|---|---|---|
| H1* reverse importers no op, never re-resolved | High | §3.1 `op_for[I]=relink`; relink action in transaction body re-emits outbound edges; D29 |
| H2* `D <path>` legacy contradicts JSONL | High | §3.1 dedupe + stat-reconciliation rule explicit; §3.5 hook now emits JSONL only; D30 |
| H3* MCP stub uses wrong SDK API; smoke not executable | High | §3.4 stub uses `ListToolsRequestSchema`/`CallToolRequestSchema`; smoke uses `StdioClientTransport`; D31 |
| H4* no package.json deps/lockfile mechanism | High | §4 P0 deliverable (b) updates package.json with deps + engines + lockfile; D32 |
| M1* lock helper not symlink-safe | Medium | §3.5 reuses `sspower_mem.lock.acquire_lock` (anchored, O_NOFOLLOW); D33 |
| M2* refresh still uses shell `flock`, split contract | Medium | §3.1 + §3.5 single Python lock contract for append + refresh; D34 |
| M3* SessionStart scan doesn't refresh in same session | Medium | §3.5 one detached worker `session-refresh` chains scan→refresh; D35 |
| M4* `ORDER BY RANDOM()` expensive; threshold wrong for small indexes | Medium | §3.5 rowid-stride sampling; divergence = `changed/len(rows)`; minimum-sample guard of 50; D36 |

## 15. v4 plan-review traceability (Codex 2026-05-26, 5 findings)

| Finding | Severity | Where addressed |
|---|---|---|
| K1 relink import-only; misses route/ambiguous-name edges | High | §3.1 closure walks `imports` ∪ inbound `edges`; D37 below |
| K2 cross-language lock impossible as written | High | §3.5 `graph-with-lock.py` wrapper holds `acquire_lock` across the child invocation; Node binary has `refresh-unlocked` mode; D38 below |
| K3 `.mcp.json` direct `node` fails on fresh install | High | §3.4 `bin/sspower-graph-bootstrap.sh` wrapper does lazy `npm install --omit=dev --prefer-offline`; matches fakechat precedent; D39 below |
| K4 rowid-stride math invalid (fractional stride, divide-by-zero) | Medium | §3.5 `stride = max(1, math.ceil(total/sample_size))`; empty-sample retry + final fallback; divergence guarded by `len(rows)>0`; D40 below |

## 17. v5 followup inline-fixes (Codex 2026-05-26, 4 followups, all resolved)

| Finding | Severity | Where addressed |
|---|---|---|
| FU1 P0 accuracy gate contradictory | Medium | §1 success criteria + §3.3 P0 gate = "fixtures runnable"; precision/recall moved to P1+ |
| FU2 smoke test bypasses bootstrap.sh | Medium | §3.4 smoke harness now spawns `bin/sspower-graph-bootstrap.sh`, sets `CLAUDE_PLUGIN_ROOT` |
| FU3 SessionStart scan misses NEW files | Medium | §3.5 prepended Step 0 = git `ls-files`+`-others` SHA8 stored in `version` file; mismatch → full_rebuild |
| FU4 stale header / `runImplement` reference | Low | header updated to v5; §11 F2 row corrected to `cmdImplement` |

## 16. New decisions from v4 review (added to §10)

- D37: refresh closure walks `imports` ∪ inbound `edges` to catch non-import edge kinds (route, ambiguous-name, implements) (K1)
- D38: `graph-with-lock.py` wrapper Python-holds-lock-across-subprocess pattern; Node binary exposes `refresh-unlocked` for the locked-side caller (K2)
- D39: `.mcp.json` invokes `sspower-graph-bootstrap.sh` (lazy npm install + marker check), NOT direct `node`; matches fakechat marketplace precedent (K3)
- D40: external-edit sampling uses integer-ceiling stride math with sparse-rowid retry + ordered fallback; divergence guarded by non-empty sample (K4)
