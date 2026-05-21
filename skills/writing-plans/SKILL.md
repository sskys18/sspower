---
name: writing-plans
description: Use when you have a spec or requirements for a multi-step task, before touching code
---

# Writing Plans

Write comprehensive implementation plans assuming the engineer has zero context and questionable taste. Document everything: which files to touch, code, testing, docs, how to verify. DRY. YAGNI. TDD. Frequent commits.

**Announce at start:** "I'm using the writing-plans skill to create the implementation plan."

**Save plans to:** `docs/plans/YYYY-MM-DD-<feature-name>.md` (user preferences override)

## Pre-flight: read prior decisions

Before drafting the plan, query the project's memory backend:

```bash
sspower-mem search --scope project --layer decision --mode recent --top-k 5 --json
sspower-mem search --scope project --layer episodic --mode recent --top-k 3 --json
```

The first call surfaces prior architectural decisions to align the plan with
(or flag conflicts against); the second surfaces recent session state. When
the plan has a concrete task description, swap `--mode recent` for
`--query "<task description>"` to align results by relevance instead of
recency.

If the command is unavailable or returns no results, skip silently.

## Scope Check

If the spec covers multiple independent subsystems, suggest breaking into separate plans — one per subsystem. Each plan should produce working, testable software on its own.

## File Structure

Before defining tasks, map out which files will be created or modified. Design units with clear boundaries and one clear responsibility per file. Prefer smaller, focused files. Files that change together should live together — split by responsibility, not technical layer. In existing codebases, follow established patterns.

## Task Format

See `references/plan-template.md` for the full plan header and task template with code examples.

Each step is one action (2-5 minutes). Every step must contain actual content — exact file paths, complete code, exact commands with expected output.

## No Placeholders — These Are Plan Failures

Never write:
- "TBD", "TODO", "implement later", "fill in details"
- "Add appropriate error handling" / "add validation" / "handle edge cases"
- "Write tests for the above" (without actual test code)
- "Similar to Task N" (repeat the code)
- Steps that describe what to do without showing how
- References to types/functions not defined in any task

## Self-Review

After writing the complete plan, check:
1. **Spec coverage:** Every spec section maps to a task?
2. **Placeholder scan:** Any banned patterns from above?
3. **Type consistency:** Names match across tasks?

Fix issues inline. If spec requirement has no task, add the task.

## Codex Plan Review (explicit gate — run before declaring the plan done)

Run plan review explicitly (the `auto-spec-gate.sh` hook was removed, D-A5):

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/codex-bridge.mjs" plan-review \
  --cd . --prompt @docs/plans/YYYY-MM-DD-<feature-name>.md
```

Fix every `high`/`medium` finding inline, re-run until `verdict` is
`approve` or `approve-with-followups`. `plan-review` (findings-shaped),
NOT `spec-review` (impl-vs-spec) — see spec v5 Finding 1.

## Execution Handoff

**"Plan complete. Three execution options:**
1. **Subagent-Driven (recommended)** → sspower:subagent-driven-development
2. **Inline Execution** → sspower:executing-plans
3. **Codex execute** → delegate via `codex-bridge.mjs implement --write`

**Which approach?"**
