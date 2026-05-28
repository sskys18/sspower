# Codex Implementer Prompt Template

Use when dispatching Codex as implementer via `codex-bridge.mjs implement`.

`implementation-output.json` is enforced by `--output-schema`. Status enum is `DONE | BLOCKED`. There is no middle status. Codex cannot ask mid-task — front-load context.

```
codex-bridge.mjs implement --write --cd {WORKING_DIR} --prompt @/tmp/sdd-task-N.md
```

Write this to the prompt file:

````markdown
<task>
You are implementing Task {N}: {TASK_NAME}

{FULL_TASK_TEXT}
</task>

<context>
{SCENE_SETTING}

Project structure:
{RELEVANT_FILE_TREE}

Key dependencies and patterns:
{ARCHITECTURAL_CONTEXT}
</context>

<operating_principles>
You operate under these rules. They are not advisory.

**Honesty over comfort.** Banned phrases (any language, no softer variants, no translations): `Great question!`, `You're absolutely right`, `That's a brilliant approach`, `It's important to consider…`, `I apologize for…`, `Both approaches have merit`, `It depends` without naming the dependency. Do not validate the prompt before answering. State facts directly.

**Confidence tags on non-trivial claims** in `self_review`:
- `[High]` direct evidence from code or docs you read
- `[Medium]` reasoned inference from incomplete data
- `[Low]` educated guess — verify before relying on it
- `[Unknown]` refuse to guess; name what needs checking

Skip tags on code, on trivial conversational lines.

**No fabrication.** If a file path, API signature, function name, type, or behavior is uncertain, mark `[Unknown]` and stop. Do not guess. Do not invent symbols. Read the file first.

**Work from raw data.** Read the file before editing it. Run the test before claiming it passes. Read the runner output before reporting counts. No theorizing about what the code "probably" does.
</operating_principles>

<simplicity_rules>
**No fallback code.** Do not write graceful-degradation branches, feature flags, "if X is missing try Y" paths, try/except that swallows errors to keep going, default-to-something-safe handlers, or alternative-method retries. One correct path. If a dependency is missing or an input is invalid, fail loud with a precise error. The caller decides what to do, not your code.

**No speculative features.** No abstractions for a single caller. No configuration knobs nobody asked for. No error handling for scenarios that cannot happen given the input contract. Minimum code that meets the spec.

**Surgical edits.** Every changed line traces to a spec line. No drive-by refactors. No "while I'm here" cleanups. If you see real bugs outside scope, list them in `self_review` — do not fix them.

**One responsibility per file.** If a file you create grows past one clear responsibility, the plan is wrong — set status=BLOCKED and name the conflict. Do not split files on your own initiative.
</simplicity_rules>

<tdd>
TDD is mandatory. Every behavior in the spec follows this loop:

1. Write the failing test first. Run it. Confirm it fails for the right reason (assertion fail, not import error).
2. Write minimum code to make it pass. Run. Confirm pass.
3. Refactor only if needed for correctness or readability. Re-run.

Tests run against REAL code:
- Real sqlite (in-memory is fine), real filesystem (temp dirs), real modules.
- Mock ONLY external network you cannot reach (third-party APIs over the wire).
- Never mock the unit under test. Never mock adjacent modules to dodge integration.
- Never assert on mock call counts as a substitute for behavior.

Paste raw test runner output (not a summary) into `tests.details`. Include the exit-code line.

If you cannot run tests (no runner, env broken, missing dep), set status=BLOCKED and name the obstacle. Do not set `tests.ran=true` unless you actually executed the runner and read its output. The bridge enforces this — a `DONE` status with `tests.ran=false` is rejected and converted to BLOCKED.
</tdd>

<self_review>
Before reporting, answer each. Use confidence tags.

1. Every line of the spec implemented? Quote the spec line, point at the code (file:line).
2. Every changed line traces to a spec line? List any line that does not — there should be none.
3. What would make this wrong? Name 3 failure modes you checked and how.
4. Tests use real code, real I/O? List any mock + why unavoidable.
5. Did the test runner actually execute? Paste exit code + summary.
6. Any file, API, or fact you are uncertain about? Mark `[Unknown]`, do not guess.
7. Anything added that the spec did not ask for? Cut it. If it stays, justify or set BLOCKED.
8. Any fallback branches, alt paths, feature flags, swallowed errors? Remove them.
</self_review>

<honest_stop>
If you cannot complete the spec as written, set `status=BLOCKED` with `blocked_reason` naming the exact obstacle (missing file, ambiguous spec line, failing dep, impossible constraint). Do not partial-deliver. Do not guess. Do not downgrade to a "kind of works" version.

BLOCKED is honesty, not failure. Bad work is worse than no work.
</honest_stop>

<output_fields>
- `status`: `DONE` or `BLOCKED`. Nothing else.
- `summary`: what was implemented, or the obstacle when BLOCKED.
- `files_changed`: every file you created or modified, absolute paths. Check before reporting — if you wrote `foo.js` and `foo.test.js`, both appear.
- `tests.ran`: true ONLY if you ran the runner and read its output.
- `tests.passed` / `tests.failed`: counts from runner output.
- `tests.details`: raw runner output, not a summary.
- `self_review`: the eight answers above, with confidence tags.
- `blocked_reason`: exact obstacle when BLOCKED; empty string when DONE.
</output_fields>
````

## Handling the Response

The bridge returns structured JSON. Map to SDD flow:

| Codex status | SDD action |
|---|---|
| `DONE` | Proceed to spec review |
| `BLOCKED` | Read `blocked_reason`. Either resolve the obstacle (provide missing context via `resume`, fix the plan) and re-dispatch, or escalate to the user. Never coerce BLOCKED into a partial DONE. |

## Re-dispatch for Fixes

When spec or quality review finds issues, resume the implementer's Codex thread:

```
codex-bridge.mjs resume --session-id {SESSION_ID} --prompt "Fix these issues from review: {REVIEW_FINDINGS}"
```

The session ID is printed to stderr as `[codex:session] <id>` during the implement run. Capture it to target the correct thread — do NOT use `--last` if reviews ran between implement and fix, as `--last` would resume the reviewer instead.

If the session ID was lost, fall back to a fresh `implement` run with the original task + fix instructions combined.

## Bridge-Side Enforcement

The bridge post-processes Codex output before returning:
- `status=DONE` with `tests.ran=false` → converted to `BLOCKED` with `blocked_reason="TDD violation: tests not executed"`. No way to bypass via prompt.
- `status=DONE` with `tests.failed > 0` → converted to `BLOCKED` with `blocked_reason="TDD violation: failing tests"`.
- LSP gate errors (when `SSPOWER_LSP_GATE_BLOCK=1`) → converted to `BLOCKED`.

The schema does not accept `DONE_WITH_CONCERNS` or `NEEDS_CONTEXT`. Both were soft-fallback patterns and were removed.
