# sspower × native Workflow integration — design

Date: 2026-05-29
Status: approved (brainstorming) — codex rounds 1–5 (needs-attention each,
converging 5→3→2→2→3); all substantive findings resolved; round-5 #1 is a codex
false-positive (refuted with the Workflow-tool spec). Pending: user review +
live `claude -p` trigger run + commit (eval/auto-review gates).
Scope: integrate Claude Code's native dynamic **Workflow** tool (shipped
2.1.154) into the sspower skill ecosystem without colliding with the `flow`
pipeline or `dispatching-parallel-agents`.

## Problem

The native Workflow tool orchestrates tens-to-hundreds of background agents
from a deterministic JS script. It overlaps two existing sspower surfaces:

- `dispatching-parallel-agents` — Task-tool fan-out.
- `flow` (`flow.sh`) — the plan→…→merge macro pipeline.

Done badly, two orchestration engines fight. The native tool also ships its own
usage instructions, so any sspower layer must justify itself against
**D-P5-KILL** (2026-05-27): *prefer native over redundant custom layers.*

## Why a layer is justified (not redundant)

The native tool's instructions cannot know three sspower-specific facts:

1. **codex-bridge** exists as an independent-verifier backend.
2. **auto-review.sh** gates git chokepoints on command structure.
3. **flow** has stages a Workflow can nest inside.

A thin layer that injects *only* these is additive, not the redundant
machinery P5-KILL rejected.

## Core model — three orthogonal axes

| Axis | Span | Shape | Tool |
|------|------|-------|------|
| **flow** | many turns | sequential lifecycle | `/flow`, `flow.sh` |
| **dispatching-parallel-agents** | one turn | small fan-out (≤~8), hand-integrated | Task tool |
| **orchestrating-workflows** | one background burst | large fan-out, structured, resumable | native Workflow |

Workflow **nests inside** a fan-out-shaped flow stage; it replaces nothing. The
flow side of this (phase fences exempting Workflow subagents, git-in-main
alignment) is specified in
`docs/specs/2026-05-29-hardened-autosteer-flow-design.md` § Workflow interaction
(D-HF6).

## Decision: Approach A (top-level skill) over B (fold into dispatching)

The native tool already *fires* on "create a workflow"/`/workflows`. The skill's
job is to load sspower **guidance** alongside it at author time. Only a
top-level skill whose description triggers on the same phrasing co-fires.
Folding into `dispatching` (trigger: "2+ independent tasks") strands the
guidance behind the wrong trigger — fails the discoverability goal.

Rejected:
- **B** (fold in) — guidance not loaded on the "create a workflow" path.
- **C** (minimal: catalog line only) — drops flow integration + codex template;
  under-scopes the agreed goals.

## Components

1. **New skill `orchestrating-workflows/`** — lean SKILL.md (three axes,
   when-to-author, opt-in, the two patterns, git-in-main constraint) +
   `references/workflow-template.md` (worked find→verify→critic script).
2. **`dispatching-parallel-agents/SKILL.md`** — router section: Task-tool vs
   Workflow decision boundary; hands off to the new skill. Sharpened so the two
   skills never contend for the same trigger.
3. **`using-sspower/SKILL.md`** — catalog note: the three axes.
4. **`flow.sh`** — `exec` + `review` stage orders carry brief Workflow pointers
   (additive literal text; no logic/arg-count change).

## Load-bearing decisions

- **D-WF1** — Approach A, justified above.
- **D-WF2** — codex verifier lens = **high-stakes/sampled, not per-finding**.
  Per-finding codex at fan-out scale = cost blowup (~90s bridge × $ × N).
  Template defaults to 2 Claude lenses; codex on high-severity or a sample.
- **D-WF3** — git chokepoints stay in main / flow MERGE; fan-out agents
  read/analyze/edit only. Reason 1 (index races) load-bearing; reason 2
  (auto-review structural) `[Medium]` inferred, not traced.
- **D-WF4** — flow pointers nest, don't replace.

## Non-goals (YAGNI)

- Not rebuilding `second-opinion` *as* a Workflow — the template *calls* the
  codex bridge it wraps.
- No new hook; no `prompt-submit`/`flow.sh`-logic change beyond literal order
  text.
- No auto-launch of Workflows from flow — the orders *suggest*, the model
  decides + opts in.

## Open / deferred

- **git-gate trace** — confirm whether a background Workflow subagent's Bash
  routes through the same PreToolUse chain as the main thread (resolves D-WF3
  reason 2 from `[Medium]` to `[High]`). Deferred — reason 1 holds the rule.
- **Live trigger run** — eval files added + registered (see Resolved §4); the
  remaining step is executing `tests/skill-triggering/run-all.sh` (spawns
  `claude -p`) in CI/locally to confirm the new skill actually triggers.
- **Boundary/negative evals** — `run-test.sh` only asserts *positive* triggering
  (did skill X fire?). It cannot express "dispatching only, NOT orchestrating"
  or "confirmation requested before authoring." Adding those needs a
  negative-assertion mode in the harness — deferred (out of this scope; the
  flow-order substring guards in `test_flow.sh` cover the wiring side).
- **Reload divergence** — cache has 4 skills (`codex-enrich*`, `diet-commit`,
  `diet-review`) absent from source; reconcile before `/reload-plugins`.

## Verification done on the spike

- `flow.sh` syntax ✓; both edited stages render with correct args, no `%`
  expansion ✓.
- New skill YAML parses ✓; template has no `process.*` in executable code ✓
  (fixed: shell-expanded `$CLAUDE_PLUGIN_ROOT`/`$(pwd)` in the codex agent's
  Bash, not JS).

## Codex spec review — round 1 (needs-attention) → resolved

All 5 findings addressed:

1. **[high]** D-WF2 drift (codex per-finding) → template now runs 2 Claude
   lenses always, codex only on high-severity or `SAMPLE_EVERY` sample; SKILL.md
   matches.
2. **[med]** gate contradiction (all-3 vs any-of-4) → both skills now state one
   gate: scale (≳8) **OR** per-result adversarial-verification need; structured
   output + background are properties, not triggers.
3. **[med]** codex lens schema mismatch → template + SKILL.md make the mapping
   explicit: real=true only when `quality-review-output.verdict` ==
   `needs-attention` with a matching blocking issue.
4. **[med]** missing eval → `tests/skill-triggering/prompts/
   orchestrating-workflows.txt` added + registered in `run-all.sh`; two
   flow-order substring guards added to `tests/hooks/test_flow.sh` (31/31 pass).
   Live `claude -p` trigger run = CI/user step (spawns claude).
5. **[low]** description summarized behavior → trimmed to trigger-only per
   `writing-skills`.

Verification after fixes: template JS body syntax-checks clean (async-wrapped);
SKILL.md YAML parses; `test_flow.sh` 31/31.

## Codex rounds 2–5 (converging) — all resolved

- **R2 [high]** sampling used a slice-local index (per-finding for single-finding
  slices) → gated on a stable hash of the derived key.
- **R2 [med]** "structured output" still listed as a routing *trigger* in
  `using-sspower`/`flow.sh` → removed; one gate everywhere (scale OR
  verification need).
- **R3 [high]** shell-injection: finder text interpolated into a double-quoted
  shell `--prompt` → finding now passed as model text; agent writes it to a
  tempfile and uses `--prompt @file` (no untrusted text on a shell line).
- **R3 [med]** dedup/sample trusted agent-supplied `id` → derive a stable key
  from `file + desc`. (A stray NUL byte introduced by that edit was found and
  replaced with a ` | ` delimiter.)
- **R4 [high]** opt-in too loose (broad triggers + "invoking = authorization")
  → description trimmed to explicit-Workflow phrasing; body distinguishes
  user-asked (authorized) from inferred-from-scale (confirm first); router calls
  the handoff a *recommendation*, not opt-in.
- **R4 [low]** README still said 19 skills → bumped to 20 + added the row.
- **R5 [high] — REFUTED (codex false-positive).** Codex flagged the template as
  invalid JS because `export const meta` + top-level `return` fails
  `node --check --input-type=module`. But that IS the documented native Workflow
  script shape (module-level meta + async-wrapped body with top-level
  await/return); codex's cutoff predates the 2.1.154 tool. Not rewritten —
  rewriting to standalone-valid JS would break it. Added a "runtime shape, not a
  standalone module" note instead.
- **R5 [med]** codex lens assumed `$CLAUDE_PLUGIN_ROOT` in the agent shell →
  now resolves the bridge with `find … -path "*/sspower/*"` (matches
  `second-opinion`); tempfile under `/tmp`.
- **R5 [low]** only a positive trigger eval exists → see Open/deferred (harness
  has no negative-assertion mode).
