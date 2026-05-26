#!/usr/bin/env bash
# sspower intent classifier - single source of truth for prompt routing.
# SOURCED (not executed) by hooks/prompt-submit and hooks/semble-context.sh.
#
#   sspower_classify_intent "<prompt>"
#     -> qa | architecture | explicit-skill | simple-coding | multi-step
#   sspower_target_trigger "<prompt>"
#     -> debugging | brainstorming | planning | tdd | code-review | none
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

# qa | architecture | explicit-skill | simple-coding | multi-step
sspower_classify_intent() {
  local p; p="$(_sspower_lc "${1:-}")"
  [ -n "$p" ] || { echo qa; return 0; }

  # 0. system-injected content guard. UserPromptSubmit also fires on
  #    harness messages — task-notifications, system-reminders — wrapped in
  #    an XML-ish <tag>. Those are NOT user requests; classifying them
  #    auto-starts spurious flows. A leading "<" → never classify.
  case "$p" in '<'*) echo qa; return 0 ;; esac

  # 1. read-only guard (after stripping a politeness modal)
  local r; r="$(_sspower_strip_modal "$p")"
  # Architecture prompts: structural questions about THIS codebase that
  # benefit from graph lookup, not generic Q&A. Must be classified before
  # the broader qa case, which also matches "how does".
  case "$r" in
    "how does "*" reach "*|"how does "*" call "*|\
    "what calls "*|"what call "*|"who calls "*|\
    "where is "*" used"*|"where is "*" called"*|\
    "trace "*|"callers of "*|"callees of "*|\
    "show the path "*|"show the call path "*|"call graph "*)
      echo architecture; return 0 ;;
  esac
  case "$r" in
    "what is"*|"what's"*|"what does"*|"how does"*|"show "*|"list "*|\
    "explain"*|"describe"*|"tell me"*|"why "*|"summarize"*|"analyze"*)
      echo qa; return 0 ;;
  esac
  case "$p" in
    hi|hello|hey|thanks|"thank you"|ok|okay|yes|no|done|go|push|why)
      echo qa; return 0 ;;
  esac

  # 2. explicit-skill - "sspower:" or a skill basename on a word boundary.
  #    Skill basenames are [a-z-] only, so each is safe as a literal regex
  #    fragment; the (^|...)/(...|$) groups are the spec's boundary rule.
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

  # 4. review-class guard -> never multi-step
  case "$p" in
    *'spec-review'*|*'plan-review'*|*'code-review'*|*'review this'*|\
    *'review the'*|*'awaiting'*|*'approve'*|*'approval'*)
      echo simple-coding; return 0 ;;
  esac

  # 5. multi-step test - strong action verb AND substantial
  local multi=0
  case " $p " in
    *' implement '*|*' refactor '*|*' migrate '*|*' rewrite '*|\
    *' redesign '*|*' port '*|*' integrate '*|*' build '*) multi=1 ;;
  esac
  if [ "$multi" -eq 1 ]; then
    local substantial=0
    [ "${#p}" -ge 80 ] && substantial=1
    case "$p" in
      *,*|*' and '*|*' then '*) substantial=1 ;;
    esac
    case "$p" in
      *$'\n'*) substantial=1 ;;
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
  # 2. review/approve of a NON-impl artifact -> none.
  #    MUST come before the code-review guard: "review this implementation
  #    plan" has both "implementation" and "plan" - the plan wins -> none.
  case "$p" in *review*|*approve*|*approval*)
    case "$p" in
      *design*|*spec*|*plan*) echo none; return 0 ;;
    esac ;;
  esac
  # 3. code-review - review of an IMPLEMENTED artifact (diff/PR/code)
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
  # 6. tdd - implementation request
  case " $p " in
    *' add '*|*' implement '*|*' create '*) echo tdd; return 0 ;;
  esac
  case "$p" in *'small change'*) echo tdd; return 0 ;; esac
  # 7. none
  echo none
}
