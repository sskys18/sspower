# sspower Workflow-Engine v2 — implementation plan

**Date:** 2026-05-22
**Repo:** `sspower` plugin (`github.com/sskys18/sspower`)
**Status:** approved — Codex plan-review `approve-with-followups`
(session 019e4e76); the one LOW finding (`sspower:`-prefixed skill IDs in
`emit_trigger`) is applied inline.
**Spec:** `docs/specs/2026-05-22-sspower-workflow-engine-design.md`
**Builds on:** branch `feat/flow-state-machine` (v1 flow state machine,
commit `8d895c5`)

## Summary

Make sspower a workflow engine: one shared intent classifier feeds a
state-aware `prompt-submit` hook that auto-starts a flow on high-confidence
multi-step work and otherwise injects a single targeted skill trigger.
Demote `using-sspower` from router to reference.

Implement on top of `feat/flow-state-machine` (the v1 hook is already the
state-aware version this plan rewrites).

## File structure

| File | Action |
|------|--------|
| `hooks/_intent.sh` | create — `sspower_classify_intent` + `sspower_target_trigger` |
| `hooks/prompt-submit` | rewrite v2 — source `_intent.sh`, auto-start, targeted triggers |
| `hooks/semble-context.sh` | edit — swap inline regex for `_intent.sh` |
| `hooks/session-start` | edit — short notice instead of full `using-sspower` SKILL.md |
| `skills/using-sspower/SKILL.md` | edit — frontmatter `description` demotion |
| `CLAUDE.md` | edit — record workflow-engine architecture |
| `tests/hooks/test_intent.sh` | create — classifier + trigger truth tables |
| `tests/hooks/test_prompt_submit.sh` | rewrite — v2 behaviors |
| `tests/hooks/test-semble-context.sh` | edit — pin consolidated gate |

No `hooks.json` change. No `scripts/flow.sh` change.

---

## Task 1 — `hooks/_intent.sh`

Create `hooks/_intent.sh` (sourced, not executed — no shebang-exec, but keep
a shebang for editors). `chmod` not required (sourced).

```bash
#!/usr/bin/env bash
# sspower intent classifier — single source of truth for prompt routing.
# SOURCED (not executed) by hooks/prompt-submit and hooks/semble-context.sh.
#
#   sspower_classify_intent "<prompt>"
#     → qa | explicit-skill | simple-coding | multi-step
#   sspower_target_trigger "<prompt>"
#     → debugging | brainstorming | planning | tdd | code-review | none
#
# Side-effect-free except one bounded glob of <this-dir>/../skills/*/ at
# source time. Tolerates a missing/unreadable skills/ dir.

_sspower_intent_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || echo .)"

# Skill basenames, derived once at source time. Leading+trailing spaces so
# membership tests can match " <name> ".
_sspower_skill_names=" "
for _sd in "${_sspower_intent_dir}/../skills"/*/; do
  [ -d "$_sd" ] || continue
  _sspower_skill_names="${_sspower_skill_names}$(basename "$_sd") "
done 2>/dev/null
unset _sd

_sspower_lc() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }

# Strip one leading politeness modal; echo the remainder.
_sspower_strip_modal() {
  local s="$1"
  case "$s" in
    "can you "*)   printf '%s' "${s#can you }" ;;
    "could you "*) printf '%s' "${s#could you }" ;;
    "would you "*) printf '%s' "${s#would you }" ;;
    "please "*)    printf '%s' "${s#please }" ;;
    "pls "*)       printf '%s' "${s#pls }" ;;
    *)             printf '%s' "$s" ;;
  esac
}

# qa | explicit-skill | simple-coding | multi-step
sspower_classify_intent() {
  local p; p="$(_sspower_lc "${1:-}")"
  [ -n "$p" ] || { echo qa; return 0; }

  # 1. read-only guard (after stripping a politeness modal)
  local r; r="$(_sspower_strip_modal "$p")"
  case "$r" in
    "what is"*|"what's"*|"what does"*|"how does"*|"show "*|"list "*|\
    "explain"*|"describe"*|"tell me"*|"why "*|"summarize"*|"analyze"*)
      echo qa; return 0 ;;
  esac
  case "$p" in
    hi|hello|hey|thanks|"thank you"|ok|okay|yes|no|done|go|push|why)
      echo qa; return 0 ;;
  esac

  # 2. explicit-skill — "sspower:" or a skill basename on a word boundary.
  #    Skill basenames are [a-z-] only, so each is safe as a literal regex
  #    fragment; the (^|…)/(…|$) groups are the spec's boundary rule.
  case "$p" in *"sspower:"*) echo explicit-skill; return 0 ;; esac
  local name
  for name in $_sspower_skill_names; do
    [ -n "$name" ] || continue
    if [[ "$p" =~ (^|[^[:alnum:]_-])"$name"([^[:alnum:]_-]|$) ]]; then
      echo explicit-skill; return 0
    fi
  done

  # 3. skill-relevant signal test
  local sig=0
  case "$p" in
    *'```'*|*.js*|*.ts*|*.py*|*.sh*|*.go*|*.rs*|*.tsx*|*.json*|*.md*) sig=1 ;;
  esac
  if [ "$sig" -eq 0 ]; then
    case " $p " in
      *' fix '*|*' bug '*|*' bugs '*|*' implement '*|*' refactor '*|\
      *' build '*|*' test '*|*' tests '*|*' error '*|*' errors '*|\
      *' debug '*|*' add '*|*' plan '*|*' feature '*|*' broken '*|\
      *' fail '*|*' fails '*|*' failing '*|*' crash '*|*' function '*|\
      *' class '*|*' commit '*|*' create '*|*' update '*|*' change '*|\
      *' remove '*|*' delete '*|*' edit '*|*' review '*|*' lint '*|\
      *' typecheck '*|*' compile '*|*' run '*|*' merge '*|*' rename '*|\
      *' brainstorm '*|*' structure '*|*' spec '*|*' approach '*|\
      *' design '*) sig=1 ;;
    esac
    case "$p" in
      *'how should i'*|*'explore options'*|*'explore ways'*) sig=1 ;;
    esac
  fi
  [ "$sig" -eq 1 ] || { echo qa; return 0; }

  # 4. review-class guard → never multi-step
  case "$p" in
    *'spec-review'*|*'plan-review'*|*'code-review'*|*'review this'*|\
    *'review the'*|*'awaiting'*|*'approve'*|*'approval'*)
      echo simple-coding; return 0 ;;
  esac

  # 5. multi-step test — strong action verb AND substantial
  local multi=0
  case " $p " in
    *' implement '*|*' refactor '*|*' migrate '*|*' rewrite '*|\
    *' redesign '*|*' port '*|*' integrate '*|*' build '*) multi=1 ;;
  esac
  if [ "$multi" -eq 1 ]; then
    local substantial=0
    [ "${#p}" -ge 80 ] && substantial=1
    case "$p" in
      *,*|*' and '*|*' then '*|*"$(printf '\n')"*) substantial=1 ;;
    esac
    [ "$substantial" -eq 1 ] && { echo multi-step; return 0; }
  fi
  echo simple-coding
}

# debugging | brainstorming | planning | tdd | code-review | none
# FIRST match wins, in the order below.
sspower_target_trigger() {
  local p; p="$(_sspower_lc "${1:-}")"
  # 1. debugging
  case " $p " in
    *' bug '*|*' bugs '*|*' error '*|*' errors '*|*' crash '*|\
    *' broken '*|*' failing '*) echo debugging; return 0 ;;
  esac
  case "$p" in *'not working'*|*'test fail'*|*'tests fail'*)
    echo debugging; return 0 ;;
  esac
  # 2. review/approve of a NON-impl artifact → none.
  #    MUST come before the code-review guard: "review this implementation
  #    plan" has both "implementation" and "plan" — the plan wins → none.
  case "$p" in *review*|*approve*|*approval*)
    case "$p" in
      *design*|*spec*|*plan*) echo none; return 0 ;;
    esac ;;
  esac
  # 3. code-review — review of an IMPLEMENTED artifact (diff/PR/code)
  case "$p" in *review*)
    case "$p" in
      *diff*|*' pr '*|*' pr'|*'pull request'*|*' change'*|\
      *implementation*|*'this code'*) echo code-review; return 0 ;;
    esac ;;
  esac
  # 4. brainstorming
  case "$p" in
    *brainstorm*|*'explore options'*|*'explore ways'*|*'explore ideas'*)
      echo brainstorming; return 0 ;;
  esac
  # 5. planning
  case "$p" in
    *spec*|*'how should i'*|*'design '*) echo planning; return 0 ;;
  esac
  # 6. tdd — implementation request
  case " $p " in
    *' add '*|*' implement '*|*' create '*) echo tdd; return 0 ;;
  esac
  case "$p" in *'small change'*) echo tdd; return 0 ;; esac
  # 7. none
  echo none
}
```

**Verify:**

```bash
bash -n hooks/_intent.sh && echo "syntax ok"
bash -c 'source hooks/_intent.sh
  sspower_classify_intent "what is a closure?"          # qa
  sspower_classify_intent "use systematic-debugging"    # explicit-skill
  sspower_classify_intent "fix the auth bug"            # simple-coding
  sspower_classify_intent "implement a retry layer with backoff and jitter for the api client" # multi-step
  sspower_classify_intent "review this design doc"      # simple-coding
  sspower_target_trigger  "the parser is broken"        # debugging
  sspower_target_trigger  "review this PR diff"         # code-review
  sspower_target_trigger  "review this design"          # none
  sspower_target_trigger  "add an export button"        # tdd'
```

---

## Task 2 — rewrite `hooks/prompt-submit` (v2)

Replace the entire file. The v1 file (committed `8d895c5`) has the
flow-active branch and the idle verb gate; v2 keeps the flow-active branch,
adds Step 0 cwd resolution, sources `_intent.sh`, and replaces the idle
branch with classify + auto-start + targeted triggers.

```bash
#!/usr/bin/env bash
# UserPromptSubmit hook: workflow-engine router.
#
#   ACTIVE FLOW → inject the current stage's marching orders (flow.sh).
#   IDLE        → classify intent (hooks/_intent.sh):
#     multi-step    → auto-start a flow (conservative; model can abort)
#     explicit-skill→ short skill-confirmation line
#     simple-coding → one targeted skill trigger
#     qa            → nothing
#
# Failure policy: never blocks submission (EXIT trap → exit 0). On
# ambiguity (no jq, malformed/empty payload, _intent.sh missing) it falls
# back to the legacy catalog REMINDER — a missed trigger costs more than a
# spare reminder.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_log.sh" 2>/dev/null || true
trap '_sspower_exit_guard $? "0" hook.prompt-submit' EXIT

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
FLOW_SH="${PLUGIN_ROOT}/scripts/flow.sh"
INTENT_SH="${PLUGIN_ROOT}/hooks/_intent.sh"

REMINDER="sspower: BEFORE responding, check which skills apply (even 1% chance = invoke via Skill tool). Priority: process skills first (brainstorming, systematic-debugging), then implementation skills (test-driven-development, writing-plans, executing-plans, subagent-driven-development). Rigid skills (TDD, debugging): follow exactly. Flexible skills: adapt to context. If about to claim done: verification-before-completion. If completing a feature: requesting-code-review. Skip only for pure Q&A with zero coding/planning intent."

INPUT="$(cat 2>/dev/null || true)"

# No jq → legacy reminder, printf-escaped.
if ! command -v jq >/dev/null 2>&1; then
  printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"%s"}}\n' "$REMINDER"
  exit 0
fi

emit() {  # $1 = additionalContext text; jq -Rs makes it JSON-safe
  printf '%s' "$1" | jq -Rs '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:.}}'
}

# --- Step 0: parse payload, resolve cwd -------------------------------
PAYLOAD_OK=1
PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)" || PAYLOAD_OK=0
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
  CWD="$(cd "$CWD" 2>/dev/null && pwd -P || printf '%s' "$CWD")"
else
  CWD="$(pwd -P)"
fi

# --- Step 1: ACTIVE FLOW wins (even on a bad prompt) ------------------
ORDERS=""
if [ -f "$FLOW_SH" ]; then
  ORDERS="$(cd "$CWD" 2>/dev/null && bash "$FLOW_SH" orders 2>/dev/null || true)"
fi
if [ -n "$ORDERS" ]; then
  emit "$ORDERS"
  exit 0
fi

# --- Step 2: idle — malformed/empty payload → legacy reminder ---------
if [ "$PAYLOAD_OK" -eq 0 ] || [ -z "$PROMPT" ]; then
  emit "$REMINDER"
  exit 0
fi

# --- Step 3: source the classifier -----------------------------------
if ! source "$INTENT_SH" 2>/dev/null || ! command -v sspower_classify_intent >/dev/null 2>&1; then
  emit "$REMINDER"
  exit 0
fi

# --- Step 4: quick: opt-out -------------------------------------------
QUICK=0
CLEAN="$PROMPT"
if printf '%s' "$PROMPT" | grep -qiE '^[[:space:]]*quick:[[:space:]]*'; then
  QUICK=1
  CLEAN="$(printf '%s' "$PROMPT" | sed -E 's/^[[:space:]]*[Qq][Uu][Ii][Cc][Kk]:[[:space:]]*//')"
fi

# --- Step 5: classify + route -----------------------------------------
# Targeted skill line for a simple-coding prompt ($1). Used by the
# simple-coding branch AND the auto-start-failure fallback (spec: a failed
# auto-start degrades to the simple-coding trigger, not a generic nudge).
emit_trigger() {
  case "$(sspower_target_trigger "$1")" in
    debugging)     emit "sspower → invoke sspower:systematic-debugging before proposing a fix." ;;
    brainstorming) emit "sspower → invoke sspower:brainstorming before designing." ;;
    planning)      emit "sspower → invoke sspower:writing-plans for this multi-step work." ;;
    tdd)           emit "sspower → invoke sspower:test-driven-development before writing code." ;;
    code-review)   emit "sspower → invoke sspower:requesting-code-review for this diff." ;;
    *)             emit "sspower: a skill may apply — check before acting." ;;
  esac
}

INTENT="$(sspower_classify_intent "$CLEAN")"
[ "$INTENT" = "multi-step" ] && [ "$QUICK" -eq 1 ] && INTENT="simple-coding"

case "$INTENT" in
  multi-step)
    TASK="$(printf '%s' "$CLEAN" | head -n1 | cut -c1-100)"
    if ( cd "$CWD" 2>/dev/null && bash "$FLOW_SH" start "$TASK" ) >/dev/null 2>&1; then
      ORDERS="$(cd "$CWD" 2>/dev/null && bash "$FLOW_SH" orders 2>/dev/null || true)"
      if [ -n "$ORDERS" ]; then
        emit "AUTO-FLOW: a pipeline was auto-started for this task. If this is actually a quick, single-step change, run: bash \"$FLOW_SH\" abort — and just do it directly. Otherwise: ${ORDERS}"
        exit 0
      fi
    fi
    # auto-start failed → log, then fall back to the simple-coding trigger
    command -v log_event >/dev/null 2>&1 && \
      log_event warn hook.prompt-submit kind=autostart_failed
    emit_trigger "$CLEAN"
    exit 0
    ;;
  explicit-skill)
    emit "sspower: you named a skill — invoke it via the Skill tool before acting."
    exit 0
    ;;
  simple-coding)
    emit_trigger "$CLEAN"
    exit 0
    ;;
  *)  # qa
    exit 0
    ;;
esac
```

**Verify:**

```bash
bash -n hooks/prompt-submit && echo "syntax ok"
PR="$(pwd -P)"
echo '{"prompt":"what is a closure?","cwd":"'"$PR"'"}' | bash hooks/prompt-submit          # (silent)
echo '{"prompt":"fix the login bug","cwd":"'"$PR"'"}' | bash hooks/prompt-submit | grep -o systematic-debugging
echo '{"prompt":"use writing-plans here","cwd":"'"$PR"'"}' | bash hooks/prompt-submit | grep -o 'named a skill'
echo 'not json'                              | bash hooks/prompt-submit | grep -o 'check which skills'
```

---

## Task 3 — `hooks/semble-context.sh`

Replace **only** the coding-intent grep (the single line after the
`case "$LC"` read-verb block). Leave every other gate (length, opt-out,
read-verb `case`, git-repo check) untouched.

Find:
```bash
echo "$LC" | grep -qE '\b(add|fix|build|refactor|implement|change|write|create|debug|update|modify|remove|delete|rename|move|migrate|port|wire|ship|integrate|setup|install|configure|test|bug|error|broken|failing|crash)\b' \
  || { log_hook info "kind=skip reason=no-coding-intent"; emit_nothing; }
```

Replace with:
```bash
if source "$(dirname "${BASH_SOURCE[0]}")/_intent.sh" 2>/dev/null \
   && command -v sspower_classify_intent >/dev/null 2>&1; then
  [ "$(sspower_classify_intent "$USER_PROMPT")" = "qa" ] \
    && { log_hook info "kind=skip reason=no-coding-intent"; emit_nothing; }
else
  # fail-open: _intent.sh unavailable → exact legacy regex
  echo "$LC" | grep -qE '\b(add|fix|build|refactor|implement|change|write|create|debug|update|modify|remove|delete|rename|move|migrate|port|wire|ship|integrate|setup|install|configure|test|bug|error|broken|failing|crash)\b' \
    || { log_hook info "kind=skip reason=no-coding-intent"; emit_nothing; }
fi
```

`USER_PROMPT` (not `PROMPT`) is the parsed-prompt variable in this hook —
using the wrong name aborts under `set -u`.

**Verify:**

```bash
bash -n hooks/semble-context.sh && echo "syntax ok"
```

---

## Task 4 — `hooks/session-start`

**Surgical edit — preserve local changes.** `hooks/session-start` already
has uncommitted local modifications (the sspower-mem `bin/` wrapper work).
Apply only the two edits below; do not overwrite the file or revert
unrelated lines.

The hook injects the full `using-sspower/SKILL.md` wrapped in
`<EXTREMELY_IMPORTANT>… your introduction to using skills …`. Replace the
body it injects with a short workflow-engine notice.

Find the `session_context=` assignment (≈ line 91):
```bash
session_context="<EXTREMELY_IMPORTANT>\nYou have sspower.\n\n**Below is the full content of your 'sspower:using-sspower' skill - your introduction to using skills. For all other skills, use the 'Skill' tool:**\n\n${using_sspower_escaped}\n</EXTREMELY_IMPORTANT>${mem_block}"
```

Replace with:
```bash
session_context="<EXTREMELY_IMPORTANT>\nYou have sspower — a workflow engine. The prompt-submit hook routes skills by intent and auto-starts a plan→review→exec→test→review flow on multi-step work. Run \`/flow status\` to inspect an active flow, \`/flow abort\` to clear one. Invoke skills via the Skill tool; \`/using-sspower\` is the skill reference.\n</EXTREMELY_IMPORTANT>${mem_block}"
```

Then delete the now-unused `using_sspower_content` / `using_sspower_escaped`
lines (the `cat .../using-sspower/SKILL.md` read and its escape step) so the
hook does no dead work.

**Verify:**

```bash
bash -n hooks/session-start && echo "syntax ok"
grep -c using_sspower_escaped hooks/session-start   # → 0
```

---

## Task 5 — `skills/using-sspower/SKILL.md`

Edit the frontmatter `description` only. Current value routes
"deciding whether a skill applies." Replace with a reference-card framing:

```
description: sspower skill reference — the catalog of available skills and
  when each applies. The prompt-submit hook routes skills automatically;
  consult this when you want the full list or an explicit lookup.
```

Leave the skill body unchanged (still usable via explicit `/using-sspower`).

**Verify:** `head -5 skills/using-sspower/SKILL.md` shows the new description.

---

## Task 6 — `CLAUDE.md`

**Surgical edit — preserve local changes.** `CLAUDE.md` already has
uncommitted local modifications (the sspower-mem wrapper rewrite). Replace
only the single line below; leave every other line, including the modified
sspower-mem paragraph, intact.

In the "Key Rules" list, replace the line:
```
- `using-sspower` is the skill-routing entrypoint (named `using-superpowers` in the original Superpowers base)
```
with:
```
- sspower is a workflow engine: `hooks/prompt-submit` + `hooks/_intent.sh` route skills by prompt intent and auto-start a plan→review→exec→test→review flow (`scripts/flow.sh`, `/flow`) on multi-step work. `using-sspower` is the skill *reference*, not the router (named `using-superpowers` in the original Superpowers base)
```

**Verify:** `grep -c 'workflow engine' CLAUDE.md` → ≥ 1.

---

## Task 7 — `tests/hooks/test_intent.sh`

Create `tests/hooks/test_intent.sh`, `chmod +x`. Truth tables for both
functions.

```bash
#!/usr/bin/env bash
# Tests for hooks/_intent.sh — classifier + target-trigger truth tables.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/hooks/_intent.sh"
PASS=0; FAIL=0

ci() {  # $1 = prompt  $2 = expected classify  $3 = label
  local got; got="$(sspower_classify_intent "$1")"
  if [ "$got" = "$2" ]; then PASS=$((PASS+1)); echo "ok   - $3"
  else FAIL=$((FAIL+1)); echo "FAIL - $3 (want $2, got $got): $1"; fi
}
tt() {  # $1 = prompt  $2 = expected trigger  $3 = label
  local got; got="$(sspower_target_trigger "$1")"
  if [ "$got" = "$2" ]; then PASS=$((PASS+1)); echo "ok   - $3"
  else FAIL=$((FAIL+1)); echo "FAIL - $3 (want $2, got $got): $1"; fi
}

# --- classify: qa ---
ci "what is a closure?"                 qa             "qa: what-is"
ci "can you explain src/foo.ts?"        qa             "qa: modal+explain+file"
ci "summarize README.md"                qa             "qa: summarize"
ci "why does this loop run twice"       qa             "qa: why"
ci "thanks"                             qa             "qa: greeting"
ci ""                                   qa             "qa: empty"

# --- classify: explicit-skill ---
ci "use systematic-debugging to dig in" explicit-skill "skill: bare name"
ci "invoke sspower:writing-plans"       explicit-skill "skill: sspower: prefix"
ci "run receiving-code-review on this"  explicit-skill "skill: globbed name"
ci "what skill should I learn next?"    qa             "skill: NEG bare 'skill'"

# --- classify: simple-coding ---
ci "fix the auth bug"                   simple-coding  "simple: bug fix"
ci "rename the helper function"         simple-coding  "simple: rename"
ci "review this design doc"            simple-coding  "simple: review-class guard"
ci "implement it"                       simple-coding  "simple: multi verb but short"

# --- classify: multi-step ---
ci "implement a retry layer with backoff and jitter for the api client" \
                                        multi-step     "multi: long + verb"
ci "refactor the auth module, then add token rotation" \
                                        multi-step     "multi: multi-clause"

# --- target_trigger ---
tt "the parser is broken"               debugging      "trig: debugging"
tt "tests fail after the merge"         debugging      "trig: test-fail"
tt "review this PR diff"                code-review    "trig: code-review"
tt "review this implementation diff"    code-review    "trig: impl diff → code-review"
tt "review this implementation plan"    none           "trig: impl plan → none"
tt "review the spec for me"             none           "trig: review spec → none"
tt "approve this plan"                  none           "trig: approve plan → none"
tt "brainstorm options for caching"     brainstorming  "trig: brainstorm"
tt "how should I structure this module" planning       "trig: planning"
tt "add an export button"               tdd            "trig: tdd"
tt "tweak the css padding"              none           "trig: generic → none"

echo "---"
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
```

**Verify:**

```bash
chmod +x tests/hooks/test_intent.sh
bash tests/hooks/test_intent.sh   # → passed: N  failed: 0
```

---

## Task 8 — rewrite `tests/hooks/test_prompt_submit.sh`

Replace the file. Keeps the v1 helper shape; covers v2 behaviors. The v1
explicit-skill test asserted the old catalog — v2 asserts the short
confirmation.

```bash
#!/usr/bin/env bash
# Tests for hooks/prompt-submit v2 — workflow-engine routing.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/hooks/prompt-submit"
FLOW="$ROOT/scripts/flow.sh"
PASS=0; FAIL=0

setup() { TMP="$(mktemp -d)"; export HOME="$TMP"; }
teardown() { [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -R "$TMP"; }
run() { printf '%s' "$1" | bash "$HOOK" 2>/dev/null; }

sub() {  # $1 label  $2 substring  $3 actual
  if printf '%s' "$3" | grep -qF "$2"; then PASS=$((PASS+1)); echo "ok   - $1"
  else FAIL=$((FAIL+1)); echo "FAIL - $1"; echo "  want: $2"; echo "  got: $3"; fi
}
empty() {  # $1 label  $2 actual
  if [ -z "$(printf '%s' "$2" | tr -d '[:space:]')" ]; then
    PASS=$((PASS+1)); echo "ok   - $1"
  else FAIL=$((FAIL+1)); echo "FAIL - $1 (want empty)"; echo "  got: $2"; fi
}
no_sub() {  # $1 label  $2 substring  $3 actual
  if printf '%s' "$3" | grep -qF "$2"; then
    FAIL=$((FAIL+1)); echo "FAIL - $1 (found '$2')"
  else PASS=$((PASS+1)); echo "ok   - $1"; fi
}

CWD="$(pwd -P)"

# idle Q&A → silent
setup; out="$(run '{"prompt":"what is a closure?","cwd":"'"$CWD"'"}')"
empty "idle Q&A → silent" "$out"; teardown

# malformed payload → legacy reminder
setup; out="$(run 'not json at all')"
sub "malformed → reminder" "check which skills apply" "$out"; teardown

# empty prompt → legacy reminder
setup; out="$(run '{"prompt":"","cwd":"'"$CWD"'"}')"
sub "empty prompt → reminder" "check which skills apply" "$out"; teardown

# explicit skill → short confirmation, NOT catalog
setup; out="$(run '{"prompt":"use writing-plans for this","cwd":"'"$CWD"'"}')"
sub  "explicit-skill → confirmation" "you named a skill" "$out"
no_sub "explicit-skill → no catalog" "check which skills apply" "$out"; teardown

# simple-coding bug → debugging trigger
setup; out="$(run '{"prompt":"the parser is broken","cwd":"'"$CWD"'"}')"
sub "bug → debugging trigger" "systematic-debugging" "$out"; teardown

# multi-step → auto-start flow
setup
out="$(run '{"prompt":"implement a retry layer with backoff and jitter for the api client","cwd":"'"$CWD"'"}')"
sub "multi-step → AUTO-FLOW" "AUTO-FLOW" "$out"
sub "multi-step → plan stage" "FLOW[plan 1/5]" "$out"
( cd "$CWD" && bash "$FLOW" abort >/dev/null 2>&1 ); teardown

# quick: suppresses auto-start
setup
out="$(run '{"prompt":"quick: implement a retry layer with backoff and jitter now","cwd":"'"$CWD"'"}')"
no_sub "quick: → no auto-flow" "AUTO-FLOW" "$out"
( cd "$CWD" && bash "$FLOW" abort >/dev/null 2>&1 ); teardown

# quick: + Q&A stays silent
setup; out="$(run '{"prompt":"quick: what is a closure?","cwd":"'"$CWD"'"}')"
empty "quick: + Q&A → silent" "$out"; teardown

# active flow → stage orders win, no classification
setup
( cd "$CWD" && bash "$FLOW" start "demo task" >/dev/null )
out="$(run '{"prompt":"what is a closure?","cwd":"'"$CWD"'"}')"
sub "active flow → orders" "FLOW[plan 1/5]" "$out"
( cd "$CWD" && bash "$FLOW" abort >/dev/null ); teardown

# active flow wins even with an empty prompt (flow spine sacrosanct)
setup
( cd "$CWD" && bash "$FLOW" start "demo task" >/dev/null )
out="$(run '{"prompt":"","cwd":"'"$CWD"'"}')"
sub "active flow + empty prompt → orders" "FLOW[plan 1/5]" "$out"
( cd "$CWD" && bash "$FLOW" abort >/dev/null ); teardown

# auto-start failure → falls back to the targeted trigger, not a flow.
# Force failure: make the state file a directory so flow.sh start dies.
setup
mkdir -p "$HOME/.claude/sspower/flow-state.json"
out="$(run '{"prompt":"implement a retry layer with backoff and jitter for the api client","cwd":"'"$CWD"'"}')"
no_sub "autostart-fail → no AUTO-FLOW" "AUTO-FLOW" "$out"
sub    "autostart-fail → targeted trigger" "test-driven-development" "$out"
teardown

echo "---"
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
```

**Verify:**

```bash
chmod +x tests/hooks/test_prompt_submit.sh
bash tests/hooks/test_prompt_submit.sh   # → passed: N  failed: 0
```

---

## Task 9 — `tests/hooks/test-semble-context.sh`

The file exists — **read it first** to learn its helper names and harness
shape, then add the cases below following that shape.

**The gate is not reachable by default.** `semble-context.sh` exits early
(lines ~47–48) when `SSPOWER_SEMBLE=0` or `semble_rs` is not on `PATH`,
*before* the consolidated coding-intent gate. So a test that just pipes a
payload and checks stdout proves nothing. Each gate test MUST:

1. Put a deterministic `semble_rs` shim first on `PATH` (a 1-line script
   that `exit 0`s, or echoes empty), so the hook reaches the gate.
2. Use an isolated `HOME` (`mktemp -d`) so the hook's log
   (`$HOME/.claude/sspower/codex.log`, via `_log.sh`) is test-private.
3. Assert on the **log line**, not stdout — grep the hook log for
   `kind=skip reason=no-coding-intent` (present = skipped, absent = passed
   the gate). `emit_context` exits before logging a skip.

Setup sketch:
```bash
setup() {
  TMP="$(mktemp -d)"; export HOME="$TMP"
  SHIM="$TMP/bin"; mkdir -p "$SHIM"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SHIM/semble_rs"
  chmod +x "$SHIM/semble_rs"; export PATH="$SHIM:$PATH"
}
ran_hook() { printf '%s' "$1" | bash "$ROOT/hooks/semble-context.sh" >/dev/null 2>&1; }
skipped_no_intent() {  # → 0 if the hook logged a no-coding-intent skip
  grep -q 'kind=skip reason=no-coding-intent' "$HOME/.claude/sspower/codex.log" 2>/dev/null
}
```

**Prompt choice matters.** `semble-context.sh` skips read-verb prefixes
(`what is`, `show`, `explain`, …) at its *own* `case` block — *before* the
consolidated gate, and without logging `no-coding-intent`. So a gate test
must use a prompt that is **≥20 chars, not a read-verb prefix, not a
greeting** — only then does it reach the `_intent.sh` gate. The negative
prompt must be non-coding *and* non-read-verb.

Cases (each: `setup`, build a `{"prompt":…,"cwd":…}` payload, `ran_hook`,
assert, `teardown` with `rm -R`):

- **coding intent passes the gate** — `"please fix the bug in auth code"`
  (31 ch; modal-stripped → `fix`/`bug` signal) → `skipped_no_intent` FALSE.
- **non-coding reaches the gate and skips** — `"compare the repository
  purpose today"` (not a read-verb prefix, no coding verb → `_intent.sh`
  returns `qa`) → `skipped_no_intent` TRUE.
- **`.ts` mention now counts** — `"take a look at the handler.ts file"`
  (not a read-verb prefix; `.ts` is a coding signal) →
  `skipped_no_intent` FALSE (widened gate vs old regex).
- **read-verb prompt** — `"what is this repository for"` → assert hook
  stdout is **empty** (skipped at semble's own read-verb `case`); do NOT
  assert the `no-coding-intent` log — that path exits before the gate.
- **unset-variable safety** — run the hook under a normal payload and
  confirm it does not abort with `USER_PROMPT: unbound variable` on stderr.
- **`_intent.sh`-missing fallback** — run against a copy of the hook tree
  with `_intent.sh` removed; the legacy regex still passes
  `"please fix the bug in auth code"` (FALSE) and skips
  `"compare the repository purpose today"` (TRUE).

**Verify:**

```bash
bash -n tests/hooks/test-semble-context.sh && echo "syntax ok"
bash tests/hooks/test-semble-context.sh   # → all pass
```

---

## Task 10 — deploy to runtime cache

The runtime executes from `plugins/cache/sskys18/sspower/1.1.1/`. Copy the
changed runtime files (tests are not deployed).

```bash
SRC=/Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower
DST=/Users/sskys/.claude/plugins/cache/sskys18/sspower/1.1.1
cp "$SRC/hooks/_intent.sh"        "$DST/hooks/_intent.sh"
cp "$SRC/hooks/prompt-submit"     "$DST/hooks/prompt-submit"
cp "$SRC/hooks/semble-context.sh" "$DST/hooks/semble-context.sh"
cp "$SRC/hooks/session-start"     "$DST/hooks/session-start"
chmod +x "$DST/hooks/prompt-submit" "$DST/hooks/semble-context.sh" "$DST/hooks/session-start"
```

`skills/using-sspower/SKILL.md` and `CLAUDE.md` also need copying to the
cache for the session-start notice + skill description to take effect:

```bash
cp "$SRC/skills/using-sspower/SKILL.md" "$DST/skills/using-sspower/SKILL.md"
cp "$SRC/CLAUDE.md"                     "$DST/CLAUDE.md"
```

**Verify:** `diff "$SRC/hooks/_intent.sh" "$DST/hooks/_intent.sh"` → no
output. New session → no `_sspower_exit_guard` errors (smoke test below).

---

## Task 11 — end-to-end verification

```bash
PR=/Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower
bash "$PR/tests/hooks/test_intent.sh"            # passed: N  failed: 0
bash "$PR/tests/hooks/test_prompt_submit.sh"     # passed: N  failed: 0
bash "$PR/tests/hooks/test_flow.sh"              # v1 regression — still 0 failed
bash "$PR/tests/hooks/test-semble-context.sh"    # passed: N  failed: 0
# deployed-cache smoke: no _sspower_exit_guard errors on stderr
DST=/Users/sskys/.claude/plugins/cache/sskys18/sspower/1.1.1
echo '{"prompt":"hi","cwd":"/tmp"}' | CLAUDE_PLUGIN_ROOT="$DST" bash "$DST/hooks/prompt-submit" 2>&1
```

**Commit is not part of the worker plan** (`AGENTS.md`: the worker must not
run `git commit`). End with the changes uncommitted and print
`git status --short`; the operator commits onto `feat/flow-state-machine`
after reviewing. Suggested message:

```
feat(flow): workflow-engine routing — intent classifier + auto-start

Add hooks/_intent.sh (single intent classifier + target-trigger).
prompt-submit v2 auto-starts a flow on multi-step work and injects one
targeted skill trigger otherwise. Consolidate semble-context's classifier.
Demote using-sspower from router to reference.

Spec: docs/specs/2026-05-22-sspower-workflow-engine-design.md
```

---

## Self-review

- **Spec coverage:** `_intent.sh` (T1), prompt-submit v2 (T2),
  semble-context (T3), session-start (T4), using-sspower (T5), CLAUDE.md
  (T6), tests T7–T9, deploy (T10), verify (T11) — every spec component
  mapped.
- **Placeholder scan:** Task 9 is the only task without verbatim code — it
  appends to an existing file whose helper names are not known without
  reading it; the four required cases are named precisely. Acceptable: the
  executor reads the file first (its structure is the spec).
- **Type/name consistency:** intent labels `qa|explicit-skill|simple-coding|
  multi-step` and trigger labels `debugging|brainstorming|planning|tdd|
  code-review|none` identical across `_intent.sh`, `prompt-submit`, and
  `test_intent.sh`.
- **Open risk (accepted, per spec):** classifier is bash substring
  matching — lossy; conservative `multi-step` bar + model-bail are the
  mitigations.

### Codex plan-review fixes applied (session 019e4e69)

- **[high] `_intent.sh` invalid bash** — the hand-enumerated explicit-skill
  `case` arms had broken apostrophe quoting and did not implement the
  spec's word-boundary rule. Replaced with the spec's exact regex via
  `[[ "$p" =~ (^|[^[:alnum:]_-])"$name"([^[:alnum:]_-]|$) ]]` — fixes both
  the syntax error and the boundary-coverage gap (`/writing-plans`,
  `systematic-debugging:` now match).
- **[med] Task 9 gate unreachable** — `semble-context.sh` exits before the
  consolidated gate when `semble_rs` is absent. Task 9 now mandates a
  `semble_rs` PATH shim, isolated `HOME`, and assertion on the hook **log**
  (`kind=skip reason=no-coding-intent`), not stdout.
- **[low] target files have local mods** — Tasks 4 and 6 (`session-start`,
  `CLAUDE.md`) carry unrelated uncommitted sspower-mem changes. Both tasks
  now flag a surgical edit that preserves those local changes.

### Codex plan-review fixes applied (session 019e4e6e)

- **[high] `target_trigger` ordering** — the non-impl review/approval guard
  (`design|spec|plan` → `none`) now runs **before** the code-review guard,
  so "review this implementation plan" → `none`, not `code-review`. Added
  truth-table cases for both impl-plan and impl-diff.
- **[med] active-flow-vs-bad-payload not pinned** — `test_prompt_submit.sh`
  now has an explicit case: flow active + `{"prompt":"","cwd":"$CWD"}` →
  emits `FLOW[plan 1/5]` (flow spine survives an empty prompt).

### Codex plan-review fixes applied (session 019e4e71)

- **[high] Task 9 test prompts unreachable** — `what is …` prompts exit at
  `semble-context.sh`'s own read-verb `case` before the consolidated gate.
  Task 9 now uses gate-reachable prompts (`compare the repository purpose
  today` for the non-coding case) and asserts read-verb prompts via empty
  stdout, not the `no-coding-intent` log.
- **[med] auto-start-failure dropped the targeted trigger** — Task 2 now
  defines `emit_trigger()`; a failed `flow.sh start` logs `autostart_failed`
  then calls `emit_trigger` (same as `simple-coding`), per spec. Added a
  `test_prompt_submit.sh` case that forces start-failure (state file made a
  directory) and asserts the targeted line, not a generic nudge.
