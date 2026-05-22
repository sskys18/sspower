# Flow State Machine — plan→review→exec→test→review pipeline

**Date:** 2026-05-22
**Repo:** `sspower` plugin (`github.com/sskys18/sspower`)
**Status:** approved (Codex plan-review, session 019e4db1, verdict `approve`)

## Problem

The `UserPromptSubmit` hook (`hooks/prompt-submit`) injects a static
skill-routing reminder on **every** prompt, including pure Q&A. Two costs:

1. **The tax.** ~500 tokens of "check which skills apply, 1% = invoke"
   prepended to every turn, relevant or not.
2. **No pipeline.** sspower has five stage-skills — `writing-plans`,
   `requesting-code-review` / `second-opinion`, `executing-plans` /
   `test-driven-development`, `verification-before-completion` — but nothing
   connects them. The plan→review→exec→test→review cycle only advances
   because the model remembers to, not because the system carries it.

## Solution

A directory-keyed state machine that drives the pipeline.

- **Flow idle** → the reminder is gated: injected only on coding/planning
  intent, silent for Q&A. Kills the tax.
- **Flow active** → the reminder is *replaced* by the current stage's
  marching orders. The hook reads state and tells the model exactly where it
  is in the pipeline.
- **Auto-advance** — the model runs `flow.sh advance` itself as each stage's
  deliverable completes; `flow.sh back` on test failure. No per-stage user
  typing. Stop only on failure.

### Known limitation (accepted)

Stage injection is still *push* — the hook suggests harder, it does not
enforce. A model can ignore "you are in TEST" the same way it can ignore
today's reminder. The win is structural (state persists, survives
compaction, re-injects on every prompt), not enforcement. State staleness is
self-correcting: if the model forgets to `advance`, the next prompt
re-injects the same stage.

## Stages

```
start ─▶ plan ─▶ plan-review ─▶ exec ─▶ test ─▶ review ─▶ (done: state cleared)
                                  ▲                │
                                  └──── back ◀──────┘   (test fail / review blocker)
```

`back` returns to `exec` — valid **only** from `test` or `review` (the
failure stages). Running `back` from `plan`/`plan-review` is rejected, so a
flow cannot skip plan approval.

## State file

`~/.claude/sspower/flow-state.json` — keyed by working directory so each
project carries its own flow.

```json
{
  "version": 1,
  "flows": {
    "/Users/sskys/proj": {
      "stage": "exec",
      "task": "add token refresh",
      "plan_path": "docs/plans/2026-05-22-add-token-refresh.md",
      "started": "2026-05-22T01:00:00Z",
      "updated": "2026-05-22T01:12:00Z"
    }
  }
}
```

`plan_path` is recorded once the PLAN stage produces a plan file
(`flow.sh set-plan <path>`). It is what lets a compacted session recover —
the `plan-review` and `exec` stage messages cite the stored path so the
model knows *which* plan to review or execute after context loss.

## File structure

| File | Action | Responsibility |
|------|--------|----------------|
| `scripts/flow.sh` | create | State CLI: `start`/`set-plan`/`advance`/`back`/`status`/`abort` |
| `commands/flow.toml` | create | `/flow` slash command — thin wrapper over `flow.sh` |
| `hooks/prompt-submit` | rewrite | State-aware injection (flow-active stages / gated idle reminder) |
| `tests/hooks/test_flow.sh` | create | State-machine transition tests |
| `tests/hooks/test_prompt_submit.sh` | create | Hook injection-behavior tests |

No `hooks.json` change — `prompt-submit` is already wired; `flow.sh` is a
plain script; `commands/*.toml` is auto-discovered.

---

## Task 1 — `scripts/flow.sh` (state CLI)

Create `scripts/flow.sh`, `chmod +x`:

```bash
#!/usr/bin/env bash
# sspower flow — plan→plan-review→exec→test→review pipeline state machine.
#
# State: ~/.claude/sspower/flow-state.json  { version, flows: { <cwd>: {...} } }
# Keyed by working directory so multiple projects each carry their own flow.
#
# Subcommands:
#   start <task>     begin a flow at the PLAN stage
#   set-plan <path>  record the plan-file path (required before leaving PLAN)
#   advance          move to the next stage (review → done clears the flow)
#   back             return to EXEC — valid only from test/review
#   status           print the current stage line (default)
#   orders           print ONLY the current stage's marching orders (for the hook)
#   abort            clear the flow for this directory
#
# render_orders() is the SINGLE source of truth for stage instructions:
# both `advance`/`start`/`back` (shown to the model in-terminal) and the
# `orders` subcommand (consumed by hooks/prompt-submit) call it. This is
# what makes same-turn auto-advance work — `advance` prints the next
# stage's full instructions, not just a status line.
set -uo pipefail
umask 077                       # state file is private (matches _log.sh 0600)

STATE_DIR="${HOME}/.claude/sspower"
STATE_FILE="${STATE_DIR}/flow-state.json"
STAGES=(plan plan-review exec test review)
# plugin root = scripts/.. — used to build absolute paths in stage orders.
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
FLOW_SH="${PLUGIN_ROOT}/scripts/flow.sh"

die() { echo "flow: $*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq is required"

CWD="$(pwd -P)"                 # resolved — must match the hook's normalized cwd
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$STATE_DIR" || die "cannot create $STATE_DIR"
[ -L "$STATE_FILE" ] && die "refusing to follow symlink: $STATE_FILE"
[ -f "$STATE_FILE" ] || printf '{"version":1,"flows":{}}\n' > "$STATE_FILE"
chmod 600 "$STATE_FILE" 2>/dev/null || true

jq_get() { jq -r --arg c "$CWD" "$1" "$STATE_FILE" 2>/dev/null; }

jq_set() {
  # $1 = jq filter mutating the document; $2.. = extra jq args (e.g. --arg t X)
  local filter="$1"; shift
  local tmp
  tmp="$(mktemp "${STATE_DIR}/.flow.XXXXXX")" || die "mktemp failed"
  if jq --arg c "$CWD" --arg n "$NOW" "$@" "$filter" "$STATE_FILE" > "$tmp"; then
    mv "$tmp" "$STATE_FILE"
  else
    rm -f "$tmp"; die "state write failed"
  fi
}

idx_of() {
  local i
  for i in "${!STAGES[@]}"; do
    [ "${STAGES[$i]}" = "$1" ] && { echo "$i"; return 0; }
  done
  echo -1
}

stage="$(jq_get '.flows[$c].stage // empty')"
task="$(jq_get '.flows[$c].task // empty')"
plan_path="$(jq_get '.flows[$c].plan_path // empty')"

print_status() {
  if [ -z "$stage" ]; then
    echo "flow: idle (no active flow in $CWD)"
    return
  fi
  local i; i="$(idx_of "$stage")"
  echo "flow: ${stage} ($((i + 1))/5) · task: ${task}${plan_path:+ · plan: ${plan_path}}"
}

# SINGLE source of truth for stage marching orders. Emits the instruction
# paragraph for $1; emits nothing for idle/unknown stages.
render_orders() {
  local s="$1" n ref=""
  n="$(idx_of "$s")"; n=$((n + 1))
  [ -n "$plan_path" ] && ref=" Plan file: ${plan_path}."
  case "$s" in
    plan)
      printf 'FLOW[plan %d/5] · task: "%s". Stage = PLAN. Invoke the sspower:writing-plans skill. Produce the plan only — no implementation code. When the plan file exists, run: bash "%s" set-plan <path-to-plan>, then bash "%s" advance. Auto-advance is on — drive the whole pipeline yourself, stop only on failure.' \
        "$n" "$task" "$FLOW_SH" "$FLOW_SH" ;;
    plan-review)
      printf 'FLOW[plan-review %d/5] · task: "%s".%s Stage = PLAN-REVIEW. Review the plan: run `node "%s/scripts/codex-bridge.mjs" plan-review --cd "%s" --prompt @%s`. Fix every high/medium finding inline and re-run until the verdict is approve or approve-with-followups. Then run: bash "%s" advance.' \
        "$n" "$task" "$ref" "$PLUGIN_ROOT" "$CWD" "${plan_path:-<plan-path>}" "$FLOW_SH" ;;
    exec)
      printf 'FLOW[exec %d/5] · task: "%s".%s Stage = EXEC. Plan approved. Invoke sspower:executing-plans (or test-driven-development for a feature/bugfix) and implement the plan. When implementation is complete, run: bash "%s" advance.' \
        "$n" "$task" "$ref" "$FLOW_SH" ;;
    test)
      printf 'FLOW[test %d/5] · task: "%s". Stage = TEST. Invoke sspower:verification-before-completion. Run tests, type-check, lint — real commands, real output. PASS → run: bash "%s" advance. FAIL → run: bash "%s" back (returns to EXEC), fix, retry. Never advance with failures outstanding.' \
        "$n" "$task" "$FLOW_SH" "$FLOW_SH" ;;
    review)
      printf 'FLOW[review %d/5] · task: "%s". Stage = REVIEW. Invoke sspower:requesting-code-review on the diff. If a blocker needs a code change, run: bash "%s" back. When the review is clean, run: bash "%s" advance — this completes and clears the flow.' \
        "$n" "$task" "$FLOW_SH" "$FLOW_SH" ;;
    *)
      : ;;  # idle / unknown → no output
  esac
}

# status line + the next stage's marching orders — what the model sees
# in-terminal after start/advance/back, so it can continue the same turn.
print_stage() {
  print_status
  local o; o="$(render_orders "$stage")"
  [ -n "$o" ] && { echo; echo "$o"; }
}

cmd="${1:-status}"
case "$cmd" in
  start)
    shift
    task="$*"
    [ -n "$task" ] || die "usage: flow start <task description>"
    [ -z "$stage" ] || die "flow already active (${stage}) — abort it first"
    jq_set '.flows[$c] = {stage:"plan",task:$t,plan_path:"",started:$n,updated:$n}' --arg t "$task"
    stage="plan"; print_stage
    ;;
  set-plan)
    [ -n "$stage" ] || die "no active flow — run: flow start <task>"
    shift
    path="$*"
    [ -n "$path" ] || die "usage: flow set-plan <path-to-plan-file>"
    jq_set '.flows[$c].plan_path = $p | .flows[$c].updated = $n' --arg p "$path"
    plan_path="$path"
    echo "flow: plan recorded — $path"
    ;;
  advance)
    [ -n "$stage" ] || die "no active flow — run: flow start <task>"
    # PLAN must record a plan file before leaving the stage — otherwise
    # plan-review/exec lose the compaction-recovery anchor.
    if [ "$stage" = "plan" ] && [ -z "$plan_path" ]; then
      die "plan path required — run: flow set-plan <path> before advancing"
    fi
    i="$(idx_of "$stage")"
    [ "$i" -ge 0 ] || die "corrupt state (stage=$stage)"
    if [ "$i" -ge $((${#STAGES[@]} - 1)) ]; then
      jq_set 'del(.flows[$c])'
      echo "flow: complete — pipeline finished, state cleared"
    else
      next="${STAGES[$((i + 1))]}"
      jq_set '.flows[$c].stage = $s | .flows[$c].updated = $n' --arg s "$next"
      stage="$next"; print_stage
    fi
    ;;
  back)
    [ -n "$stage" ] || die "no active flow"
    case "$stage" in
      test|review) ;;
      *) die "back is valid only from test/review (current stage: $stage)" ;;
    esac
    jq_set '.flows[$c].stage = "exec" | .flows[$c].updated = $n'
    stage="exec"; print_stage
    ;;
  abort)
    [ -n "$stage" ] || { echo "flow: idle — nothing to abort"; exit 0; }
    jq_set 'del(.flows[$c])'
    echo "flow: aborted — state cleared for $CWD"
    ;;
  orders) render_orders "$stage" ;;
  status) print_status ;;
  *) die "unknown subcommand: $cmd (use start|set-plan|advance|back|status|orders|abort)" ;;
esac
```

**Verify:**

```bash
chmod +x scripts/flow.sh
T="$(mktemp -d)"
HOME="$T" scripts/flow.sh start "demo task"            # → flow: plan (1/5) · task: demo task
HOME="$T" scripts/flow.sh set-plan docs/plans/x.md     # → flow: plan recorded — docs/plans/x.md
HOME="$T" scripts/flow.sh advance                      # → flow: plan-review (2/5) ...
HOME="$T" scripts/flow.sh abort                        # → flow: aborted ...
[ -n "$T" ] && [ -d "$T" ] && rm -R "$T"
```

---

## Task 2 — `commands/flow.toml` (slash command)

Create `commands/flow.toml`:

```toml
description = "Dev pipeline — start/advance/abort the plan→review→exec→test→review flow"
prompt = """Run the sspower flow state machine.

Execute: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/flow.sh" {{args}}` and report the
resulting stage line. If `${CLAUDE_PLUGIN_ROOT}` is unset, the script is at
`scripts/flow.sh` under the sspower plugin directory.

If no argument was given, default to the `status` subcommand.

If the subcommand was `start`, the pipeline is now ACTIVE and auto-advancing.
Drive it yourself — do not wait for the user between stages:
- The UserPromptSubmit hook injects the current stage's marching orders.
- Begin the PLAN stage now: invoke the sspower:writing-plans skill.
- When PLAN produces a plan file, run `flow.sh set-plan <path>` so the path
  survives compaction, then `flow.sh advance`.
- As each later stage's deliverable is done, run `flow.sh advance` and continue.
- On test failure, run `flow.sh back` (returns to EXEC), fix, retry.
- Stop only on failure. The flow clears itself after the REVIEW stage."""
```

**Verify:** new session → `/flow` appears in the command list; `/flow status`
prints `flow: idle`.

---

## Task 3 — rewrite `hooks/prompt-submit`

Replace the entire file. Current behavior: unconditional `REMINDER`
injection. New behavior: flow-active → stage orders; flow-idle → gated
reminder.

```bash
#!/usr/bin/env bash
# UserPromptSubmit hook: state-aware skill-routing injection.
#
#   FLOW ACTIVE — inject the current pipeline stage's marching orders
#                 (replaces the generic reminder entirely).
#   FLOW IDLE   — inject the skill-routing reminder only on coding/planning
#                 intent; stay silent for pure Q&A (kills the per-turn tax).
#
# Failure policy: a crash never blocks prompt submission (the EXIT trap
# guarantees exit 0). On *ambiguity* the hook is conservative, not silent:
#   - jq missing            → legacy unconditional reminder (compat exception)
#   - malformed/empty prompt → reminder (cannot classify → assume coding)
# This is deliberate — a missed skill trigger costs more than an extra
# reminder. "Fail-open" here means "never block", not "never inject".

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_log.sh" 2>/dev/null || true
trap '_sspower_exit_guard $? "0" hook.prompt-submit' EXIT

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
FLOW_SH="${PLUGIN_ROOT}/scripts/flow.sh"

REMINDER="sspower: BEFORE responding, check which skills apply (even 1% chance = invoke via Skill tool). Priority: process skills first (brainstorming, systematic-debugging), then implementation skills (test-driven-development, writing-plans, executing-plans, subagent-driven-development). Rigid skills (TDD, debugging): follow exactly. Flexible skills: adapt to context. If about to claim done: verification-before-completion. If completing a feature: requesting-code-review. Skip only for pure Q&A with zero coding/planning intent."

INPUT="$(cat 2>/dev/null || true)"

# No jq → fall back to the legacy unconditional reminder (printf-escaped).
if ! command -v jq >/dev/null 2>&1; then
  printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"%s"}}\n' "$REMINDER"
  exit 0
fi

emit() {
  # $1 = additionalContext text; jq -Rs makes it JSON-safe.
  printf '%s' "$1" | jq -Rs '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:.}}'
}

PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null || true)"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
# Normalize cwd so the lookup key matches flow.sh's `pwd -P` writer key.
# Without this, a symlinked project path stored by flow.sh would never be
# found here and active flows would silently appear idle.
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
  CWD="$(cd "$CWD" 2>/dev/null && pwd -P || printf '%s' "$CWD")"
else
  CWD="$(pwd -P)"
fi

# --- FLOW ACTIVE? -------------------------------------------------------
# Stage instructions are NOT duplicated here — flow.sh's render_orders() is
# the single source of truth. Ask flow.sh for the current stage's orders;
# `cd "$CWD"` so flow.sh's `pwd -P` key matches the normalized cwd.
ORDERS=""
if [ -f "$FLOW_SH" ]; then
  ORDERS="$(cd "$CWD" 2>/dev/null && bash "$FLOW_SH" orders 2>/dev/null || true)"
fi
if [ -n "$ORDERS" ]; then
  emit "$ORDERS"
  exit 0
fi

# --- FLOW IDLE: gate the reminder on skill / coding intent --------------
needs_reminder() {
  local p
  p="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  # (1) explicit skill requests — must NEVER be suppressed (hook's core job)
  case "$p" in
    *'sspower:'*|*'systematic-debugging'*|*'writing-plans'*|*'test-driven'*|\
    *'subagent-driven'*|*'executing-plans'*|*'brainstorm'*|*'verification-before'*|\
    *'requesting-code-review'*|*'code-review'*|*'second-opinion'*|\
    *'finishing-a-development'*|*' skill'*|*'invoke '*|*' use the '*)
      return 0 ;;
  esac
  # (2) code signals — fenced code, file extensions
  case "$p" in
    *'```'*|*'.js'*|*'.ts'*|*'.py'*|*'.sh'*|*'.go'*|*'.rs'*|*'.tsx'*|*'.json'*|*'.md'*)
      return 0 ;;
  esac
  # (3) coding / planning verbs
  case " $p " in
    *' fix '*|*' bug '*|*' bugs '*|*' implement '*|*' refactor '*|*' build '*|\
    *' test '*|*' tests '*|*' error '*|*' errors '*|*' debug '*|*' add '*|\
    *' plan '*|*' feature '*|*' broken '*|*' fail '*|*' fails '*|\
    *' failing '*|*' crash '*|*' function '*|*' class '*|*' commit '*|\
    *' create '*|*' update '*|*' change '*|*' remove '*|*' delete '*|\
    *' edit '*|*' review '*|*' lint '*|*' typecheck '*|*' compile '*|\
    *' run '*|*' merge '*|*' rename '*)
      return 0 ;;
  esac
  return 1
}

if [ -z "$PROMPT" ] || needs_reminder "$PROMPT"; then
  emit "$REMINDER"
fi
exit 0
```

**Notes:**
- Empty prompt → inject (cannot classify; fail toward over-reminding).
- The idle gate checks **explicit skill requests first** (`sspower:`, skill
  names, `invoke`, `use the … skill`). These must never be suppressed —
  routing to a named skill is the hook's core job. Code signals and the
  verb heuristic come after.
- The verb heuristic is deliberately conservative: false positives
  (reminder on a borderline Q&A) are acceptable; false negatives (missed
  intent) are worse, so the verb list errs broad. The real win is
  flow-active mode, not the heuristic.
- No stage text in the hook — `flow.sh orders` renders it (single source of
  truth, shared with `advance`/`start`/`back`).
- `_log.sh` / `_sspower_exit_guard` trap preserved from the original.

**Verify:**

```bash
PR=/Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower
# idle + Q&A → silent
echo '{"prompt":"is this natural?","cwd":"/tmp/x"}' | bash "$PR/hooks/prompt-submit"
# → (no output)
# idle + coding intent → reminder
echo '{"prompt":"fix the auth bug","cwd":"/tmp/x"}' | bash "$PR/hooks/prompt-submit"
# → {"hookSpecificOutput":{...REMINDER...}}
# idle + explicit skill request → reminder (not suppressed)
echo '{"prompt":"use systematic-debugging here","cwd":"/tmp/x"}' | bash "$PR/hooks/prompt-submit"
# → {"hookSpecificOutput":{...REMINDER...}}
# flow active → stage orders
T="$(mktemp -d)"
HOME="$T" bash "$PR/scripts/flow.sh" start "demo" >/dev/null
echo '{"prompt":"hi","cwd":"'"$(pwd -P)"'"}' | HOME="$T" bash "$PR/hooks/prompt-submit"
# → {"hookSpecificOutput":{...FLOW[plan 1/5]...}}
[ -n "$T" ] && [ -d "$T" ] && rm -R "$T"
```

---

## Task 4 — tests (`flow.sh` + `prompt-submit`)

Two test files. Pattern follows `tests/test_log_helpers.sh` (plain bash,
`set -u`, pass/fail counter). The hook is a hot-path rewrite, so it gets
automated coverage too — not just manual `echo` checks.

### 4a — `tests/hooks/test_flow.sh`

Create `tests/hooks/test_flow.sh`, `chmod +x`.

```bash
#!/usr/bin/env bash
# Tests for scripts/flow.sh — pipeline state machine transitions.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FLOW="$ROOT/scripts/flow.sh"
PASS=0; FAIL=0

setup() { TMP="$(mktemp -d)"; export HOME="$TMP"; }
teardown() { [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -R "$TMP"; }

check() {
  # $1 = label  $2 = expected substring  $3 = actual
  if printf '%s' "$3" | grep -qF "$2"; then
    PASS=$((PASS + 1)); echo "ok   - $1"
  else
    FAIL=$((FAIL + 1)); echo "FAIL - $1"; echo "  want substring: $2"; echo "  got: $3"
  fi
}

# start → plan
setup
out="$(bash "$FLOW" start "my task")"
check "start sets plan stage" "flow: plan (1/5)" "$out"
check "start records task" "task: my task" "$out"

# back is rejected outside test/review
out="$(bash "$FLOW" back 2>&1)"; rc=$?
check "back from plan refused" "valid only from test/review" "$out"
[ "$rc" -ne 0 ] && { PASS=$((PASS+1)); echo "ok   - back-from-plan exits nonzero"; } \
                || { FAIL=$((FAIL+1)); echo "FAIL - back-from-plan exits nonzero"; }

# set-plan records the plan path; status surfaces it (compaction recovery)
out="$(bash "$FLOW" set-plan "docs/plans/demo.md")"
check "set-plan records path" "plan recorded" "$out"
out="$(bash "$FLOW" status)"
check "status surfaces plan path" "plan: docs/plans/demo.md" "$out"

# orders subcommand emits the current stage's marching orders
out="$(bash "$FLOW" orders)"
check "orders emits plan instructions" "Stage = PLAN" "$out"

# double start refused
out="$(bash "$FLOW" start "again" 2>&1)"; rc=$?
check "double start refused" "already active" "$out"
[ "$rc" -ne 0 ] && { PASS=$((PASS+1)); echo "ok   - double start exits nonzero"; } \
                || { FAIL=$((FAIL+1)); echo "FAIL - double start exits nonzero"; }

# advance walks the pipeline — and surfaces the NEXT stage's orders
out="$(bash "$FLOW" advance)"
check "advance → plan-review" "plan-review (2/5)" "$out"
check "advance surfaces next-stage orders" "Stage = PLAN-REVIEW" "$out"

# back still rejected from plan-review
out="$(bash "$FLOW" back 2>&1)"
check "back from plan-review refused" "valid only from test/review" "$out"

out="$(bash "$FLOW" advance)"; check "advance → exec"        "exec (3/5)"        "$out"
out="$(bash "$FLOW" advance)"; check "advance → test"        "test (4/5)"        "$out"

# back → exec (valid from test)
out="$(bash "$FLOW" back)"; check "back returns to exec" "exec (3/5)" "$out"

# advance to review then past → clears
bash "$FLOW" advance >/dev/null   # exec → test
out="$(bash "$FLOW" advance)"; check "advance → review" "review (5/5)" "$out"
out="$(bash "$FLOW" advance)"; check "advance past review clears" "complete" "$out"
out="$(bash "$FLOW" status)"; check "status idle after complete" "idle" "$out"
teardown

# abort clears mid-flow
setup
bash "$FLOW" start "abortme" >/dev/null
bash "$FLOW" advance >/dev/null
out="$(bash "$FLOW" abort)"; check "abort clears state" "aborted" "$out"
out="$(bash "$FLOW" status)"; check "status idle after abort" "idle" "$out"
teardown

# advance with no flow → error
setup
out="$(bash "$FLOW" advance 2>&1)"; rc=$?
check "advance with no flow errors" "no active flow" "$out"
[ "$rc" -ne 0 ] && { PASS=$((PASS+1)); echo "ok   - no-flow advance exits nonzero"; } \
                || { FAIL=$((FAIL+1)); echo "FAIL - no-flow advance exits nonzero"; }
teardown

# advance from plan without a recorded plan_path → rejected, stays in plan
setup
bash "$FLOW" start "needs a plan" >/dev/null
out="$(bash "$FLOW" advance 2>&1)"; rc=$?
check "advance without plan_path refused" "plan path required" "$out"
[ "$rc" -ne 0 ] && { PASS=$((PASS+1)); echo "ok   - advance-no-plan exits nonzero"; } \
                || { FAIL=$((FAIL+1)); echo "FAIL - advance-no-plan exits nonzero"; }
out="$(bash "$FLOW" status)"; check "stays in plan after refused advance" "plan (1/5)" "$out"
teardown

echo "---"
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
```

**Verify:**

```bash
chmod +x tests/hooks/test_flow.sh
bash tests/hooks/test_flow.sh   # → passed: N  failed: 0  (exit 0)
```

### 4b — `tests/hooks/test_prompt_submit.sh`

Create `tests/hooks/test_prompt_submit.sh`, `chmod +x`. Covers the
injection behaviors of the rewritten hook: idle silence, idle reminder,
malformed JSON, explicit-skill requests (must not be suppressed),
active-stage injection, reminder suppression, plan-path citation, and
unknown-stage fallthrough.

```bash
#!/usr/bin/env bash
# Tests for hooks/prompt-submit — state-aware injection.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/hooks/prompt-submit"
FLOW="$ROOT/scripts/flow.sh"
PASS=0; FAIL=0

setup() { TMP="$(mktemp -d)"; export HOME="$TMP"; }
teardown() { [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -R "$TMP"; }

# run hook with a JSON payload → stdout
run() { printf '%s' "$1" | bash "$HOOK" 2>/dev/null; }

want_sub() {  # $1 label  $2 substring  $3 actual
  if printf '%s' "$3" | grep -qF "$2"; then
    PASS=$((PASS+1)); echo "ok   - $1"
  else
    FAIL=$((FAIL+1)); echo "FAIL - $1"; echo "  want: $2"; echo "  got: $3"
  fi
}
want_empty() {  # $1 label  $2 actual
  if [ -z "$(printf '%s' "$2" | tr -d '[:space:]')" ]; then
    PASS=$((PASS+1)); echo "ok   - $1"
  else
    FAIL=$((FAIL+1)); echo "FAIL - $1"; echo "  want: (empty)"; echo "  got: $2"
  fi
}

CWD="$(pwd -P)"

# idle + pure Q&A → silent
setup
out="$(run '{"prompt":"what is a closure?","cwd":"'"$CWD"'"}')"
want_empty "idle Q&A → silent" "$out"
teardown

# idle + coding intent → reminder
setup
out="$(run '{"prompt":"fix the auth bug","cwd":"'"$CWD"'"}')"
want_sub "idle coding → reminder" "check which skills apply" "$out"
teardown

# idle + malformed JSON → conservative reminder (cannot classify)
setup
out="$(run 'not json at all')"
want_sub "malformed JSON → reminder" "check which skills apply" "$out"
teardown

# idle + explicit skill request → reminder (must NOT be suppressed)
setup
out="$(run '{"prompt":"use systematic-debugging to find the bug","cwd":"'"$CWD"'"}')"
want_sub "explicit skill name → reminder" "check which skills apply" "$out"
teardown
setup
out="$(run '{"prompt":"please invoke writing-plans for this","cwd":"'"$CWD"'"}')"
want_sub "invoke + skill name → reminder" "check which skills apply" "$out"
teardown

# active flow → stage injection, reminder replaced
setup
( cd "$CWD" && bash "$FLOW" start "demo task" >/dev/null )
out="$(run '{"prompt":"hello","cwd":"'"$CWD"'"}')"
want_sub "active flow → stage orders" "FLOW[plan 1/5]" "$out"
case "$out" in *"check which skills apply"*)
  FAIL=$((FAIL+1)); echo "FAIL - active flow suppresses generic reminder" ;;
*) PASS=$((PASS+1)); echo "ok   - active flow suppresses generic reminder" ;;
esac
( cd "$CWD" && bash "$FLOW" abort >/dev/null )
teardown

# plan_path is cited in the exec-stage injection (compaction recovery)
setup
(
  cd "$CWD"
  bash "$FLOW" start "demo task" >/dev/null
  bash "$FLOW" set-plan "docs/plans/demo.md" >/dev/null
  bash "$FLOW" advance >/dev/null    # plan → plan-review
  bash "$FLOW" advance >/dev/null    # plan-review → exec
)
out="$(run '{"prompt":"continue","cwd":"'"$CWD"'"}')"
want_sub "exec injection cites plan path" "docs/plans/demo.md" "$out"
want_sub "exec injection shows exec stage" "FLOW[exec 3/5]" "$out"
( cd "$CWD" && bash "$FLOW" abort >/dev/null )
teardown

# corrupt stage value → no stage injection, falls through to idle gate
setup
mkdir -p "$HOME/.claude/sspower"
printf '{"version":1,"flows":{"%s":{"stage":"bogus","task":"x"}}}\n' "$CWD" \
  > "$HOME/.claude/sspower/flow-state.json"
out="$(run '{"prompt":"just a question?","cwd":"'"$CWD"'"}')"
want_empty "unknown stage → no FLOW injection" "$(printf '%s' "$out" | grep -F 'FLOW[' || true)"
teardown

echo "---"
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
```

**Verify:**

```bash
chmod +x tests/hooks/test_prompt_submit.sh
bash tests/hooks/test_prompt_submit.sh   # → passed: N  failed: 0  (exit 0)
```

---

## Task 5 — deploy to runtime cache

The runtime executes from `plugins/cache/sskys18/sspower/1.1.1/`, not the
marketplace source. Hooks/scripts are read fresh each invocation, so copying
takes effect on the next prompt; the slash command registers on the next
session.

```bash
SRC=/Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower
DST=/Users/sskys/.claude/plugins/cache/sskys18/sspower/1.1.1
cp "$SRC/scripts/flow.sh"        "$DST/scripts/flow.sh"
cp "$SRC/hooks/prompt-submit"    "$DST/hooks/prompt-submit"
cp "$SRC/commands/flow.toml"     "$DST/commands/flow.toml"
cp "$SRC/hooks/_log.sh"          "$DST/hooks/_log.sh"
chmod +x "$DST/scripts/flow.sh" "$DST/hooks/prompt-submit"
```

`_log.sh` MUST be copied too: the rewritten hook's EXIT trap calls
`_sspower_exit_guard`, which the stale cache `_log.sh` (v1.1.1, pre-error-
capture) does not define. The source `_log.sh` is a strict superset
(`_sspower_rotate_log` + `log_event` unchanged, adds `_sspower_err_jsonl`
+ `_sspower_exit_guard`), so other cache hooks are unaffected.

**Verify:** `diff "$SRC/hooks/prompt-submit" "$DST/hooks/prompt-submit"` →
no output. New session → `/flow` is listed.

---

## Task 6 — end-to-end verification

```bash
PR=/Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower
bash "$PR/tests/hooks/test_flow.sh"            # passed: N  failed: 0
bash "$PR/tests/hooks/test_prompt_submit.sh"   # passed: N  failed: 0
```

**Commit is not part of the worker plan.** Per `AGENTS.md`, an automated
Codex worker must not run `git commit`/`push`/`merge`. End execution with
the changes **uncommitted** and print `git status --short`. The human
operator (or orchestrating session) commits after reviewing the diff.

Suggested message for the operator to use:

```
feat(flow): plan→review→exec→test→review pipeline state machine

Gate the per-prompt skill reminder on coding intent; replace it with
stage-aware marching orders when a flow is active. Adds scripts/flow.sh
state CLI and the /flow command. Auto-advance, stop on failure.
```

The runtime cache (Task 5) is outside the git tree — nothing to commit there.

---

## Self-review

- **Spec coverage:** gate (Task 3 idle branch) ✓; state machine (Tasks 1–2)
  ✓; auto-advance (model-driven `advance`, Task 2/3 wording) ✓; stop-on-fail
  (`back`, Task 1/3) ✓; deploy (Task 5) ✓; tests — `flow.sh` 4a + hook 4b ✓.
- **Placeholder scan:** none — all code complete, all commands have expected
  output.
- **Type consistency:** stage names `plan|plan-review|exec|test|review`
  identical across `flow.sh` `STAGES`, `prompt-submit` `case`, and tests.

### Codex plan-review fixes applied (session 019e4d9c)

- **[high] cwd key mismatch** — writer (`flow.sh`) and reader
  (`prompt-submit`) now both normalize to `pwd -P`; the hook resolves the
  payload `.cwd` via `cd … && pwd -P`. Otherwise symlinked project paths
  make active flows read as idle.
- **[med] hook coverage** — Task 4b adds `test_prompt_submit.sh` (idle
  silence, idle reminder, malformed JSON, active-stage injection, reminder
  suppression, unknown-stage fallthrough).
- **[med] failure policy** — header reworded: "fail-open" = never *block*
  submission; on ambiguity the hook deliberately *injects* (missed skill
  trigger costs more than a spare reminder). no-jq legacy branch documented
  as a compat exception.
- **[med] state file privacy** — `flow.sh` sets `umask 077` and
  `chmod 600` on the state file, matching `_log.sh` conventions.
- **[low] intent verbs** — added create/update/change/remove/delete/edit/
  review/lint/typecheck/compile/run/merge/rename.

### Codex plan-review fixes applied (session 019e4da0)

- **[high] plan artifact not persisted** — added a `plan_path` state field
  and a `flow.sh set-plan <path>` subcommand. The `plan-review` and `exec`
  stage injections now cite the stored path, so a compacted session knows
  which plan to review/execute. Covered by tests 4a (set-plan + status) and
  4b (exec injection cites path).
- **[high] worker-rule violations** — Task 6 no longer instructs a
  `git commit` (the operator commits, not the worker — `AGENTS.md`). All
  `rm -R` calls are now guarded (`[ -n "$T" ] && [ -d "$T" ]`) and scoped
  to `mktemp -d` directories.
- **[med] unrestricted `back`** — `back` is now rejected from
  `plan`/`plan-review`; valid only from `test`/`review`. Tests 4a cover the
  rejection from both pre-exec stages.

### Codex plan-review fixes applied (session 019e4da6)

- **[high] same-turn auto-advance had no next-stage orders** — `flow.sh`
  now owns a `render_orders()` function (single source of truth) and an
  `orders` subcommand. `advance`/`start`/`back` print the new stage's full
  marching orders, not just a status line — so the model gets next-stage
  instructions in the same turn it advances. The hook no longer hardcodes
  stage text; it calls `flow.sh orders`. Tests 4a (`advance` surfaces
  orders, `orders` subcommand) cover it.
- **[high] idle gate could suppress explicit skill requests** — the gate
  now matches explicit skill signals *first* (`sspower:`, skill names,
  `invoke`, `use the … skill`) before the verb heuristic. `use
  systematic-debugging …` and `invoke writing-plans` now correctly trigger
  the reminder. Tests 4b cover both.
- **[med] wrong plan-review tool** — the `plan-review` stage no longer
  mentions `sspower:second-opinion` (which routes to code review, not
  plan-document review). It now names the exact command:
  `node "$PLUGIN_ROOT/scripts/codex-bridge.mjs" plan-review --cd "$CWD"
  --prompt @<plan_path>`.

### Codex plan-review fixes applied (session 019e4dae)

- **[high] `advance` could leave PLAN with no `plan_path`** — `advance`
  now rejects `stage=plan` when `plan_path` is empty (`die "plan path
  required …"`), so plan-review/exec always have the compaction-recovery
  anchor. Test 4a covers the rejection + stays-in-plan.
- **[high] `rm -rf` banned by `AGENTS.md`** — all cleanup switched to
  `rm -R` (recursive, non-forced) on `mktemp -d` directories. Applies to
  both verify snippets and both test files.
- *(med "could not execute" — environment note, not a plan defect; the
  plan is executed in a writable session, not the read-only review one.)*

- **Open risk (accepted):** the idle-intent heuristic is lossy by design.
  Auto-advance is model-driven, not enforced (see "Known limitation"). Both
  accepted in scoping.
