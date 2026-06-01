#!/usr/bin/env bash
# Deterministic description-contract lint for skill-triggering.
#
# WHY this exists instead of the live `claude -p` eval (run-test.sh):
#   Several of these skills (notably orchestrating-workflows) are NOT routed
#   by the deterministic intent hook (hooks/_intent.sh has no workflow class).
#   Their triggering is 100% model-decided from the SKILL.md `description:`
#   frontmatter. The #1 regression is an edit that drops a trigger phrase from
#   that description -> the model stops selecting the skill. This lint pins the
#   trigger phrases as a contract: no spawn, no billing, no nondeterminism.
#
#   It does NOT prove the model picks the skill (that needs a model). For the
#   occasional behavior check, prefer an in-session subagent over `claude -p`;
#   if scripting, use --max-turns 1 (the skill fires on turn 1).
set -uo pipefail

SKILLS="$(cd "$(dirname "$0")/../../skills" && pwd)"
PROMPTS="$(cd "$(dirname "$0")/prompts" && pwd)"
PASS=0; FAIL=0

# desc_of <skill> -> lowercased, whitespace-collapsed description text.
# Frontmatter here is exactly {name, description}; drop name:, strip the
# description: label, fold continuation lines, lowercase.
desc_of() {
  awk '/^---[[:space:]]*$/{n++; next} n==1' "$SKILLS/$1/SKILL.md" \
    | sed -e '/^name:/d' -e 's/^description:[[:space:]]*//' \
    | tr '\n' ' ' | tr -s ' ' | tr '[:upper:]' '[:lower:]'
}

# need <skill> <lowercase-phrase> -- description MUST contain phrase.
need() {
  local d; d="$(desc_of "$1")"
  case "$d" in
    *"$2"*) PASS=$((PASS+1)); echo "ok   - $1: \"$2\"" ;;
    *)      FAIL=$((FAIL+1)); echo "FAIL - $1: missing \"$2\"" ;;
  esac
}

# budget <skill> <max> -- description non-empty and within length budget.
# Over-long descriptions dilute routing signal.
budget() {
  local d n; d="$(desc_of "$1")"; n=${#d}
  if [ "$n" -gt 0 ] && [ "$n" -le "$2" ]; then
    PASS=$((PASS+1)); echo "ok   - $1: length $n <= $2"
  else
    FAIL=$((FAIL+1)); echo "FAIL - $1: length $n (want 1..$2)"
  fi
}

# fixture <skill> -- naive prompt fixture exists and is non-empty.
fixture() {
  if [ -s "$PROMPTS/$1.txt" ]; then
    PASS=$((PASS+1)); echo "ok   - $1: prompt fixture present"
  else
    FAIL=$((FAIL+1)); echo "FAIL - $1: prompt fixture missing/empty"
  fi
}

# --- contract: trigger phrases each description MUST carry ---
need systematic-debugging       "bug"
need systematic-debugging       "test failure"
need systematic-debugging       "unexpected behavior"

need test-driven-development     "feature or bugfix"
need test-driven-development     "before writing implementation"

need writing-plans               "spec or requirements"
need writing-plans               "multi-step"

need dispatching-parallel-agents "independent tasks"
need dispatching-parallel-agents "shared state"

# orchestrating-workflows is description-only routed -> pin every trigger.
need orchestrating-workflows     "author"
need orchestrating-workflows     "workflow"
need orchestrating-workflows     "orchestrate this across"
need orchestrating-workflows     "fan out"
need orchestrating-workflows     "/workflows"

need executing-plans             "written implementation plan"
need executing-plans             "review checkpoints"

need requesting-code-review      "before merging"
need requesting-code-review      "meets requirements"

# --- description length budget (routing signal hygiene) ---
budget systematic-debugging       300
budget test-driven-development     300
budget writing-plans              300
budget dispatching-parallel-agents 300
budget orchestrating-workflows    600
budget executing-plans            300
budget requesting-code-review     300

# --- naive-prompt fixtures present for every covered skill ---
fixture systematic-debugging
fixture test-driven-development
fixture writing-plans
fixture dispatching-parallel-agents
fixture orchestrating-workflows
fixture executing-plans
fixture requesting-code-review

echo "---"
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
