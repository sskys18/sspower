# Session Handoff
> Generated: 2026-06-01 — SSPOWER_* env-flag cleanup. 2 dead flags removed + CLAUDE.md consolidated. Plan-reviewed (approve-with-followups). Uncommitted, awaiting supervisor commit.

## Task
Reduce SSPOWER_* env-flag surface. User wanted "minimum (~22)"; codex review + docs sweep proved most flags are a documented operator API → corrected scope to "remove genuinely-dead flags only + fix CLAUDE.md prose". DONE.

## Status
### Completed (uncommitted on `main`)
- `tests/hooks/test-integration.sh` — removed 2 dead flags: `SSPOWER_REVIEW_AUTO_APPLY` (from `NO_CACHE`, :313) + stale `SSPOWER_SANITY_REVIEW` comment block (:83-85). Suite **40/0**.
- `CLAUDE.md` — review-tunable enumeration (`SSPOWER_REVIEW_CACHE_TTL/APPROVE_TTL/TIMEOUT/MAX_ROUNDS`) replaced with pointer to `docs/ARCHITECTURE.md §Tunables`.
- `docs/plans/2026-06-01-sspower-env-flag-reduction.md` — NEW, plan-reviewed `approve-with-followups`. Contains the §Rejected list (do-not-inline) + §6 Tier-2 (feature-deletion path, not done).
- Net: 53 → **51** distinct flags in code. (Earlier this session, ALSO done + PUSHED @ `73bb72e`: skill-triggering coverage lint — separate, unrelated.)

### In Progress
- None. 3 files uncommitted (below). Supervisor commits (plan rule: codex worker must not git commit).

## Resume Here
1. **Commit the 3 uncommitted changes + push** (standalone `git -C` chokepoints, auto-review-gated): `CLAUDE.md`, `tests/hooks/test-integration.sh`, `docs/plans/2026-06-01-sspower-env-flag-reduction.md`. Suggested msg: `refactor(env): remove 2 dead SSPOWER_* flags + point CLAUDE.md tunables at ARCHITECTURE.md`.
2. **Nothing else pending.** 51 is the no-regret floor.
3. **Optional (only if user wants <51):** §6 Tier-2 of the plan — deletes features (codex-surface hook, LSP block-modes) or reworks p4-eval off env toggles. Needs explicit "delete those features" decision.

## Decisions (do NOT revisit)
- **2026-06-01 D-ENV-FLOOR-51**: SSPOWER_* env flags are a documented operator API (`docs/ARCHITECTURE.md §Tunables`), NOT clutter. Only 2 were dead (`REVIEW_AUTO_APPLY`, `SANITY_REVIEW`). Inlining documented tunables/toggles = breaking contracts + deleting capability. Rejected: the 22/25/31 inlining targets (codex plan-review needs-attention'd them; `BRIDGE_PATH` live in `sspower_mem`, `FLOW_FENCE`/`SEMBLE_REWRITE`/`REVIEW_TIMEOUT` documented escape hatches). The "too many" feeling was CLAUDE.md prose, not code — fixed by the ARCHITECTURE.md pointer.
- **2026-06-01 D-EVAL-NO-CLAUDE-P** (prior, shipped @ `73bb72e`): skill-trigger regression tested by deterministic description-contract lint, not live `claude -p`. `run-all.sh` defaults to lint unless `SSPOWER_LIVE_SKILL_TRIGGERING=1`.
- Carries forward: D-A (state key = git-common-dir), D-HF1 (funnel-not-push), flow-fence-before-auto-review, brainstorm → `/7`, hash-keyed review markers.

## Gotchas
- **zsh does NOT word-split unquoted vars** (`for v in $LIST` treats LIST as one word). Use `bash <<'EOF'` for loop-over-list greps (bit me twice this session).
- **ARCHITECTURE.md is the env SSOT** — never delete a flag from it to "reduce count"; that removes operator capability. CLAUDE.md points AT it.
- **Distinguish doc types**: `docs/plans/*` + `.claude/wiki/*` = historical record (quote old code, not live contracts); `docs/ARCHITECTURE.md` + `README.md` = live operator reference. A flag in a plan doc ≠ documented knob; a flag in ARCHITECTURE.md = documented knob (keep).
- **Codex worker sandbox is read-only + forbids `rm -rf`** — it can't run the hook test suites (their `trap rm -rf EXIT` cleanup) or the plan-review mkdtemp. Run suites + bridge from supervisor session.
- **Pre-existing test failure** (NOT mine): `tests/hooks/auto-review-detect.sh` 124/3 — the 3 (`--cd otherrepo`, `bridge ran` ×2) are codex-bridge-env failures, identical before this work.
- Prior gotchas hold (statusline symlink → claude-mine build, semble-rewrite mangles recursive `grep -rn`, tests in temp git repo, `cd && git` denied → use `git -C`).

## Context
- **Repo**: `~/.claude/plugins/marketplaces/sskys18/plugins/sspower` (sskys18/sspower), branch `main`, currently AHEAD of origin only by uncommitted (no unpushed commits — `73bb72e` is pushed).
- **Tests**: `test-integration.sh` 40/0 ✓; `auto-review-detect.sh` 124/3 (pre-existing); skill lint 32/0.
- **Also pending (DIFFERENT repo `~/.claude`, untouched):** `M skills/daily/SKILL.md`, `?? skills/arc-farm/`, `M docs/handoff.md`. Not this session's work.
