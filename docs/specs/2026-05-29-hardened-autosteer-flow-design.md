# Hardened auto-steer flow — design

Date: 2026-05-29
Status: approved (brainstorming); codex spec review R1+R2 (needs-attention, 5+5)
all addressed in-spec — load-bearing contracts now pinned: brainstorm-gate +
plan-review markers (flow-owned, hash-keyed, JSON), worktree single-owner via
git-common-dir re-key, narrow `design` intent, `current-stage` machine output.
R3+R4 addressed (severity trajectory 3→2→1→0 high). R4 surfaced a baseline
error: `auto-spec-gate.sh` is an UNWIRED orphan (verified) — corrected;
plan-review marker is now the primary plan-review enforcement. Also pinned:
unified per-stage fence policy (file+Bash), exact-`approve` pass-set everywhere,
non-git `project_root`. **Codex loop stopped here** (converged to med/low
impl-precision; remaining detail belongs to writing-plans + TDD). Pending user
review → `writing-plans`.
Scope: make the sspower flow pipeline *enforce* phase progression (not just
advise it), so multi-step work is reliably steered brainstorm→…→merge without
silently skipping phases — while NOT increasing the wedge risk the existing
codex gates already carry.

## Problem

The flow auto-starts and re-injects stage orders each turn, but enforcement
only fires at the **git boundary** (`auto-spec-gate.sh` @commit,
`auto-review.sh` @push). Everything before exec is **advisory**: the model is
trusted to follow orders and run `flow advance`. Four observed failure modes:

1. **Codes before plan approved** — edits src during plan/plan-review.
2. **Advances past gates** — `flow advance` out of plan-review→exec with no
   approved plan-review verdict.
3. **Loses the thread** — forgets to advance, or drifts off-flow after
   compaction.
4. **Chain incomplete** — brainstorm + worktree aren't stages.

## Baseline (what already exists — do NOT rebuild)

- **auto-start** — `hooks/prompt-submit` classifies via `hooks/_intent.sh`;
  `multi-step` → `flow.sh start` + emits orders with an abort hint.
- **orders re-injected each turn** — `prompt-submit` (compaction-resilient).
- **plan-review enforcement** — `auto-spec-gate.sh` (commit-time hook) was
  **deliberately unwired** in c884a04 (decision **D-A5**) and **repackaged as an
  explicit plan-review call in the `writing-plans`/`brainstorming` skills**. So
  plan-review IS enforced — at the **skill checkpoint** (codex plan-review), NOT
  a commit hook. `auto-spec-gate.sh` is now **dead code**. ⇒ this design's M2
  marker *upgrades* that skill-level check to a hard **flow-advance gate**
  (closing the "model skips invoking the skill" hole); it does NOT depend on,
  and must NOT re-wire, `auto-spec-gate.sh`.
- **review gate @push** — `auto-review.sh` (codex approve, verdict cache at
  `~/.cache/sspower/verdicts/`, 3-round cap).
- **complexity threshold** — `_intent.sh` (`qa|architecture|explicit-skill|
  simple-coding|multi-step`).
- **phase pointer** — `~/.claude/sspower/flow-state.json` keyed by cwd
  (survives compaction).

## Governing principle: funnel, don't push (D-HF1)

You cannot force the model to *think* the right step. You CAN make the wrong
next move require a deliberate override. So: **fence each phase so the only
frictionless forward move is the correct one** — same pattern as
`auto-review.sh` (deny push until approved), pushed earlier.

Critical refinement given the wedge tension (existing codex gates already wedge
— 3-round non-convergence needs a manual `rm`): the new early-phase fences
return PreToolUse **`ask`** (permission prompt), NOT hard-deny. A human escape
valve on every out-of-phase action → steers without wedging. Only git
chokepoints stay hard-deny.

## Stages (D-HF2)

`brainstorm → plan → plan-review → [worktree] → exec → test → review → merge`

Entry by `_intent.sh`: a **NEW `design` class** → **brainstorm**
(`flow.sh start --stage brainstorm`); `multi-step` → **plan** (`flow start`,
default); `simple-coding`/`qa` → **no flow** (the threshold — small work never
enters, so no ceremony and no wedge). worktree is **optional** (config flag).

> **`design` must be NARROW (codex R2 #5).** Generic `build`/`implement`/
> `refactor` already classify as `multi-step` (`_intent.sh:117-130`) and must
> STAY there — routing them to brainstorm would force ideation on plain
> implementation. `design` matches only explicit ideation framing: `^design `,
> `how should we structure`, `explore options`, `brainstorm`, `should we …?`.
> Precedence: test `design` patterns, but fall through to `multi-step` for bare
> action verbs. Add classifier tests for the boundary.
>
> **Correction (codex R1 #5):** the EXISTING `architecture` class is read-only
> graph/trace intent ("what calls", "trace", "call graph") — it must STAY
> flow-free. Do NOT route `architecture` to brainstorm.

## Mechanisms

### M1 — phase-fence hook (NEW) `hooks/flow-fence.sh` · PreToolUse:Write|Edit|MultiEdit + Bash (D-HF4)

Reads stage from a **machine-readable** `flow.sh current-stage` (NEW — prints
just the bare stage token or empty; parsing the human `flow.sh status` line is
brittle, codex R2 #4). **Fail-open contract (codex R3 #4):** `current-stage`
prints a bare stage **or empty string** and **exits 0** in every failure case —
missing `jq`, corrupt/absent state, git-key resolution failure, non-git
fallback, inactive flow. (It must NOT inherit `flow.sh`'s top-level
`jq`-missing hard-die.) The fence treats empty/nonzero/invalid as **idle** → no
fence. A per-event hook must never wedge on its own dependency gaps. Per-stage **allow-list** of writable paths; out-of-policy
mutation → return `ask` with a reason. Allow-list (not deny-list) so the failure
mode is "prompt", not "silent gap".

Two surfaces (codex R1 #2, #4):
- **Write|Edit|MultiEdit** — evaluate every path in `.tool_input.file_path`
  AND `.tool_input.edits[]?.file_path` (MultiEdit bypasses an Edit-only fence;
  `graph-mark-dirty.sh` already parses this shape — copy it).
- **Bash** — a conservative mutation fence detecting obvious source writes
  (`sed -i`, `tee`, `mv`, `cp`, `>`/`>>` into a non-allowed path, `python -c`
  writes, `git checkout/restore`). **Fail-open on parse uncertainty**
  (wedge-priority) — Bash mutation is harder to parse soundly, so it's
  best-effort; an Edit/Write-only fence would be *advisory*, not enforcement.

**The per-stage policy is IDENTICAL for both surfaces** (codex R4 #1) — a source
write is judged the same whether via Edit/Write/MultiEdit or Bash:

| stage | source write → | git chokepoint → |
|---|---|---|
| brainstorm/plan/plan-review | `ask` ("in {stage}; coding skips the plan — allow?") | existing gates |
| worktree | `ask` if outside the recorded worktree | existing gates |
| exec | pass (must be inside worktree if flow owns one) | existing gates |
| test/review/merge | `ask` ("you're past exec — run `flow back` to edit code") | existing gates |

"source write" = a path outside the always-writable allow-list (`docs/**`, the
recorded plan/design dir, `/tmp/**`, `.claude/**`). Bypass:
`SSPOWER_FLOW_FENCE=off`. No active flow → hook is a no-op (idle).

### M2 — advance-gating (NEW, inside `flow.sh advance`) (D-HF3)

`advance` refuses unless the current stage's exit-gate is met; flow.sh stays the
single source of truth (no separate transition hook).

| transition | gate | mechanism |
|---|---|---|
| brainstorm→plan | design doc recorded **and** design-review approve marker matching current design-file hash | `flow set-design <path>` → `flow set-design-review <verdict>` |
| plan→plan-review | plan file recorded | `set-plan` (exists) |
| plan-review→exec | plan-review approve marker matching current plan-file hash | `flow set-plan-review <verdict>` |
| worktree→exec | worktree exists + cwd inside + flow owns this worktree | git check + state transfer (M4) |
| exec→test | none (impl-complete unverifiable) | model-driven |
| test→review | test-artifact marker present | soft — missing → warn, allow |
| review→merge | none — existing push gate enforces | model-driven (see below) |

**Verdict-marker contract (codex R1 #1 + R2 #1/#3 — the push cache is NOT
reusable, and the contract must be pinned, not deferred).** The shared verdict
cache (`~/.cache/sspower/verdicts/`) is written by `auto-review.sh` *at the
push/PR chokepoint*, so:

- `review→merge` cannot read it (cache doesn't exist until merge-stage push) →
  **model-driven**; the existing `auto-review.sh` push gate enforces review
  there. No new gate.
- `brainstorm→plan` and `plan-review→exec` get **explicit, flow-owned markers**,
  pinned here:
  - **Writer:** `flow.sh set-design-review <verdict>` / `flow.sh
    set-plan-review <verdict>` (NOT `codex-bridge` — keep flow.sh the single
    owner). Each validates the recorded design/plan path exists.
  - **Pass set:** exact **`approve`** only — matching the gate that actually
    blocks, `auto-spec-gate.sh:291` (codex R3 #2). The flow-orders wording at
    `flow.sh:118` ("approve or approve-with-followups") is a pre-existing
    inconsistency with that gate; reconciling it is out of scope here — this
    design adopts the stricter shipped contract to avoid adding a *third*
    variant. (If `approve-with-followups` should pass, that's a separate change
    to `auto-spec-gate.sh` + orders, decided on its own.)
  - **Marker:** `<repo>/.claude/sspower/<design|plan>-review.<sha8(file)>.json`
    with `{verdict, file_hash, ts}` (JSON, not a `.approve` filename — avoids
    the `approve` vs `approve-with-followups` naming clash, R2 #3).
  - **Check:** `advance` recomputes `sha8(current file)` and requires a marker
    whose `file_hash` matches and whose `verdict` is in the pass set. A later
    edit to the design/plan file changes the hash → marker stale → re-review.
  - The model still runs the actual codex review (`codex-bridge plan-review`);
    `set-*-review` records *its* verdict. (Model-asserted verdict is the trust
    boundary — acceptable: it mirrors how the model already self-reports;
    push-time `auto-review.sh` is the hard backstop.)

test-gate is **soft** (warn, not block): a hook cannot verify "tests pass"
without a brittle convention; faking enforcement is worse than honest advisory.
Marker convention: `<repo>/.claude/sspower/test-result.json` ({cmd, exit}).

### M3 — thread-loss fix (small `flow.sh render_orders` edit)

Orders gain one line: "stage X/8; gate to advance = Y". Post-compaction the
model re-reads not just the stage but the *exit condition*, so it resumes
correctly instead of free-running.

### M4 — worktree state transfer (NEW, in `flow.sh`) (codex R1 #3)

`flow-state.json` is keyed by `pwd -P`. Entering a linked worktree changes
`pwd` → `flow.sh` would see **no active flow** and `advance` breaks. So the
worktree stage requires explicit state transfer, not just "cwd inside a
worktree":

Transfer must be **single-owner** — copying leaves two live entries that drift
and inject stale orders from the old cwd (codex R2 #2). Decision: **re-key flow
state by `git rev-parse --path-format=absolute --git-common-dir`** — the
*absolute* common dir (bare `--git-common-dir` is cwd-relative: `.git` at root,
`../.git` from `hooks/` → would fragment state, codex R3 #1). Fallback to
`pwd -P` outside a git repo. Then a flow has exactly one entry regardless of
which worktree the model is in; `advance`/`abort`/`orders`/`current-stage` all
resolve to the same entry.

`flow.sh enter-worktree <path>` **cannot change the model's cwd** (a bash script
only cds its own process, codex R3 #3). So it: creates the worktree if absent,
records `worktree_path` on the flow, and **prints the next command** for the
model to run there (subsequent tools use `cwd=<worktree>` or `git -C
<worktree>`). The `worktree→exec` gate validates *recorded* `worktree_path` AND
that the tool's actual cwd is inside it — no state copy.

This re-key is a **breaking change to the state key** for in-flight flows, so it
ships with a one-time migration (on read, if a `pwd`-keyed entry exists for the
current repo and no common-dir entry does, move it). Because worktree is
**optional**, non-worktree flows are otherwise unaffected.

## Workflow interaction (orchestrating-workflows) — D-HF6

Pairs with `docs/specs/2026-05-29-sspower-workflow-integration-design.md`. A
native Workflow **nests inside** a fan-out-shaped flow stage (exec migration,
review multi-dimension pass). The load-bearing rule:

- **Fences are MAIN-THREAD ONLY. Workflow fan-out agents are exempt.** Two
  reasons: (1) an `ask` raised to a *background* agent has no human to answer →
  it wedges; (2) Workflow agents are already governed by the **git-in-main
  invariant** (they read/edit only, never commit), which aligns with the flow's
  git gates — so per-edit fencing them is both redundant and harmful.
- **Detection:** `flow-fence.sh` checks the PreToolUse input for subagent/background
  context (e.g. `parent_tool_use_id` / agent id); present → pass (no fence).
  Verify the exact field at writing-plans. Fallback if undetectable: flow sets a
  transient "workflow-running" flag that suspends fences.
- **Advance-gating unaffected:** a Workflow inside `exec` doesn't change
  `exec→test` (still model-driven); the Workflow's completeness-critic informs
  the model's advance decision.
- **Shared OPEN (== D-WF3 `[Medium]`):** whether PreToolUse hooks fire for
  background subagents at all is **untraced**. If they DON'T → the exemption is
  automatic (zero work). If they DO → the hook needs the subagent-detection
  branch above. One trace resolves both this and the Workflow spec's D-WF3.

## Wedge safety (D-HF5 — mandatory)

- soft-`ask` fences = per-call human valve.
- every advance-deny message names the exact unblock command.
- always-available: `flow abort`, `SSPOWER_FLOW_FENCE=off`,
  `SSPOWER_AUTO_REVIEW=off`.
- NO new silent hard-deny. New hard-deny would compound the existing 3-round
  codex wedge — explicitly disallowed.

## Non-goals (YAGNI)

- No auto-advance-on-detection — funnel via fences + gates; auto-firing risks
  false transitions.
- worktree NOT mandatory — many tasks edit in place.
- test-gate NOT hard — see M2.
- Do not rebuild auto-start / git gates / classifier — all exist.

## Files touched (implementation sketch)

- `scripts/flow.sh` — add `brainstorm`/`worktree` stages; **re-key state by
  absolute `git-common-dir`** + one-time migration (M4); `start --stage
  brainstorm`; advance-gating per transition; `set-design`/`set-design-review`/
  `set-plan-review` marker writers (verdict+hash+ts JSON, pass-set **exact
  `approve`**); `enter-worktree` (records + prints next cmd, no cd);
  `current-stage` (fail-open machine output); render_orders gate line (M3);
  `SSPOWER_FLOW_FENCE` awareness. `project_root` for markers + allow-list =
  `git rev-parse --show-toplevel`, else the canonical state root (non-git flows).
- NEW `hooks/flow-fence.sh` + register PreToolUse **`Write|Edit|MultiEdit`** and
  a conservative **`Bash`** arm in `hooks/hooks.json` (M1) — with the
  **subagent-exempt branch** so Workflow fan-out agents pass (D-HF6).
- `hooks/_intent.sh` — add a NARROW **`design`** class (ideation framing only;
  bare build/implement/refactor stay `multi-step`); `architecture` stays
  flow-free.
- `hooks/prompt-submit` — route `design` → `start --stage brainstorm`.
- tests: `tests/hooks/test_flow.sh` (new stages, advance-gate denials, marker
  hash-staleness, git-common-dir re-key + migration), `tests/hooks/
  test_intent.sh` (`design` vs `multi-step` boundary, `architecture` flow-free),
  `tests/hooks/test_prompt_submit.sh` (design→brainstorm start); NEW
  `tests/hooks/test_flow_fence.sh`.

## Open / deferred

- **test-artifact convention** — who writes `test-result.json`? Either the
  `verification-before-completion` skill emits it, or a PostToolUse hook scrapes
  test-runner exit codes. Decide at writing-plans (only the test→review *soft*
  gate depends on it; not load-bearing).
- **false-deny tuning** — the plan-stage allow-list paths will need iteration on
  real repos (monorepo `src` layouts vary).
- **`auto-spec-gate.sh` = dead code (D-A5, intentional)** — deliberately unwired
  in c884a04, superseded by skill-level plan-review. NOT a bug to fix; do NOT
  re-wire (regression). Open question is only delete-vs-keep the dead script —
  independent of this design.
