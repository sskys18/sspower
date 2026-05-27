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
   `sessions_with_call / sessions_total ≥ 1.0` over the 50 most-recent
   distinct sessions captured in
   `~/.claude/state/sspower/graph-mcp/sessions.json`.
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

Resolution order inside `recordEvent`:

1. `process.env.CLAUDE_SESSION_ID` if present.
2. `process.env.CLAUDE_PROJECT_DIR` + start-of-day timestamp
   (`YYYYMMDD` in UTC) if `CLAUDE_SESSION_ID` absent.
3. Fallback: `sha8(pid + boottime + cwd)` — flagged in metric report as
   `degraded_session_id_count`.

The hard preference is (1). The hook contract change to guarantee (1):
extend `hooks/session-start` to export `CLAUDE_SESSION_ID=<uuid>` into the
environment of any subsequently-spawned MCP server. Verify Claude Code
session-start hooks can export env — if not, fall through to (2).

### 4.2 Event log writer (`scripts/graph/mcp-tools/metric.mjs`)

Append-only JSONL at `~/.claude/state/sspower/graph-mcp/<session-id>.jsonl`:

```json
{"ts":"2026-05-27T14:22:01.337Z","tool":"graph_callers","ok":true,"duration_ms":34,"cwd":"/Users/sskys/proj"}
```

Atomic append via `fs.appendFile` (jsonl tolerates partial writes — last
line discarded by parsers). Best-effort: failure to write is logged to
`stderr` but NEVER throws back to the MCP request handler. The metric
must not break query execution.

Directory permissions: `0700` on the per-session dir, `0600` on jsonl
files. Reuses the existing `~/.claude/state/sspower/` pattern from the
Codex registry (`scripts/codex-registry.mjs`).

### 4.3 SessionEnd reconciler

New hook script: `hooks/graph-metric-reconcile.sh` (PostSessionEnd matcher).

```bash
#!/usr/bin/env bash
set -euo pipefail
SID="${CLAUDE_SESSION_ID:-}"
[ -z "$SID" ] && exit 0
node "$CLAUDE_PLUGIN_ROOT/scripts/graph/mcp-tools/metric.mjs" reconcile --session "$SID" || true
exit 0
```

`metric.mjs reconcile` reads `<session-id>.jsonl`, computes per-session
summary `{session_id, tool_calls, unique_tools, first_call_ts,
last_call_ts}`, and appends to
`~/.claude/state/sspower/graph-mcp/sessions.json`:

```json
{
  "schema_version": 1,
  "updated": "2026-05-27T22:14:00Z",
  "sessions": [
    {
      "session_id": "01HXY…",
      "tool_calls": 7,
      "unique_tools": ["graph_callers", "graph_trace"],
      "first_call_ts": "2026-05-27T14:22:01Z",
      "last_call_ts":  "2026-05-27T14:55:32Z"
    }
  ]
}
```

Tail-truncate `sessions[]` to most-recent 500 entries on each write,
ordered by `last_call_ts desc` (sessions with no `last_call_ts` are
dropped first). Atomic via write-tempfile + `fs.rename` (POSIX rename
atomic on same fs).

### 4.4 Aggregator CLI

```
sspower-graph metric [--json] [--window 50]
```

Prints (or returns JSON):

```json
{
  "window": 50,
  "sessions_total": 50,
  "sessions_with_call": 47,
  "adoption_rate": 0.94,
  "tool_histogram": {
    "graph_callers": 132, "graph_callees": 88, "graph_trace": 41,
    "graph_impact": 12,  "graph_node":    23, "graph_context": 9,
    "graph_status":   8
  },
  "p95_duration_ms_by_tool": { "graph_callers": 47, ... },
  "degraded_session_id_count": 0,
  "gate_met": true
}
```

`gate_met = sessions_with_call >= 50 AND adoption_rate >= 1.0`.

Note: spec §4 reads "≥1 call per session × 50 sessions". Strict reading
= 50 *consecutive* sessions all with ≥1 call. Aggregator implements
strict: gate_met iff every one of the 50 most-recent sessions has
tool_calls ≥1.

## 5. Sub-agent .md updates

Each of the 3 files gets a new `## Graph tool guidance` section appended
as the last section of the body (after the existing role instructions,
before any trailing examples block if present). ~15 LOC. Hard rule
lifted verbatim from parent spec §6:

> Call graph tools BEFORE delegating to the Explore subagent; never
> invoke graph tools from inside Explore.

### 5.1 `agents/code-reviewer.md` (role-tuned)

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

### 5.2 `agents/sanity-reviewer.md` (role-tuned)

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

### 5.3 `agents/security-reviewer.md` (role-tuned)

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
| Metric | synthesized event jsonl → reconciler → aggregator gate output | `tests/graph/test-mcp-metric.mjs` (new) | gate logic correct on synthetic 50-session input |
| Agent | manual: invoke each agent in a fixture project; transcript shows ≥1 graph_* call before any Explore delegation | manual smoke (recorded in plan execution log) | each agent calls ≥1 graph tool |
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
| `CLAUDE_SESSION_ID` env not propagated to MCP child process | Probe early in P3 implementation: if Claude Code session-start hook cannot export env to the MCP-spawned process, fall through to date-based session-id and flag `degraded_session_id_count`. Worst case: aggregation slightly lossy at midnight boundary but adoption signal intact. |
| MCP cold-start latency discourages adoption | `metric.mjs` records `duration_ms` per call. After 1 week of telemetry, if p95 > 300ms for any tool, profile and reduce — likely culprit is dynamic SDK import. Move imports to module top-level. |
| Agent prose regresses agent quality | Two-week observation window before declaring adoption met. If any agent's review-quality score drops, roll back that agent's section and iterate. |
| Spec §4 reads ≥1 call per session × 50 sessions ambiguously | Implementation locks the strict reading (every one of the most-recent 50 = ≥1 call). Documented in §4.4 of this spec. If user prefers looser reading (≥50% of last 50), parameterize via `--threshold 0.5`. |
| Metric harness sandbags MCP latency | `recordEvent` writes async, never blocks the MCP response. Failure logged to stderr, never thrown. Verified by injecting a write failure in tests. |
| Tool name collision with future codegraph install | All 7 tools prefixed `graph_`; codegraph upstream uses `codegraph_*`. No collision today; document the convention. |

## 9. Anti-goal circuit-breaker (parent §1)

Estimate: 5 task-days.

- T1: scaffolding refactor + 7 handlers + listTools wiring.
- T2: metric.mjs (writer + reconcile + aggregator) + tests.
- T3: 3 agent .md updates + manual agent smoke.
- T4: integration + perf tests + perf gate verification.
- T5: plan-review + ship + tag + handoff.

If execution exceeds 10 task-days (2 weeks) measured from worktree
creation to merged PR, fire spec §1 anti-goal: abandon P3 in-tree, ship
`codegraph install` companion script that installs the upstream MIT
package and aliases its tools under `sspower-graph` prefix. Decision
point: 10 task-days elapsed without merged PR → trigger.

## 10. Locked decisions (P3-specific, additions to parent §10)

- **D11**: 7 MCP tools = `graph_{status,callers,callees,trace,impact,node,context}`.
  `graph_routes` deferred to P4. Tool names lock at P3; renames after P3
  ship require a parent-spec amendment.
- **D12**: Output shape is `{content:[{type:'text', text:<JSON>}]}` where
  the JSON matches CLI `--json` byte-identical. Tests assert exact match
  against `sspower-graph <verb> --json` golden output on fixture DB.
- **D13**: Adoption metric uses strict reading of spec §4 P3 — every one
  of the 50 most-recent sessions must show ≥1 graph tool call. Looser
  thresholds are CLI flags, not the default.
- **D14**: `CLAUDE_SESSION_ID` is the canonical session identifier. Date-
  based fallback is degraded; sha8(pid+boottime+cwd) is last-resort.
  Hook contract update may be required; probe early.
- **D15**: Per-tool handlers live under `scripts/graph/mcp-tools/<tool>.mjs`,
  not inlined in `bin/sspower-graph.mjs`. The bin file orchestrates only.

## 11. Open questions (to resolve in plan, not blocking spec)

1. Does Claude Code's session-start hook contract permit exporting env
   vars consumed by MCP child processes? Probe before T2.
2. Does the existing `tests/graph/test-mcp-stub.mjs` harness need a
   fixture DB seeded before listTools, or does the SDK tolerate a missing
   DB until callTool? Probe before T1.
3. `graph_context "<task>"` underlying handler accepts free-form
   task strings. Does the MCP input validation need to constrain length
   to avoid token-budget blowup in caller subagents? Decision: clamp
   `task.length ≤ 500`; document in tool schema.
4. Sub-agent `.md` updates — should each agent's frontmatter `tools:`
   field be extended to explicitly list the 7 MCP tools? Today agents
   without an explicit `tools:` line inherit "All tools". Decision pending
   verification of Claude Code agent semantics.

---

End of spec.
