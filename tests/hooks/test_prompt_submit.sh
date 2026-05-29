#!/usr/bin/env bash
# Tests for hooks/prompt-submit v2 - workflow-engine routing.
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

# idle Q&A -> silent
setup; out="$(run '{"prompt":"what is a closure?","cwd":"'"$CWD"'"}')"
empty "idle Q&A -> silent" "$out"; teardown

# malformed payload -> legacy reminder
setup; out="$(run 'not json at all')"
sub "malformed -> reminder" "check which skills apply" "$out"; teardown

# empty prompt -> legacy reminder
setup; out="$(run '{"prompt":"","cwd":"'"$CWD"'"}')"
sub "empty prompt -> reminder" "check which skills apply" "$out"; teardown

# explicit skill -> short confirmation, NOT catalog
setup; out="$(run '{"prompt":"use writing-plans for this","cwd":"'"$CWD"'"}')"
sub  "explicit-skill -> confirmation" "you named a skill" "$out"
no_sub "explicit-skill -> no catalog" "check which skills apply" "$out"; teardown

# simple-coding bug -> debugging trigger
setup; out="$(run '{"prompt":"the parser is broken","cwd":"'"$CWD"'"}')"
sub "bug -> debugging trigger" "systematic-debugging" "$out"; teardown

# multi-step -> auto-start flow
setup
out="$(run '{"prompt":"implement a retry layer with backoff and jitter for the api client","cwd":"'"$CWD"'"}')"
sub "multi-step -> AUTO-FLOW" "AUTO-FLOW" "$out"
sub "multi-step -> plan stage" "FLOW[plan 2/7]" "$out"
( cd "$CWD" && bash "$FLOW" abort >/dev/null 2>&1 ); teardown

# quick: suppresses auto-start
setup
out="$(run '{"prompt":"quick: implement a retry layer with backoff and jitter now","cwd":"'"$CWD"'"}')"
no_sub "quick: -> no auto-flow" "AUTO-FLOW" "$out"
( cd "$CWD" && bash "$FLOW" abort >/dev/null 2>&1 ); teardown

# quick: + Q&A stays silent
setup; out="$(run '{"prompt":"quick: what is a closure?","cwd":"'"$CWD"'"}')"
empty "quick: + Q&A -> silent" "$out"; teardown

# active flow -> stage orders win, no classification
setup
( cd "$CWD" && bash "$FLOW" start "demo task" >/dev/null )
out="$(run '{"prompt":"what is a closure?","cwd":"'"$CWD"'"}')"
sub "active flow -> orders" "FLOW[plan 2/7]" "$out"
( cd "$CWD" && bash "$FLOW" abort >/dev/null ); teardown

# active flow wins even with an empty prompt (flow spine sacrosanct)
setup
( cd "$CWD" && bash "$FLOW" start "demo task" >/dev/null )
out="$(run '{"prompt":"","cwd":"'"$CWD"'"}')"
sub "active flow + empty prompt -> orders" "FLOW[plan 2/7]" "$out"
( cd "$CWD" && bash "$FLOW" abort >/dev/null ); teardown

# auto-start failure -> falls back to the targeted trigger, not a flow.
# Force failure: make the state file a directory so flow.sh start dies.
setup
mkdir -p "$HOME/.claude/sspower/flow-state.json"
out="$(run '{"prompt":"implement a retry layer with backoff and jitter for the api client","cwd":"'"$CWD"'"}')"
no_sub "autostart-fail -> no AUTO-FLOW" "AUTO-FLOW" "$out"
sub    "autostart-fail -> targeted trigger" "test-driven-development" "$out"
teardown

echo "---"
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
