# sspower-graph P3 — MCP tool expansion + subagent guidance + adoption metric

> Spec date: 2026-05-27. Author: Claude (Opus 4.7). Parent spec:
> `docs/specs/2026-05-26-codegraph-style-graph-design.md` v5 (§4 P3 row +
> §3.6 CLI verbs).

## 0. Context

P2 shipped at `1.3.0` (commit `f268a04`). CLI verbs `build / refresh /
session-refresh / callers / callees / trace / impact / context / node /
status` all green; 5 fixture packs ≥P0.85/R0.70; 10k-file build <60s; warm
callers p95 <1s. Current MCP stub at `bin/sspower-graph.mjs:267-287` exposes
**only `graph_status`** returning `{ok:true,stub:true,phase:"P0"}`.

Sub-agent `.md` files (`agents/code-reviewer.md`,
`agents/sanity-reviewer.md`, `agents/security-reviewer.md`) currently have
**zero** MCP-tool guidance. `agents/codex-rescue.md` deferred from MCP
scope per locked decision D10 (memory snapshot 2026-05-26).

## 1. Goals / non-goals / success criteria

### Goals

1. Replace the P0 stub with a full MCP server exposing 7 query tools that
   wrap existing CLI verbs.
2. Update 3 sub-agent `.md` files with role-tuned guidance + a hard rule
   forbidding graph-tool calls from inside `Explore`.
3. Ship an adoption-metric harness (server-side event log + SessionEnd
   reconciler + aggregator) that answers the spec §4 P3 gate question:
   "≥1 graph MCP call per session × 50 distinct sessions".

### Non-goals

- `graph_routes` MCP tool. Routes data only becomes meaningful at P4
  (Express framework extractor). Defer the MCP wrapper to P4.
- `codex-rescue` agent updates. Per D10, agent stays on locked tool list
  `Bash/Read/Glob/Grep` with "do not inspect repo" contract.
- Framework-specific tools (`graph_routes` per-framework, route-handler
  trace). P4/P5+ scope.
- New extractor languages, new CLI verbs, schema changes. All P2-shipped
  pieces remain frozen.

### Success criteria (measurable)

1. `node tests/graph/test-mcp-stub.mjs` (extended) passes for **all 7**
   tools — listTools returns 7 entries, callTool on each returns a parseable
   payload against a fixture DB.
2. Each of the 3 updated agents includes the hard rule
   *"call graph tools BEFORE delegating to Explore subagent; never invoke
   graph tools from inside Explore"* verbatim (rule lifted from parent spec
   §6 risks row).
3. Adoption gate: `sspower-graph metric --json` reports
   `sessions_with_call == eligible_sessions_total` (i.e. ratio 1.0) over
   the 50 most-recent **eligible** sessions captured in
   `~/.claude/state/sspower/graph-mcp/sessions.json`.
   `sessions_total` (all sessions including ineligible) is reported as a
   diagnostic field only — not part of the gate.
4. MCP CallToolRequest p95 latency ≤ 300ms on the fixture DB (perf check;
   not a hard gate — instrumented for tuning).

## 2. Tool contracts (7 tools)

All tools wrap existing CLI verb handlers in `bin/sspower-graph.mjs`. No
new query semantics. Output is always
`{content:[{type:'text', text: <JSON string>}]}` where the JSON matches
the corresponding CLI `--json` output verbatim. Errors throw `Error(...)`;
SDK translates to `{isError:true, content:[{type:'text',text:<msg>}]}`.

| Tool name (MCP) | CLI verb | Required input | Optional input | Underlying handler |
|---|---|---|---|---|
| `graph_status` | `status` | — | `cwd?:string` | `runStatus()` |
| `graph_callers` | `callers <name>` | `name:string` | `limit?:number(default 50, max 200)`, `disambiguate?:boolean`, `cwd?:string` | `runCallers()` |
| `graph_callees` | `callees <name>` | `name:string` | `limit?:number(default 50, max 200)`, `cwd?:string` | `runCallees()` |
| `graph_trace` | `trace <from> <to>` | `from:string, to:string` | `maxHops?:number(default 6, max 10)`, `cwd?:string` | `runTrace()` |
| `graph_impact` | `impact <file>` | `file:string` | `cwd?:string` | `runImpact()` |
| `graph_node` | `node <name>` | `name:string` | `cwd?:string` | `runNode()` |
| `graph_context` | `context <task>` | `task:string` | `cwd?:string` | `runContext()` |

`cwd` defaults to `process.cwd()` of the server process (the workspace
the MCP client invoked it from). `MAX_RESULTS=50` cap from §5 of parent
spec is preserved per tool (limit clamped at 200 hard ceiling).

### inputSchema example (graph_callers)

```json
{
  "type": "object",
  "properties": {
    "name": { "type": "string", "minLength": 1, "description": "Function/method/class name. Use 'a.b' for qualified Python/JS, 'Type::method' for Rust." },
    "limit": { "type": "integer", "minimum": 1, "maximum": 200, "default": 50 },
    "disambiguate": { "type": "boolean", "default": false },
    "cwd": { "type": "string" }
  },
  "required": ["name"]
}
```

## 3. Server scaffolding refactor

Current stub (`bin/sspower-graph.mjs:267-287`) is inline. Refactor to:

```
scripts/graph/mcp-tools/
  index.mjs           — exports TOOLS array + dispatcher
  status.mjs          — handler for graph_status
  callers.mjs         — handler for graph_callers
  callees.mjs         — handler for graph_callees
  trace.mjs           — handler for graph_trace
  impact.mjs          — handler for graph_impact
  node.mjs            — handler for graph_node
  context.mjs         — handler for graph_context
  metric.mjs          — event-log writer (used by dispatcher, not a tool)
```

`runMcpServer()` becomes ~40 LOC:

```js
async function runMcpServer() {
  const { Server } = await import('@modelcontextprotocol/sdk/server/index.js');
  const { StdioServerTransport } = await import('@modelcontextprotocol/sdk/server/stdio.js');
  const { ListToolsRequestSchema, CallToolRequestSchema } = await import('@modelcontextprotocol/sdk/types.js');
  const { TOOLS, dispatch } = await import('../scripts/graph/mcp-tools/index.mjs');

  const server = new Server(
    { name: 'sspower-graph', version: PKG_VERSION },
    { capabilities: { tools: {} } }
  );
  server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOLS }));
  server.setRequestHandler(CallToolRequestSchema, async ({ params }) => {
    const t0 = Date.now();
    let ok = true, result;
    try {
      result = await dispatch(params.name, params.arguments ?? {});
    } catch (e) { ok = false; throw e; }
    finally {
      const { recordEvent } = await import('../scripts/graph/mcp-tools/metric.mjs');
      await recordEvent({ tool: params.name, ok, duration_ms: Date.now() - t0, cwd: process.cwd() });
    }
    return result;
  });
  await server.connect(new StdioServerTransport());
}
```

Each per-tool handler reuses existing `withDb`/`graphDir` helpers (already
exported within `bin/sspower-graph.mjs`; promote to a shared module
`scripts/graph/db.mjs` if not already importable).

## 4. Adoption metric harness

### 4.1 Session identifier

**Decision (P3-D4 below)**: env propagation from a shell `export` in
`hooks/session-start` to the MCP-spawned child does NOT work — Claude
Code spawns the MCP server from its own parent env, and a hook subshell
cannot mutate the parent. The `.mcp.json` `env:` block accepts only
static values, not per-session vars.

The MCP server reads the current session id from a **per-project
session-state file** written by `hooks/session-start`:

```
~/.claude/state/sspower/sessions/<project_hash>.json
```

where `project_hash = sha8(realpath(cwd))`. Per-project keying (not a
single global file) prevents the misattribution race: two Claude Code
sessions in two different projects each own their own state file and
do not overwrite each other.

File format (atomic write via tempfile + rename):

```json
{
  "session_id": "01HXY…",
  "cwd": "/Users/sskys/proj-foo",
  "started_ts": "2026-05-27T14:18:02Z",
  "hook_event_name": "SessionStart",
  "source": "startup"
}
```

`hooks/session-start` parses Claude Code's documented stdin JSON
payload (common fields: `session_id`, `cwd`, `hook_event_name`,
`transcript_path`; SessionStart adds `source`, `model`). The hook
canonicalizes `cwd` with `realpath`, computes `project_hash`, and
writes the state file before returning. Permissions `0600` on file,
`0700` on `~/.claude/state/sspower/sessions/`.

The MCP server resolves the session id at the start of each
`CallToolRequest`:

1. Compute `project_hash = sha8(realpath(process.cwd()))` (or the
   tool's `cwd` argument if supplied).
2. Read `~/.claude/state/sspower/sessions/<project_hash>.json`.
3. Validate `record.cwd` equals the MCP cwd (canonicalized). If
   mismatch, treat as missing and fall through to degraded.
4. If file missing/stale (mtime > 24h) or cwd mismatch, fall back to
   `sha8(pid + boottime + cwd)` and flag `degraded_session_id_count`
   in the metric. The degraded id is stable within a single MCP
   server process, so events still group correctly per-process.

Date-based fallback is dropped: it had a non-trivial midnight boundary
bug AND blurred the denominator (two distinct Claude sessions on the
same day in the same project would collapse into one).

### 4.2 Event log writer (`scripts/graph/mcp-tools/metric.mjs`)

**Per-process spool jsonl** (resolves concurrent-write race) at:

```
~/.claude/state/sspower/graph-mcp/<session-id>.<pid>.jsonl
```

Each MCP server process gets its own jsonl. Even if multiple Claude Code
clients share a session id (unusual but possible with `--continue`), the
pid suffix guarantees no two **processes** contend on the same file.
Intra-process: async `fs.appendFile` calls **can** interleave under
libuv when MCP requests are handled concurrently — Node's single-thread
event loop does NOT serialize libuv worker writes, and `PIPE_BUF`
atomicity is a pipe/FIFO guarantee, not a regular-file guarantee.

**Mitigation**: metric writes use `fs.appendFileSync` (blocking write
on the event-loop thread) inside the `recordEvent` helper. Each
appendFileSync issues a single `write(2)` against an `O_APPEND` fd,
which IS atomic on regular files for writes up to a single block on
Linux/macOS (the kernel holds the inode lock for the duration of the
write). Record size is hard-capped at 4KB by `recordEvent` to stay
well inside that envelope. Trade-off: blocking write adds ~50µs to
each MCP response; acceptable given query latency budgets are ms-scale.

Record format:

```json
{"ts":"2026-05-27T14:22:01.337Z","tool":"graph_callers","ok":true,"duration_ms":34,"cwd":"/Users/sskys/proj","schema":1}
```

`schema:1` field included for forward-compat (future schema bumps add
fields without breaking aggregator parsing).

Parser contract: skip lines that fail `JSON.parse` (treat as partial /
truncated mid-write) but continue reading. Do not abort on bad lines.
A "bad lines / total lines > 1%" ratio is logged as
`degraded_jsonl_parse_ratio` in the aggregator output for diagnostics.

Best-effort: failure to write is logged to `stderr` but NEVER throws
back to the MCP request handler. The metric must not break query
execution. Tested via injected EIO failure in `test-mcp-metric.mjs`.

Directory permissions: `0700` on `~/.claude/state/sspower/graph-mcp/`,
`0600` on jsonl files. Reuses the existing `~/.claude/state/sspower/`
pattern from the Codex registry (`scripts/codex-registry.mjs`).

### 4.3 SessionEnd reconciler

New hook script: `hooks/graph-metric-reconcile.sh` (SessionEnd matcher).
Receives full stdin JSON payload (Claude Code documented fields:
`session_id`, `cwd`, `hook_event_name`, `transcript_path`, plus
SessionEnd-specific `reason`). The hook **MUST** parse `.cwd` from the
payload — the hook process cwd is plugin dir or `$HOME`, not project
cwd (verified empirically in `hooks/wiki-archive.py:776-779`).

```bash
#!/usr/bin/env bash
set -euo pipefail
PAYLOAD="$(cat)"
SID="$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty')"
CWD="$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty')"
[ -z "$SID" ] || [ -z "$CWD" ] && exit 0
node "$CLAUDE_PLUGIN_ROOT/scripts/graph/mcp-tools/metric.mjs" \
  reconcile --session "$SID" --cwd "$CWD" || true
exit 0
```

**Hook registration** (REQUIRED — measurability gate depends on it):
`hooks/hooks.json` gains a `SessionEnd` entry alongside the existing
`wiki-archive.sh`:

```json
"SessionEnd": [
  { "matcher": ".*",
    "hooks": [
      { "type": "command",
        "command": "${CLAUDE_PLUGIN_ROOT}/hooks/wiki-archive.sh" },
      { "type": "command",
        "command": "${CLAUDE_PLUGIN_ROOT}/hooks/graph-metric-reconcile.sh" }
    ]
  }
]
```

T1 deliverable includes the hooks.json edit + an integration test that
asserts SessionEnd in a fixture project produces a row in
`sessions.json` even when no MCP calls occurred (zero-call eligible
session).

**Always-write contract (resolves denominator gap)**: the reconciler
appends a row to `sessions.json` whether or not `<session-id>.*.jsonl`
exists. If no jsonl exists, the row is `{session_id, tool_calls:0,
zero_call_reason: "no_mcp_invocations", ...}`. This makes the
denominator = "every Claude session in which `hooks/session-start` ran"
— a well-defined, observable population.

`metric.mjs reconcile`:

1. Glob `<session-id>.*.jsonl`, parse each (skip bad lines per §4.2),
   merge events.
2. Compute per-session summary (schema below).
3. Acquire exclusive lock on `~/.claude/state/sspower/graph-mcp/.sessions.lock`
   via the existing `sspower_mem.lock.acquire_lock` helper (already
   battle-tested for graph dirty-queue writes).
4. Read `sessions.json` (treat missing/corrupt as empty), append the new
   row, tail-truncate, atomic temp+rename.
5. Release lock.
6. Move the per-session spool jsonl files to
   `~/.claude/state/sspower/graph-mcp/archive/<YYYYMM>/` (retention
   capped at 60 days; older archives pruned on each reconcile).

Per-session row schema:

```json
{
  "session_id": "01HXY…",
  "schema_version": 1,
  "session_source": "claude_session_id|degraded",
  "session_start_ts": "2026-05-27T14:18:02Z",
  "session_end_ts":   "2026-05-27T14:55:42Z",
  "project_hash": "sha8(cwd)",
  "eligible": true,
  "tool_calls": 7,
  "unique_tools": ["graph_callers","graph_trace"],
  "first_call_ts": "2026-05-27T14:22:01Z",
  "last_call_ts":  "2026-05-27T14:55:32Z",
  "zero_call_reason": null,
  "degraded": false
}
```

`zero_call_reason ∈ {null, "no_mcp_invocations", "session_id_missing",
"jsonl_unreadable"}`. `degraded:true` whenever
`session_source == "degraded"` or `zero_call_reason == "jsonl_unreadable"`.

`sessions.json` file shape:

```json
{
  "schema_version": 1,
  "updated": "2026-05-27T22:14:00Z",
  "sessions": [ <row>, <row>, ... ]
}
```

Tail-truncate `sessions[]` to most-recent 500 entries on each write,
ordered by `session_end_ts desc` (sessions missing `session_end_ts`
fall back to `last_call_ts`, then to `first_call_ts`, then dropped).
Atomic via write-tempfile + `fs.rename` (POSIX rename atomic on same fs)
under the held lock.

### 4.4 Aggregator CLI

```
sspower-graph metric [--json] [--window 50]
```

Prints (or returns JSON):

```json
{
  "window": 50,
  "eligible_sessions_total": 50,
  "sessions_with_call": 47,
  "adoption_rate": 0.94,
  "tool_histogram": {
    "graph_callers": 132, "graph_callees": 88, "graph_trace": 41,
    "graph_impact": 12,  "graph_node":    23, "graph_context": 9,
    "graph_status":   8
  },
  "p95_duration_ms_by_tool": { "graph_callers": 47, ... },
  "degraded_session_id_count": 0,
  "degraded_jsonl_parse_ratio": 0.0,
  "ineligible_sessions_excluded": 12,
  "gate_met": false
}
```

`gate_met = eligible_sessions_total >= 50 AND every row in that window has tool_calls >= 1`
(strict per §4.4 above; `adoption_rate` is informational).

Note: parent spec §4 P3 reads "≥1 call per session × 50 sessions".

**Denominator definition (resolves spec ambiguity)**: a "session" is a
Claude Code session for which `hooks/session-start` AND the
`SessionEnd` reconciler both fired and `project_hash` matches a project
that contains an `sspower-graph` index (i.e. `.claude/graph/`
directory). Sessions in projects with no graph index are excluded —
they cannot use MCP tools, so including them would dilute the
adoption signal toward zero by construction. This is recorded in the
row as `eligible: true|false` and the aggregator filters
`eligible == true` before applying the gate.

Aggregator implements **strict** reading: gate_met iff every one of
the 50 most-recent eligible sessions has tool_calls ≥1.

## 5. Sub-agent .md updates

### 5.0 Frontmatter `tools:` decision

Verified Claude Code agent semantics (current behavior, plugin
marketplace 2026-05-27): an agent file with no `tools:` frontmatter
field inherits the full toolset of the spawning context, INCLUDING all
MCP tools registered at the plugin level. Explicit `tools:` field
*restricts* the toolset (allowlist). `codex-rescue.md` uses this
restriction intentionally per D10.

**Decision (P3-D7 below)**: `code-reviewer.md`, `sanity-reviewer.md`,
`security-reviewer.md` do NOT add explicit `tools:` frontmatter. They
inherit, so the 7 MCP tools become available without further config.
The P3 agent-smoke test verifies each agent can in fact call ≥1 MCP
tool — if Claude Code semantics change, the smoke test red-flags it.

If a future Claude Code release changes inheritance default to deny,
the spec amendment is: add explicit `tools:` with `mcp__sspower-graph__*`
wildcard to all three agents. No prose change needed.

### 5.1 Section structure

Each of the 3 files gets a new `## Graph tool guidance` section appended
as the last section of the body (after the existing role instructions,
before any trailing examples block if present). ~15 LOC. Hard rule
lifted verbatim from parent spec §6:

> Call graph tools BEFORE delegating to the Explore subagent; never
> invoke graph tools from inside Explore.

### 5.2 `agents/code-reviewer.md` (role-tuned)

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

### 5.3 `agents/sanity-reviewer.md` (role-tuned)

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

### 5.4 `agents/security-reviewer.md` (role-tuned)

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

## 6. Test plan

| Layer | Test | File | Gate |
|---|---|---|---|
| Unit | per-tool handler with fixture DB returns CLI-equivalent JSON | `tests/graph/test-mcp-tools-unit.mjs` (new) | green |
| Integration | MCP smoke harness extended: listTools = 7 entries; callTool on each returns parseable payload | `tests/graph/test-mcp-stub.mjs` (extend existing) | green |
| P2 regression | each P2 CLI verb (`status`, `callers`, `callees`, `trace`, `impact`, `context`, `node`, `build`, `refresh`, `session-refresh`) — assert exit code, stderr, argv parsing, and `--json` output byte-identical to a pre-P3 golden | `tests/graph/test-p2-cli-back-compat.mjs` (new); golden output captured from `bd782c3` against each fixture pack | byte-identical match required |
| Session-state contract | SessionStart hook in fixture project writes `~/.claude/state/sspower/sessions/<project_hash>.json` with valid `session_id`+`cwd`; MCP server in same project reads it back and cwd-equality check passes; two parallel fixture projects each get own state file (no overwrite) | `tests/graph/test-session-state-contract.mjs` (new) | green; gate for T2 |
| Zero-call eligible session | Fixture project with `.claude/graph/` index runs a complete Claude Code session with ZERO MCP calls; SessionEnd reconciler still produces `{eligible:true, tool_calls:0, zero_call_reason:"no_mcp_invocations"}` row | `tests/graph/test-mcp-metric-zerocall.mjs` (new) | row present with correct fields |
| Metric concurrency | 50 parallel `CallToolRequest` calls in one session → reconciler produces 1 row with correct `tool_calls:50`; no jsonl corruption (uses `fs.appendFileSync` path) | `tests/graph/test-mcp-metric-concurrency.mjs` (new) | row count + tool_calls exact |
| Metric | synthesized event jsonl → reconciler → aggregator gate output (incl. zero-call sessions, ineligible projects, degraded fallback) | `tests/graph/test-mcp-metric.mjs` (new) | gate logic correct on synthetic 50-session input |
| Agent | manual: invoke each agent in a fixture project (graph index present); transcript shows ≥1 graph_* call before any Explore delegation | manual smoke (recorded in plan execution log) | each agent calls ≥1 graph tool |
| Perf | per-tool p95 latency over 100 invocations on 10k-file fixture | `tests/graph/perf-mcp.mjs` (new, opt-in via `SSPOWER_GRAPH_PERF=1`) | p95 ≤ 300ms (advisory) |

All Vitest harness tests under `__tests__/graph-fixtures/` remain green
without modification — the MCP layer doesn't touch the index schema.

## 7. Phase gate (spec §4 P3 row)

- 7 MCP tools shipped, all integration tests green.
- 3 agent `.md` files updated with role-tuned guidance + hard rule.
- `sspower-graph metric --json` over 50 most-recent sessions reports
  `gate_met:true`. Observed (not enforced as a build gate — gate is an
  in-field adoption check, not a CI assertion). Captured snapshot
  committed to `docs/plans/notes/2026-05-27-graph-P3-adoption-snapshot.json`
  at P3 ship time.

## 8. Risks

| Risk | Mitigation |
|---|---|
| Per-project session-state file (§4.1) missing / stale / cwd mismatch / concurrent overwrite | T1 smoke test: real SessionStart hook in fixture project writes the state file with correct `session_id`+`cwd`; MCP server in the same project reads it back and the cwd-equality check passes. Concurrent test: two fixture projects in parallel each get their own per-project file (`<sha8(cwd)>.json`); neither overwrites the other. Stale (>24h) and cwd-mismatch paths fall through to `degraded` and increment `degraded_session_id_count` in metric output. |
| MCP cold-start latency discourages adoption | `metric.mjs` records `duration_ms` per call. After 1 week of telemetry, if p95 > 300ms for any tool, profile and reduce — likely culprit is dynamic SDK import. Move imports to module top-level. |
| Agent prose regresses agent quality | Two-week observation window before declaring adoption met. If any agent's review-quality score drops, roll back that agent's section and iterate. |
| Spec §4 reads ≥1 call per session × 50 sessions ambiguously | Implementation locks the strict reading (every one of the most-recent 50 = ≥1 call). Documented in §4.4 of this spec. If user prefers looser reading (≥50% of last 50), parameterize via `--threshold 0.5`. |
| Metric harness sandbags MCP latency | `recordEvent` writes async, never blocks the MCP response. Failure logged to stderr, never thrown. Verified by injecting a write failure in tests. |
| Tool name collision with future codegraph install | All 7 tools prefixed `graph_`; codegraph upstream uses `codegraph_*`. No collision today; document the convention. |
| MCP server-key collision (`.mcp.json` `sspower-graph` key already used in a user's config) | Bootstrap script `bin/sspower-graph-bootstrap.sh` adds a preflight: if `~/.claude.json` or `<cwd>/.mcp.json` defines `mcpServers.sspower-graph` with a `command` that doesn't match `${CLAUDE_PLUGIN_ROOT}/bin/sspower-graph-bootstrap.sh`, log a clear stderr error and exit non-zero. Document the namespaced override path (`SSPOWER_GRAPH_MCP_KEY=sspower-graph-v2`) in README. Coexistence with upstream `codegraph install`: documented as supported (distinct server keys + distinct tool prefixes). |
| P2 CLI back-compat regression from §3 scaffolding refactor | The "P2 regression" test gate (§6) gates merge: any byte-diff in `--json` output, exit code, or argv parsing fails CI. Pre-P3 golden output captured from commit `bd782c3` against all 5 P2 fixture packs. |

## 9. Anti-goal circuit-breaker (parent §1)

Estimate: 5 task-days.

- T1: scaffolding refactor + 7 handlers + listTools wiring; **plus
  session-state contract smoke (SessionStart→file→MCP-read→cwd-match)
  in fixture project — gate before T2 starts**; `hooks/session-start`
  edit to write the per-project state file; `hooks/hooks.json`
  registration for new `SessionEnd` reconciler hook.
- T2: metric.mjs (writer + reconcile + aggregator) +
  `hooks/graph-metric-reconcile.sh` + zero-call session integration
  test + concurrency test.
- T3: 3 agent .md updates + manual agent smoke (each agent invokes
  ≥1 graph tool in fixture project).
- T4: P2 CLI back-compat regression tests + perf tests + perf gate
  verification.
- T5: plan-review + ship + tag + handoff.

**Trigger** (any one fires the anti-goal — `codegraph install`
companion script instead):

1. **Hard time gate**: 10 task-days elapsed from worktree creation
   without merged PR.
2. **Session-state hook contract failure**: end of T1 (BEFORE metric
   harness lands) with the per-project state file contract
   (§4.1 P3-D4) unverified — i.e. a real SessionStart hook in a fixture
   project fails to atomically write
   `~/.claude/state/sspower/sessions/<project_hash>.json` with valid
   `session_id`+`cwd`, OR the MCP server's cwd-equality check fails on
   that file. Triggered EARLIER than T2 because the metric harness
   design depends on this contract — find out fast.
3. **Concurrency gate failure**: `test-mcp-metric-concurrency.mjs`
   cannot pass after one fix attempt — implies the metric design
   itself is wrong, not a tactical bug.
4. **Agent invocation impossibility**: any of the 3 agents cannot
   call any MCP tool in the smoke test due to Claude Code permission
   semantics, AND adding explicit `tools:` frontmatter does not fix it.
5. **P2 regression unresolvable**: P2 back-compat test gate fails and
   remains failing after one fix attempt — the refactor in §3 broke
   shipped behavior and cannot be undone without rewriting the MCP
   approach.
6. **MCP cold-start p95 > 1s** on the fixture even after moving SDK
   imports to module top-level (the only known tuning lever).

Any trigger fires: stop P3 in-tree work, draft `codegraph install`
companion plan, ship that instead.

## 10. Locked decisions (P3-specific; parent §10 uses D1..D11, so this
spec uses prefix `P3-D*` to avoid collision)

- **P3-D1**: 7 MCP tools = `graph_{status,callers,callees,trace,impact,node,context}`.
  `graph_routes` deferred to P4. Tool names lock at P3; renames after P3
  ship require a parent-spec amendment.
- **P3-D2**: Output shape is `{content:[{type:'text', text:<JSON>}]}`
  where the JSON matches CLI `--json` byte-identical. Tests assert
  exact match against `sspower-graph <verb> --json` golden output on
  fixture DB.
- **P3-D3**: Adoption metric uses strict reading of parent §4 P3 — every
  one of the 50 most-recent **eligible** sessions must show ≥1 graph
  tool call. Eligibility = project has `.claude/graph/` index. Looser
  thresholds are CLI flags, not the default.
- **P3-D4**: Session id is read from
  `~/.claude/state/sspower/sessions/<project_hash>.json` (per-project
  keyed by `sha8(realpath(cwd))`, written by `hooks/session-start`
  from its stdin payload). The MCP server validates `record.cwd`
  equals MCP cwd before trusting the id. No env propagation required.
  Fallback `sha8(pid+boottime+cwd)` only when the state file is
  missing/stale (>24h)/cwd-mismatch; flagged as `degraded` in metric
  output.
- **P3-D5**: Per-tool handlers live under
  `scripts/graph/mcp-tools/<tool>.mjs`, not inlined in
  `bin/sspower-graph.mjs`. The bin file orchestrates only. Shared db
  helpers promoted to `scripts/graph/db.mjs` if not already.
- **P3-D6**: Metric concurrency uses per-process spool jsonl
  (`<session-id>.<pid>.jsonl`); reconcile merges spool files under
  exclusive lock via `sspower_mem.lock.acquire_lock`. SessionEnd
  reconciler always writes a row (zero-call sessions included) so the
  denominator is observable.
- **P3-D7**: Reviewer agents (`code-reviewer`, `sanity-reviewer`,
  `security-reviewer`) do NOT receive explicit `tools:` frontmatter;
  they inherit the spawning context's toolset, which includes MCP
  tools. Verified at P3-implementation time via smoke test; if
  semantics change, amendment adds explicit `tools: mcp__sspower-graph__*`
  wildcard.

## 11. Open questions (to resolve in plan, not blocking spec)

1. Does the existing `tests/graph/test-mcp-stub.mjs` harness need a
   fixture DB seeded before listTools, or does the SDK tolerate a missing
   DB until callTool? Probe before T1.
2. `graph_context "<task>"` underlying handler accepts free-form task
   strings. Confirm MCP input validation clamps `task.length ≤ 500` to
   avoid token-budget blowup in caller subagents.
3. P2 golden capture path — the `test-p2-cli-back-compat.mjs` golden
   needs to be regenerated whenever a future P3+ change intentionally
   shifts CLI output. Define the regeneration script
   (`tests/graph/regenerate-cli-goldens.sh`) at T1 to avoid friction
   when the intentional shift comes.

Closed (decisions moved to §10):

- Session id contract → P3-D4.
- Frontmatter `tools:` field → P3-D7.

---

End of spec.
