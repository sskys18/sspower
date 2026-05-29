#!/usr/bin/env bash
# Tests for hooks/_intent.sh - classifier + target-trigger truth tables.
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
ci "<task-notification> implement a retry layer with backoff</task-notification>" \
                                        qa             "qa: system tag not classified"
ci "<system-reminder>refactor and migrate the whole module</system-reminder>" \
                                        qa             "qa: system-reminder not classified"

# --- classify: explicit-skill ---
ci "use systematic-debugging to dig in" explicit-skill "skill: bare name"
ci "invoke sspower:writing-plans"       explicit-skill "skill: sspower: prefix"
ci "run receiving-code-review on this"  explicit-skill "skill: globbed name"
ci "what skill should I learn next?"    qa             "skill: NEG bare 'skill'"

# --- classify: simple-coding ---
ci "fix the auth bug"                   simple-coding  "simple: bug fix"
ci "rename the helper function"         simple-coding  "simple: rename"
ci "review this design doc"             simple-coding  "simple: review-class guard"
ci "implement it"                       simple-coding  "simple: multi verb but short"

# --- classify: multi-step ---
ci "implement a retry layer with backoff and jitter for the api client" \
                                        multi-step     "multi: long + verb"
ci "refactor the auth module, then add token rotation" \
                                        multi-step     "multi: multi-clause"

# --- classify: design (narrow ideation framing) ---
ci "design a cache layer"                      design       "design: 'design a cache layer'"
ci "how should we structure the auth module"   design       "design: structure framing"
ci "brainstorm options for the cache layer"    design       "design: brainstorm framing"
ci "build the login page and wire the api"     multi-step   "design NEG: bare build stays multi-step"
ci "what calls foo"                            architecture "design NEG: architecture stays flow-free"
ci "review this design doc"                    simple-coding "design NEG: review guard wins"

# --- target_trigger ---
tt "the parser is broken"               debugging      "trig: debugging"
tt "tests fail after the merge"         debugging      "trig: test-fail"
tt "review this PR diff"                code-review    "trig: code-review"
tt "review this implementation diff"    code-review    "trig: impl diff -> code-review"
tt "review this implementation plan"    none           "trig: impl plan -> none"
tt "review the spec for me"             none           "trig: review spec -> none"
tt "approve this plan"                  none           "trig: approve plan -> none"
tt "brainstorm options for caching"     brainstorming  "trig: brainstorm"
tt "how should I structure this module" planning       "trig: planning"
tt "add an export button"               tdd            "trig: tdd"
tt "tweak the css padding"              none           "trig: generic -> none"

echo "---"
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
