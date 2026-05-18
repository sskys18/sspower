# Session Handoff
> Generated: 2026-05-18 22:25 (KST)

## Task
sspower Codex-worker LSP gate, Track B. P2 + pulled-in P3 (B3+B4) + P6 — **SHIPPED & MERGED**.

## Status
### Completed (merged to `main`, PR #7, mergeCommit `242382e9`)
- **P2**: vendored codex-lsp (`tools/codex-lsp/`), `scripts/lib/codex-lsp-path.mjs` resolver, `scripts/setup-codex-lsp.mjs` (real `lsp` schema, merge-not-clobber), `.codex/` B2 advisory PostToolUse hook, bridge `-c mcp_servers.lsp.*` registration.
- **B3+B4** (the pulled-forward P3, by user decision): `scripts/mcp-lsp-client.mjs` + `runLspGate`/`runLspRepairLoop` in `scripts/codex-bridge.mjs`. **Resolves P2 B1** — dogfood-proven (seeded TS error → gate → repair_rounds=1 → Codex fix → clean).
- **P6**: C4–C9 cleanup (rounds-GC, `SSPOWER_DIET=off`, cmdComplete guard, env audit, patch audit, hook integration tests).
- 5 branch-review fix rounds → Codex `approve`. Tests: test-complete 15/0, test-integration 53/0, test-diet-off 10/0, all LSP/setup tests PASS.

### In Progress
- None. Track B executable scope complete. Branch `feat/codex-worker-trackB` merged (safe to delete local+remote).

## Resume Here
1. **No active build task.** Next forward move = re-plan **P4** (spec Phases B5+B6: Codex Stop gate + `.codex/rules` + sandbox profile `approval_policy=never`/`workspace-write`/`network off`). Its roadmap trigger ("P3 shipped AND bridge `_lsp.decision` repair loop converges in real use") is **now SATISFIED**. Invoke `sspower:writing-plans` for P4 — but only on explicit user go-ahead (P4/P5 are roadmap, not auto-start).
2. Owner decision (small, standalone): **`SSPOWER_REVIEW_CACHE_TTL`** — code default is `3600` (`hooks/auto-review.sh:229`) but `~/.claude/CLAUDE.md` + original design say "10min" (`600`). ARCHITECTURE.md now matches code. Decide: revert code→600 (honor design) OR ratify 3600 + update CLAUDE.md. Not changed pending decision.
3. P5 (semble_rs, Phase B7) stays roadmap — trigger: P2–P4 shipped AND semble_rs re-validated on a current working repo. Not yet (P4 unshipped).

## Decisions (do NOT revisit)
- **P3 pulled into Track B** (not deferred): P2 T6 proved B1-via-Codex-model unrecoverable (Codex 0.130 per-tool-call approval; only `--dangerously-bypass` overrides = unacceptable). Bridge-direct MCP sidesteps it. User-chosen.
- **Bridge-direct MCP, not model-issued**: the bridge speaks JSON-RPC to `codex-lsp mcp` itself, never via Codex's model tool path. Approval-gate path rejected (security cost).
- **`_lsp` NOT in `schemas/implementation-output.json`**: OpenAI strict `--output-schema` rejects optional/open props; `_lsp` is bridge-injected post-parse, never re-validated. Do not re-add (it 400s Codex).
- **codex-lsp config schema = `{lsp:{id:{command:[argv],extensions:[]}}}`** (not `{servers:...}`); setup MERGES, never clobbers a user `~/.codex/lsp-client.json`.
- **Worktree state via `git rev-parse --absolute-git-dir`** (not `$REPO_ROOT/.git`): worktree `.git` is a file. git 2.13+ floor accepted (no project floor documented).
- **PR #6 (P0+P1, `design/codex-worker-lsp-gate`) is separate** — untouched, still open. Track B was its own PR #7.

## Gotchas
- Codex 0.130 gates every **model-issued** MCP tool call behind a per-call approval that auto-cancels non-interactively (`user cancelled MCP tool call`). NOT sandbox/approval_policy/granular-knob fixable. Bridge-direct MCP is the only safe path. (See `.claude/wiki/gotchas.md` + ARCHITECTURE "Codex LSP self-repair".)
- codex-lsp signals infra-absence (missing server / no source files) as a SUCCESSFUL response: `isError:false` + `result.details.errorKind ∈ {missing_dependency,no_files}`. Must fail-open on errorKind, not just isError. Closed on both paths (bridge MCP + B2 hook).
- `git commit/push/merge` + `gh pr create/ready` are chained-shell-check chokepoints: standalone Bash only, `git -C <path>` (no `cd ;`), redirects OK, no `&&`/`;`. `gh pr merge` is NOT auto-review-gated (reviewed at PR open).
- `--output-schema` is sent verbatim to OpenAI strict API; `parseStructuredOutput` is plain JSON.parse (no ajv anywhere).

## Context
- **Branch**: `main` (Track B merged). `feat/codex-worker-trackB` merged, deletable. PR #6 (P0+P1) open & separate.
- **Tests**: all green — `tests/codex-bridge/*` (complete 15/0, mcp-lsp-client, lsp-gate, lsp-repair-termination, lsp-selfrepair-advisory 8/0, lsp-path, setup-codex-lsp), `tests/hooks/*` (diet-off 10/0, integration 53/0).
- **Plans**: `docs/plans/2026-05-18-codex-worker-lsp-trackB-P2-P6.md` (P4/P5 roadmap section has triggers); `docs/plans/2026-05-18-bridge-side-lsp-gate-B3B4.md` (the executed P3 plan, SSOT-corrected).
- **Unknowns**: P4 sandbox-profile interaction with the existing bridge `--print-args`/spawn path is unmapped — verify against `scripts/codex-bridge.mjs` `runCodexExec` before planning P4 tasks.
