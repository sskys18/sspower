# sspower-graph P4 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `sspower:subagent-driven-development` (recommended) or `sspower:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship hooks orchestration so the graph index actually pays off at prompt-injection time, plus the first framework (Express) for route intelligence. Drop-in replace `semble-context.sh` in the UserPromptSubmit chain with `graph-orchestrator.sh`; add graph-impact enrichment + cache-key revision to `auto-review.sh`; add Express route extraction + `routes` CLI verb + `graph_routes` MCP tool.

**Architecture:**

```
UserPromptSubmit:
  prompt-submit  → diet-track  → codex-track-prompt  → graph-orchestrator.sh (NEW; replaces semble-context.sh)
                                                       ├── fork: timeout 5s semble_rs plan ... (existing semble path)
                                                       └── fork: timeout 5s sspower-graph context ...
                                                       wait wall 6s · 2KB/2KB merge · jq-emit one block
                                                       (graph absent OR dirty non-empty → exec semble-context.sh; pure fallback)

PreToolUse:Bash → auto-review.sh
  cache key:    DIFF_HASH || GRAPH_VERSION || GRAPH_HASH   (graph absent → omit terms; pre-graph behavior preserved)
  enrichment:   on cache miss, parse diff for changed files →
                parallel sspower-graph impact <file> --json --timeout 3s (cap 8) →
                append "# Graph impact" section to MAIN_PROMPT_FILE
                (skip-if-dirty: graph dirty non-empty → emit empty section + log reason=stale_index)

Express extractor:
  scripts/graph/rules/ts-express-*.yml       (3 rules: app.METHOD, router.METHOD, mount)
  scripts/graph/extract-ts.mjs               (route-node emission + route edge kind)
  __tests__/graph-fixtures/express/          (5 fixtures with goldens)
  bin/sspower-graph.mjs CLI: `routes [--framework F]`
  scripts/graph/mcp-tools/routes.mjs         (8th MCP tool; reads shared queries.mjs)
```

**Tech Stack:** Node ≥22.5, `@modelcontextprotocol/sdk` (already-vendored), `node:sqlite`, bun, vitest, bash, jq. No new external deps.

**Spec:** `docs/specs/2026-05-26-codegraph-style-graph-design.md` v5 §3.5 + §4 P4 row + §3.6.

**Phase budget:** 6 task-days (T1..T13). Anti-goal: if any of P3-level §9 triggers fires OR if 12 task-days exceeded, STOP — defer Express to P5 and ship orchestrator+auto-review alone.

## Decisions locked before drafting (P4-D1..D6)

- **P4-D1**: Orchestrator budget split = parallel-equal. Both children get `timeout 5s` independently; wall budget 6s after which survivors are SIGTERM'd. Reason: architecture-intent prompts (graph-only useful) shouldn't wait on semble.
- **P4-D2**: 4KB merge cap = budget-per-source: 2KB semble + 2KB graph, truncated independently with `[...truncated]` markers. Reason: round-robin merge lets one fast source starve the other.
- **P4-D3**: Graph-absent fallback = orchestrator `exec`s `semble-context.sh`. `semble-context.sh` remains source of truth for semble gating; orchestrator becomes a routing shim. Reason: less duplication, easier rollback.
- **P4-D4**: Dirty-queue staleness = if `<cwd>/.claude/graph/dirty` non-empty, orchestrator SKIPS the graph child (semble-only fallback). Auto-review enrichment likewise skips. Reason: stale impact lies; inline-refresh inside a prompt-time hook would blow the wall budget.
- **P4-D5**: `graph_routes` MCP tool + CLI `routes` verb ship in P4 (8th MCP tool; supersedes P3-D1's "7 tools"). Express extractor without surface = dead data.
- **P4-D6**: Two feature flags. `SSPOWER_GRAPH_ORCHESTRATOR=on|off` (default `off` until eval gate passes; flip to `on` in Task 13 after metrics commit). `SSPOWER_GRAPH=on|off` retained as the umbrella kill switch. Reason: ship orchestrator code dark while running baseline eval; switch deploys are reversible by env, not git revert.

## Execution conventions (READ FIRST)

This plan is intended to run under `sspower:subagent-driven-development` (recommended; see Execution Handoff section at end for dependency-aware fan-out). Two alternatives: `sspower:executing-plans` (Claude inline, serial T1→T13) or Codex worker per task. Codex workers CANNOT commit — repo `AGENTS.md` rule: Codex workers MUST leave changes uncommitted; the supervisor commits.

Ordering constraint: strict serial T1 → T2. T3-T7 and T8-T11 are independent and can fan out in parallel AFTER T2 commits the baseline. Strict serial T12 → T13 at the end.

Every task ends with a step that:

1. Writes the suggested commit message to a temp file (`/tmp/commit-msg-p4-<task>.txt`).
2. Stages the files via `git add <exact paths>`.
3. **If Claude (inline or subagent): runs `git commit -F /tmp/commit-msg-p4-<task>.txt` as a standalone Bash invocation per the chokepoint policy.**
4. **If Codex: STOPS HERE. Reports `staged: <files>; commit-msg: /tmp/commit-msg-p4-<task>.txt` and lets the supervisor run the commit.**

Task-end commit commands are written as Claude-mode. Codex workers must skip the `git commit` line and stop after staging.

`git push` / `gh pr ...` only appear in Task 13 and are exclusively supervisor actions regardless of executor.

## additionalContext contract (load-bearing)

Each UserPromptSubmit hook emits its OWN `{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:<str>}}` block. They accumulate — not collide (verified against `prompt-submit`, `diet-track.js`, `codex-track-prompt.sh`, `semble-context.sh`). Orchestrator emits ONE merged block where semble section is wrapped with the existing `[semble_rs repo orientation - advisory, token-cheap; verify before acting]:` marker so downstream consumers see no shape change.

## Eval gate contract (load-bearing)

Net-positive criterion is frozen in `tests/graph/p4-eval/criteria.json` and re-read by `tests/graph/p4-eval/gate.mjs` — there is no human judgment at gate time. A candidate run PASSES iff:

```
  mean(answerable_candidate) >= mean(answerable_baseline)
  AND mean(bytes_candidate) <= 1.5 * mean(bytes_baseline)
  AND p95(wall_ms_candidate) <= 6500
```

OR strictly:

```
  mean(answerable_candidate) >= mean(answerable_baseline) + 0.15
  AND mean(bytes_candidate) <= 4096
  AND p95(wall_ms_candidate) <= 6500
```

`answerable` per-prompt = fraction of `expected_evidence` entries (each is a `file_path` substring or qualified-name token) found in the emitted `additionalContext`. Baseline = `SSPOWER_GRAPH_ORCHESTRATOR=off` (semble-only). Candidate = `SSPOWER_GRAPH_ORCHESTRATOR=on`.

Failing the gate → rollback: revert `hooks.json` swap, KEEP Express extractor + `graph_routes` + auto-review changes (independently shippable in a follow-up PR).

---

## File map

| Action | Path | Reason |
|---|---|---|
| Create | `tests/graph/p4-eval/prompts.json` | 20-prompt fixture (12 coding + 8 architecture) with `expected_evidence` |
| Create | `tests/graph/p4-eval/criteria.json` | net-positive thresholds (frozen pre-baseline) |
| Create | `tests/graph/p4-eval/run.mjs` | hook-driver: feeds each prompt through the UserPromptSubmit chain, captures bytes + answerable + wall |
| Create | `tests/graph/p4-eval/gate.mjs` | reads baseline.json + candidate.json, applies criteria.json, exits 0/1 |
| Create | `docs/plans/notes/2026-05-27-graph-P4-eval-baseline.json` | Task 2 output — committed |
| Create | `docs/plans/notes/2026-05-27-graph-P4-eval-candidate.json` | Task 12 output — committed |
| Create | `scripts/graph/rules/ts-express-route.yml` | `app.<METHOD>('/path', handler)` pattern |
| Create | `scripts/graph/rules/ts-express-router.yml` | `router.<METHOD>('/path', handler)` pattern |
| Create | `scripts/graph/rules/ts-express-mount.yml` | `app.use('/prefix', router)` pattern |
| Modify | `scripts/graph/extract-ts.mjs` | new RULE_FILES entries; emit `kind=route` nodes + `kind=routes` edges; mount-path embedded in qname |
| Create | `__tests__/graph-fixtures/express/app.ts` | minimal Express app fixture |
| Create | `__tests__/graph-fixtures/express/router.ts` | sub-router fixture |
| Create | `__tests__/graph-fixtures/express/mount.ts` | mount-path fixture |
| Create | `__tests__/graph-fixtures/express/expected.json` | golden nodes + edges |
| Modify | `bin/sspower-graph.mjs` | add `routes [--framework F]` CLI verb |
| Create | `scripts/graph/queries.mjs` (extend) | `queryRoutes(cwd, { framework })` function |
| Create | `scripts/graph/mcp-tools/routes.mjs` | `graph_routes` MCP handler |
| Modify | `scripts/graph/mcp-tools/index.mjs` | register `routes` in TOOLS array |
| Create | `hooks/graph-orchestrator.sh` | new UserPromptSubmit hook (replaces semble-context.sh slot) |
| Modify | `hooks/hooks.json` | swap `semble-context.sh` entry → `graph-orchestrator.sh`; timeout 8s preserved |
| Modify | `hooks/auto-review.sh` | cache-key revision + enrichment block |
| Create | `tests/graph/test-p4-orchestrator.mjs` | unit: budget split, 4KB merge, fail-open, dirty-skip, graph-absent exec fallback |
| Create | `tests/graph/test-p4-express-extract.mjs` | Express fixture P/R thresholds |
| Create | `tests/graph/test-p4-routes-cli.mjs` | CLI `routes` byte-identical output |
| Create | `tests/graph/test-p4-routes-mcp.mjs` | MCP `graph_routes` ≡ CLI `--json` (canonical equivalence per F1) |
| Create | `tests/graph/test-p4-auto-review-cachekey.mjs` | cache-key incorporates GRAPH_VERSION + GRAPH_HASH; absence preserves pre-graph hash |
| Create | `tests/graph/test-p4-auto-review-enrichment.mjs` | enrichment runs on miss, skips on dirty non-empty, parallel cap 8, per-file 3s timeout |
| Modify | `package.json` | new scripts: `graph:p4-eval-baseline`, `graph:p4-eval-candidate`, `graph:p4-eval-gate`, `graph:p4-tests` |
| Modify | `CLAUDE.md` | P4 row in sspower-graph subsystem block; bump tool count to 8 |
| Modify | `README.md` | new env vars `SSPOWER_GRAPH_ORCHESTRATOR`; document orchestrator wall budget; document Express scope; document `graph_routes` |

---

## Task 1 — Eval fixture + harness skeleton (eval-first, no implementation yet)

Build the 20-prompt fixture and harness BEFORE any implementation so the baseline measurement (Task 2) is reproducible and the gate (Task 12) re-runs the same harness.

### Step 1.1 — Create fixture prompts

- [ ] Create `tests/graph/p4-eval/prompts.json` with exactly 20 entries. 12 coding-intent + 8 architecture-intent. Each entry:

```json
{
  "id": "p01",
  "intent": "coding",
  "cwd": "{{REPO_ROOT}}",
  "prompt": "fix the timeout handling in semble-context.sh — make the perl fallback respect the same env var",
  "expected_evidence": [
    "hooks/semble-context.sh",
    "SSPOWER_SEMBLE_TIMEOUT"
  ]
}
```

Required prompt distribution (frozen; reviewer agents will re-check this list):

| id | intent | prompt theme | expected_evidence (≥1, ≤5) |
|---|---|---|---|
| p01 | coding | fix timeout in semble-context.sh | `hooks/semble-context.sh`, `SSPOWER_SEMBLE_TIMEOUT` |
| p02 | coding | add a new MCP tool `graph_orphans` | `scripts/graph/mcp-tools/index.mjs`, `TOOLS` |
| p03 | coding | refactor `extractFile` to support a new language | `scripts/graph/extract-ts.mjs`, `extractFile` |
| p04 | coding | wire a new ast-grep rule into the TS extractor | `scripts/graph/extract-ts.mjs`, `RULE_FILES` |
| p05 | coding | change the auto-review verdict cache TTL | `hooks/auto-review.sh`, `SSPOWER_REVIEW_CACHE_TTL` |
| p06 | coding | add a new `--limit` flag to `graph_callers` | `scripts/graph/mcp-tools/callers.mjs`, `queryCallers` |
| p07 | coding | move the diet activation hook to a different SessionStart slot | `hooks/diet-activate.js`, `hooks/hooks.json` |
| p08 | coding | rename `graph_status` → `graph_health` | `scripts/graph/mcp-tools/status.mjs`, `graph_status` |
| p09 | coding | add a new field `extension` to the `files` table | `scripts/graph/db.mjs`, `files` |
| p10 | coding | change the orchestrator wall budget from 6s to 8s | `hooks/graph-orchestrator.sh`, `WALL_BUDGET` |
| p11 | coding | add a parallel-cap tunable to auto-review enrichment | `hooks/auto-review.sh`, enrichment |
| p12 | coding | fix the lock helper to ignore stale lockfiles | `scripts/sspower_mem/sspower_mem/lock.py`, `acquire_lock` |
| p13 | architecture | what calls `extractFile`? | `scripts/graph/refresh.mjs`, `extractFile` |
| p14 | architecture | trace the path from `semble-context.sh` to `semble_rs plan` | `hooks/semble-context.sh`, `semble_rs plan` |
| p15 | architecture | what would changing `db.mjs` break? | `scripts/graph/db.mjs`, `withDb`, `graphDirFor` |
| p16 | architecture | how does the MCP server reach `queryCallers`? | `bin/sspower-graph.mjs`, `scripts/graph/queries.mjs`, `queryCallers` |
| p17 | architecture | where are graph events recorded? | `scripts/graph/mcp-tools/metric.mjs`, `recordEvent` |
| p18 | architecture | what writes to `<cwd>/.claude/graph/dirty`? | `hooks/graph-mark-dirty.sh`, `scripts/graph-append-dirty.py` |
| p19 | architecture | trace the auto-review chokepoint detection | `hooks/auto-review.sh`, `_parse-git-cmd.py`, `chain_position` |
| p20 | architecture | what reads the session-state file? | `scripts/graph/session-state.mjs`, `readSessionState` |

The fixture is a self-test — it targets the sspower repo itself so prompts have known-stable expected_evidence.

### Step 1.2 — Freeze gate criteria

- [ ] Create `tests/graph/p4-eval/criteria.json`:

```json
{
  "version": 1,
  "modes": [
    {
      "name": "balanced",
      "answerable_mean_delta_min": 0.0,
      "bytes_mean_ratio_max": 1.5,
      "wall_p95_ms_max": 6500
    },
    {
      "name": "answerable-first",
      "answerable_mean_delta_min": 0.15,
      "bytes_mean_cap": 4096,
      "wall_p95_ms_max": 6500
    }
  ],
  "pass_if": "balanced OR answerable-first"
}
```

### Step 1.3 — Build hook driver

- [ ] Create `tests/graph/p4-eval/run.mjs`. Drives the UserPromptSubmit chain against each fixture prompt, captures the merged `additionalContext`, measures wall time, computes `answerable` per prompt.

```js
#!/usr/bin/env node
// tests/graph/p4-eval/run.mjs
// Usage: node run.mjs --mode baseline|candidate --out <path.json>
//   baseline:  SSPOWER_GRAPH_ORCHESTRATOR=off  (semble-context.sh runs)
//   candidate: SSPOWER_GRAPH_ORCHESTRATOR=on   (graph-orchestrator.sh runs)
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import url from 'node:url';

const HERE = path.dirname(url.fileURLToPath(import.meta.url));
const PLUGIN_ROOT = path.resolve(HERE, '..', '..', '..');
const PROMPTS = JSON.parse(fs.readFileSync(path.join(HERE, 'prompts.json'), 'utf8'));

const args = parseArgs(process.argv.slice(2));
const mode = args.mode === 'candidate' ? 'candidate' : 'baseline';
const outPath = args.out;
if (!outPath) { console.error('--out required'); process.exit(2); }

const env = {
  ...process.env,
  CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT,
  SSPOWER_GRAPH_ORCHESTRATOR: mode === 'candidate' ? 'on' : 'off',
  SSPOWER_SEMBLE: '1',
};

// In candidate mode, run graph-orchestrator.sh; in baseline, semble-context.sh.
// Both consume the same JSON payload on stdin and emit hookSpecificOutput on stdout.
const HOOK = mode === 'candidate'
  ? path.join(PLUGIN_ROOT, 'hooks', 'graph-orchestrator.sh')
  : path.join(PLUGIN_ROOT, 'hooks', 'semble-context.sh');

const results = [];
for (const p of PROMPTS) {
  const cwd = p.cwd.replace('{{REPO_ROOT}}', PLUGIN_ROOT);
  const payload = JSON.stringify({ prompt: p.prompt, cwd });
  const t0 = Date.now();
  const r = spawnSync(HOOK, [], { input: payload, env, encoding: 'utf8', timeout: 10_000 });
  const wallMs = Date.now() - t0;
  let additionalContext = '';
  try {
    const j = JSON.parse(r.stdout || '{}');
    additionalContext = j?.hookSpecificOutput?.additionalContext ?? '';
  } catch { /* empty emission OK */ }
  const bytes = Buffer.byteLength(additionalContext, 'utf8');
  const hits = p.expected_evidence.filter(ev => additionalContext.includes(ev)).length;
  const answerable = p.expected_evidence.length === 0 ? 1 : hits / p.expected_evidence.length;
  results.push({ id: p.id, intent: p.intent, wallMs, bytes, answerable, exit: r.status });
}

const summary = {
  mode, n: results.length,
  mean_bytes: mean(results.map(r => r.bytes)),
  mean_answerable: mean(results.map(r => r.answerable)),
  p95_wall_ms: p95(results.map(r => r.wallMs)),
  results,
};
fs.writeFileSync(outPath, JSON.stringify(summary, null, 2) + '\n');
console.log(`wrote ${outPath}: bytes=${summary.mean_bytes.toFixed(0)} ans=${summary.mean_answerable.toFixed(2)} p95=${summary.p95_wall_ms}ms`);

function mean(xs) { return xs.reduce((a,b)=>a+b,0) / xs.length; }
function p95(xs) { const s = [...xs].sort((a,b)=>a-b); return s[Math.floor(s.length * 0.95)]; }
function parseArgs(argv) {
  const o = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith('--')) o[argv[i].slice(2)] = argv[i+1];
  }
  return o;
}
```

### Step 1.4 — Build gate

- [ ] Create `tests/graph/p4-eval/gate.mjs`:

```js
#!/usr/bin/env node
// tests/graph/p4-eval/gate.mjs
// Usage: node gate.mjs --baseline <a.json> --candidate <b.json> --criteria <c.json>
import fs from 'node:fs';
const args = parseArgs(process.argv.slice(2));
const base = JSON.parse(fs.readFileSync(args.baseline, 'utf8'));
const cand = JSON.parse(fs.readFileSync(args.candidate, 'utf8'));
const crit = JSON.parse(fs.readFileSync(args.criteria, 'utf8'));

const ansDelta = cand.mean_answerable - base.mean_answerable;
const bytesRatio = cand.mean_bytes / Math.max(base.mean_bytes, 1);

const modes = {};
for (const m of crit.modes) {
  if (m.name === 'balanced') {
    modes.balanced =
      ansDelta >= m.answerable_mean_delta_min &&
      bytesRatio <= m.bytes_mean_ratio_max &&
      cand.p95_wall_ms <= m.wall_p95_ms_max;
  } else if (m.name === 'answerable-first') {
    modes['answerable-first'] =
      ansDelta >= m.answerable_mean_delta_min &&
      cand.mean_bytes <= m.bytes_mean_cap &&
      cand.p95_wall_ms <= m.wall_p95_ms_max;
  }
}
const pass = modes.balanced || modes['answerable-first'];

const report = {
  baseline: { bytes: base.mean_bytes, answerable: base.mean_answerable, p95_wall_ms: base.p95_wall_ms },
  candidate: { bytes: cand.mean_bytes, answerable: cand.mean_answerable, p95_wall_ms: cand.p95_wall_ms },
  delta: { answerable: ansDelta, bytes_ratio: bytesRatio },
  modes, pass,
};
console.log(JSON.stringify(report, null, 2));
process.exit(pass ? 0 : 1);

function parseArgs(argv) {
  const o = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith('--')) o[argv[i].slice(2)] = argv[i+1];
  }
  return o;
}
```

### Step 1.5 — package.json scripts

- [ ] Append to `package.json` scripts block:

```json
"graph:p4-eval-baseline":  "node tests/graph/p4-eval/run.mjs --mode baseline  --out docs/plans/notes/2026-05-27-graph-P4-eval-baseline.json",
"graph:p4-eval-candidate": "node tests/graph/p4-eval/run.mjs --mode candidate --out docs/plans/notes/2026-05-27-graph-P4-eval-candidate.json",
"graph:p4-eval-gate":      "node tests/graph/p4-eval/gate.mjs --baseline docs/plans/notes/2026-05-27-graph-P4-eval-baseline.json --candidate docs/plans/notes/2026-05-27-graph-P4-eval-candidate.json --criteria tests/graph/p4-eval/criteria.json",
"graph:p4-tests":          "node tests/graph/test-p4-orchestrator.mjs && node tests/graph/test-p4-express-extract.mjs && node tests/graph/test-p4-routes-cli.mjs && node tests/graph/test-p4-routes-mcp.mjs && node tests/graph/test-p4-auto-review-cachekey.mjs && node tests/graph/test-p4-auto-review-enrichment.mjs"
```

### Step 1.6 — Commit

- [ ] Write `/tmp/commit-msg-p4-t1.txt`:

```
feat(graph-p4): eval fixture + gate harness — pre-baseline scaffold

20 prompts (12 coding + 8 architecture) with expected_evidence; gate
criteria frozen (balanced OR answerable-first); run.mjs drives the
UserPromptSubmit chain against the sspower repo itself for deterministic
self-test.

Gate is binary: ./gate.mjs exits 0/1 — no human judgment at gate time.
```

- [ ] Stage:

```
git add tests/graph/p4-eval/prompts.json tests/graph/p4-eval/criteria.json tests/graph/p4-eval/run.mjs tests/graph/p4-eval/gate.mjs package.json
```

- [ ] **Claude only:** `git commit -F /tmp/commit-msg-p4-t1.txt` as a standalone Bash call.

---

## Task 2 — Baseline measurement (commit before any P4 implementation)

### Step 2.1 — Run baseline

- [ ] `bun run graph:p4-eval-baseline`
- [ ] Inspect output: confirm `n=20`, `mean_bytes > 0` (semble is producing), `mean_answerable` in `[0.0, 1.0]`, `p95_wall_ms < 10000`.
- [ ] If `mean_bytes == 0` for >5 prompts: semble path is broken on this repo — STOP and debug semble-context.sh gating before continuing P4.

### Step 2.2 — Commit baseline

- [ ] Write `/tmp/commit-msg-p4-t2.txt`:

```
chore(graph-p4): freeze pre-P4 eval baseline

20-prompt semble-only baseline (SSPOWER_GRAPH_ORCHESTRATOR=off).
Candidate (Task 12) must beat this per criteria.json — committed to
make the gate auditable.
```

- [ ] Stage: `git add docs/plans/notes/2026-05-27-graph-P4-eval-baseline.json`
- [ ] **Claude only:** `git commit -F /tmp/commit-msg-p4-t2.txt`

---

## Task 3 — Express ast-grep rules

### Step 3.1 — Route rule

- [ ] Create `scripts/graph/rules/ts-express-route.yml`:

```yaml
id: ts-express-route
language: typescript
rule:
  any:
    - pattern: $APP.get($PATH, $$$HANDLERS)
    - pattern: $APP.post($PATH, $$$HANDLERS)
    - pattern: $APP.put($PATH, $$$HANDLERS)
    - pattern: $APP.delete($PATH, $$$HANDLERS)
    - pattern: $APP.patch($PATH, $$$HANDLERS)
    - pattern: $APP.all($PATH, $$$HANDLERS)
```

### Step 3.2 — Router rule

- [ ] Create `scripts/graph/rules/ts-express-router.yml`:

```yaml
id: ts-express-router
language: typescript
rule:
  any:
    # Direct router method (matches fixture: r.get('/users', listUsers))
    - pattern: $ROUTER.get($PATH, $$$H)
    - pattern: $ROUTER.post($PATH, $$$H)
    - pattern: $ROUTER.put($PATH, $$$H)
    - pattern: $ROUTER.delete($PATH, $$$H)
    - pattern: $ROUTER.patch($PATH, $$$H)
    - pattern: $ROUTER.all($PATH, $$$H)
    # Chained .route(path).METHOD form
    - pattern: $ROUTER.route($PATH).get($$$H)
    - pattern: $ROUTER.route($PATH).post($$$H)
    - pattern: $ROUTER.route($PATH).put($$$H)
    - pattern: $ROUTER.route($PATH).delete($$$H)
    - pattern: $ROUTER.route($PATH).patch($$$H)
```

NOTE on rule overlap with `ts-express-route.yml`: both rules will fire on `app.get(...)` because the patterns are identical except for the $-variable name. The extractor must DEDUPE matches by `(file, start_line, end_line, METHOD, PATH)` before emitting nodes — otherwise every Express call emits two route nodes with identical span_sha8. Dedupe logic lives in `extract-ts.mjs` Task 4.2; the existing `RULE_ID` dispatcher already buckets per rule, so the dedupe pass runs after both buckets are collected.

### Step 3.3 — Mount rule

- [ ] Create `scripts/graph/rules/ts-express-mount.yml`:

```yaml
id: ts-express-mount
language: typescript
rule:
  pattern: $APP.use($PREFIX, $ROUTER)
```

### Step 3.4 — Smoke

- [ ] Run inline ast-grep against an Express snippet to confirm the rules match:

```bash
cat > /tmp/express-smoke.ts <<'EOF'
import express from 'express';
const app = express();
const r = express.Router();
app.get('/health', (req, res) => res.json({ok:true}));
r.post('/items', handleCreate);
app.use('/api', r);
EOF
ast-grep scan --inline-rules "$(cat scripts/graph/rules/ts-express-route.yml)" --json=compact /tmp/express-smoke.ts
ast-grep scan --inline-rules "$(cat scripts/graph/rules/ts-express-router.yml)" --json=compact /tmp/express-smoke.ts
ast-grep scan --inline-rules "$(cat scripts/graph/rules/ts-express-mount.yml)" --json=compact /tmp/express-smoke.ts
rm /tmp/express-smoke.ts
```

- [ ] Confirm: rule 1 matches 1 result, rule 2 matches 1 result, rule 3 matches 1 result.

### Step 3.5 — Commit

- [ ] Write `/tmp/commit-msg-p4-t3.txt`:

```
feat(graph-p4): Express ast-grep rules — route/router/mount

3 rules: app.METHOD, router.route(...).METHOD, app.use mount. Covers the
80% Express surface; sub-router chaining + middleware-only mounts are
out of P4 scope (P5+).
```

- [ ] Stage: `git add scripts/graph/rules/ts-express-route.yml scripts/graph/rules/ts-express-router.yml scripts/graph/rules/ts-express-mount.yml`
- [ ] **Claude only:** `git commit -F /tmp/commit-msg-p4-t3.txt`

---

## Task 4 — Extractor emits route nodes + route edges

### Step 4.1 — Wire rules into extract-ts.mjs

- [ ] Read `scripts/graph/extract-ts.mjs` end-to-end (216 lines). Note `RULE_FILES` array and the `RULE_ID` → bucket dispatch.
- [ ] Append Express rules to `RULE_FILES`:

```js
const RULE_FILES = [
  'ts-function.yml',
  'ts-arrow.yml',
  'ts-class.yml',
  'ts-method.yml',
  'ts-call.yml',
  'ts-import.yml',
  'ts-express-route.yml',
  'ts-express-router.yml',
  'ts-express-mount.yml',
];
```

- [ ] Extend `RULE_ID` map to dispatch the 3 new rule IDs into a new `routes` bucket alongside the existing buckets.

### Step 4.2 — Route-node emission

- [ ] In the per-file extraction function, when a `routes` bucket entry is processed, emit a node with:
  - `kind = 'route'`
  - `name = '<METHOD> <PATH>'` (e.g. `'GET /health'`)
  - `qualified_name = '<file_relpath>::<METHOD> <PATH>'`
  - `signature = METHOD + ' ' + PATH + ' ' + (handler_name || 'anonymous')`
  - `span_sha8 = spanSha8(matchedText)` (existing helper)
  - `language = 'typescript'`

- [ ] **Dedupe across rules**: `ts-express-route` and `ts-express-router` patterns overlap (both match `<ident>.get(...)`). Collect both buckets into a single intermediate list, then dedupe by tuple `(file, start_line, end_line, METHOD, PATH_LITERAL)` BEFORE emitting nodes. Last-write-wins on the tuple key. Test in Task 9 case J asserts a single `app.get('/health', ...)` produces exactly 1 route node, not 2.

For mount edges (`app.use('/api', r)`), embed the mount prefix in `qualified_name` of the parent route — DO NOT add a new edge kind. Per P4-D5/advisor: edges.kind set stays `{calls,references,routes,implements}`.

### Step 4.3 — Route-edge emission

- [ ] For each route node where the handler is a named identifier (not arrow), emit a `routes` edge from the route node to the handler node:
  - Resolve handler ID using the existing intra-file + import-aware resolver (confidence 1 or 2).
  - Skip if handler is an inline arrow/expression — leave route node only (handler `span_sha8` captures the inline body).

### Step 4.4 — Schema compat check

- [ ] Re-read `scripts/graph/db.mjs` `nodes` table — `kind` is unconstrained TEXT; `'route'` slots in. `edges.kind` likewise unconstrained TEXT. No migration needed.
- [ ] Confirm no existing code filters `kind != 'function'` (grep `scripts/graph/queries.mjs` and `scripts/graph/query.mjs`). If any caller assumes function-only nodes, document the assumption break in the task commit.

### Step 4.5 — Commit

- [ ] Write `/tmp/commit-msg-p4-t4.txt`:

```
feat(graph-p4): emit route nodes + routes edges from TS extractor

Route nodes carry kind=route, name="<METHOD> <PATH>", qname embeds the
file path. Named handlers get a routes-kind edge; inline arrows leave
the route node alone (handler body is already captured in span_sha8).
Mount prefix is embedded in qname — edges.kind set unchanged.
```

- [ ] Stage: `git add scripts/graph/extract-ts.mjs`
- [ ] **Claude only:** `git commit -F /tmp/commit-msg-p4-t4.txt`

---

## Task 5 — Express fixtures + goldens

### Step 5.1 — App fixture

- [ ] Create `__tests__/graph-fixtures/express/app.ts`:

```ts
import express, { Request, Response } from 'express';
import { handleHealth } from './handlers';

const app = express();

app.get('/health', handleHealth);
app.post('/items', (req: Request, res: Response) => {
  res.json({ created: true });
});
app.delete('/items/:id', handleDelete);

function handleDelete(req: Request, res: Response) {
  res.status(204).end();
}

export default app;
```

### Step 5.2 — Router + mount fixtures

- [ ] Create `__tests__/graph-fixtures/express/router.ts`:

```ts
import { Router } from 'express';
import { listUsers, createUser } from './handlers';

const r = Router();
r.get('/users', listUsers);
r.post('/users', createUser);
export default r;
```

- [ ] Create `__tests__/graph-fixtures/express/mount.ts`:

```ts
import express from 'express';
import r from './router';

const app = express();
app.use('/api/v1', r);
export default app;
```

- [ ] Create `__tests__/graph-fixtures/express/handlers.ts` with stub handlers (`handleHealth`, `listUsers`, `createUser`).

### Step 5.3 — Golden

- [ ] Create `__tests__/graph-fixtures/express/expected.json`:

```json
{
  "nodes": [
    { "file": "app.ts",    "kind": "route", "name": "GET /health" },
    { "file": "app.ts",    "kind": "route", "name": "POST /items" },
    { "file": "app.ts",    "kind": "route", "name": "DELETE /items/:id" },
    { "file": "router.ts", "kind": "route", "name": "GET /users" },
    { "file": "router.ts", "kind": "route", "name": "POST /users" },
    { "file": "mount.ts",  "kind": "route", "name": "GET /api/v1/users" },
    { "file": "mount.ts",  "kind": "route", "name": "POST /api/v1/users" }
  ],
  "edges": [
    { "kind": "routes", "src_name": "GET /health",      "tgt_name": "handleHealth" },
    { "kind": "routes", "src_name": "DELETE /items/:id","tgt_name": "handleDelete" },
    { "kind": "routes", "src_name": "GET /users",       "tgt_name": "listUsers" },
    { "kind": "routes", "src_name": "POST /users",      "tgt_name": "createUser" }
  ],
  "precision_min": 0.85,
  "recall_min": 0.70
}
```

Mount-time path expansion (`/api/v1/users` from `app.use('/api/v1', r)`) is COMPUTED at extractor time by joining the mount prefix with the imported router's routes. This is the only cross-file resolution Express needs in P4. If the implementation finds this prohibitive, accept the cost: emit the bare router routes (`GET /users`) and document the limitation in the fixture comment — P5+ adds the mount-expansion pass.

### Step 5.4 — Extract test

- [ ] Create `tests/graph/test-p4-express-extract.mjs`. Builds a temporary graph index over `__tests__/graph-fixtures/express/`, compares against `expected.json`, asserts:
  - `precision >= 0.85` AND `recall >= 0.70` against goldens
  - Rule-overlap dedupe: `app.get('/health', handleHealth)` produces exactly 1 node where `kind='route'` AND `name='GET /health'` — not 2 (ts-express-route and ts-express-router patterns overlap on direct `<ident>.METHOD` form; extractor must dedupe by `(file, start_line, end_line, METHOD, PATH)` per Step 4.2)

### Step 5.5 — Run

- [ ] `node tests/graph/test-p4-express-extract.mjs` — must pass.

### Step 5.6 — Commit

- [ ] Write `/tmp/commit-msg-p4-t5.txt`:

```
test(graph-p4): Express fixtures + goldens

5 fixtures cover app.METHOD, router.METHOD, mount-path expansion,
inline arrow handler, named handler. P/R thresholds at the §1 success
criteria gate (P≥0.85, R≥0.70).
```

- [ ] Stage: `git add __tests__/graph-fixtures/express/ tests/graph/test-p4-express-extract.mjs`
- [ ] **Claude only:** `git commit -F /tmp/commit-msg-p4-t5.txt`

---

## Task 6 — CLI `routes` verb + queries.mjs extension

### Step 6.1 — Add queryRoutes

- [ ] Append to `scripts/graph/queries.mjs`:

```js
export async function queryRoutes(cwd, { framework = null, limit = 200 } = {}) {
  return withDb(graphDirFor(cwd), db => {
    if (db === null) return { routes: [], reason: 'no-index' };
    let rows;
    if (framework === 'express' || framework === null) {
      // P4: framework filter is a no-op until P5 adds a `framework` column
      // to nodes. Returning all kind=route nodes is correct for P4 (Express
      // is the only emitter).
      rows = db.prepare(`
        SELECT name, qualified_name AS qname, file_path AS file, start_line AS line, signature
          FROM nodes WHERE kind='route' ORDER BY file_path, start_line LIMIT ?
      `).all(limit);
    } else {
      rows = [];
    }
    return { routes: rows, framework: framework ?? 'all' };
  });
}
```

### Step 6.2 — CLI verb

- [ ] Read `bin/sspower-graph.mjs`. Add a `routes` case to the verb dispatch table alongside `callers/callees/trace/impact/context/node/status`.

```js
async function runRoutes(opts) {
  const { framework, limit, cwd } = opts;
  const payload = await queryRoutes(cwd ?? process.cwd(), {
    framework: framework ?? null,
    limit: Number(limit ?? 200),
  });
  emit(opts, payload);
}
```

- [ ] Wire `--framework <name>` and `--limit <N>` arg parsing matching the existing argv-walk style.
- [ ] Wire `routes` into the verbs switch.

### Step 6.3 — Smoke

- [ ] `node bin/sspower-graph.mjs build` (or `bun run graph:build`) against the Express fixtures dir, then `node bin/sspower-graph.mjs routes --framework express --json --cwd __tests__/graph-fixtures/express` — expect 7 route entries (per Task 5 golden).

### Step 6.4 — Test

- [ ] Create `tests/graph/test-p4-routes-cli.mjs`. Asserts: (a) `--json` output is `JSON.stringify(payload, null, 2) + '\n'` exact; (b) without `--framework`, returns same set as `--framework express`; (c) `--limit 3` returns 3 entries.

### Step 6.5 — Commit

- [ ] Write `/tmp/commit-msg-p4-t6.txt`:

```
feat(graph-p4): sspower-graph routes CLI verb

Reads kind=route nodes from the shared queries layer. --framework
filter is a no-op pass-through in P4 (Express-only emitter); P5+ adds
the framework column to nodes for true multi-framework dispatch.
```

- [ ] Stage: `git add scripts/graph/queries.mjs bin/sspower-graph.mjs tests/graph/test-p4-routes-cli.mjs`
- [ ] **Claude only:** `git commit -F /tmp/commit-msg-p4-t6.txt`

---

## Task 7 — `graph_routes` MCP tool

### Step 7.1 — Handler

- [ ] Create `scripts/graph/mcp-tools/routes.mjs` mirroring `callers.mjs`:

```js
import { queryRoutes } from '../queries.mjs';

export const TOOL = {
  name: 'graph_routes',
  description: 'List HTTP routes discovered by the symbol graph (framework-tagged).',
  inputSchema: {
    type: 'object',
    properties: {
      cwd: { type: 'string', description: 'project root; defaults to server cwd' },
      framework: { type: 'string', description: 'optional framework filter (e.g. "express")' },
      limit: { type: 'number', description: 'cap returned routes; default 200' },
    },
    required: [],
  },
};

export async function handle({ params }) {
  const args = params.arguments ?? {};
  const payload = await queryRoutes(args.cwd ?? process.cwd(), {
    framework: args.framework ?? null,
    limit: Number(args.limit ?? 200),
  });
  return { content: [{ type: 'text', text: JSON.stringify(payload, null, 2) }] };
}
```

### Step 7.2 — Register

- [ ] Modify `scripts/graph/mcp-tools/index.mjs`:
  - Import `* as routes from './routes.mjs'`
  - Append `routes.TOOL` to TOOLS array
  - Add `case 'graph_routes': return routes.handle(req);` to the dispatch switch

### Step 7.3 — Parity test

- [ ] Create `tests/graph/test-p4-routes-mcp.mjs`. Spawns `sspower-graph-bootstrap.sh serve --mcp` via `StdioClientTransport`. Calls `graph_routes` with no args, asserts `JSON.parse(result.content[0].text)` deep-equals `JSON.parse(spawnSync('sspower-graph', ['routes','--json']).stdout)` — modulo trailing newline (F1 known issue).

### Step 7.4 — Smoke MCP integration

- [ ] `node tests/graph/test-p4-routes-mcp.mjs` — must pass.

### Step 7.5 — Commit

- [ ] Write `/tmp/commit-msg-p4-t7.txt`:

```
feat(graph-p4): graph_routes MCP tool

8th tool; mirrors the 7-tool P3 dispatcher pattern. byte-identical CLI
parity (F1 trailing-newline gap inherited from P3). Supersedes
P3-D1's "7 tools" decision — bump tracked in CLAUDE.md (Task 13).
```

- [ ] Stage: `git add scripts/graph/mcp-tools/routes.mjs scripts/graph/mcp-tools/index.mjs tests/graph/test-p4-routes-mcp.mjs`
- [ ] **Claude only:** `git commit -F /tmp/commit-msg-p4-t7.txt`

---

## Task 8 — `graph-orchestrator.sh` core

### Step 8.1 — Skeleton

- [ ] Create `hooks/graph-orchestrator.sh`:

```bash
#!/usr/bin/env bash
# UserPromptSubmit hook — concurrent semble + graph context injection.
# REPLACES semble-context.sh in hooks.json when SSPOWER_GRAPH_ORCHESTRATOR=on.
#
# Fail-OPEN: any error / missing dep / timeout -> emit nothing OR exec
# semble-context.sh as fallback (no-graph path).
#
# Budget: 5s per child (timeout), 6s wall, 2KB per source after merge.
#
# Flags:
#   SSPOWER_GRAPH_ORCHESTRATOR=off    full bypass (exec semble-context.sh)
#   SSPOWER_SEMBLE=0                  disable semble child only
#   SSPOWER_GRAPH=0                   disable graph child only

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_log.sh" 2>/dev/null || true

# Single EXIT trap (do NOT add a second `trap ... EXIT` later — it would
# overwrite this one and lose the _sspower_exit_guard call).
# Temp file paths are exported into the function via globals set below.
SEMBLE_OUT=""
GRAPH_OUT=""
_orch_cleanup() {
  local rc=$?
  [[ -n "$SEMBLE_OUT" ]] && rm -f "$SEMBLE_OUT" 2>/dev/null
  [[ -n "$GRAPH_OUT"  ]] && rm -f "$GRAPH_OUT"  2>/dev/null
  command -v _sspower_exit_guard >/dev/null 2>&1 \
    && _sspower_exit_guard "$rc" "0" hook.graph-orchestrator
  return "$rc"
}
trap '_orch_cleanup' EXIT

DIAG_LOG="${HOME}/.claude/sspower/codex.log"
log_hook() {
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$(dirname "$DIAG_LOG")" 2>/dev/null
  ( printf '%s [%s] hook.graph-orchestrator %s\n' "$ts" "$1" "$2" >> "$DIAG_LOG" ) 2>/dev/null || true
}

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SEMBLE_HOOK="$PLUGIN_ROOT/hooks/semble-context.sh"

INPUT="$(cat 2>/dev/null || true)"

# Fast exits — fall back to semble-context.sh, never silent-drop the
# semble path (D-P4-3).
exec_semble_fallback() {
  printf '%s' "$INPUT" | exec "$SEMBLE_HOOK"
}

[[ "${SSPOWER_GRAPH_ORCHESTRATOR:-off}" != "on" ]] && exec_semble_fallback
command -v jq >/dev/null 2>&1 || exec_semble_fallback

PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
[[ -z "$CWD" ]] && CWD="$(pwd)"
[[ -z "$PROMPT" ]] && exit 0
(( ${#PROMPT} < 20 )) && exit 0
[[ "$PROMPT" =~ ^/ ]] && exit 0

# Graph-absent → pure semble fallback (D-P4-3).
GRAPH_DIR="$CWD/.claude/graph"
[[ ! -f "$GRAPH_DIR/index.sqlite" ]] && exec_semble_fallback

# Dirty-queue staleness → semble-only (D-P4-4). Inline refresh would
# blow the 6s wall budget.
if [[ -s "$GRAPH_DIR/dirty" ]]; then
  log_hook info "kind=skip_graph reason=dirty"
  exec_semble_fallback
fi

# Resolve timeout binary (gtimeout > timeout > perl alarm > unbounded).
if command -v gtimeout >/dev/null 2>&1; then TO=(gtimeout)
elif command -v timeout >/dev/null 2>&1; then TO=(timeout)
elif command -v perl >/dev/null 2>&1; then TO=(perl -e 'alarm shift; exec @ARGV')
else TO=(); fi

# ---- Fork children -----------------------------------------------------
# Assign the globals declared above so _orch_cleanup will rm them.
SEMBLE_OUT=$(mktemp -t sspower-orch-semble-XXXXXX)
GRAPH_OUT=$(mktemp -t sspower-orch-graph-XXXXXX)

START="$(date +%s)"

(
  if [[ "${SSPOWER_SEMBLE:-1}" != "0" ]] && command -v semble_rs >/dev/null 2>&1; then
    ${TO[@]+"${TO[@]}"} 5 semble_rs plan "$PROMPT" "$CWD" >"$SEMBLE_OUT" 2>/dev/null || true
  fi
) &
SEMBLE_PID=$!

(
  if [[ "${SSPOWER_GRAPH:-1}" != "0" ]]; then
    ${TO[@]+"${TO[@]}"} 5 "$PLUGIN_ROOT/bin/sspower-graph-bootstrap.sh" \
      context "$PROMPT" --cwd "$CWD" --json >"$GRAPH_OUT" 2>/dev/null || true
  fi
) &
GRAPH_PID=$!

# ---- Wait with 6s wall budget ------------------------------------------
WALL_BUDGET=6
DEADLINE=$(( START + WALL_BUDGET ))
while :; do
  NOW=$(date +%s)
  (( NOW >= DEADLINE )) && break
  if ! kill -0 "$SEMBLE_PID" 2>/dev/null && ! kill -0 "$GRAPH_PID" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

# Kill any survivors.
kill -TERM "$SEMBLE_PID" 2>/dev/null || true
kill -TERM "$GRAPH_PID" 2>/dev/null || true
wait 2>/dev/null || true

DUR=$(( $(date +%s) - START ))

# ---- Per-source 2KB cap (D-P4-2) ---------------------------------------
SEM_CAP=2048
GR_CAP=2048
MARKER='
[...truncated]'

cap_file() {
  local f="$1" cap="$2"
  [[ ! -s "$f" ]] && { printf ''; return; }
  local content
  content="$(cat "$f")"
  if (( ${#content} > cap )); then
    printf '%s%s' "${content:0:$(( cap - ${#MARKER} ))}" "$MARKER"
  else
    printf '%s' "$content"
  fi
}

SEMBLE_TXT="$(cap_file "$SEMBLE_OUT" "$SEM_CAP")"
GRAPH_TXT="$(cap_file "$GRAPH_OUT" "$GR_CAP")"

# ---- Merge + emit ------------------------------------------------------
MERGED=""
if [[ -n "$SEMBLE_TXT" ]]; then
  MERGED+="[semble_rs repo orientation - advisory, token-cheap; verify before acting]:
$SEMBLE_TXT"
fi
if [[ -n "$GRAPH_TXT" ]]; then
  [[ -n "$MERGED" ]] && MERGED+="

"
  MERGED+="[sspower-graph context - advisory; symbol-level, may include ambiguous-name matches]:
$GRAPH_TXT"
fi

if [[ -z "$MERGED" ]]; then
  log_hook info "kind=empty dur=${DUR}s cwd=$CWD"
  exit 0
fi

log_hook info "kind=inject dur=${DUR}s semble_bytes=${#SEMBLE_TXT} graph_bytes=${#GRAPH_TXT} cwd=$CWD"
printf '%s' "$MERGED" | jq -Rs '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:.}}'
exit 0
```

### Step 8.2 — chmod

- [ ] `chmod +x hooks/graph-orchestrator.sh`

### Step 8.3 — Manual smoke

- [ ] Build graph index for sspower repo:

```bash
node bin/sspower-graph.mjs build --cwd "$PWD"
```

- [ ] Confirm `<repo>/.claude/graph/index.sqlite` exists, dirty file empty.
- [ ] Hand-test orchestrator:

```bash
SSPOWER_GRAPH_ORCHESTRATOR=on CLAUDE_PLUGIN_ROOT="$PWD" \
  bash -c 'echo "{\"prompt\":\"trace cmdImplement callers\",\"cwd\":\"$PWD\"}" | hooks/graph-orchestrator.sh' | jq .
```

- [ ] Confirm: emits valid `{hookSpecificOutput:...additionalContext}` JSON with both semble + graph sections. Wall < 6s.

### Step 8.4 — Commit

- [ ] Write `/tmp/commit-msg-p4-t8.txt`:

```
feat(graph-p4): graph-orchestrator.sh — concurrent semble + graph

Forks both backends with timeout 5s each, 6s wall, 2KB/2KB merge.
Fail-open: graph absent OR dirty queue non-empty OR orchestrator
disabled -> exec semble-context.sh (no behavior change for graph-less
repos). Emits single additionalContext block.

D-P4-1..4 locked: parallel-equal split, per-source budget, graph-absent
exec fallback, dirty-skip (no inline refresh inside prompt-time hook).
```

- [ ] Stage: `git add hooks/graph-orchestrator.sh`
- [ ] **Claude only:** `git commit -F /tmp/commit-msg-p4-t8.txt`

---

## Task 9 — Orchestrator unit tests

### Step 9.1 — Test harness

- [ ] Create `tests/graph/test-p4-orchestrator.mjs`. Assertions:

| # | Case | Expected |
|---|---|---|
| A | `SSPOWER_GRAPH_ORCHESTRATOR=off` + valid input | exec's `semble-context.sh`; output shape matches semble-context.sh output |
| B | Graph index absent (no `.claude/graph/index.sqlite`) | exec's `semble-context.sh`; identical to A |
| C | `dirty` non-empty | exec's `semble-context.sh`; log line carries `reason=dirty` |
| D | Both backends healthy, prompt length ≥20 | emits merged additionalContext with both markers present |
| E | `SSPOWER_SEMBLE=0`, graph healthy | emits graph-only section, semble marker absent |
| F | `SSPOWER_GRAPH=0`, semble healthy | emits semble-only section, graph marker absent |
| G | Both children timeout (mock by stubbing PATH) | emits no additionalContext, exit 0 |
| H | Semble output 5KB, graph output 5KB | merged truncated to ~4KB total with `[...truncated]` markers in both sections |
| I | Wall clock | every case completes in <7s (allow 1s overhead beyond 6s budget) |

Implementation hint: stub `semble_rs` and `sspower-graph-bootstrap.sh` via `PATH` shimming to a temp dir containing fake binaries that print known content.

### Step 9.2 — Run

- [ ] `node tests/graph/test-p4-orchestrator.mjs` — all 9 cases must pass.

### Step 9.3 — Commit

- [ ] Write `/tmp/commit-msg-p4-t9.txt`:

```
test(graph-p4): orchestrator unit suite

9 cases cover budget split, 4KB merge truncation, fail-open fallbacks,
dirty-skip, per-backend kill switches. PATH-shimmed stubs avoid
requiring a real semble_rs or graph index.
```

- [ ] Stage: `git add tests/graph/test-p4-orchestrator.mjs`
- [ ] **Claude only:** `git commit -F /tmp/commit-msg-p4-t9.txt`

---

## Task 10 — hooks.json swap

### Step 10.1 — Edit

- [ ] Modify `hooks/hooks.json` — replace the `semble-context.sh` entry under `UserPromptSubmit` with `graph-orchestrator.sh`:

```json
{
  "type": "command",
  "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/graph-orchestrator.sh\"",
  "timeout": 8,
  "async": false
}
```

Timeout 8s = wall budget (6s) + jq emit overhead (1s) + safety (1s). `semble-context.sh` is NOT deleted; it remains the fallback target invoked via `exec` when orchestrator gates out.

### Step 10.2 — Verify

- [ ] `jq . hooks/hooks.json` — must parse cleanly.
- [ ] Re-run Task 9 unit tests — orchestrator behavior unchanged.
- [ ] Hand-test in a fresh Claude Code session: send a coding-intent prompt with `SSPOWER_GRAPH_ORCHESTRATOR=on` exported in `~/.claude/settings.json` env block; confirm additionalContext appears with both markers; flip to `=off`, confirm semble-only injection (no behavior change vs pre-P4).

### Step 10.3 — Commit

- [ ] Write `/tmp/commit-msg-p4-t10.txt`:

```
chore(graph-p4): swap UserPromptSubmit hook to graph-orchestrator.sh

semble-context.sh remains the fallback target (graph-absent / dirty /
flag-off all exec it). Default SSPOWER_GRAPH_ORCHESTRATOR=off — Task 13
flips on after eval gate passes.
```

- [ ] Stage: `git add hooks/hooks.json`
- [ ] **Claude only:** `git commit -F /tmp/commit-msg-p4-t10.txt`

---

## Task 11 — auto-review.sh cache key + enrichment

### Step 11.1 — Cache-key revision

- [ ] Read `hooks/auto-review.sh` lines 247-256 (HASH_INPUT construction).
- [ ] Add graph terms — conditional on graph index existence. The pre-graph `HASH_INPUT` line stays UNCHANGED; the graph branch APPENDS to it so the absent-graph hash is byte-identical to pre-P4:

```bash
# Existing line — DO NOT modify:
HASH_INPUT=$(printf '%s|%s|%s|%s' "${REPO_ROOT:-}" "$HEAD_SHA" "$BRANCH" "$DIFF_SHA")

# Graph cache-key terms (F9 from spec, P4-D6 implementation).
# Append-only — graph-absent leaves HASH_INPUT byte-identical to pre-P4.
if [ -n "$REPO_ROOT" ] && [ -f "$REPO_ROOT/.claude/graph/version" ]; then
  GRAPH_VERSION=$(head -1 "$REPO_ROOT/.claude/graph/version" 2>/dev/null | tr -d '\n')
  GRAPH_HASH=$(sha256sum "$REPO_ROOT/.claude/graph/version" 2>/dev/null | cut -c1-16)
  [ -z "$GRAPH_HASH" ] && GRAPH_HASH=$(shasum -a 256 "$REPO_ROOT/.claude/graph/version" 2>/dev/null | cut -c1-16)
  HASH_INPUT="${HASH_INPUT}|${GRAPH_VERSION}|${GRAPH_HASH}"
fi
```

Graph-absent → no append; `HASH_INPUT` byte-identical to pre-graph form. Graph-present → two extra terms; one-time cache invalidation at first deploy is correct behavior (stale verdicts shouldn't survive a graph schema bump). Document the one-time spike in the commit body.

### Step 11.2 — Enrichment block

- [ ] Add new block immediately BEFORE `# ---------- Spawn main review ----------` (around line 361). Reads changed files from diff, runs `sspower-graph impact` in parallel with cap 8, appends `# Graph impact` section to `MAIN_PROMPT_FILE`.

```bash
# ---------- Graph-impact enrichment (P4) --------------------------------
# Runs ONLY on cache miss (this code path), skips silently if graph
# unavailable or dirty queue non-empty (stale-data avoidance per P4-D4).
GRAPH_ENRICH=""
GRAPH_DIR_AR="$REPO_ROOT/.claude/graph"
if [ -d "$GRAPH_DIR_AR" ] && [ ! -s "$GRAPH_DIR_AR/dirty" ]; then
  # Extract unique changed files from the diff.
  CHANGED=$(awk '/^diff --git / { gsub(/^a\//,"",$3); print $3 }' "$DIFF_FILE" \
              | sort -u | head -8)
  if [ -n "$CHANGED" ]; then
    ENRICH_TMP=$(mktemp -t sspower-autoreview-enrich-XXXXXX)
    : > "$ENRICH_TMP"
    PIDS=()
    PER_FILE_TMP=()
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      tf=$(mktemp -t sspower-autoreview-impact-XXXXXX)
      PER_FILE_TMP+=("$tf")
      (
        if command -v timeout >/dev/null 2>&1; then
          timeout 3 node "$PLUGIN_ROOT/bin/sspower-graph.mjs" impact "$f" \
            --json --cwd "$REPO_ROOT" >"$tf" 2>/dev/null || true
        else
          node "$PLUGIN_ROOT/bin/sspower-graph.mjs" impact "$f" \
            --json --cwd "$REPO_ROOT" >"$tf" 2>/dev/null || true
        fi
      ) &
      PIDS+=($!)
    done <<< "$CHANGED"
    for pid in "${PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
    # Assemble enrichment.
    for tf in "${PER_FILE_TMP[@]}"; do
      [ -s "$tf" ] && {
        SUMMARY_LINE=$(jq -r '
          if .reason == "no-index" then empty
          else "- " + (.target_file // "?") + ": direct=" + ((.direct_count // 0)|tostring) +
               " transitive=" + ((.transitive_count // 0)|tostring)
          end
        ' "$tf" 2>/dev/null)
        [ -n "$SUMMARY_LINE" ] && printf '%s\n' "$SUMMARY_LINE" >> "$ENRICH_TMP"
      }
      rm -f "$tf"
    done
    if [ -s "$ENRICH_TMP" ]; then
      GRAPH_ENRICH=$(printf '\n# Graph impact (sspower-graph; cap 8 files, 3s each)\n%s\n' "$(cat "$ENRICH_TMP")")
    fi
    rm -f "$ENRICH_TMP"
    log_event info hook.auto-review kind=graph_enrich files="$(printf '%s' "$CHANGED" | wc -l)" bytes="${#GRAPH_ENRICH}"
  fi
elif [ -s "$GRAPH_DIR_AR/dirty" ]; then
  log_event info hook.auto-review kind=graph_enrich_skip reason=dirty
fi

# Append to MAIN_PROMPT_FILE (which was written above with the review brief).
[ -n "$GRAPH_ENRICH" ] && printf '%s' "$GRAPH_ENRICH" >> "$MAIN_PROMPT_FILE"
```

CRITICAL: this block must run AFTER `MAIN_PROMPT_FILE` is written (line ~343) and BEFORE the bridge invocation (line ~368). Place it between those two existing markers.

### Step 11.3 — Tests

- [ ] Create `tests/graph/test-p4-auto-review-cachekey.mjs`. Stubs: temp repo with `.claude/graph/version` file. Asserts:
  - Different `version` file content → different `HASH_INPUT`
  - `.claude/graph/` absent → `HASH_INPUT` equals pre-graph form (no graph terms appended)
- [ ] Create `tests/graph/test-p4-auto-review-enrichment.mjs`. Stubs a fake `sspower-graph` binary on PATH. Asserts:
  - `dirty` empty + 3 changed files → 3 parallel invocations, output appended to prompt
  - `dirty` non-empty → enrichment skipped, log `kind=graph_enrich_skip reason=dirty`
  - 12 changed files → exactly 8 invocations (cap enforced)
  - Per-file timeout (stub sleeps 5s with 3s timeout) → that file's output empty, others succeed

### Step 11.4 — Run

- [ ] `node tests/graph/test-p4-auto-review-cachekey.mjs && node tests/graph/test-p4-auto-review-enrichment.mjs` — both pass.

### Step 11.5 — Commit

- [ ] Write `/tmp/commit-msg-p4-t11.txt`:

```
feat(graph-p4): auto-review cache key + graph-impact enrichment

Cache key now incorporates GRAPH_VERSION || GRAPH_HASH; graph-absent
collapses to pre-graph form. One-time cache spike at deploy is correct
behavior — stale verdicts shouldn't survive a graph schema bump.

Enrichment runs on cache miss only: parses changed files from diff,
runs sspower-graph impact in parallel (cap 8, 3s/file). Skips silently
when dirty queue non-empty (avoid stale lies).
```

- [ ] Stage: `git add hooks/auto-review.sh tests/graph/test-p4-auto-review-cachekey.mjs tests/graph/test-p4-auto-review-enrichment.mjs`
- [ ] **Claude only:** `git commit -F /tmp/commit-msg-p4-t11.txt`

---

## Task 12 — Candidate measurement + gate

### Step 12.1 — Run candidate

- [ ] `bun run graph:p4-eval-candidate`
- [ ] Inspect output: confirm `n=20`, `mean_bytes` and `mean_answerable` populated, `p95_wall_ms < 7000`.

### Step 12.2 — Run gate

- [ ] `bun run graph:p4-eval-gate`
- [ ] If exit 0 (pass): proceed to Step 12.4.
- [ ] If exit 1 (fail): inspect report.

### Step 12.3 — Failure rollback (if gate fails)

If the gate fails, the failure mode determines next action:

| Failure | Action |
|---|---|
| `mean_bytes_candidate > 1.5 × baseline` and `answerable_delta < 0.15` | Tune `GR_CAP` / `SEM_CAP` in orchestrator (try 1500/1500); re-run from Step 12.1. |
| `p95_wall_ms > 6500` | Reduce per-child timeout from 5s to 4s; re-run. |
| `answerable_delta < 0` | Real regression. ROLLBACK: revert hooks.json swap (Task 10) only. Keep Express extractor (Tasks 3-7) + auto-review changes (Task 11). Commit revert with body explaining the eval delta. Skip to Task 13 with orchestrator-disabled docs. |

Each tune attempt must commit the parameter change with `/tmp/commit-msg-p4-t12-tune-N.txt` describing the dial moved and the resulting metric improvement. Hard cap: 3 tune iterations. After cap, accept the answerable-first-disabled rollback path.

### Step 12.4 — Commit candidate + report

- [ ] Write `/tmp/commit-msg-p4-t12.txt`:

```
chore(graph-p4): freeze candidate eval + gate report

Candidate (SSPOWER_GRAPH_ORCHESTRATOR=on) measured against
the pre-P4 baseline; criteria.json gate verdict:
  delta_answerable=<X.XX>  bytes_ratio=<X.XX>  p95_wall=<NNNN>ms
  mode_balanced=<true|false>  mode_answerable_first=<true|false>

PASS → Task 13 flips default-on.
```

Embed actual numbers from `gate.mjs` output in the commit body.

- [ ] Stage: `git add docs/plans/notes/2026-05-27-graph-P4-eval-candidate.json`
- [ ] **Claude only:** `git commit -F /tmp/commit-msg-p4-t12.txt`

---

## Task 13 — Default-on flip + docs + PR

### Step 13.1 — Decide flag default

- [ ] If Task 12 gate PASSED: in `hooks/graph-orchestrator.sh`, change default from `off` to `on`:

```bash
[[ "${SSPOWER_GRAPH_ORCHESTRATOR:-on}" != "on" ]] && exec_semble_fallback
```

- [ ] If Task 12 gate FAILED with full rollback: leave default `off` and document in CLAUDE.md.

### Step 13.2 — CLAUDE.md update

- [ ] Modify `CLAUDE.md` sspower-graph subsystem block: add a P4 row to the phase list:

```
  - **P4 (shipped at 1.5.0)** — `hooks/graph-orchestrator.sh` (concurrent
    semble + graph; 6s wall, 2KB/2KB merge; graph-absent OR dirty →
    exec semble-context.sh). `hooks/auto-review.sh` cache key now
    includes GRAPH_VERSION || GRAPH_HASH; enrichment block runs
    `sspower-graph impact` per changed-file in parallel (cap 8, 3s
    each, skip-if-dirty). 8th MCP tool `graph_routes` + CLI `routes`
    verb + Express ast-grep rules (P/R ≥0.85/0.70 on
    __tests__/graph-fixtures/express/). `SSPOWER_GRAPH_ORCHESTRATOR`
    env flag controls swap (default <on|off> per eval gate).
  - **P5+** framework routes (FastAPI → Django → Rails → ...).
```

- [ ] Bump the "ship candidate at 1.4.0" reference to "shipped at 1.5.0" and update the MCP tool count to 8.

### Step 13.3 — README.md update

- [ ] Add an `Environment variables (P4)` subsection (or extend existing) documenting:
  - `SSPOWER_GRAPH_ORCHESTRATOR=on|off` (default <per Task 13.1>)
  - `SSPOWER_SEMBLE=0` and `SSPOWER_GRAPH=0` as per-backend kill switches
  - Orchestrator wall budget (6s) and per-child timeout (5s)
  - Express scope (P4 ships only Express; other frameworks P5+)
  - `graph_routes` MCP tool added (now 8 total)

### Step 13.4 — Worktree cleanup + commit

- [ ] Write `/tmp/commit-msg-p4-t13.txt`:

```
docs(graph-p4): document P4 ship + flip orchestrator default

CLAUDE.md + README record:
- graph-orchestrator.sh hook (concurrent semble + graph, fail-open
  via exec semble-context.sh on graph-absent / dirty / flag-off)
- auto-review.sh cache key + graph-impact enrichment
- 8th MCP tool graph_routes + CLI routes verb + Express extractor

Default SSPOWER_GRAPH_ORCHESTRATOR=<on|off> per Task 12 eval gate.
```

- [ ] Stage: `git add CLAUDE.md README.md hooks/graph-orchestrator.sh`
- [ ] **Claude only:** `git commit -F /tmp/commit-msg-p4-t13.txt`

### Step 13.5 — PR

- [ ] Supervisor: from the P4 worktree:

```
git -C <wt> push -u origin feat/graph-P4
```

- [ ] Open PR:

```
gh pr create --base main --head feat/graph-P4 \
  --title "feat(graph): P4 hooks orchestration + Express extractor" \
  --body-file /tmp/pr-body-p4.md
```

PR body summarizes file map + eval gate report + locked decisions (P4-D1..D6) + followups list (any new ones discovered during impl).

---

## Spec coverage check (every spec requirement maps to a task)

| Spec §3.5 requirement | Task |
|---|---|
| `graph-orchestrator.sh` REPLACES semble-context.sh invocation site | T8 + T10 |
| Forks two children with EXTERNAL timeout wrappers | T8 step 8.1 |
| Wall 6s, merge cap 4KB | T8 (2KB+2KB per D-P4-2) |
| `semble-context.sh` retained as fallback | T8 (exec_semble_fallback) |
| `hooks/auto-review.sh` cache key revised | T11.1 |
| Cache absent → graph terms omitted | T11.1 |
| Enrichment runs on cache miss only | T11.2 (placement between MAIN_PROMPT_FILE write and bridge invocation) |
| Per-file `sspower-graph impact --json --timeout 3s` | T11.2 |
| Parallel cap 8 | T11.2 |
| Skip silently on per-file timeout | T11.2 |

| Spec §3.6 requirement | Task |
|---|---|
| `sspower-graph routes [--framework F]` | T6 |

| Spec §4 P4 row | Task |
|---|---|
| One framework: Express | T3-T5 |
| Head-to-head token-budget delta net-positive on 20-prompt eval | T1, T2, T12 |

## Placeholder scan

Audited the plan body — no `TBD`, `TODO`, `implement later`, `fill in details`, `add appropriate error handling`, `write tests for the above` (all test cases enumerated), `similar to Task N` (each task self-contained). Eval criteria, fixture prompts, ast-grep rules, hook code, cache-key terms, enrichment block — all enumerated as exact content.

## Type / name consistency check

- `queryRoutes` defined in T6.1, called by T6.2 (CLI) + T7.1 (MCP handler) + T7.3 (parity test). Consistent.
- `WALL_BUDGET=6` referenced in T8.1 (definition), T9.1 case I, T11 step 11.2 (3s/file ≤ orchestrator's 6s budget — not directly used but co-budgeted).
- `kind='route'` / `kind='routes'` distinction: route NODES are `kind='route'`, route EDGES are `kind='routes'`. Locked in T4 + T6 + T7.
- `SSPOWER_GRAPH_ORCHESTRATOR` flag: defined T8, swapped T10, evaluated T1+T12, flipped T13. Default `off` → `on` after eval pass.

---

## Codex Plan Review (run before declaring done)

```bash
node "/Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower/scripts/codex-bridge.mjs" plan-review \
  --cd . --prompt @docs/plans/2026-05-27-codegraph-graph-P4.md
```

Fix every `high`/`medium` finding inline, re-run until `verdict` is `approve` or `approve-with-followups`. Cache review JSON at `docs/plans/notes/2026-05-27-graph-P4-plan-review.json`.

---

## Execution Handoff

**Execution model — read these constraints BEFORE picking an option:**

- **Strict serial T1 → T2**. T2 commits the pre-P4 baseline before any P4 implementation lands. The gate (T12) is auditable ONLY against this committed baseline; running any P4 code before T2 commits poisons the baseline.
- **Parallel fan-out allowed AFTER T2 commit** on two independent clusters:
  - **Express cluster** = T3 → T4 → T5 → T6 → T7 (internally serial: rules → extractor → fixtures → CLI → MCP).
  - **Hooks cluster** = T8 → T9 → T10 → T11 (internally serial: orchestrator → tests → hooks.json → auto-review).
  - The two clusters share no files; either order or true parallel agents are safe.
- **Strict serial T12 → T13** after both clusters land. T12 measures candidate (requires both clusters in tree). T13 flips default + commits docs + PR.
- **Codex workers MUST NOT commit**. Repo `AGENTS.md` rule, restated in every task's commit step. Codex stops after `git add`; supervisor runs `git commit -F <msg>`. Codex cannot drive T13.5 (`git push` / `gh pr create`) — those are supervisor-only chokepoints under `auto-review.sh`.

**Three execution options:**

1. **Subagent-Driven (recommended for this plan)** → `sspower:subagent-driven-development`. Fits the dependency shape: serial T1→T2, then two parallel subagents (Express cluster + Hooks cluster), then serial T12→T13. Subagents commit independently per the spec/quality-review-per-task pattern.
2. **Inline Execution** → `sspower:executing-plans`. Linear T1→T13. Slower; use if subagent infra is unavailable.
3. **Codex execute** → delegate via `codex-bridge.mjs implement --write` per task. Supervisor stages every commit and runs T13.5. Codex CANNOT run the full plan unattended.

**Which approach?**
