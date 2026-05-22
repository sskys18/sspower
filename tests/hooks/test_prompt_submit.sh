#!/usr/bin/env bash
# Tests for hooks/prompt-submit - state-aware injection.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/hooks/prompt-submit"
FLOW="$ROOT/scripts/flow.sh"
PASS=0; FAIL=0

setup() { TMP="$(mktemp -d)"; export HOME="$TMP"; }
teardown() { [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -R "$TMP"; }

# run hook with a JSON payload -> stdout
run() { printf '%s' "$1" | bash "$HOOK" 2>/dev/null; }

want_sub() {
  # $1 label  $2 substring  $3 actual
  if printf '%s' "$3" | grep -qF "$2"; then
    PASS=$((PASS+1)); echo "ok   - $1"
  else
    FAIL=$((FAIL+1)); echo "FAIL - $1"; echo "  want: $2"; echo "  got: $3"
  fi
}
want_empty() {
  # $1 label  $2 actual
  if [ -z "$(printf '%s' "$2" | tr -d '[:space:]')" ]; then
    PASS=$((PASS+1)); echo "ok   - $1"
  else
    FAIL=$((FAIL+1)); echo "FAIL - $1"; echo "  want: (empty)"; echo "  got: $2"
  fi
}

CWD="$(pwd -P)"

# idle + pure Q&A -> silent
setup
out="$(run '{"prompt":"what is a closure?","cwd":"'"$CWD"'"}')"
want_empty "idle Q&A -> silent" "$out"
teardown

# idle + coding intent -> reminder
setup
out="$(run '{"prompt":"fix the auth bug","cwd":"'"$CWD"'"}')"
want_sub "idle coding -> reminder" "check which skills apply" "$out"
teardown

# idle + malformed JSON -> conservative reminder (cannot classify)
setup
out="$(run 'not json at all')"
want_sub "malformed JSON -> reminder" "check which skills apply" "$out"
teardown

# idle + explicit skill request -> reminder (must NOT be suppressed)
setup
out="$(run '{"prompt":"use systematic-debugging to find the bug","cwd":"'"$CWD"'"}')"
want_sub "explicit skill name -> reminder" "check which skills apply" "$out"
teardown
setup
out="$(run '{"prompt":"please invoke writing-plans for this","cwd":"'"$CWD"'"}')"
want_sub "invoke + skill name -> reminder" "check which skills apply" "$out"
teardown

# active flow -> stage injection, reminder replaced
setup
( cd "$CWD" && bash "$FLOW" start "demo task" >/dev/null )
out="$(run '{"prompt":"hello","cwd":"'"$CWD"'"}')"
want_sub "active flow -> stage orders" "FLOW[plan 1/5]" "$out"
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
  bash "$FLOW" advance >/dev/null    # plan -> plan-review
  bash "$FLOW" advance >/dev/null    # plan-review -> exec
)
out="$(run '{"prompt":"continue","cwd":"'"$CWD"'"}')"
want_sub "exec injection cites plan path" "docs/plans/demo.md" "$out"
want_sub "exec injection shows exec stage" "FLOW[exec 3/5]" "$out"
( cd "$CWD" && bash "$FLOW" abort >/dev/null )
teardown

# corrupt stage value -> no stage injection, falls through to idle gate
setup
mkdir -p "$HOME/.claude/sspower"
printf '{"version":1,"flows":{"%s":{"stage":"bogus","task":"x"}}}\n' "$CWD" \
  > "$HOME/.claude/sspower/flow-state.json"
out="$(run '{"prompt":"just a question?","cwd":"'"$CWD"'"}')"
want_empty "unknown stage -> no FLOW injection" "$(printf '%s' "$out" | grep -F 'FLOW[' || true)"
teardown

echo "---"
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
