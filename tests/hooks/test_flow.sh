#!/usr/bin/env bash
# Tests for scripts/flow.sh - pipeline state machine transitions.
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

# start -> plan
setup
out="$(bash "$FLOW" start "my task")"
check "start sets plan stage" "flow: plan (1/6)" "$out"
check "start records task" "task: my task" "$out"

# back is rejected outside test/review/merge
out="$(bash "$FLOW" back 2>&1)"; rc=$?
check "back from plan refused" "valid only from test/review/merge" "$out"
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

# advance walks the pipeline - and surfaces the NEXT stage's orders
out="$(bash "$FLOW" advance)"
check "advance -> plan-review" "plan-review (2/6)" "$out"
check "advance surfaces next-stage orders" "Stage = PLAN-REVIEW" "$out"

# back still rejected from plan-review
out="$(bash "$FLOW" back 2>&1)"
check "back from plan-review refused" "valid only from test/review/merge" "$out"

out="$(bash "$FLOW" advance)"; check "advance -> exec"        "exec (3/6)"        "$out"
out="$(bash "$FLOW" advance)"; check "advance -> test"        "test (4/6)"        "$out"

# back -> exec (valid from test)
out="$(bash "$FLOW" back)"; check "back returns to exec" "exec (3/6)" "$out"

# back from merge -> exec (valid)
bash "$FLOW" advance >/dev/null   # exec -> test
bash "$FLOW" advance >/dev/null   # test -> review
bash "$FLOW" advance >/dev/null   # review -> merge
out="$(bash "$FLOW" back)"; check "back from merge returns to exec" "exec (3/6)" "$out"

# advance to review, then to merge, then past -> clears
bash "$FLOW" advance >/dev/null   # exec -> test
out="$(bash "$FLOW" advance)"; check "advance -> review" "review (5/6)" "$out"
out="$(bash "$FLOW" advance)"; check "advance -> merge"  "merge (6/6)"  "$out"
check "merge stage orders surfaced" "Stage = MERGE" "$out"
out="$(bash "$FLOW" advance)"; check "advance past merge clears" "complete" "$out"
out="$(bash "$FLOW" status)"; check "status idle after complete" "idle" "$out"
teardown

# abort clears mid-flow
setup
bash "$FLOW" start "abortme" >/dev/null
bash "$FLOW" set-plan "docs/plans/abort.md" >/dev/null
bash "$FLOW" advance >/dev/null
out="$(bash "$FLOW" abort)"; check "abort clears state" "aborted" "$out"
out="$(bash "$FLOW" status)"; check "status idle after abort" "idle" "$out"
teardown

# advance with no flow -> error
setup
out="$(bash "$FLOW" advance 2>&1)"; rc=$?
check "advance with no flow errors" "no active flow" "$out"
[ "$rc" -ne 0 ] && { PASS=$((PASS+1)); echo "ok   - no-flow advance exits nonzero"; } \
                || { FAIL=$((FAIL+1)); echo "FAIL - no-flow advance exits nonzero"; }
teardown

# advance from plan without a recorded plan_path -> rejected, stays in plan
setup
bash "$FLOW" start "needs a plan" >/dev/null
out="$(bash "$FLOW" advance 2>&1)"; rc=$?
check "advance without plan_path refused" "plan path required" "$out"
[ "$rc" -ne 0 ] && { PASS=$((PASS+1)); echo "ok   - advance-no-plan exits nonzero"; } \
                || { FAIL=$((FAIL+1)); echo "FAIL - advance-no-plan exits nonzero"; }
out="$(bash "$FLOW" status)"; check "stays in plan after refused advance" "plan (1/6)" "$out"
teardown

# concurrent starts from different cwds must not clobber each other
# (the .flow.lock mutex serializes the read-modify-write).
setup
conc_root="$TMP/conc"; mkdir -p "$conc_root"
for i in 1 2 3 4 5 6 7 8; do
  d="$conc_root/p$i"; mkdir -p "$d"
  ( cd "$d" && bash "$FLOW" start "task $i" >/dev/null 2>&1 ) &
done
wait
n="$(jq '.flows | length' "$HOME/.claude/sspower/flow-state.json" 2>/dev/null || echo 0)"
if [ "$n" = "8" ]; then PASS=$((PASS+1)); echo "ok   - 8 concurrent starts all persisted"
else FAIL=$((FAIL+1)); echo "FAIL - concurrent starts: want 8 flows, got $n"; fi
teardown

echo "---"
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
