---
name: orchestrating-workflows
description: Use when the user explicitly asks to author a native dynamic
  Workflow — "create/write/author a workflow", "orchestrate this across
  background agents", "fan out N agents in the background", or `/workflows`.
  Loads the sspower way to build one. For deciding *whether* a job warrants a
  Workflow at all, the routing gate lives in dispatching-parallel-agents.
---

<SUBAGENT-STOP>
If you were dispatched as a subagent, skip this skill. You do not author workflows.
</SUBAGENT-STOP>

# Orchestrating Workflows

The native **Workflow** tool runs a deterministic JS script that fans agents
out in the background (`agent()`, `parallel()`, `pipeline()`), with concurrency
caps, schema-validated output, and resume. This skill is how sspower uses it
**without colliding** with the flow pipeline or `dispatching-parallel-agents`.

## Three axes — do not confuse them

| Tool | Span | Shape | Use for |
|------|------|-------|---------|
| **flow** (`/flow`, `flow.sh`) | many turns | sequential: plan→…→merge | the macro lifecycle of a task |
| **`dispatching-parallel-agents`** (Task tool) | one turn | small fan-out (≤~8), hand-integrated | a few independent problems, results into *your* context |
| **Workflow** (this skill) | one background burst | large fan-out, tens–hundreds | structured/verified/resumable bulk work |

Workflow does **not** replace the other two. It **nests inside** a flow stage
when that stage is itself fan-out-shaped — e.g. an `exec` stage migrating 40
files, or a `review` stage running a multi-dimension adversarial pass.

## When to author a Workflow

Single gate — **scale or verification need**:

- ≳8 independent units of work, **OR**
- each result needs independent adversarial verification before you trust it.

Below that line → `dispatching-parallel-agents` (Task tool), adding an explicit
output format if you need structure. Structured output and background/resume are
*properties* of the Workflow path, not extra gates — they follow from scale, so
don't treat them as separate triggers. (`dispatching-parallel-agents` routes
here on the same gate — the two never contend.)

Scale to the ask: "find any bugs" → a few finders, single vote.
"Thoroughly audit" → large finder pool, 3–5 vote adversarial, synthesis stage.

## Opt-in — explicit vs inferred (do not conflate)

The Workflow tool is token-heavy and gated on **explicit** opt-in. Two cases:

- **User asked** — "create a workflow", "orchestrate this in the background",
  `/workflows`, or they invoked this skill directly → authorized, proceed.
- **You only inferred it from scale** — `dispatching-parallel-agents` routed
  here because a job is large, but the user never asked for a background
  Workflow → do **not** silently author one. Confirm first ("this is ~N agents
  in the background — want a Workflow, or handle it inline?"), then proceed on
  their yes.

Spinning up tens-to-hundreds of background agents the user didn't ask for, and
can't cheaply undo, is exactly what the native opt-in gate exists to prevent.
Routing here ≠ authorization; the user's ask (or `/workflows`) is.

## sspower wiring — the two patterns worth keeping

- **codex as a verifier lens — high-stakes/sampled, NOT per-finding.** A codex
  pass via the bridge (`node "$CLAUDE_PLUGIN_ROOT/scripts/codex-bridge.mjs"
  review …`) is ~90s + real cost; running it on *every* finding at fan-out
  scale blows up time and money. Default to two Claude lenses (a skeptic + an
  independent reproduce check); add codex only for **high-severity** findings or
  a **sample**. The bridge's `review` returns the `quality-review-output` schema
  (`verdict`/`issues`/…), not `{real}` — so map explicitly: real=true only when
  codex returns `needs-attention` with a blocking issue matching the finding.
  This is `second-opinion`'s value applied selectively — do not rebuild
  `second-opinion` *as* a Workflow; call it from one.
- **completeness critic.** End multi-phase runs with one agent that asks "what's
  missing — modality not run, claim unverified, file unread?" This is
  `verification-before-completion` applied to the run itself; its output is the
  next round's work.

See `references/workflow-template.md` for a worked find→verify→critic script
with both wired in (illustrative — validate against the live Workflow sandbox
before relying on it).

## HARD constraint — git stays in the main thread

Workflow fan-out agents **must not** run git chokepoints (`commit`/`push`/
`merge`/`gh pr …`). Two reasons:

1. Parallel agents committing to one repo race the index — corrupt state.
2. The `auto-review.sh` gate appears to key on **command structure**, not
   subagent context (`[Medium]` — inferred from the hook source, not traced for
   a background agent's Bash path). If so, a fan-out agent's chokepoint hits the
   same deny rules and review-verdict requirement, with no terminal to recover
   in. Reason 1 holds regardless, so the rule stands either way.

So: fan-out agents **read, analyze, and edit files only**. All git work returns
to the main thread — or, inside a flow, to the **MERGE stage**, which already
owns standalone chokepoints under the auto-review gate. A Workflow that "does a
migration and commits it" = migrate in the Workflow, return the file list,
commit in MERGE.

## Process

1. Confirm opt-in and that the work clears the when-to-author gate (scale or
   verification need).
2. Sketch phases: find → (dedup vs a seen-set, plain code) → verify → critic.
   Default to `pipeline()`; reach for `parallel()` only when a stage genuinely
   needs *all* prior results at once (dedup/merge/early-exit).
3. Give every `agent()` a `schema` so results come back validated.
4. Keep git out of agents (above).
5. Author inline via the Workflow tool; iterate by editing the persisted
   `scriptPath` and re-invoking, not by resending the whole script.
6. On completion, fold the structured result back into your turn (or the flow
   stage) and proceed — `verification-before-completion` before claiming done.
