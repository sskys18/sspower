#!/usr/bin/env bash
# Run skill-triggering checks.
# Default: deterministic description-coverage lint (no model spawn, no billing).
# Set SSPOWER_LIVE_SKILL_TRIGGERING=1 for the legacy live `claude -p` run.
# Usage: ./run-all.sh
#   SSPOWER_LIVE_SKILL_TRIGGERING=1 ./run-all.sh   # rare live behavior check

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${SSPOWER_LIVE_SKILL_TRIGGERING:-0}" != "1" ]; then
    exec "$SCRIPT_DIR/test-description-coverage.sh"
fi

PROMPTS_DIR="$SCRIPT_DIR/prompts"

SKILLS=(
    "systematic-debugging"
    "test-driven-development"
    "writing-plans"
    "dispatching-parallel-agents"
    "orchestrating-workflows"
    "executing-plans"
    "requesting-code-review"
)

echo "=== Running Skill Triggering Tests ==="
echo ""

PASSED=0
FAILED=0
RESULTS=()

for skill in "${SKILLS[@]}"; do
    prompt_file="$PROMPTS_DIR/${skill}.txt"

    if [ ! -f "$prompt_file" ]; then
        echo "⚠️  SKIP: No prompt file for $skill"
        continue
    fi

    echo "Testing: $skill"

    if "$SCRIPT_DIR/run-test.sh" "$skill" "$prompt_file" 3 2>&1 | tee /tmp/skill-test-$skill.log; then
        PASSED=$((PASSED + 1))
        RESULTS+=("✅ $skill")
    else
        FAILED=$((FAILED + 1))
        RESULTS+=("❌ $skill")
    fi

    echo ""
    echo "---"
    echo ""
done

echo ""
echo "=== Summary ==="
for result in "${RESULTS[@]}"; do
    echo "  $result"
done
echo ""
echo "Passed: $PASSED"
echo "Failed: $FAILED"

if [ $FAILED -gt 0 ]; then
    exit 1
fi
