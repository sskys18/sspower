# Session Handoff
> Generated: 2026-05-19 (KST)

## Task
sspower Codex-worker LSP gate, **Track C / P4** (spec Phases B5+B6, D-B4/D-B5): Codex Stop gate + PreToolUse guard/AGENTS.md + hardened write profile + D-4a resume-hardening. Executed via subagent-driven-development with Codex workers. **Implemented on branch `feat/codex-worker-trackC`; NOT yet pushed/merged.**

## Status
### Completed (committed on `feat/codex-worker-trackC`, NOT pushed)
- **Pre-work**: `git merge`+push of leftover Track B → `origin/main` (was a stale tracking ref, not a lost merge); `SSPOWER_REVIEW_CACHE_TTL` reverted 3600→600 (owner decision) in `hooks/auto-review.sh` + ARCHITECTURE.md.
- **P4 plan**: `docs/plans/2026-05-18-codex-worker-lsp-trackC-P4.md` (plan-review 3-round cap; honest gate-outcome documented — NOT a clean approve; rounds 1–2 defects fixed).
- **Task 0** (`042836e`): verification spike. Codex 0.130 contract confirmed; **D-4a CONFIRMED GAP** (resume runs network-ON; `-c` flags accepted → closable). Findings: `docs/plans/notes/P4-spike-findings.md`.
- **Task 1** (`7da892a`): `lsp-check` subcommand (reuses `runLspGate`, fail-open). Spec+quality reviewed → approve.
- **Task 2** (`35037a5`): Codex Stop gate (`.codex/codex-lsp-stop.sh` + hooks.json Stop). Spec compliant; quality approve-with-followups (block-path coverage advisory).
- **Task 3** (`4d654f4`): PreToolUse guard (`.codex/codex-guard-pretool.sh`) + `AGENTS.md`. Spec compliant; quality needs-attention **accepted with documented threat-model rationale** (cooperative-worker scope; deeper evasion out of layer — see `.claude/sspower/followups.md`).
- **Task 4** (`8220e7c`): hardened write profile + **D-4a fully closed** (all 3 write-capable resume callers — runLspRepairLoop/cmdResume/cmdSteer — pass `hardenWrite:true`). Spec compliant; quality **approve**.
- **Full P4 verification matrix GREEN** (run 2026-05-19, before docs edits): node-check OK, test-lsp-check PASS, test-complete 15/0, test-harden-write-args 4/0, test-codex-stop-gate PASS, test-codex-guard-pretool PASS (26 cases), hooks.json `PostToolUse,PreToolUse,Stop`, test-integration 0 failed.

### In Progress — Task 5 (docs), being committed now
- **Task 5**: docs written (ARCHITECTURE P4 section + env line, wiki gotchas+decisions, this handoff). Codex doc-accuracy review run → 2 blocking accuracy fixes applied (ARCHITECTURE PreToolUse claim de-overstated; this handoff Task-5 status corrected). **Not yet committed** at the time these lines were written — it is the *next* commit on `feat/codex-worker-trackC` (the one carrying this file). Tasks 0–4 ARE committed (SHAs above).

## Resume Here
1. **Finish the branch.** Invoke `sspower:finishing-a-development-branch` for `feat/codex-worker-trackC`: push + open PR into `main`. `git push`/`gh pr create` are auto-review chokepoints — the branch-diff Codex review is the real merge gate (per-task reviews already done; expect it to surface the same Task-3 threat-model point — the documented rationale in `.claude/sspower/followups.md` + commit `4d654f4` is the answer, not more guard iteration).
2. **`.claude/sspower/followups.md`** holds advisory followups (Task 2 block-path test coverage; Task 3 threat-model disposition; PreToolUse matcher widened to `.*`). NOTE: that file is **gitignored** (local-only) — the durable threat-model + matcher rationale also lives in committed `docs/ARCHITECTURE.md` (P4 section), so it travels with the branch/PR and the branch-review Codex will see it there. Carry forward; not blockers.
3. **P5** (semble_rs, Phase B7) stays roadmap — trigger: P2–P4 **shipped** (P4 not yet merged) AND semble_rs re-validated on a current repo. Re-plan via `writing-plans` only when triggered + explicit go-ahead.

## Decisions (do NOT revisit) — see `.claude/wiki/decisions.md` P4 block
- **D-4a empirically gated**: `codex exec resume` does NOT inherit network-off but accepts the `-c` flags; every write-capable resume caller hardened. Proven by Task-0 spike, not assumed.
- **B6 rules = PreToolUse hook + AGENTS.md**, not `.codex/rules/*.rules` (no such Codex primitive). D-B4 intent honored.
- **`.codex/` is Codex-sandbox-unwritable** → those files are supervisor-authored; relied on as a security property.
- **PreToolUse guard = cooperative-worker threat model**; adversarial evasion out of scope at that layer (sandbox/approval profile is the real perimeter). Quality `needs-attention` accepted with this rationale — do NOT re-litigate by iterating the guard.
- **plan-review gate**: 3-round cap reached, NOT a clean terminal approve; rounds 1–2 substantive defects fixed; documented honestly in the plan. Codex reviewed the v1.1.0 **cache** tree (D-C1) — gate evidence weaker than canonical; a canonical-tree re-review is advised before promoting B5/B6 from advisory.

## Gotchas — see `.claude/wiki/gotchas.md`
- Codex 0.130 hook contract == Claude Code's (verified in native binary). Stop=`{decision:block,reason}`/exit-2; PreToolUse=`permissionDecision`.
- Codex per-call **model**-MCP approval is un-bypassable (`approval_policy=never` does NOT lift it) → B5 uses bridge-direct `lsp-check`, never model MCP.
- `codex exec --json` emits `thread_id` (not session_id); `codex exec resume` rejects `-C` (use spawn cwd), accepts `-c`.
- Security-reminder PreToolUse hook false-positives on the string `child_process` in prompt/test text — retry the Write.
- Chokepoints: `git commit/push/merge` + `gh pr create/ready` standalone Bash only; the chained-shell-check hook also scans **prompt text** (a `git ... || ...` literal inside a `--prompt` string trips it — pass such prompts via `@file`).

## Context
- **Branch**: `feat/codex-worker-trackC` (off `main`). `git rev-list --count origin/main..HEAD` = **7** before the Task-5 commit (2 plan commits `92d41f9`/`d750de2` + Task 0–4 `042836e`/`7da892a`/`35037a5`/`4d654f4`/`8220e7c`) → **8** after Task 5. NOT pushed. `origin/main` = `af75222` (TTL revert) — Track B already merged there.
- **Plans**: `docs/plans/2026-05-18-codex-worker-lsp-trackC-P4.md` (the executed P4 plan, honest gate-outcome); `docs/plans/notes/P4-spike-findings.md` (Task-0 D-4a evidence).
- **Engine note**: Tasks 1 & 4 = Codex workers (codex-bridge.mjs implement/resume, session-resumed fix loops). Tasks 0, 2, 3, 5 = supervisor-direct (verification spike / `.codex/`-bound content Codex sandbox forbids / docs) — each still passed the Codex two-stage review.
- **Unknowns**: none open for P4. For the branch PR: the branch-diff auto-review may re-raise Task-3 adversarial-evasion — answer is the documented threat-model rationale, not guard changes.
