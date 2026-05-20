# Session Handoff
> Generated: 2026-05-20 KST

## Task
sspower Codex-worker LSP gate. P4/Track C + P5/B7 + semble-rewrite
ownership fix — ALL SHIPPED, MERGED to `main`, and **PUSHED TO ORIGIN**.
Resume #1 fresh-process smoke discharged 2026-05-20 (Approach B
confirmed). semble-rewrite hardened (quote-type-aware bail; always-sq
emit; bash 3.2 shq fix). No active build.

## Status
### Completed (origin/main @ `da54a97`; local main one doc-commit ahead until this handoff is pushed)
- **P2–P4 / Track C**: codex-lsp vendored; bridge MCP gate + repair
  loop; `lsp-check` + Stop gate; guard pretool + AGENTS.md.
- **P5 / Phase B7**: 4 advisory fail-open Claude-side hooks + tests +
  fixtures.
- **semble-rewrite ownership** (Approach B = hooks.json reorder):
  semble-rewrite FIRST in PreToolUse:Bash. Live-confirmed by fresh-
  process smoke 2026-05-20.
- **semble-rewrite quoting hardening** (this session, 4 commits):
  - `41407f4` dequote single-token paths (round-1 fix).
  - `b306efc` bail on unquoted globs (round-2 fix).
  - `da54a97` quote-type aware bail (var/tilde/cmd-sub) + always-sq
    emit (printf %q tilde leak fix) + bash 3.2 shq via printf -v.
    Also README + P5 plan superseded note.
- **Push to origin succeeded** after auto-review converged
  (`9bc8121..da54a97`). 17 commits.

### In Progress
- None. Tree clean. Local `main` ahead by exactly this handoff commit
  until pushed; the 17-commit feature backlog is on `origin/main` @
  `da54a97`.

## Resume Here
1. Optional: re-draft Inv-A shared-fixture drift-guard test (run
   `semble-rewrite.sh` + `cmd-rewrite.sh` on shared inputs, assert
   cmd-rewrite SKIPS ⇔ semble EMITS `ask`). Prior draft (41/41 green)
   never committed and is lost — re-draft fresh. CI safety, not
   blocking; B is smoke-proven + auto-review approved.
2. Roadmap: **P6** (C4–C9 cleanup tail, spec §9) — only unshipped
   phase, not triggered. D-B6 advisory→block promotion stays
   operator-gated.
3. Optional polish: address remaining followups in
   `.claude/sspower/followups.md` (advisory backlog accumulated from
   prior rounds — none blocking).

## Decisions (do NOT revisit)
- **semble-rewrite owns `ls -R`/`grep -R` via hooks.json REORDER
  (Approach B)** — live-CONFIRMED by fresh-process smoke 2026-05-20.
  A (skip-list) / C (merged-hook) rejected.
- **semble-rewrite always single-quote-wraps emitted args** (not
  printf %q). Reason: bash 3.2's %q does not escape a leading `~`,
  leaking tilde expansion through single-quoted-intent inputs. Single-
  quote wrap also disables every other shell expansion uniformly.
- **dequote_to tracks QTYPE** ('', "'", '"') so callers can bail on
  unquoted expansion intent (`ls -R $HOME`) while honoring single-
  quoted literal intent (`ls -R '$DIR'` → literal `$DIR`).
- rtk kept (broad surface: git/read/find/gh); wholesale removal rejected.
- P5 hooks advisory-first (D-B6); DP-1 tree justified on gitignore-
  correctness, NOT discredited spec-§2 3000× figure.
- P2–P4 (bridge-direct `lsp-check` never model-MCP; `.codex/*`
  supervisor-authored; cooperative-worker guard) — locked, see
  ARCHITECTURE.md.

## Gotchas
- **Hook registry loads at CLI-PROCESS start. `/clear` does NOT reload it.**
  Valid hook-engine smoke = full `claude` quit+relaunch. Disambiguate
  non-execution vs engine-honor failure with a temp trace
  (`echo … >> /tmp/x.log`) at hook top.
  [[feedback-hooks-json-session-start-load]]
- **bash 3.2 mis-parses `'\\''` inline inside `${var//pat/rep}`** —
  even though the same idiom works on the command line. Build the
  4-char replacement (`'\''`) via `printf -v _r '%s%s%s%s' "'" '\' "'" "'"`
  and substitute via `${1//\'/$_r}`. macOS default bash is 3.2.57; hooks
  must remain 3.2-compatible.
- **bash 3.2 `printf %q` does NOT escape a leading `~`** — `~/src` is
  emitted as `~/src` (not `\~/src`), so always-single-quote wrap is
  the correct fix when user intent is literal.
- **Auto-review iteration cap** = 3 rounds per branch (CLAUDE.md);
  tunable via `SSPOWER_REVIEW_MAX_ROUNDS`. Each push attempt increments
  `<repo>/.git/sspower-review-rounds-<branch>`; at cap, push is denied
  with `deny_rounds_cap`. Observed this session: deny fired at 2/2 with
  default config (env may have lowered the cap). Remedy: `rm` the
  counter file (stale-counter remedy per CLAUDE.md), NOT
  `AUTO_REVIEW=off`. Counter persists across push attempts within the
  same branch.
- `git checkout main` showing tracked files "modified" = behind-ref
  view, NOT data loss.
- chained-shell-check scans command TEXT: `&&`/`|`/`;` trips it — run
  chokepoints standalone (no trailing `; tail`), commit via `-F /tmp/file`.
- `git diff`/`ls -l` rtk-wrapped by cmd-rewrite → mangled; prefix
  `CMD_REWRITER=__none__` for true output. (Same bypass useful for
  validating semble-rewrite shape.)
- `.claude/` gitignored — `git add .claude/...` ERRORS/aborts the
  stage; durable rationale goes in `docs/`.
- Codex `implement --write @plan.md` stalls on plan's trailing "Which
  approach?" — prepend explicit EXECUTE directive.
  [[feedback-codex-execute-workflow]]
- Uncommitted in-session test drafts can be silently lost when the
  session's other work is reverted — commit (or stash with explicit
  label) BEFORE any revert.

## Context
- **Branch**: local `main` one doc-commit ahead of `origin/main` @
  `da54a97`; pushing this handoff brings them in sync. Tree clean.
  `main` only; no worktrees.
- **Tests**: all 8 hook suites green
  (codex-guard-pretool, codex-lsp-posttool, codex-stop-gate, diet-off,
   integration, semble-context, semble-rewrite, semble-session).
  semble-rewrite gained 22 new test cases this session
  (quoted-path dequote, unquoted-glob bail, var/tilde/cmd-sub bail,
   single-quoted-literal honor, embedded-sq escape).
- **Unknowns**: none.
