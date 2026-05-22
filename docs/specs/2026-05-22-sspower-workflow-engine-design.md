# sspower Workflow-Engine v2 — design

**Date:** 2026-05-22
**Repo:** `sspower` plugin (`github.com/sskys18/sspower`)
**Status:** design — Codex spec-review closed (8 rounds, architecture
"coherent"); awaiting user approval → `writing-plans`
**Builds on:** `docs/plans/2026-05-22-flow-state-machine.md` (the flow state
machine — shipped, uncommitted)

## Problem

sspower skill invocation is unreliable. The `UserPromptSubmit` hook
(`prompt-submit`) injects a generic catalog reminder ("check which skills
apply, 1% = invoke") every turn. A catalog gets ignored; a specific
instruction gets followed. Three deeper issues:

1. **No spine.** The flow state machine exists but only carries skills when
   a flow is *active* — and nobody runs `/flow start`. A pipeline that never
   starts is worthless.
2. **Triple intent classifier.** `semble-context.sh:66` already classifies
   coding intent (`grep -qE '\b(add|fix|build|refactor|implement…'`). The
   shipped `prompt-submit` added a second verb heuristic. They drift — Codex
   flagged exactly this in the flow-state plan-review (round 3).
3. **Identity drift.** sspower's docs call skills *advisory guidance* and
   `using-sspower` "the skill-routing entrypoint." In practice the hook is
   the router. The architecture and the docs disagree.

## Decision: sspower is a workflow engine

Owner decision (2026-05-22): commit to it. The `prompt-submit` hook is the
router. `using-sspower` becomes a reference card, not the entrypoint. Skills
are pipeline stages, not just a catalog. This design makes that explicit
rather than letting it drift.

## Solution

A single intent classifier feeds a state-aware hook that **auto-starts a
flow** on high-confidence multi-step work, and otherwise injects one
targeted skill trigger (or nothing).

### Approach: conservative auto-start + model bail

Auto-start on a bash classifier *will* misfire. The cost is asymmetric: a
false start drags a one-line fix through a 5-stage pipeline (expensive); a
false negative just means the user runs `/flow start` (cheap). So the
classifier is biased hard toward *not* starting, with two safety layers:

1. **Conservative heuristic** — `multi-step` requires a strong verb AND a
   substantial prompt. Bare `"refactor this"` does not qualify.
2. **Model bail** — the auto-start injection opens with an explicit "if this
   is actually trivial, run `flow.sh abort` and proceed directly."

Plus a `quick:` opt-out prefix that suppresses auto-start outright.

(Alternatives considered: aggressive auto-start — too many misfires;
`proposed` sub-state — adds a state and transition for little gain over the
model-bail layer.)

## File structure

| File | Action | Responsibility |
|------|--------|----------------|
| `hooks/_intent.sh` | create | Single intent classifier — `sspower_classify_intent` |
| `hooks/prompt-submit` | rewrite v2 | Auto-start + targeted triggers; sources `_intent.sh` |
| `hooks/semble-context.sh` | edit | Replace inline `grep -qE` with `_intent.sh` |
| `skills/using-sspower/SKILL.md` | edit | Demote: "entrypoint" → "reference card" |
| `hooks/session-start` | edit | Stop injecting the full `using-sspower` SKILL.md as the router |
| `CLAUDE.md` (plugin) | edit | Record the workflow-engine architecture |
| `tests/hooks/test_intent.sh` | create | `classify_intent` + `target_trigger` truth tables |
| `tests/hooks/test_prompt_submit.sh` | edit | Auto-start, opt-out, targeted triggers |
| `tests/hooks/test-semble-context.sh` | edit | Pin the consolidated gate (file already exists — hyphenated) |

`scripts/flow.sh` — no change. `hooks.json` — no change (all three hooks
already wired).

## Component 1 — `hooks/_intent.sh`

Single source of truth for prompt classification. Sourced (not executed)
by hooks. Side-effect-free except one bounded read: a glob of
`<intent_dir>/../skills/*/` to derive skill basenames (step 2). The glob
must tolerate a missing/unreadable `skills/` dir — on failure the
explicit-skill set is empty and classification continues (a missed
explicit-skill degrades to `simple-coding`/`qa`, never a crash).

```
sspower_classify_intent "<prompt>" → one of:
  explicit-skill   prompt names a skill / sspower: / "invoke <skill>"
  qa               no code signals and no coding verbs
  multi-step       strong multi-step verb AND substantial prompt
  simple-coding    coding intent below the multi-step bar
```

Classification order (first match wins):
1. **read-only guard** — strip a leading politeness modal if present
   (`can you`, `could you`, `would you`, `please`, `pls`), then if the
   remaining text *starts with* a read/explain verb (`what is`, `what's`,
   `show`, `list`, `explain`, `describe`, `tell me`, `why`, `how does`,
   `what does`, `summarize`, `analyze`) or the whole prompt is a bare
   greeting/ack (`hi`, `hello`, `thanks`, `ok`, `yes`, `no`, `done`, `go`)
   → **qa**. A question *about* code is not a request to *change* code.
   The modal-strip is what lets `can you explain src/foo.ts?` classify
   `qa` instead of coding (the `.ts` would otherwise be a coding signal).
   Prefix match — a prompt that opens "show…" but later asks for a change
   is a known false-negative, accepted for consistency with
   `semble-context.sh`.
2. **explicit-skill** — names an sspower skill. Match `sspower:` (direct
   substring) OR a **current skill directory basename** on a word boundary:
   the lowercased prompt matches `(^|[^[:alnum:]_-])<skill>([^[:alnum:]_-]|$)`.
   Boundary-anchored, not bare substring — so a longer identifier or a URL
   containing the name does not false-trigger. `_intent.sh` derives the
   skill-name set at runtime by globbing `<intent_dir>/../skills/*/` (where
   `<intent_dir>` is `_intent.sh`'s own directory) — so the set never goes
   stale as skills are added or removed. **Not** bare ` skill` / `invoke ` /
   ` use the ` (misfire on "what skill should I learn?", "use the docs").
   `use systematic-debugging` matches via the boundary-anchored basename.
3. **skill-relevant signal test** — any of:
   - code fence ```` ``` ````, file extensions
     (`.js .ts .py .sh .go .rs .tsx .json .md`)
   - coding verbs: `fix bug bugs implement refactor build test tests error
     errors debug add plan feature broken fail fails failing crash function
     class commit create update change remove delete edit review lint
     typecheck compile run merge rename`
   - ideation/planning phrases: `brainstorm`, `explore options`, `explore
     ways`, `how should i`, `structure`, `spec`, `approach`, `design`
     (noun-ish — kept here as a *signal* but NOT a multi-step verb).

   None of the above → **qa**. (Ideation phrases must be a signal here, or
   `brainstorm options for auth` classifies `qa` and the `brainstorming`
   target trigger is unreachable.)
4. **review-class guard** (only if coding) — if the prompt is about
   *reviewing/approving* rather than *doing*: contains `spec-review`,
   `plan-review`, `code-review`, `review this`, `review the`, `awaiting`,
   `approve`, or `approval` → classify **simple-coding** and stop (never
   `multi-step`). Without this, "review this design" auto-starts a flow —
   a review request must not enter PLAN stage.
5. **multi-step test** (only if coding and not review-class) — strong
   *action* verb in `implement refactor migrate rewrite redesign port
   integrate build` (note: bare `design` is **excluded** — too often a
   noun/review context) AND substantial = (length ≥ 80 chars) OR
   multi-clause (contains `,` / ` and ` / ` then ` / newline /
   numbered-list marker). Match → **multi-step**; else → **simple-coding**.

### `_intent.sh` also owns trigger *selection*

Division of responsibility: `_intent.sh` owns **classification and trigger
selection** (the decisions); `prompt-submit` owns the **presentation
strings** (the literal injected lines). So `_intent.sh` exports a second
helper that returns a symbolic trigger, not a string:

```
sspower_target_trigger "<prompt>" → FIRST match wins, in this order:
  1. debugging     bug / error / crash / "not working" / "test fail*"
  2. code-review   "review" + an IMPLEMENTED artifact: diff / PR / change /
                   implementation / "this code"
  3. none          "review"/"approve" + a NON-impl artifact: design / spec /
                   plan  → a review request fits no skill; short nudge
  4. brainstorming brainstorm / "explore options" / "explore ways" / ideation
  5. planning      a request to PLAN/design: spec / "how should I structure"
                   / "design <thing>"  (review verbs already excluded by 3)
  6. tdd           an implementation request: "add" / "implement" /
                   "create <function/endpoint/…>" / "small change"
  7. none          generic coding, nothing specific
```

Order matters: step 3 fires before `planning` (5) and `code-review` (2-vs-3
split by object), so `review this design` → `none`, not `planning`.
`requesting-code-review` is for a post-implementation diff only;
`test-driven-development` is the default for any feature/bugfix
implementation (its SKILL contract), hence the `tdd` trigger at step 6.

`prompt-submit` calls this for `simple-coding` prompts to pick the targeted
line. Both hook tests exercise `sspower_classify_intent` and
`sspower_target_trigger` directly.

## Component 2 — `hooks/prompt-submit` v2

**Order matters.** The active-flow check runs **first**, before
`_intent.sh` is ever sourced — so a missing/broken `_intent.sh` can never
suppress the flow spine. `_intent.sh` is sourced only on the idle path.

```
0. read stdin payload.
   - `jq` unavailable → emit legacy REMINDER, exit.
   - parse `cwd`; normalize: if it is a dir, `CWD=(cd "$cwd" && pwd -P)`;
     if `cwd` is missing/unparseable → `CWD=$(pwd -P)` (best-effort).
1. ORDERS = (cd "$CWD" && flow.sh orders)
   → if non-empty: emit ORDERS, exit               (active flow — UNCHANGED v1)
   PRIORITY (precise): a **valid payload** with an empty/unparseable
   `prompt` field still resolves the active flow for the payload `cwd` —
   the flow spine survives a bad prompt. But a **fully malformed payload**
   yields no `cwd`, so Step 0 falls back to `pwd -P` (the hook process
   dir); the flow lookup then only finds a flow keyed to *that* dir. Step 2's
   REMINDER fallback is the IDLE path only. Tests split the two cases.

--- idle path below ---
2. parse `prompt`. If the payload was malformed (jq parse failed) OR the
   parsed prompt is empty → emit legacy REMINDER, exit  (preserves v1).
3. source _intent.sh
   → if it fails: emit legacy REMINDER, exit
4. if prompt matches case-insensitive `^[[:space:]]*quick:[[:space:]]*`
   → strip that matched prefix, set quick=1 (rest of prompt unchanged)
5. classify the (stripped) prompt and route:
    multi-step     → quick=1 ? downgrade to simple-coding (step below)
                     : AUTO-START —
                         (cd "$CWD" && flow.sh start "<first line ≤100ch>")
                         discard start stdout
                         ORDERS=(cd "$CWD" && flow.sh orders)
                         emit  AUTO-FLOW preamble + ORDERS
                       (flow.sh start MUST run from $CWD — flow.sh keys
                        state by `pwd -P`; running from the plugin dir
                        keys the wrong directory and the flow reads idle)
    explicit-skill → emit a SHORT confirmation, not the catalog —
                     `sspower: you named a skill — invoke it before acting.`
                     (the user already chose; the full catalog is noise)
    simple-coding  → emit sspower_target_trigger line / short nudge
    qa             → emit nothing
```

The full catalog `REMINDER` survives only as the fail-open fallback (step 2
empty/unparseable input, step 3 `_intent.sh` missing) — never on the
normal classified path.

Step 2 matters: v1 emits the reminder on empty/unparseable input. Without
this step, v2 would classify empty input as `qa` and go silent — a
regression. The malformed-JSON test stays after the rewrite.

`quick:` is precisely: *strip the prefix, classify normally, downgrade only
`multi-step`→`simple-coding`*. It does **not** force coding intent —
`quick: what is a closure?` still classifies `qa` → silent. It only
suppresses auto-start.

**AUTO-FLOW preamble** (hook-side, auto-start path only — a manual
`/flow start` never shows it):

> `AUTO-FLOW: a pipeline was auto-started for this task. If this is actually
> a quick, single-step change, run \`bash <flow.sh> abort\` and just do it
> directly. Otherwise, proceed: <plan-stage orders follow>`

**Targeted trigger** — `prompt-submit` calls `sspower_target_trigger` and
maps the result:

| `sspower_target_trigger` | Injected line |
|--------------------------|---------------|
| `debugging`     | `→ invoke sspower:systematic-debugging` |
| `brainstorming` | `→ invoke sspower:brainstorming` |
| `planning`      | `→ invoke sspower:writing-plans` |
| `tdd`           | `→ invoke sspower:test-driven-development` |
| `code-review`   | `→ invoke sspower:requesting-code-review` |
| `none`          | short nudge: `sspower: a skill may apply — check before acting.` |

The full generic catalog `REMINDER` is **never** emitted on a classified
path — it survives only as the fail-open fallback (steps 0/2/3:
`jq` missing, malformed/empty payload, `_intent.sh` missing). `explicit-skill`
emits the short confirmation line, not the catalog. Existing
`test_prompt_submit.sh` cases that assert the old catalog for explicit-skill
must be updated to assert the short confirmation + absence of "check which
skills apply".

## Component 3 — `hooks/semble-context.sh`

**Scope of the consolidation:** `_intent.sh` replaces *only* the
coding-intent regex (lines 66–67). `semble-context.sh`'s other, earlier
gates — length `< 20`, slash-command / opt-out prefixes, and read-verb
prefixes (`show`, `explain`, `why`) — are a *different* decision (skip
repo-context on trivial or read-only prompts) and **stay as-is**. The
"one classifier" goal is: one *coding-intent* classifier, not one
mega-gate.

Line 63 today (the coding-intent grep — verbatim, this is the legacy
regex, no ellipsis):
```bash
echo "$LC" | grep -qE '\b(add|fix|build|refactor|implement|change|write|create|debug|update|modify|remove|delete|rename|move|migrate|port|wire|ship|integrate|setup|install|configure|test|bug|error|broken|failing|crash)\b' \
  || { log_hook info "kind=skip reason=no-coding-intent"; emit_nothing; }
```

Replace with (note: `semble-context.sh` holds the parsed prompt in
`USER_PROMPT`, not `PROMPT` — using the wrong name crashes under `set -u`):
```bash
if ! source "$(dirname "${BASH_SOURCE[0]}")/_intent.sh" 2>/dev/null; then
  # fail-open: _intent.sh missing → keep the EXACT legacy regex above
  echo "$LC" | grep -qE '\b(add|fix|build|refactor|implement|change|write|create|debug|update|modify|remove|delete|rename|move|migrate|port|wire|ship|integrate|setup|install|configure|test|bug|error|broken|failing|crash)\b' \
    || { log_hook info "kind=skip reason=no-coding-intent"; emit_nothing; }
elif [ "$(sspower_classify_intent "$USER_PROMPT")" = "qa" ]; then
  log_hook info "kind=skip reason=no-coding-intent"; emit_nothing
fi
```
The fallback regex must be the literal above — no ellipsis — so the
`_intent.sh`-present and `_intent.sh`-missing paths cannot drift.
`test-semble-context.sh` must include an unset-variable-crash case.

Repo context is injected when intent ≠ `qa` *and* the earlier gates pass.
This slightly widens the coding-intent gate vs the old regex (e.g. a `.ts`
file mention now counts); `test-semble-context.sh` pins the new behavior.

## Component 4 — `skills/using-sspower/SKILL.md`

Frontmatter `description` today routes "deciding whether a skill applies."
Change to reflect demotion — `using-sspower` is now a reference card the
hook's targeted triggers point at, not the per-turn router. The skill body
stays usable via explicit `/using-sspower`. (Exact wording decided at
plan time.)

## Component 4b — `hooks/session-start`

`session-start` currently injects the **entire** `using-sspower/SKILL.md`
wrapped in `<EXTREMELY_IMPORTANT>… your introduction to using skills …`
(line ~91). That keeps the old catalog-router alive at every session start —
directly contradicting the demotion. Change it: inject a short
workflow-engine notice instead of the full SKILL.md body, e.g.

> `sspower workflow engine active. The prompt-submit hook routes skills by
> intent and auto-starts a flow on multi-step work. /flow status to inspect,
> /using-sspower for the skill reference.`

The full `using-sspower` content stays reachable on demand via the skill;
it is just no longer force-fed every session.

## Component 5 — `CLAUDE.md` (plugin)

Add a short architecture note: sspower is a workflow engine; `prompt-submit`
+ `_intent.sh` route skills; `flow.sh` carries the pipeline; `using-sspower`
is a reference. Update the existing line that calls `using-sspower` "the
skill-routing entrypoint."

## Out of scope (flagged, not built)

- The user's **global** `~/.claude/CLAUDE.md` says "`using-sspower` reminder
  runs each turn as backup" — that goes stale. Flag to the user; do not
  auto-edit global config.
- Stale-flow detection (the `updated`-timestamp gap — a forgotten flow
  resumes silently). Separate change.

## Failure behavior (fail-open)

A `UserPromptSubmit` hook must never block prompt submission. Specified
fallbacks:

- **`_intent.sh` unavailable** (missing / source fails):
  - `prompt-submit` → fall back to the legacy unconditional `REMINDER`.
    This is reached **only on the idle path** — the active-flow check
    (`flow.sh orders`) already ran and returned before `_intent.sh` is
    sourced, so a broken classifier never suppresses an active flow.
  - `semble-context.sh` → fall back to its legacy coding-intent regex
    (shown in Component 3).
- **`flow.sh start` fails** (corrupt state, jq error, state-file write
  failure, or a flow somehow already active): the hook does **not** emit
  the AUTO-FLOW preamble. It emits the `simple-coding` targeted trigger
  instead and logs the failure via `_log.sh` `log_event warn`. A failed
  auto-start degrades to a reminder, never to a broken pipeline.
- **`flow.sh orders` empty while a flow is active** (unknown/corrupt
  stage): treated as idle — falls through to the idle classifier. (Already
  the v1 behavior.)

## Open risks

- `_intent.sh` is bash substring matching — lossy. The conservative
  `multi-step` bar is the mitigation; misclassification falls to a cheaper
  failure mode (reminder instead of flow, or flow the model aborts).
- `semble-context.sh` gate widens slightly — behavior change pinned by test.
- Auto-start misfire → model bails via `flow.sh abort` (layer 2).
- `quick:` opt-out is a learned convention, undiscoverable until documented
  in the plugin CLAUDE.md.

## Self-review

- **Spec coverage:** classifier (C1), auto-start (C2), targeted triggers
  (C2), classifier consolidation (C3), identity/demotion (C4, C5), tests
  (C6) — all mapped.
- **Placeholder scan:** `using-sspower` exact wording deferred to plan time
  — acceptable (it is copy, not logic; the change is described).
- **Consistency:** intent labels `qa|explicit-skill|simple-coding|
  multi-step` identical across `_intent.sh`, `prompt-submit`, tests.

### Codex spec-review fixes applied (session 019e4e3f)

- **[high] design/review prompts auto-started flows** — added a
  **review-class guard** (step 3): review/approval phrasing →
  `simple-coding`, never `multi-step`. Bare `design` removed from the
  strong-verb set. Truth-table cases for design-review prompts required in
  `test_intent.sh`.
- **[high] `semble-context.sh` consolidation incomplete** — Component 3 now
  scopes the change explicitly: `_intent.sh` replaces only the coding-intent
  regex; semble's length/opt-out/read-verb pre-gates stay. Added
  `test_semble_context.sh` to the file structure.
- **[med] `explicit-skill` too broad** — dropped bare ` skill` / `invoke ` /
  ` use the `; match only `sspower:` + known skill names. Negative tests
  required.
- **[med] routing logic split from the classifier** — `_intent.sh` now also
  exports `sspower_target_trigger`; the trigger map is data, not hook code.
- **[med] failure behavior underspecified** — added the **Failure behavior**
  section: fail-open fallbacks for `_intent.sh` unavailable and
  `flow.sh start` failure.

### Codex spec-review fixes applied (session 019e4e44)

- **[high] `semble-context.sh` wrong prompt variable** — the hook holds the
  prompt in `USER_PROMPT` (not `PROMPT`); Component 3 snippet corrected, or
  it crashes under `set -u`. Test must cover the unset-variable case.
- **[high] review-class routed to wrong skill** — `requesting-code-review`
  is post-implementation diff review, not spec/plan review. `target_trigger`
  now distinguishes `code-review` (implemented diff/PR) from spec/plan/
  approval prompts, which route to `none` (short nudge, no skill).
- **[med] `_intent.sh` failure vs active-flow** — Component 2 now states the
  order explicitly: active-flow (`flow.sh orders`) resolves first; `_intent.sh`
  is sourced only on the idle path, so its failure cannot suppress a flow.
- **[med] `brainstorm` dropped** — added a `brainstorming` target trigger
  (`brainstorm` / `explore options` / ideation) → `sspower:brainstorming`.
- **[low] test filename** — use the existing hyphenated
  `tests/hooks/test-semble-context.sh` (edit), not a new underscore variant.

### Codex spec-review fixes applied (session 019e4e48)

- **[high] auto-start keyed wrong directory** — `flow.sh start` MUST run as
  `(cd "$CWD" && …)`; `flow.sh` keys state by `pwd -P`, so starting from the
  plugin dir makes the flow read idle. Component 2 step 5 specifies it; a
  test pins state-under-payload-cwd.
- **[high] unreachable triggers** — `brainstorm`/`structure`/`spec`/etc. had
  no signal in step 2, so they classified `qa` and never reached
  `target_trigger`. Step 2 now includes ideation/planning phrases as a
  signal. Truth-table cases required for trigger prompts without file
  extensions or coding verbs.
- **[med] malformed/empty input regression** — added idle-path step 2:
  jq-parse failure or empty prompt → emit `REMINDER` (preserves v1).
- **[med] `quick:` overreach** — redefined precisely: strip prefix, classify
  normally, downgrade only `multi-step`→`simple-coding`. `quick: <Q&A>`
  stays silent.

### Codex spec-review fixes applied (session 019e4e4b)

- **[med] read-only Q&A routed as coding** — added classifier **step 1**, a
  read-only/greeting prefix guard → `qa`, so `prompt-submit` no longer
  nudges on technical Q&A that mentions a file. Lives in `_intent.sh` (both
  hooks share it).
- **[med] fallback regex ellipsis** — Component 3 now carries the verbatim
  legacy regex (no `…`); `_intent.sh`-present and `_intent.sh`-missing paths
  cannot drift.
- **[low] explicit-skill emitted the catalog** — changed to a short
  confirmation line. The full `REMINDER` catalog now appears only as the
  fail-open fallback, never on a classified path.
- **[low] `quick:` syntax** — pinned to case-insensitive
  `^[[:space:]]*quick:[[:space:]]*`.

### Codex spec-review fixes applied (session 019e4e4e)

- **[high] ordering: `cwd` needed before flow lookup** — added explicit
  **Step 0** to Component 2: read payload, check `jq`, parse+normalize
  `cwd` (fallback `pwd -P`) — *then* the active-flow lookup. Prompt parsing
  and the empty/malformed fallback moved to step 2.
- **[med] explicit-skill output contradiction** — removed the stale
  "catalog retained for explicit-skill" sentence. One behavior:
  explicit-skill → short confirmation; catalog → fail-open only. Noted that
  `test_prompt_submit.sh` explicit-skill cases must be updated.
- **[med] routing-ownership over-claim** — reworded: `_intent.sh` owns
  classification + trigger *selection*; `prompt-submit` owns presentation
  strings. `sspower_target_trigger` returns a symbol, not a line.

### Codex spec-review fixes applied (session 019e4e51)

- **[high] explicit-skill list incomplete** (missed 9 of 19 skills) — the
  match set is no longer a hardcoded list. `_intent.sh` globs
  `<intent_dir>/../skills/*/` at runtime; the set never goes stale.
- **[med] read-only guard too literal** — added a leading-politeness-modal
  strip (`can you`/`could you`/`please`/…) before the read-verb prefix
  match, plus `summarize`/`analyze`. `can you explain src/foo.ts?` now
  classifies `qa`.
- **[low] malformed-payload vs active-flow** — stated the priority
  explicitly: an active flow wins even when the prompt fails to parse; the
  REMINDER fallback is idle-path only. One regression test required.

### Codex spec-review fixes applied (session 019e4e55)

- **[high] missing TDD trigger** — added a `tdd` target trigger →
  `sspower:test-driven-development` for plain feature/bugfix implementation
  prompts (`add`/`implement`/`create <fn>`). Without it, "add an export
  button" degraded to the generic nudge.
- **[med] target-trigger order** — `sspower_target_trigger` is now an
  explicit 7-step ordered list; review/approval of a non-impl artifact
  returns `none` *before* `planning`/`code-review` are considered.
- **[low] "pure, no I/O" contradiction** — reworded: `_intent.sh` is
  side-effect-free except one bounded `skills/*` glob, which tolerates a
  missing/unreadable dir.

### Codex spec-review fixes applied (session 019e4e58)

- **[scope] `session-start` kept the old router** — added Component 4b:
  `session-start` stops force-feeding the full `using-sspower` SKILL.md and
  injects a short workflow-engine notice instead. Without this the demotion
  is cosmetic.
- **[low] malformed-payload priority overclaimed** — clarified: a *valid*
  payload with a bad `prompt` preserves the payload-cwd flow; a *fully
  malformed* payload can only resolve a flow for the hook process cwd.
- **[low] explicit-skill delimiter** — match skill basenames on a word
  boundary (`(^|[^[:alnum:]_-])<skill>([^[:alnum:]_-]|$)`), not bare
  substring; `sspower:` stays a direct substring trigger.

> Spec-review closed at round 8 (session 019e4e58): architecture assessed
> "coherent"; residual findings were all LOW polish, now applied.
> Implementation-stage review will catch any further detail.
