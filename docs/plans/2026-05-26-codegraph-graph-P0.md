# Codegraph-style Symbol Graph — P0 Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use sspower:subagent-driven-development (recommended) or sspower:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the executable foundation for the codegraph-style symbol graph: package metadata, dependency declarations, intent classifier extension, MCP stub server + smoke harness, lock helper, and fixture suite — with NO extractor (P1 territory) and NO real graph queries.

**Architecture:** All files live in the sspower plugin repo. `package.json` gains real deps (npm + Node 22 engine). `bin/sspower-graph.mjs` + `bin/sspower-graph-bootstrap.sh` expose an MCP stdio server via `@modelcontextprotocol/sdk`, with a Node-MCP-client smoke (`tests/graph/test-mcp-stub.mjs`) that goes through the bootstrap wrapper to validate the K3 fresh-install path. `hooks/_intent.sh` gains an `architecture` class so future graph-context hook can route on read-only architecture prompts. `scripts/graph-append-dirty.py` + `scripts/graph-with-lock.py` reuse the existing safe `sspower_mem.lock.acquire_lock` (POSIX `fcntl.flock`, anchored, `O_NOFOLLOW`). `__tests__/graph-fixtures/` ships goldens + a vitest harness that exits 0 in goldens-only mode and will fail red once P1 wires the extractor.

**Tech Stack:** Node 22 + `@modelcontextprotocol/sdk` (MCP server), Python 3 + `fcntl` (lock helpers), bash (bootstrap wrapper, install gate), vitest (fixture harness), ast-grep 0.43 (brew, runtime dep declared for P1).

**Spec:** `docs/specs/2026-05-26-codegraph-style-graph-design.md` v5 (APPROVED-with-followups, all inline-resolved). Locked decisions D1-D40 + FU1-FU4.

---

## File map

**Create:**
- `bin/sspower-graph.mjs` — MCP stdio server (P0 stub: `graph_status` tool only)
- `bin/sspower-graph-bootstrap.sh` — lazy `npm install` wrapper for `.mcp.json` invocation
- `.mcp.json` — plugin-root MCP server declaration
- `scripts/graph-append-dirty.py` — POSIX-safe dirty-file JSONL appender
- `scripts/graph-with-lock.py` — Python-holds-lock-across-child wrapper
- `tests/graph/test-mcp-stub.mjs` — executable MCP smoke (Node MCP client → bootstrap.sh)
- `__tests__/graph-fixtures/ts-js/expected.json` — goldens-only seed
- `__tests__/graph-fixtures/harness.test.ts` — vitest harness, goldens-only mode
- `docs/plans/2026-05-26-codegraph-graph-P0.md` — this plan

**Modify:**
- `package.json` — add `engines.node`, `dependencies.@modelcontextprotocol/sdk`, `devDependencies.vitest`, generate lockfile
- `hooks/_intent.sh:80-122` — add `architecture` intent class
- `README.md` — Node 22 install gate + ast-grep brew dep
- `NOTICE.md` (create if absent) — codegraph MIT attribution for borrowed ast-grep patterns

**Out of scope (P1+):**
- Any TS/JS extractor code (P1)
- SQLite schema, refresh logic (P2)
- Hook orchestrator, auto-review enrichment (P4)
- Framework route extractors (P5+)

---

## Task 1: Pin Node 22 engine + create lockfile baseline

**Files:**
- Modify: `package.json`
- Create: `package-lock.json`

- [ ] **Step 1.1: Read current package.json**

Run: `cat package.json`
Expected: `{ "name": "sspower", "version": "1.1.1", "type": "module" }` (no deps, no engines)

- [ ] **Step 1.2: Update package.json**

Replace file content with:
```json
{
  "name": "sspower",
  "version": "1.1.1",
  "type": "module",
  "engines": {
    "node": ">=22.0.0"
  },
  "dependencies": {
    "@modelcontextprotocol/sdk": "^1.0.0"
  },
  "devDependencies": {
    "vitest": "^2.1.0"
  }
}
```

- [ ] **Step 1.3: Verify Node version meets engine constraint**

Run: `node --version`
Expected: `v22.x.x` or higher. If lower, abort plan and upgrade Node first.

- [ ] **Step 1.4: Install dependencies + generate lockfile**

Run: `npm install --no-audit --no-fund`
Expected: completes without error; creates `package-lock.json`; creates `node_modules/`

- [ ] **Step 1.5: Smoke-test SDK import resolves**

Run:
```bash
node -e "import('@modelcontextprotocol/sdk/server/index.js').then(m => console.log('OK', !!m.Server))"
```
Expected: `OK true`

- [ ] **Step 1.6: Verify vitest available**

Run: `npx vitest --version`
Expected: `2.x.x`

- [ ] **Step 1.7: Commit**

```bash
git add package.json package-lock.json
git commit -F /tmp/commit-msg-1.txt
```

Where `/tmp/commit-msg-1.txt` contains:
```
feat(graph): pin Node >=22 and add MCP SDK + vitest deps

P0 prerequisite for codegraph-style symbol graph (spec v5 D22, D32, D27).
Adds @modelcontextprotocol/sdk for upcoming MCP stub server and vitest
for fixture-harness scaffolding.
```

---

## Task 2: README install gate for Node 22 + ast-grep

**Files:**
- Modify: `README.md`

- [ ] **Step 2.1: Locate Installation section (heading may have emoji)**

Run: `grep -nE "^## .*Installation" README.md`
Expected: prints line number matching either `## Installation` or `## 🚀 Installation` (current README uses the emoji form).

- [ ] **Step 2.2: Add prerequisites block after the Installation heading**

Insert immediately after whichever Installation heading was located in Step 2.1:
```markdown
### Prerequisites

- **Node.js ≥ 22** (required by MCP SDK; check with `node --version`).
- **ast-grep ≥ 0.43** (`brew install ast-grep` on macOS; `cargo install ast-grep`
  elsewhere). Required for the symbol graph extractor (P1+); P0 install
  works without it but the graph subsystem won't index code until ast-grep
  is on `PATH`.

```

- [ ] **Step 2.3: Verify edit**

Run: `grep -A 5 "^### Prerequisites" README.md`
Expected: shows the new prerequisites block with both bullet items.

- [ ] **Step 2.4: Commit**

```bash
git add README.md
git commit -F /tmp/commit-msg-2.txt
```
Where `/tmp/commit-msg-2.txt`:
```
docs(graph): require Node 22 and ast-grep 0.43

Spec v5 D22, D3 — install gate communication. Plan P0 Task 2.
```

---

## Task 3: NOTICE.md attribution for borrowed codegraph patterns

**Files:**
- Create: `NOTICE.md`

- [ ] **Step 3.1: Check NOTICE.md does not already exist**

Run: `test -f NOTICE.md && echo EXISTS || echo MISSING`
Expected: `MISSING` (D8 says we add it now).

- [ ] **Step 3.2: Create NOTICE.md**

```markdown
# Third-party Attributions

This product includes designs adapted from third-party open-source projects.

## colbymchenry/codegraph (MIT)

https://github.com/colbymchenry/codegraph

The `sspower-graph` subsystem borrows the following design ideas (NOT code):

- Per-project SQLite cache at `<cwd>/.claude/graph/` paralleling codegraph's
  `<cwd>/.codegraph/` layout.
- MCP tool naming convention (`graph_callers`, `graph_callees`, `graph_trace`,
  `graph_context`, `graph_impact`, `graph_node`, `graph_status`).
- Framework-aware route extraction concept (P5+, ast-grep based, originals
  used tree-sitter queries).
- Cap-MAX_RESULTS=50 pattern from codegraph issue #296.

No source code from codegraph is vendored. The sspower-graph implementation
uses ast-grep directly, not tree-sitter wasms.
```

- [ ] **Step 3.3: Verify file written**

Run: `wc -l NOTICE.md`
Expected: ~20 lines.

- [ ] **Step 3.4: Commit**

```bash
git add NOTICE.md
git commit -F /tmp/commit-msg-3.txt
```
Where `/tmp/commit-msg-3.txt`:
```
docs(graph): attribute codegraph (MIT) design influence

Spec v5 D8 — borrowed ast-grep pattern shapes and tool naming.
No source code vendored; designs only.
```

---

## Task 4: Add `architecture` intent class to `_intent.sh`

**Files:**
- Modify: `hooks/_intent.sh`
- Test: `tests/hooks/test-intent-architecture.sh`

- [ ] **Step 4.1: Read current `_intent.sh` classifier**

Run: `sed -n '1,60p' hooks/_intent.sh`
Note: function `sspower_classify_intent` returns one of `qa|explicit-skill|simple-coding|multi-step`. We add a fifth output: `architecture`.

- [ ] **Step 4.2: Write failing test first**

Create `tests/hooks/test-intent-architecture.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
HOOKS_DIR="$(cd "$(dirname "$0")/../../hooks" && pwd)"
source "$HOOKS_DIR/_intent.sh"

assert_class() {
  local prompt="$1" expected="$2"
  local got
  got=$(sspower_classify_intent "$prompt")
  if [ "$got" != "$expected" ]; then
    echo "FAIL: prompt='$prompt' expected=$expected got=$got" >&2
    exit 1
  fi
  echo "OK: '$prompt' -> $expected"
}

# Architecture prompts must NOT be classified as qa.
assert_class "how does X reach Y in this codebase" architecture
assert_class "what calls handleRequest" architecture
assert_class "where is parseConfig used" architecture
assert_class "trace the auth middleware chain" architecture
assert_class "callers of validateInput" architecture
assert_class "callees of dispatchEvent" architecture
assert_class "show the path from controller to db" architecture

# Existing classes still work
assert_class "what is React" qa
assert_class "fix the bug in auth.ts" simple-coding
assert_class "sspower:writing-plans" explicit-skill

echo "ALL PASS"
```

- [ ] **Step 4.3: Run test — expect failure**

```bash
chmod +x tests/hooks/test-intent-architecture.sh
bash tests/hooks/test-intent-architecture.sh
```
Expected: FAIL on first `architecture` assertion (currently returns `qa`).

- [ ] **Step 4.4: Edit `_intent.sh` to add architecture class**

In `hooks/_intent.sh`, locate the read-only guard block (around line 50-56, the `case "$r" in "what is"* | ...) echo qa; ...` block).

INSERT a NEW block BEFORE the qa-classification case:
```bash
  # Architecture prompts: structural questions about THIS codebase that
  # benefit from graph lookup, not generic Q&A. Must be classified BEFORE
  # the broader qa case (which would also match "how does"). Added 2026-05-26
  # per docs/specs/2026-05-26-codegraph-style-graph-design.md D15, FU3.
  case "$r" in
    "how does "*" reach "*|"how does "*" call "*|\
    "what calls "*|"what call "*|"who calls "*|\
    "where is "*" used"*|"where is "*" called"*|\
    "trace "*|"callers of "*|"callees of "*|\
    "show the path "*|"show the call path "*|"call graph "*)
      echo architecture; return 0 ;;
  esac
```

- [ ] **Step 4.5: Run test — expect pass**

```bash
bash tests/hooks/test-intent-architecture.sh
```
Expected: `ALL PASS`.

- [ ] **Step 4.6: Manually verify existing intent tests still pass**

Run: `bash tests/skill-triggering/run-all.sh 2>&1 | tail -20` (if it exists)
Expected: no regression. If suite doesn't exist, skip.

- [ ] **Step 4.7: Commit**

```bash
git add hooks/_intent.sh tests/hooks/test-intent-architecture.sh
git commit -F /tmp/commit-msg-4.txt
```
Where `/tmp/commit-msg-4.txt`:
```
feat(hooks): add architecture intent class

Spec v5 D15, FU3. Distinguishes structural codebase questions ("how does
X reach Y", "callers of foo") from generic read-only qa. Required so the
upcoming graph-context hook (P4) can route on graph-relevant prompts
without being suppressed by the existing qa guard.
```

---

## Task 5: Python lock helpers (append + with-lock wrapper)

**Files:**
- Create: `scripts/graph-append-dirty.py`
- Create: `scripts/graph-with-lock.py`
- Test: `tests/graph/test-lock-helpers.py`

- [ ] **Step 5.1: Verify existing `sspower_mem.lock` is importable**

Run:
```bash
PYTHONPATH=scripts/sspower_mem python3 -c \
  "from sspower_mem.lock import acquire_lock; print('OK', acquire_lock.__doc__[:60])"
```
Expected: prints `OK Exclusive blocking flock on lock_path.`

- [ ] **Step 5.2: Write failing test first**

Create `tests/graph/test-lock-helpers.py`:
```python
#!/usr/bin/env python3
"""Smoke tests for graph-append-dirty.py + graph-with-lock.py."""
import json, os, pathlib, subprocess, sys, tempfile, time

PLUGIN_ROOT = pathlib.Path(__file__).resolve().parents[2]
ENV = {**os.environ, "CLAUDE_PLUGIN_ROOT": str(PLUGIN_ROOT)}

def test_append_writes_jsonl():
    with tempfile.TemporaryDirectory() as cwd:
        graph_dir = pathlib.Path(cwd) / ".claude" / "graph"
        r = subprocess.run(
            ["python3", str(PLUGIN_ROOT / "scripts" / "graph-append-dirty.py"),
             "--graph-dir", str(graph_dir),
             "--op", "upsert", "--path", "/abs/path/foo.ts"],
            env=ENV, check=True, capture_output=True, text=True)
        dirty = (graph_dir / "dirty").read_text()
        assert dirty.strip() == '{"op": "upsert", "path": "/abs/path/foo.ts"}', dirty
        print("OK append_writes_jsonl")

def test_with_lock_runs_child():
    with tempfile.TemporaryDirectory() as cwd:
        graph_dir = pathlib.Path(cwd) / ".claude" / "graph"
        graph_dir.mkdir(parents=True)
        marker = pathlib.Path(cwd) / "ran.txt"
        r = subprocess.run(
            ["python3", str(PLUGIN_ROOT / "scripts" / "graph-with-lock.py"),
             "--graph-dir", str(graph_dir), "--",
             "sh", "-c", f"echo locked > {marker}"],
            env=ENV, check=True, capture_output=True, text=True)
        assert marker.read_text().strip() == "locked"
        print("OK with_lock_runs_child")

def test_with_lock_blocks_concurrent():
    """Second invocation must wait for first to release."""
    with tempfile.TemporaryDirectory() as cwd:
        graph_dir = pathlib.Path(cwd) / ".claude" / "graph"
        graph_dir.mkdir(parents=True)
        marker = pathlib.Path(cwd) / "log.txt"
        # First holds lock for 1s; second appends after.
        p1 = subprocess.Popen(
            ["python3", str(PLUGIN_ROOT / "scripts" / "graph-with-lock.py"),
             "--graph-dir", str(graph_dir), "--",
             "sh", "-c", f"sleep 1 && echo A >> {marker}"], env=ENV)
        time.sleep(0.2)
        p2 = subprocess.Popen(
            ["python3", str(PLUGIN_ROOT / "scripts" / "graph-with-lock.py"),
             "--graph-dir", str(graph_dir), "--",
             "sh", "-c", f"echo B >> {marker}"], env=ENV)
        p1.wait(); p2.wait()
        log = marker.read_text().split()
        assert log == ["A", "B"], f"got {log}"
        print("OK with_lock_blocks_concurrent")

if __name__ == "__main__":
    test_append_writes_jsonl()
    test_with_lock_runs_child()
    test_with_lock_blocks_concurrent()
    print("ALL PASS")
```

- [ ] **Step 5.3: Run test — expect failure**

```bash
python3 tests/graph/test-lock-helpers.py
```
Expected: `FileNotFoundError` on `graph-append-dirty.py` (not yet created).

- [ ] **Step 5.4: Implement `scripts/graph-append-dirty.py`**

```python
#!/usr/bin/env python3
"""Append a single JSONL record to <graph-dir>/dirty under exclusive lock.

Invoked by hooks/graph-mark-dirty.sh on PostToolUse:Write|Edit|MultiEdit.
Reuses sspower_mem.lock.acquire_lock for symlink-safe POSIX locking.
"""
import argparse, json, os, pathlib, sys

PLUGIN_ROOT = pathlib.Path(os.environ["CLAUDE_PLUGIN_ROOT"]).resolve()
sys.path.insert(0, str(PLUGIN_ROOT / "scripts" / "sspower_mem"))
from sspower_mem.lock import acquire_lock                # noqa: E402
from sspower_mem.io import safe_makedirs_strict, safe_append_strict  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--graph-dir", required=True)
ap.add_argument("--op", required=True, choices=["upsert", "delete"])
ap.add_argument("--path", required=True)
args = ap.parse_args()

graph_dir = pathlib.Path(args.graph_dir).resolve()
trust_root = graph_dir.parent.parent
safe_makedirs_strict(graph_dir, trust_root, mode=0o700)

lock_path = graph_dir / ".lock"
dirty_path = graph_dir / "dirty"
record = json.dumps({"op": args.op, "path": args.path}) + "\n"

with acquire_lock(lock_path, parent_anchor=trust_root):
    safe_append_strict(dirty_path, record, trust_root=trust_root)
```

- [ ] **Step 5.5: Implement `scripts/graph-with-lock.py`**

```python
#!/usr/bin/env python3
"""Hold <graph-dir>/.lock for the duration of a child process.

Used by sspower-graph refresh to bracket the SQLite transaction
across the cross-language Node ↔ Python boundary.

Usage:
  graph-with-lock.py --graph-dir <dir> -- <cmd> [args...]
"""
import argparse, os, pathlib, subprocess, sys

PLUGIN_ROOT = pathlib.Path(os.environ["CLAUDE_PLUGIN_ROOT"]).resolve()
sys.path.insert(0, str(PLUGIN_ROOT / "scripts" / "sspower_mem"))
from sspower_mem.lock import acquire_lock                # noqa: E402
from sspower_mem.io import safe_makedirs_strict          # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--graph-dir", required=True)
ap.add_argument("cmd", nargs=argparse.REMAINDER)
args = ap.parse_args()

graph_dir = pathlib.Path(args.graph_dir).resolve()
trust_root = graph_dir.parent.parent
safe_makedirs_strict(graph_dir, trust_root, mode=0o700)
lock_path = graph_dir / ".lock"

# argparse REMAINDER includes the literal `--` separator; strip it.
cmd = args.cmd[1:] if args.cmd and args.cmd[0] == "--" else args.cmd
if not cmd:
    print("error: no command after --", file=sys.stderr)
    sys.exit(2)

with acquire_lock(lock_path, parent_anchor=trust_root):
    completed = subprocess.run(cmd, env=os.environ)
    sys.exit(completed.returncode)
```

- [ ] **Step 5.6: Run test — expect pass**

```bash
python3 tests/graph/test-lock-helpers.py
```
Expected: `OK append_writes_jsonl`, `OK with_lock_runs_child`, `OK with_lock_blocks_concurrent`, `ALL PASS`.

- [ ] **Step 5.7: Commit**

```bash
git add scripts/graph-append-dirty.py scripts/graph-with-lock.py tests/graph/test-lock-helpers.py
git commit -F /tmp/commit-msg-5.txt
```
Where `/tmp/commit-msg-5.txt`:
```
feat(graph): add Python lock helpers for dirty queue + refresh

Spec v5 D33, D34, D38. Reuses sspower_mem.lock.acquire_lock for
symlink-safe POSIX fcntl locking. graph-append-dirty.py appends one
JSONL record per PostToolUse event; graph-with-lock.py brackets the
Node SQLite refresh inside a Python-held lock so the critical section
spans the cross-language boundary correctly.
```

---

## Task 6: MCP stub server + bootstrap wrapper

**Files:**
- Create: `bin/sspower-graph.mjs`
- Create: `bin/sspower-graph-bootstrap.sh`
- Create: `.mcp.json`

- [ ] **Step 6.1: Implement `bin/sspower-graph.mjs` (P0 stub: graph_status only)**

```js
#!/usr/bin/env node
// sspower-graph MCP stub server (P0).
// Exposes one tool: graph_status. Expands in P1 (callers/callees/node/status)
// and P2 (trace/impact/context/refresh).
//
// Spec: docs/specs/2026-05-26-codegraph-style-graph-design.md §3.4, D31.

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';

const argv = process.argv.slice(2);
const cmd = argv[0];

if (cmd !== 'serve' || argv[1] !== '--mcp') {
  console.error('usage: sspower-graph serve --mcp');
  process.exit(2);
}

const server = new Server(
  { name: 'sspower-graph', version: '0.0.1' },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [{
    name: 'graph_status',
    description: 'Graph index freshness (P0 stub — always returns {ok:true,stub:true})',
    inputSchema: { type: 'object', properties: {}, required: [] },
  }],
}));

server.setRequestHandler(CallToolRequestSchema, async ({ params }) => {
  if (params.name === 'graph_status') {
    return {
      content: [{
        type: 'text',
        text: JSON.stringify({ ok: true, stub: true, phase: 'P0' }),
      }],
    };
  }
  throw new Error(`unknown tool: ${params.name}`);
});

await server.connect(new StdioServerTransport());
```

- [ ] **Step 6.2: Make executable**

```bash
chmod +x bin/sspower-graph.mjs
```

- [ ] **Step 6.3: Implement `bin/sspower-graph-bootstrap.sh`**

```bash
#!/usr/bin/env bash
# sspower-graph bootstrap wrapper for .mcp.json invocation.
# Lazy-installs Node deps on first run, then launches the MCP server.
# K3 fix: direct `node bin/sspower-graph.mjs` would fail on a fresh
# plugin install before `npm install` runs.
set -euo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
if [ ! -d "$ROOT/node_modules/@modelcontextprotocol" ]; then
  # First-run install. Prefer offline cache; fall back to network if cold.
  npm install --omit=dev --no-audit --no-fund --silent --prefer-offline \
    >/dev/null 2>&1 \
    || npm install --omit=dev --no-audit --no-fund --silent >&2
fi
exec node "$ROOT/bin/sspower-graph.mjs" "$@"
```

- [ ] **Step 6.4: Make executable**

```bash
chmod +x bin/sspower-graph-bootstrap.sh
```

- [ ] **Step 6.5: Create `.mcp.json` at plugin root**

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

- [ ] **Step 6.6: Manual sanity check — bootstrap launches without crash**

This is a coarse smoke-check that defers correctness to the Task 7 MCP client test. The stdio MCP server may exit cleanly on stdin EOF or wait for a request — either is fine here. We only need to confirm it doesn't crash on startup.

```bash
CLAUDE_PLUGIN_ROOT="$(pwd)" timeout 2 bin/sspower-graph-bootstrap.sh serve --mcp </dev/null; ec=$?
case "$ec" in
  0|124) echo "OK exit=$ec (clean EOF or timeout — neither is a crash)";;
  *) echo "FAIL crash exit=$ec"; exit 1;;
esac
```
Expected: prints `OK exit=0` or `OK exit=124`. Task 7 is the authoritative startup + protocol check.

- [ ] **Step 6.7: Commit**

```bash
git add bin/sspower-graph.mjs bin/sspower-graph-bootstrap.sh .mcp.json
git commit -F /tmp/commit-msg-6.txt
```
Where `/tmp/commit-msg-6.txt`:
```
feat(graph): add MCP stub server + bootstrap wrapper

Spec v5 D6, D25, D31, D39, K3. P0 stub exposes one tool (graph_status).
Bootstrap wrapper lazy-installs @modelcontextprotocol/sdk so fresh plugin
installs work without a separate npm step. .mcp.json points at the
bootstrap, NOT direct node, matching the fakechat marketplace pattern.
```

---

## Task 7: MCP smoke test (executable, end-to-end)

**Files:**
- Create: `tests/graph/test-mcp-stub.mjs`

- [ ] **Step 7.1: Write the test**

```js
#!/usr/bin/env node
// MCP stub smoke test. Spawns the bootstrap wrapper (which spawns the
// stub server), runs through full MCP handshake: initialize, tools/list,
// tools/call. Verifies graph_status returns {ok:true,stub:true,phase:'P0'}.
//
// Spec: docs/specs/2026-05-26-codegraph-style-graph-design.md §3.4 FU2.
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import assert from 'node:assert/strict';
import path from 'node:path';

const pluginRoot = process.env.CLAUDE_PLUGIN_ROOT
  ?? path.resolve(import.meta.dirname, '..', '..');

const transport = new StdioClientTransport({
  command: path.join(pluginRoot, 'bin', 'sspower-graph-bootstrap.sh'),
  args: ['serve', '--mcp'],
  env: { ...process.env, CLAUDE_PLUGIN_ROOT: pluginRoot },
});

const client = new Client(
  { name: 'sspower-graph-smoke', version: '0.0.1' },
  { capabilities: {} }
);

await client.connect(transport);

const tools = await client.listTools();
assert.equal(tools.tools.length, 1, `expected 1 tool, got ${tools.tools.length}`);
assert.equal(tools.tools[0].name, 'graph_status');

const result = await client.callTool({ name: 'graph_status', arguments: {} });
assert.equal(result.content.length, 1);
assert.equal(result.content[0].type, 'text');
const payload = JSON.parse(result.content[0].text);
assert.equal(payload.ok, true);
assert.equal(payload.stub, true);
assert.equal(payload.phase, 'P0');

// Negative case: unknown tool name must throw.
let threw = false;
try {
  await client.callTool({ name: 'nonexistent', arguments: {} });
} catch (e) {
  threw = true;
}
assert.ok(threw, 'unknown tool should throw');

await client.close();
console.log('OK MCP stub smoke passed');
```

- [ ] **Step 7.2: Run smoke test — expect pass**

```bash
node tests/graph/test-mcp-stub.mjs
```
Expected: `OK MCP stub smoke passed`. Exit code 0.

- [ ] **Step 7.3: Run smoke test in fresh-install simulation**

```bash
# Temporarily move node_modules to verify bootstrap re-installs cleanly
mv node_modules node_modules.bak
node tests/graph/test-mcp-stub.mjs
mv node_modules.bak node_modules  # restore
```
Expected: bootstrap runs `npm install` automatically; test still passes; subsequent runs no-op the install.

- [ ] **Step 7.4: Commit**

```bash
git add tests/graph/test-mcp-stub.mjs
git commit -F /tmp/commit-msg-7.txt
```
Where `/tmp/commit-msg-7.txt`:
```
test(graph): add executable MCP stub smoke

Spec v5 H3*, FU2. Validates the K3 fresh-install path by going through
bootstrap.sh (not direct node). Uses StdioClientTransport + Client to
exercise initialize/tools/list/tools/call against the stub server.
```

---

## Task 8: Fixture-suite scaffolding (goldens-only, vitest harness)

**Files:**
- Create: `__tests__/graph-fixtures/README.md`
- Create: `__tests__/graph-fixtures/ts-js/sample-input.ts`
- Create: `__tests__/graph-fixtures/ts-js/expected.json`
- Create: `__tests__/graph-fixtures/harness.test.ts`
- Create: `vitest.config.ts` (if absent)

- [ ] **Step 8.1: Check vitest config existence**

Run: `ls vitest.config.* 2>/dev/null || echo MISSING`
Expected: `MISSING` (we create it). If present, skip Step 8.2.

- [ ] **Step 8.2: Create minimal `vitest.config.ts`**

```typescript
import { defineConfig } from 'vitest/config';
export default defineConfig({
  test: {
    include: ['__tests__/**/*.test.ts'],
    testTimeout: 5000,
  },
});
```

- [ ] **Step 8.3: Create README explaining goldens-only mode**

```markdown
# Graph extractor fixtures

Each subdirectory is one language fixture pack with:

- `sample-input.<ext>` — the source file under test
- `expected.json` — ground-truth nodes + edges the extractor must produce

## P0 goldens-only mode

P0 has no extractor. The harness verifies that `expected.json` parses and
that the sample-input file exists. Once P1 wires the TS/JS extractor, the
harness compares extractor output against goldens and gates the P1 ship on
precision ≥ 0.85 and recall ≥ 0.70 (spec v5 §3.3).
```

- [ ] **Step 8.4: Create TS/JS sample input**

```typescript
// __tests__/graph-fixtures/ts-js/sample-input.ts
// Minimal fixture for graph extractor: one caller, one callee, one
// ambiguous same-name across two classes.

export function helper(x: number): number {
  return x + 1;
}

function caller(): number {
  return helper(42);
}

class A {
  shared(): string { return 'a'; }
}
class B {
  shared(): string { return 'b'; }
}

function ambiguous(a: A, b: B): string {
  return a.shared() + b.shared();
}

export { caller, ambiguous };
```

- [ ] **Step 8.5: Create expected.json with goldens**

```json
{
  "language": "typescript",
  "nodes": [
    { "name": "helper",    "kind": "function", "start_line": 5,  "end_line": 7 },
    { "name": "caller",    "kind": "function", "start_line": 9,  "end_line": 11 },
    { "name": "A.shared",  "kind": "method",   "start_line": 14, "end_line": 14 },
    { "name": "B.shared",  "kind": "method",   "start_line": 17, "end_line": 17 },
    { "name": "ambiguous", "kind": "function", "start_line": 20, "end_line": 22 }
  ],
  "edges": [
    { "source": "caller",    "target": "helper",   "kind": "calls", "confidence": 2 },
    { "source": "ambiguous", "target": "A.shared", "kind": "calls", "confidence": 0, "ambiguous": true },
    { "source": "ambiguous", "target": "B.shared", "kind": "calls", "confidence": 0, "ambiguous": true }
  ]
}
```

- [ ] **Step 8.6: Create harness test (goldens-only mode)**

```typescript
// __tests__/graph-fixtures/harness.test.ts
import { describe, it, expect } from 'vitest';
import { readdirSync, readFileSync, existsSync } from 'node:fs';
import path from 'node:path';

const FIXTURES_DIR = path.resolve(import.meta.dirname);

const FIXTURE_PACKS = readdirSync(FIXTURES_DIR, { withFileTypes: true })
  .filter(d => d.isDirectory())
  .map(d => d.name);

describe('graph-fixtures goldens-only mode', () => {
  it('has at least one fixture pack', () => {
    expect(FIXTURE_PACKS.length).toBeGreaterThan(0);
  });

  for (const pack of FIXTURE_PACKS) {
    const packDir = path.join(FIXTURES_DIR, pack);
    const expectedPath = path.join(packDir, 'expected.json');

    it(`pack '${pack}' has parseable expected.json`, () => {
      expect(existsSync(expectedPath)).toBe(true);
      const data = JSON.parse(readFileSync(expectedPath, 'utf8'));
      expect(data.language).toBeTruthy();
      expect(Array.isArray(data.nodes)).toBe(true);
      expect(Array.isArray(data.edges)).toBe(true);
    });

    it(`pack '${pack}' has a sample input file`, () => {
      const candidates = readdirSync(packDir).filter(f => f.startsWith('sample-input.'));
      expect(candidates.length).toBeGreaterThanOrEqual(1);
    });
  }

  it('extractor comparison is gated (P1)', () => {
    // P0: this assertion intentionally passes. P1 replaces this with a
    // real extractor invocation + precision/recall computation.
    expect(true).toBe(true);
  });
});
```

- [ ] **Step 8.7: Run harness — expect pass**

```bash
npx vitest run __tests__/graph-fixtures/
```
Expected: 4 tests pass (1 pack-count, 2 per-pack assertions × 1 pack, 1 P1 gate). 0 fail.

- [ ] **Step 8.8: Commit**

```bash
git add vitest.config.ts __tests__/graph-fixtures/
git commit -F /tmp/commit-msg-8.txt
```
Where `/tmp/commit-msg-8.txt`:
```
test(graph): scaffold extractor fixture suite (goldens-only)

Spec v5 D14, FU1. P0 ships the fixture pack format (sample-input +
expected.json) and a vitest harness that validates structure only.
P1 will plug in the actual TS/JS extractor and gate ship on precision
>= 0.85, recall >= 0.70 against these goldens.
```

---

## Task 9: Self-review pass

- [ ] **Step 9.1: Verify all P0 deliverables exist**

```bash
for f in package.json package-lock.json README.md NOTICE.md \
         .mcp.json bin/sspower-graph.mjs bin/sspower-graph-bootstrap.sh \
         scripts/graph-append-dirty.py scripts/graph-with-lock.py \
         tests/graph/test-mcp-stub.mjs tests/graph/test-lock-helpers.py \
         tests/hooks/test-intent-architecture.sh \
         __tests__/graph-fixtures/harness.test.ts \
         __tests__/graph-fixtures/ts-js/sample-input.ts \
         __tests__/graph-fixtures/ts-js/expected.json \
         vitest.config.ts; do
  test -f "$f" && echo "OK $f" || echo "MISSING $f"
done
```
Expected: all 16 files print `OK`.

- [ ] **Step 9.2: Run all P0 tests in one go**

```bash
set -e
echo "--- intent classifier ---"
bash tests/hooks/test-intent-architecture.sh
echo "--- lock helpers ---"
CLAUDE_PLUGIN_ROOT="$(pwd)" python3 tests/graph/test-lock-helpers.py
echo "--- MCP smoke ---"
CLAUDE_PLUGIN_ROOT="$(pwd)" node tests/graph/test-mcp-stub.mjs
echo "--- fixture harness ---"
npx vitest run __tests__/graph-fixtures/ --reporter=basic
echo "--- ALL PASS ---"
```
Expected: all four green. Final line: `--- ALL PASS ---`.

- [ ] **Step 9.3: Verify SDK import + node:sqlite import (P1 prep)**

```bash
node -e "Promise.all([
  import('@modelcontextprotocol/sdk/server/index.js'),
  import('node:sqlite')
]).then(() => console.log('OK')).catch(e => { console.error(e); process.exit(1); })"
```
Expected: `OK` on stderr or stdout; possibly `ExperimentalWarning` for `node:sqlite`.

- [ ] **Step 9.4: No stray edits in `hooks/` outside `_intent.sh`**

```bash
git diff --stat HEAD~9..HEAD hooks/
```
Expected: shows only `hooks/_intent.sh` modified.

- [ ] **Step 9.5: Spec traceability — every locked decision is honored or explicitly deferred**

Verify in `docs/specs/2026-05-26-codegraph-style-graph-design.md`:
- D1 storage path → deferred to P2 (refresh ships then)
- D2 schema → deferred to P2
- D3 ast-grep ≥0.43 → README install gate (Task 2) ✓
- D6 `.mcp.json` at plugin root → Task 6 ✓
- D7 `node:sqlite` → Task 9.3 import verified ✓
- D8 NOTICE.md → Task 3 ✓
- D10 codex-rescue deferred → P3 concern, not P0
- D11 single orchestrator hook → P4 concern
- D14 fixture suite in P0 → Task 8 ✓
- D15 architecture intent class → Task 4 ✓
- D22 Node ≥22 engine → Task 1 ✓
- D25 MCP SDK + stub → Task 6 ✓
- D26 Python flock helper → Task 5 ✓
- D27 vitest in devDeps → Task 1 ✓
- D31 MCP schemas from `/types.js` → Task 6 ✓
- D32 package.json deps + lockfile → Task 1 ✓
- D33 reuses sspower_mem.lock → Task 5 ✓
- D34 single lock contract → Task 5 ✓
- D38 graph-with-lock.py wrapper → Task 5 ✓
- D39 bootstrap.sh wrapper → Task 6 ✓
- D40 sampling math → deferred to P2 (refresh ships then)
- FU1 P0 gate = fixtures runnable → Task 8 ✓
- FU2 smoke through bootstrap → Task 7 ✓
- FU3 architecture intent → Task 4 ✓
- FU4 stale labels → not applicable to plan (spec-only)

Other decisions (D2, D4, D5, D9, D12, D13, D16-D21, D23, D24, D28-D30, D35-D37): all gate P1+ phases, NOT P0.

---

## Task 10: Post-implementation Codex review of the realized diff

Plan-level codex review was done by the author BEFORE Task 1 (verdict =
needs-attention with 4 real findings, all fixed inline in v1.1 of this plan).
This task is the POST-implementation review of the actual code produced
by Tasks 1-8.

- [ ] **Step 10.1: Sanity-check that all P0 commits landed**

```bash
git log --oneline HEAD~8..HEAD
```
Expected: 8 commits matching Tasks 1-8 commit subjects.

- [ ] **Step 10.2: Run codex review on the realized branch diff**

```bash
node "/Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower/scripts/codex-bridge.mjs" review \
  --cd /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower
```

- [ ] **Step 10.3: Fix High/Medium findings as new commits; re-run until `approve` or `approve-with-followups`**

Cap at 3 review iterations. If verdict stalls at `needs-attention` after 3, escalate to `sspower:second-opinion` (sanity-reviewer subagent).

- [ ] **Step 10.4: Tag the P0 milestone**

```bash
git tag -a graph-p0 -m "sspower-graph P0: deps + intent class + MCP stub + lock helpers + fixture harness"
```

---

## Acceptance summary

P0 SHIPPED when:
- 8 implementation commits landed (Tasks 1-8 each produce one commit). Tasks 9 + 10 are verification/review tasks — Task 10 may produce additional fix commits during its 3-iteration review loop; those count as P0 cleanup, not new task commits.
- Task 9.2 prints `--- ALL PASS ---`
- Task 10 codex review verdict ∈ {approve, approve-with-followups}
- Task 10.4 tag `graph-p0` exists at HEAD
- No regressions in existing sspower tests (`tests/skill-triggering/` if present)

P0 does NOT ship:
- Any extractor code (P1)
- Any SQLite schema or refresh logic (P2)
- Any production hook wiring (P4)
- Any framework route extraction (P5+)

P0 unblocks:
- P1 TS/JS extractor (plugs into fixture harness; uses lock helpers + MCP server expansion)
- P3 sub-agent MCP integration (manifest + bootstrap already work)
- P4 hook orchestration (intent class already present)
