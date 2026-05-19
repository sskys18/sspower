# Session Handoff
> Generated: 2026-05-19 (KST)

## Task
sspower Codex-worker LSP gate. P4/Track C + P5/Phase B7 + semble-rewrite
ownership fix — all SHIPPED & MERGED to **local** `main`. No active build task.
One verification obligation outstanding (Resume #1).

## Status
### Completed (all on local `main` @ `1634ad9`, NOT pushed)
- **P2–P4 / Track C** (`9bc8121`): codex-lsp vendored; bridge MCP gate +
  repair loop (`mcp-lsp-client.mjs`); `lsp-check` + `.codex/codex-lsp-stop.sh`
  Stop gate; `.codex/codex-guard-pretool.sh` + `AGENTS.md`; hardened write
  profile (D-4a). Detail in `docs/ARCHITECTURE.md`.
- **P5 / Phase B7** (`82e3dad`): 4 advisory fail-open Claude-side hooks
  (`semble-context`, `semble-rewrite`, `semble-session`, `codex-lsp-posttool`)
  + tests + fixtures + ARCHITECTURE. Plan-review approve; impl + 4/4 tests.
- **semble-rewrite ownership fix** (`0d13ee6`, merge `b7b227c`): P5 had
  semble-rewrite AFTER cmd-rewrite → rtk shadowed it (CLI chains
  `updatedInput` in array order). Fix = reorder semble-rewrite FIRST in
  `hooks/hooks.json`. Spec/plan `docs/specs|plans/2026-05-19-semble-rewrite-ownership-*`
  (both Codex-approved). Structural + 4/4 unit green; pre-flight approve.

### In Progress
- None. Tree clean. `main` @ `1634ad9` is **ahead of `origin/main` `9bc8121`**
  (local-only; P5 + semble fix unpushed).

## Resume Here
1. **FRESH-SESSION LIVE SMOKE (highest priority — the one unproven thing).**
   In a NEW Claude Code session on `main`, run `ls -R hooks/__pycache__`.
   Expect: a `semble_rs tree …` **ask-prompt**. If instead you get rtk's
   `N files, M dirs (…)` auto-run with no prompt → the reorder is
   INEFFECTIVE; implement spec **Approach A** (skip-list in
   `hooks/cmd-rewrite.sh`: before `rtk rewrite`, if CMD matches semble's
   `ls -R`/`grep -R IDENT` patterns → `exit 0` passthrough). Reason it
   can't be tested in the editing session: hooks.json loads at session
   start, not hot-reloaded.
2. Optional: `git push origin main` to publish (auto-review re-fires;
   verdicts already converged `approve-with-followups`; if
   `deny_rounds_cap`, reset `.git/sspower-review-rounds-main` — that's
   the stale-counter remedy, NOT a verdict failure, NOT `AUTO_REVIEW=off`).
3. Roadmap: **P6** (C4–C9 cleanup tail, spec §9) — only unshipped phase,
   not triggered. D-B6 advisory→block promotion stays operator-gated.

## Decisions (do NOT revisit)
- **semble-rewrite owns `ls -R`/`grep -R` via hooks.json REORDER (Approach B)**,
  not skip-list (A) / merged-hook (C): one-line change, no matcher
  duplication. rtk kept for its broad surface — wholesale removal rejected
  (rtk only loses on non-gitignore recursive trees; helps git/read/find/gh).
- **My earlier "rtk zeroes git/cat" was a measurement error** (broken
  `CMD_REWRITER=__none__ rtk $c` word-split). rtk works; do not re-raise.
- P5 hooks **advisory-first** (D-B6); DP-1 tree justified on
  gitignore-correctness, NOT the discredited spec-§2 3000× figure.
- P2–P4 decisions (bridge-direct `lsp-check` never model-MCP; `.codex/*`
  supervisor-authored; cooperative-worker guard threat model) — locked,
  see `docs/ARCHITECTURE.md`.

## Gotchas
- **hooks.json loads at SESSION START — mid-session edits not hot-reloaded.**
  Live hook-engine changes are unverifiable in the editing session; defer
  to fresh-session smoke (Resume #1). [[feedback-hooks-json-session-start-load]]
- `git checkout main` then seeing tracked files "modified" = behind-ref
  view (fix lives in branch/merge commit), NOT data loss.
- chained-shell-check scans commit-message/prompt TEXT: `&&`/`|`/`;` or
  `cd … ; git` trips it — commit via `-F /tmp/file`, run chokepoints
  standalone (no `cd …;`), cwd already = repo root.
- `git diff` is rtk-wrapped by cmd-rewrite → mangled capture; use
  `CMD_REWRITER=__none__ git diff -p A B > file` for a true patch.
- `.claude/` gitignored — `git add .claude/wiki/gotchas.md` ERRORS/aborts
  the whole stage (not silent-skip); durable rationale goes in `docs/`.
- Codex `implement --write @plan.md` stalls on the plan's trailing
  "Which approach?" handoff — prepend an explicit EXECUTE directive.
  [[feedback-codex-execute-workflow]]

## Context
- **Branch**: `main` @ `1634ad9`, working tree clean, local-only
  (`origin/main` = `9bc8121`). Local branches = `main` only; no worktrees.
- **Tests**: 4 hook suites `rc=0 PASS` (semble-context/rewrite/session/
  codex-lsp-posttool) on merged `main`. hooks.json valid.
- **Unknowns**: live multi-hook reorder effect (Resume #1) — the only
  thing not empirically proven. Everything else verified.
