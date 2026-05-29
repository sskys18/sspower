# Session Handoff
> Generated: 2026-05-29 — supersedes 2026-05-26 graph-P1→P2 (graph terminal at P4/1.5.0, P5+ killed; that handoff fully stale).

## Task
Two workstreams shipped this session; one build remains:
1. **sspower × native Workflow integration** — SHIPPED (committed + pushed).
2. **Hardened auto-steer flow** — design + spec + implementation plan SHIPPED; **the BUILD is the next action.**

## Status
### Completed (on `main`, pushed)
- `d7ea09a` feat(skills): `orchestrating-workflows` skill + dispatching router + flow.sh exec/review pointers + README 20 skills. Design: `docs/specs/2026-05-29-sspower-workflow-integration-design.md`. (5 codex rounds.)
- `d4a5d75` docs(spec): hardened auto-steer flow design + `auto-spec-gate.sh` STATUS header. Spec: `docs/specs/2026-05-29-hardened-autosteer-flow-design.md`. (4 codex rounds.)
- `e10c64f` docs(plan): **`docs/plans/2026-05-29-hardened-autosteer-flow.md`** — TDD task groups A–E. (codex plan-review applied.)

### In Progress
- None. Plan is reviewed + committed; build unstarted.

## Resume Here
1. **Execute the plan via `sspower:subagent-driven-development`** (or `executing-plans` inline) on `docs/plans/2026-05-29-hardened-autosteer-flow.md`, **task group A first** (flow.sh: git-common-dir state re-key + `current-stage` + brainstorm stage). Each group ends with `bash -n` + its test + a SUPERVISOR commit.
2. Then B (advance-gating + markers), C (orders), D (`flow-fence.sh` + hooks.json), E (intent `design` class). A→B→D are ordered (B/D need A's `current-stage`); C/E independent.
3. Live `claude -p` skill-trigger eval for `orchestrating-workflows` (`tests/skill-triggering/run-all.sh`) — NOT run this session (spawns claude). Run in CI/locally to confirm trigger.

## Decisions (do NOT revisit)
- **Workflow = thin layer over native tool, nests in flow stages** (D-WF1..4): codex-lens (sampled, not per-finding), completeness-critic, git-in-main. NOT a reimplementation.
- **Hardened flow = funnel-not-push** (D-HF1): early-phase fences return PreToolUse `ask` (human valve), NOT hard-deny. Only git stays hard-deny. Rejected hard-deny everywhere — compounds the existing 3-round codex wedge.
- **Fences MAIN-THREAD ONLY; Workflow/Task subagents EXEMPT** (D-HF6). RESOLVED `[High]`: PreToolUse hooks DO fire for subagents (CC added agent_id/agent_type to hook events; wiki-archive.py reads subagent_type) → flow-fence MUST detect agent_id/agent_type and pass.
- **Worktree is a PROPERTY, not a stage** (codex plan-review): the stage was unreachable (chicken-egg on `wt`). `enter-worktree` settable at plan-review; exec gate checks cwd-in-worktree when `worktree:true`.
- **Marker root = `dirname(git-common-dir)`/.claude/sspower** — same stable key as flow state (show-toplevel differs per worktree → fragments).
- **`auto-spec-gate.sh` is intentionally unwired dead code (D-A5)** — do NOT re-wire (regression; re-introduces removed double-gate). Plan-review enforced at writing-plans/brainstorming skill checkpoint. Header documents this.
- **Plan-review pass-set = exact `approve`** (matches the contract auto-spec-gate used).

## Gotchas
- **Codex misreads an implementation-PLAN as an execute-request** (refuses "read-only, can't commit"). For plan-review, prepend a "REVIEW only, do NOT implement/commit" wrapper to the prompt — see this session's re-run. Design-doc reviews don't hit this.
- **Plan commits are SUPERVISOR-run.** The codex worker cannot `git commit/push/merge` (policy). subagent-driven execution must commit from the main thread.
- **`flow.sh current-stage` must fail-open** (print empty + exit 0 on missing jq/corrupt/non-git) — it's called every PreToolUse event; must never inherit flow.sh's top-level `jq` hard-die or it wedges the session.
- Plan line-number refs are hints — anchor on text/function names (file drifts).

## Context
- **Repo**: `~/.claude/plugins/marketplaces/sskys18/plugins/sspower` (sskys18/sspower remote)
- **Branch**: `main`, in sync with `origin/main` @ `e10c64f`. Clean working tree.
- **Tests**: `bash tests/hooks/test_flow.sh` (31/31 ✓ incl. 2 new Workflow guards). New build adds `test_flow_fence.sh` + extends `test_intent.sh`/`test_flow.sh` (see plan).
- **Unknowns** (verify before acting):
  - `_intent.sh` exact class-precedence location for inserting the `design` branch (must sit before multi-step action-verb test) — read the file.
  - `hooks/hooks.json` existing PreToolUse structure before registering flow-fence (preserve order; semble-rewrite→cmd-rewrite→auto-review chain).
  - Whether to delete vs keep the `auto-spec-gate.sh` dead script — left documented; user's call.
