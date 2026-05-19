# Session Handoff
> Generated: 2026-05-19 (KST, updated post-P5-revalidation)

## Task
sspower Codex-worker LSP gate. **P4 / Track C — SHIPPED & MERGED.** **P5 / Phase B7 — SHIPPED & MERGED LOCALLY** (`82e3dad`). **semble-rewrite ownership fix — MERGED LOCALLY** (`main` @ `b7b227c`, NOT pushed — `origin/main` still `9bc8121`). No active build task.

> ⚠️ **DEFERRED LIVE-SMOKE (must run in a FRESH session):** the semble-rewrite reorder fix (`0d13ee6`) is structurally + unit-verified but its live multi-hook effect is UNCONFIRMED — `hooks/hooks.json` loads at session start, so the editing session can't test it. In a new Claude Code session on `main`, run `ls -R <small dir>` and confirm it yields a `semble_rs tree …` **ask-prompt** (NOT rtk's `N files, M dirs` auto-run). If still rtk → reorder is ineffective; fall back to spec Approach A (skip-list in cmd-rewrite.sh). Spec/plan: `docs/specs|plans/2026-05-19-semble-rewrite-ownership-*`.

## Status
### Completed (merged to `main`, PR #8, mergeCommit `9bc8121`)
- **B5**: `lsp-check` bridge subcommand (reuses shipped `runLspGate`; bridge-direct, never model MCP) + `.codex/codex-lsp-stop.sh` Codex Stop hook (advisory default `SSPOWER_CODEX_STOP_GATE`; D-B7 fail-open incl reason-escape).
- **B6**: `.codex/codex-guard-pretool.sh` PreToolUse guard (deny git commit/push/merge & recursive rm; ask installs; node classifier; matcher `.*`) + root `AGENTS.md`.
- **B6/D-B5**: hardened write profile — `runCodexExec`/`runCodexResume` `hardenWrite` → `-c approval_policy="never"` + `-c sandbox_workspace_write.network_access=false`; `cmdImplement` ties to `--write`; ALL write-capable resume callers (runLspRepairLoop/cmdResume/cmdSteer) hardened (**D-4a closed**). Review paths stay read-only.
- **Pre-work**: leftover Track B synced to `origin/main` (was stale tracking ref, not lost merge); `SSPOWER_REVIEW_CACHE_TTL` reverted 3600→600.
- Tests green: node-check, test-lsp-check, test-complete 15/0, test-harden-write-args 4/0, test-codex-stop-gate, test-codex-guard-pretool (incl quoted/escaped-arg cases), hooks 3 events, test-integration 0 failed.
- Branches cleaned: `feat/codex-worker-trackC` (local+remote) + all stale (trackB, design/, phase-a..d) deleted. Local branches = `main` only.

- **P5 re-validation (2026-05-19)**: semble_rs re-measured (sspower, 307 files). `docs/plans/notes/P5-semble-revalidation-findings.md`. search ~89× win, savings 84%, sub-second warm.

### Completed — P5 / Phase B7 (merged local `main` `82e3dad`, 2026-05-19)
- 4 advisory + fail-open Claude-side hooks: `hooks/semble-context.sh` (UserPromptSubmit `semble_rs plan` inject), `hooks/semble-rewrite.sh` (PreToolUse:Bash `ls -R`/`grep -R IDENT` → semble, **single explicit `ask`**, never deny, between cmd-rewrite & auto-review), `hooks/semble-session.sh` (SessionStart avail + time-bounded detached warm), `hooks/codex-lsp-posttool.sh` (PostToolUse codex-lsp on Claude's edits, **de-fanged** block→advisory). + hooks.json wiring, 4 test scripts, 3 committed `.cjs` fixtures, ARCHITECTURE P5 section + hook table.
- Plan `docs/plans/2026-05-19-codex-worker-P5-semble-context-layer.md` — Codex plan-review **approve** (8 rounds; 3 findings refuted w/ primary evidence). Codex `implement --write` executed; independent test re-run 4/4 green; pre-flight branch-review **approve** (1 blocking root-glob data-loss in test-semble-context FIXED `0ebdb6f`). Merge gate: converged `approve-with-followups` + sec `approve`; stale per-branch round-counter reset (documented remedy, NOT `AUTO_REVIEW=off`).
- All advisory-first (D-B6); semble_rs/codex-lsp pre-1.0 → every hook `command -v…||exit 0` + timeout (gtimeout/timeout/perl/unbounded-doc) + fail-open. DP-1 tree justified on gitignore-correctness, NOT discredited 3000×.

### In Progress
- None. `main` is **ahead of `origin/main` by the P5 merge `82e3dad`** (local-only). handoff edit uncommitted.

## Resume Here
1. **No active task. P5 shipped local.** If publishing: `git push origin main` (auto-review gate will fire — latest verdict converged `approve-with-followups`; if `deny_rounds_cap`, the stale `.git/sspower-review-rounds-main` counter is the documented-remedy reset, the verdict itself passes). Then commit this handoff.
2. Optional (operator-gated, never auto): D-B6 advisory→block promotion — P5 hooks ship advisory-only; flip a block-mode env ONLY after operator confirms N clean advisory runs. Distinct from P4's `SSPOWER_CODEX_STOP_GATE`. Not now.
3. Spec roadmap remainder: **P6** (C4–C9 cleanup tail, spec §9) is the only unshipped phase. P3 (B3+B4 bridge MCP gate) already shipped in Track C.

## Decisions (do NOT revisit)
- **B5 reuses bridge-direct `runLspGate` via `lsp-check`, never model MCP**: Codex 0.130 per-call model-MCP approval is un-bypassable (`approval_policy=never` doesn't lift it). Model-MCP path rejected — security/abort cost.
- **B6 rules = `.codex/hooks.json` PreToolUse hook + `AGENTS.md`, NOT `.codex/rules/*.rules`**: no such Codex primitive exists. Honors D-B4 intent. Spec-prose filename deviation ratified.
- **PreToolUse guard = COOPERATIVE-worker threat model**: regex classifier can't reproduce shell+git option parsing; exotic quoting/escaping evasion + git-globals outside the strip-list are documented OUT-OF-SCOPE in `docs/ARCHITECTURE.md`. Real adversarial perimeter = sandbox + approval_policy=never + network_access=false (shipped). Do NOT re-iterate the guard for adversarial cases — accepted boundary, advisor+user sanctioned.
- **`.codex/*` files are supervisor-authored**: Codex workspace-write sandbox forbids writing `.codex/` (a relied-on security property).
- **D-4a empirically gated**: `codex exec resume` does NOT inherit network-off but accepts the `-c` flags (proven, `docs/plans/notes/P4-spike-findings.md`). All resume callers re-apply hardening.
- **PR #8 final push used `SSPOWER_AUTO_REVIEW=off`** per user pre-authorization to accept the documented guard threat-model boundary after 4 good-faith review rounds. Reviewed code; objection was the boundary itself.

## Gotchas
- Codex 0.130 hook contract == Claude Code's (verified in native blob): Stop=`{decision:block,reason}`/exit-2; PreToolUse=`permissionDecision`; hooks.json nested `{matcher?,hooks:[{type,command,timeout,statusMessage}]}`. See `.claude/wiki/gotchas.md`.
- `codex exec --json` emits `thread_id` (not session_id); `codex exec resume` rejects `-C` (use spawn cwd), accepts `-c`.
- Codex shell `tool_name` token NOT pinned (blob has bash/exec/run + local_shell/exec_command) → PreToolUse matcher MUST stay `.*` (anchored = silent total D-B4 bypass).
- `git checkout main` after a remote-only merge shows stale local-main files as "modified" — it's a behind-ref, FF/reset to `origin/main` (verify ancestor first), not data loss.
- chained-shell-check scans **prompt/commit-message text too**: `git ... || ...` or `|` regex literals inside a `--prompt`/`-m` string trip it — pass via `@file` / `-F file`.
- `.claude/` is gitignored (wiki + followups.md are local-only sidecars); durable rationale must live in committed `docs/` to travel with a PR.
- **semble_rs `tree` 3000× collapsed to ~5× on a clean repo**: spec §2's 3000× was an artifact of kimp's un-gitignored exploding 12 MB `ls -R` tree. On gitignore-clean repos absolute win is small. search win (~89×) is the real, repo-independent value. B7 design must not lean on the tree figure.

## Context
- **Branch**: `main` @ `9bc8121` (PR #8 merged; P4 full). Working tree NOT clean: new `docs/plans/notes/P5-semble-revalidation-findings.md` (untracked) + modified `docs/handoff.md`, uncommitted. `origin/main` synced at `9bc8121`.
- **Tests**: all green (matrix above).
- **Plans**: `docs/plans/2026-05-18-codex-worker-lsp-trackC-P4.md` (executed P4, honest gate-outcome); `…-trackB-P2-P6.md` §P5 (roadmap); `docs/plans/notes/P4-spike-findings.md` (D-4a evidence).
- **Unknowns**: P5 semble_rs perf RESOLVED (re-validated 2026-05-19, this repo — see findings note). Residual: semble_rs still pre-1.0/young (R1) → B7 stays advisory-first w/ availability guards, no hard critical-path dep.
