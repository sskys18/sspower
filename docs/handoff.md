# Session Handoff
> Generated: 2026-05-20 KST

## Task
sspower Codex-worker LSP gate. P4/Track C + P5/B7 + semble-rewrite
ownership fix — ALL SHIPPED & MERGED to local `main`. Resume #1
fresh-process smoke **DISCHARGED 2026-05-20** — Approach B confirmed.
No active build. Open item: push backlog to `origin`.

## Status
### Completed (local `main` @ `29f31a7`, NOT pushed; `origin/main` = `9bc8121`)
- **P2–P4 / Track C** (`9bc8121`): codex-lsp vendored; bridge MCP gate +
  repair loop; `lsp-check` + Stop gate; guard pretool + AGENTS.md.
  Detail in `docs/ARCHITECTURE.md`.
- **P5 / Phase B7** (`91cda0c`): 4 advisory fail-open Claude-side hooks
  + tests + fixtures. Plan-review approve; 4/4 tests.
- **semble-rewrite ownership fix** (`0d13ee6`, merge `b7b227c`):
  hooks.json reorder semble-rewrite FIRST (Approach B). Structural +
  4/4 unit green.
- **Resume #1 smoke (2026-05-20, NEW claude PROCESS)**: `ls -R skills`
  → tree-style output (`├──`/`└──`) with gitignore-filtered dirs =
  `semble_rs tree skills` ran. NOT rtk's `N files, M dirs (xx ms)`
  summary. Control: `CMD_REWRITER=__none__ ls -R skills` → native
  flat all-20-dir listing. → **Approach B EFFECTIVE.** Approach A
  fallback NOT needed. Resume #1 obligation discharged.

### In Progress
- None. Tree clean. `main` @ `29f31a7`, local-only (12 ahead).

## Resume Here
1. **`git push origin main`** (12 ahead). Auto-review re-fires;
   verdicts have converged `approve-with-followups`. If
   `deny_rounds_cap`, reset `.git/sspower-review-rounds-main`
   (stale-counter remedy, NOT `AUTO_REVIEW=off`).
2. Optional: re-draft Inv-A shared-fixture drift-guard test (run
   `semble-rewrite.sh` + `cmd-rewrite.sh` on shared inputs, assert
   cmd-rewrite SKIPS ⇔ semble EMITS `ask`). Prior draft (41/41 green)
   never committed and is lost — re-draft fresh. CI safety, not
   blocking; B is smoke-proven so no urgency.
3. Roadmap: **P6** (C4–C9 cleanup tail, spec §9) — only unshipped
   phase, not triggered. D-B6 advisory→block promotion stays
   operator-gated.

## Decisions (do NOT revisit)
- **semble-rewrite owns `ls -R`/`grep -R` via hooks.json REORDER
  (Approach B)** — one-line, no matcher duplication. Live-CONFIRMED
  by fresh-process smoke 2026-05-20. A (skip-list) / C (merged-hook)
  rejected: duplication / largest test surface.
- rtk kept (broad surface: git/read/find/gh); wholesale removal rejected.
- P5 hooks advisory-first (D-B6); DP-1 tree justified on
  gitignore-correctness, NOT discredited spec-§2 3000× figure.
- P2–P4 (bridge-direct `lsp-check` never model-MCP; `.codex/*`
  supervisor-authored; cooperative-worker guard) — locked, see ARCHITECTURE.

## Gotchas
- **Hook registry loads at CLI-PROCESS start. `/clear` does NOT reload it.**
  `/clear`-smoke = false negative (hook silently never runs). Valid
  hook-engine smoke = full `claude` quit+relaunch. Disambiguate
  non-execution vs engine-honor failure with a temp trace
  (`echo … >> /tmp/x.log`) at hook top. [[feedback-hooks-json-session-start-load]]
- `git checkout main` showing tracked files "modified" = behind-ref view,
  NOT data loss.
- chained-shell-check scans command TEXT: `&&`/`|`/`;` trips it — run
  chokepoints standalone (no trailing `; tail`), commit via `-F /tmp/file`.
- `git diff`/`ls -l` rtk-wrapped by cmd-rewrite → mangled; prefix
  `CMD_REWRITER=__none__` for true output. (Same bypass useful for
  validating semble-rewrite shape, as in Resume #1 smoke.)
- `.claude/` gitignored — `git add .claude/...` ERRORS/aborts the stage;
  durable rationale goes in `docs/`.
- Codex `implement --write @plan.md` stalls on plan's trailing "Which
  approach?" — prepend explicit EXECUTE directive. [[feedback-codex-execute-workflow]]
- Uncommitted in-session test drafts can be silently lost when the
  session's other work is reverted — commit (or stash with explicit
  label) BEFORE any revert.

## Context
- **Branch**: `main` @ `29f31a7`, tree clean, local-only — 12 commits
  ahead of `origin/main` = `9bc8121`. `main` only; no worktrees.
- **Tests**: 4 hook suites `rc=0 PASS` on merged `main`. hooks.json
  valid. Standalone semble-rewrite.sh confirmed correct.
- **Unknowns**: none. Resume #1 (live multi-hook reorder effect)
  discharged 2026-05-20 by fresh-process smoke.
