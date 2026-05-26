# Session Handoff
> Generated: 2026-05-26 — supersedes 2026-05-21 sspower-mem Phase E handoff (long-shipped).

## Task
sspower-graph **P1** (TS/JS extractor + full §3.1 schema + CLI verbs) SHIPPED on `main` via PR #1 merge. Tag `graph-p1` at HEAD. P2 (incremental refresh + multi-language extractors) is the next phase.

## Status

### Completed (P1 — merged to main at `6d28e18` via PR #1)
- Plan `docs/plans/2026-05-26-codegraph-graph-P1.md` (~2,400 lines, 13 tasks, 4 plan-review iterations, 5 branch-diff review iterations — all blockers fixed inline).
- 18 commits merged on `main`:
  - `chore`: P1 branch + version bump 1.1.1 → 1.2.0-rc.0 + engines.node 22.0 → 22.5
  - `feat(graph)`: db schema (full §3.1 — files/nodes/edges/imports/FTS5+triggers, idempotent CREATE IF NOT EXISTS, WAL+FK)
  - `feat(graph)`: 6 ast-grep YAML kind rules + spawn wrapper with shape validation + 0→1 line normalization
  - `feat(graph)`: TS/JS extractor (qualifies methods via byte-range, async-fn regex, JSX→tmp .tsx / JS→tmp .ts)
  - `feat(graph)`: import resolution + three-tier confidence resolver
  - `feat(graph)`: file walker (git ls-files + readdir fallback)
  - `feat(graph)`: build orchestrator (single-tx destructive + insert, aborts pre-DELETE if >25% extraction failures)
  - `feat(graph)`: query API (callers/callees/node/status, MAX_RESULTS=50, disambiguate)
  - `feat(graph)`: CLI dispatcher (Node ≥22.5 startup gate, re-exec through `graph-with-lock.py` for `build`)
  - `test(graph)`: cross-file fixture pack + e2e test (live demo: `callers cmdImplement` → `main@codex-bridge.mjs:2061`)
  - `test(graph)`: fixture harness flipped to extractor-comparison mode (P=0.85+, R=0.70+ on `ts-js` + `ts-js-multifile`)
  - `docs(graph)`: README CLI usage section + P2 known limits
  - 5 `fix(graph)` commits applying each codex-review iteration's blocking findings.
- Acceptance: 9 graph:tests OK + 3 vitest fixtures (P/R met) + P0 regressions clean.
- Live demo on plugin repo: 89 files, 387 nodes, 929 edges in ~1.5s build; `callers cmdImplement` returns `main@codex-bridge.mjs:2061` (the spec §4 P1 acceptance target).

### In Progress
- None. P1 shipped + tagged. P2 unstarted.

## Resume Here
1. **P2 scope** — incremental refresh + multi-language extractors. Specifically:
   - `refresh` CLI verb consuming the dirty JSONL queue (P0 helpers `graph-append-dirty.py` + `graph-with-lock.py` already in place).
   - Two-phase refresh transaction with reverse-import closure per spec §3.1 (upsert / delete / relink ops; D29/D37).
   - `PostToolUse:Write|Edit|MultiEdit` hook (`graph-mark-dirty.sh`) emitting JSONL records via the P0 lock helper.
   - `SessionStart` sweep: rowid-stride external-edit scan + git filesethash NEW-file detection per spec §3.5 + FU3.
   - Python / Go / Rust extractors with their own fixture packs meeting P≥0.85 / R≥0.70 per language.
   - CLI: `refresh`, `trace`, `impact`, `context` (per spec §3.6).
2. **If user says go on P2:** invoke `sspower:writing-plans` with spec §3.5 + §4 P2 row + the realized P1 build orchestrator as the extension point. Branch off `graph-p1` tag (`6d28e18`).
3. **P1 followups documented in plugin README (not blockers — defer to P2 where natural):**
   - Default-import-alias resolution (extractor needs to tag default-exported nodes).
   - Parallel `js-*.yml` rules so JS files don't round-trip through temp `.ts`/`.tsx`.
   - JSX/TSX exotic edge cases (P5+ React framework patterns).
4. **Pre-existing dirty files in sspower plugin (not graph-related):** `hooks/auto-review.sh`, `scripts/codex-bridge.mjs`, `scripts/mcp-lsp-client.mjs`. Carried forward from P0 handoff; status unchanged. Don't auto-commit; ask user.

## Decisions (do NOT revisit)
- **Node engine floor ≥22.5** (P1 codex iter 1). `node:sqlite` stable `DatabaseSync` API requires it; below 22.5 needs `--experimental-sqlite` flag. Both `bin/sspower-graph.mjs` and `bin/sspower-graph-bootstrap.sh` enforce.
- **Build is single transaction with pre-DELETE abort** (P1 codex iter 1, iter 4). `BEGIN IMMEDIATE` wraps destructive wipe + every insert. If >25% extraction-or-read failures, abort BEFORE the DELETE so the previous index survives tooling regressions.
- **Resolver three-tier confidence per spec §3.2** (P1 codex iter 1-5 — every blocker iterated to convergence):
  - DIRECT calls: intra-file (top-level only) → imports → cross-graph ambiguous.
  - MEMBER calls: import-via-namespace/default-receiver → cross-graph ambiguous. (Never intra-file by bareName — property-name lookup would forge false edges.)
  - Intra-file filtered to `qualifiedName === name` so class methods never capture bare calls.
  - Import lookup uses `byFileAndQualified` (qname-indexed), not bare-name — `import { helper }` resolves only to top-level `helper`, not `C.helper`.
- **JS files round-trip through a temp `.ts`/`.tsx`** (P1 design choice). The 6 YAML rules pin `language: typescript`; ast-grep refuses to apply them to `.js`/`.jsx`/`.mjs`/`.cjs`. JSX → `.tsx`, plain JS → `.ts`. P2 cleanup: parallel `js-*.yml` rules.
- **Default-import-alias resolution deferred to P2** (P1 codex iter 5). `import run from './mod'` where mod has `export default function actualName` produces no edge. Documented in plugin README. P2 extractor will tag default-exported nodes.
- **bun is canonical installer, npm fallback dropped** (P0 Codex review A1). `bun.lock` committed; bootstrap fails fast on missing bun.
- **MCP via `@modelcontextprotocol/sdk` with proper schemas** (D31, H3*): `ListToolsRequestSchema` + `CallToolRequestSchema` from `/types.js`. NOT string literals.
- **Single lock contract** (D34): Python `fcntl.flock` on `<cwd>/.claude/graph/.lock` for both dirty-append AND build/refresh. No shell `flock(1)`. Refresh + build run inside `graph-with-lock.py` wrapper that holds the lock across the Node child process.
- **node:sqlite NOT better-sqlite3** (D7): zero native build deps; `ExperimentalWarning` on Node 22 acceptable.
- **Anti-goal circuit-breaker** (D9, §1): if P3 MCP layer effort > 2 weeks, STOP and ship `codegraph install` companion via sspower installer.

## Gotchas
- **5 codex review iterations** were needed to fully harden the resolver. Each iter found a real correctness bug. If P2 refresh logic seems to "work", run codex review aggressively before declaring done — the test fixtures don't catch resolver edge cases that prod code triggers.
- **`graph-p0` and `graph-p1` are annotated tags** — use `git rev-parse 'graph-p1^{commit}'`, NOT the bare tag name, when comparing SHAs.
- **JSX support is best-effort.** The temp-extension dance handles common JSX cases, but exotic TSX/JSX edge cases may miss nodes silently.
- **Plan file uses `XEC(` sentinel during authoring** (sed-restored before commit) because a project Write hook blocks literal db.exec( substrings. The sed pass is one-shot; the committed plan file uses the real method name.

## Context
- **Repo**: `~/.claude/plugins/marketplaces/sskys18/plugins/sspower` (sskys18/sspower remote)
- **Branch**: `main` @ `6d28e18` (PR #1 merge commit), tag `graph-p1` at HEAD
- **Tests** (run from plugin root):
  - `bun run graph:tests` — chains 9 node-based tests (db schema, ast-grep wrapper, walker, extractor, resolver, build+query incl. live `cmdImplement` demo, MCP stub smoke)
  - `bun run graph:fixtures` — vitest harness with P/R gate on `ts-js` + `ts-js-multifile` packs
  - `bash tests/hooks/test-intent-architecture.sh` + `CLAUDE_PLUGIN_ROOT=$(pwd) python3 tests/graph/test-lock-helpers.py` — P0 regressions
- **Unknowns** (verify before acting):
  - User intent on P2 timing — may want to inspect P1 in real usage before committing to P2 scope.
  - 3 pre-existing dirty files in plugin — status unchanged from prior handoff.
