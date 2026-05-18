# Session Handoff
> Generated: 2026-05-18 (KST)

## Task
sspower Codex-worker LSP gate — Track B. P2 (vendor codex-lsp + B1/B2 advisory self-repair) + P6 (cleanup C4–C9). P3–P5 roadmap-only.

## Status
### Completed
- **P0+P1 fully shipped** — PR #6 (`design/codex-worker-lsp-gate`), Codex branch-review `approve`. Separate; do NOT touch.
- `docs/plans/2026-05-18-codex-worker-lsp-trackB-P2-P6.md` — Track B plan, `plan-review` approve-with-followups, committed `20c5d9b`.
- **P2 Task 1 DONE** (`29f85e3`): `tools/codex-lsp/` vendored — `dist/` (272K, maps stripped) + `LICENSE` (MIT) + `PROVENANCE.md` (pinned `05e8f07`, 0-dep, verified runs standalone).

### In Progress
- P2 Tasks 2–7 not started. Branch `feat/codex-worker-trackB` clean at `29f85e3`.

## Resume Here
1. **Invoke `sspower:subagent-driven-development`** on `docs/plans/2026-05-18-codex-worker-lsp-trackB-P2-P6.md`, executable scope only, starting at **P2 Task 2** (resolver `scripts/lib/codex-lsp-path.mjs`). Strictly sequential, one worker per task + spec-review then quality-review. Order: P2 Tasks 2→7, then P6 Tasks 8→14.
2. After P6: `sspower:finishing-a-development-branch` → Codex branch-review loop → push `feat/codex-worker-trackB` + its **own** PR (NOT into PR #6).
3. P3/P4/P5: do NOT implement. Each re-plans via `writing-plans` only when its roadmap trigger fires.

## Decisions (do NOT revisit)
- **Vendor codex-lsp `dist/`** (not submodule, not env-only): 0-dep static MIT bundle — reproducible, no setup build/network. Submodule rejected (ceremony, zero gain). `SSPOWER_CODEX_LSP_CLI` = override escape hatch.
- **New branch `feat/codex-worker-trackB` off P0+P1 HEAD** (not on `design/`): keeps PR #6 clean. User-chosen. Worktree rejected (branch isolates; loaded plugin = marketplace tree).
- **Codex tier = default/`fast`** (P1 config, out-of-repo). **Never set `service_tier`** — `flex` API-rejected (400) this account. Memory: `project-codex-service-tier-flex-unsupported`.
- **P2/P6 strictly sequential** (SDD red-flag: no parallel implementation subagents).
- **P3–P5 roadmap-only** — speculative matrices for unproven phases violate no-placeholder (spec v6 PROVISIONAL).

## Gotchas
- `node tools/codex-lsp/dist/cli.js` with **no args = MCP stdio server (hangs)**, NOT help. Verify with `--help` → `Usage: codex-lsp [mcp | hook post-tool-use]` exit 0. Plan Task 1 Step 1/4 verify cmd is wrong this way.
- `auto-spec-gate.sh` removed in P1 (D-A5): committing `docs/plans/*` does NOT auto-trigger Codex review. Replacement = explicit `codex-bridge.mjs plan-review` (already done for this plan).
- Git chokepoints (`git commit/push/merge`, `gh pr ...`) MUST be standalone Bash (no `&&`/`;`/`cd ;`) or the chained-shell-check hook denies.
- `.codex/hooks.json` (P2 Task 4) uses **Codex's** hook schema, NOT Claude's — re-read codex-lsp's own `hooks/` dir for real key names first.

## Context
- **Branch**: `feat/codex-worker-trackB` @ `29f85e3` (parents `20c5d9b` plan → `f4e77e0` P0+P1 tip). `main` unaffected. PR #6 = P0+P1 on `design/codex-worker-lsp-gate`.
- **Tests**: `test-complete.sh` PASS=14/0; `test-track-prompt-hook.sh` 7/7; `test-registry.sh` rescue→implement (codex-network full pass). Bridge `node --check` OK.
- **Tools**: `semble_rs` @ `~/.cargo/bin` (P5 only); `typescript-language-server` + `bun` on PATH; codex-lsp vendored `tools/codex-lsp/dist/cli.js`. `/tmp/codex-lsp` transient (rebuild recipe in PROVENANCE.md).
- **Unknowns** (verify before acting): Codex `.codex/config.toml` fragment-merge semantics (P2 Task 5 — never overwrite user file; write-only-if-absent + log skip); Codex `.codex/hooks.json` exact schema (P2 Task 4).
