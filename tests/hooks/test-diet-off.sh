#!/usr/bin/env bash
# Verifies the SSPOWER_DIET=off permanent kill switch (Track B P6 C8).
#
# Both diet hooks emit the "DIET MODE ACTIVE" directive:
#   - diet-activate.js  (SessionStart) — plain text
#   - diet-track.js     (UserPromptSubmit) — JSON additionalContext
# SSPOWER_DIET=off must make BOTH inert (no directive, exit 0); unset
# must produce the normal directive.
#
# Hermetic: each node invocation runs in a subprocess with
# CLAUDE_CONFIG_DIR pointed at a throwaway dir so the persistent diet
# flag (~/.claude/sspower/config.json) is never touched.

set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOKS="$ROOT/hooks"

PASS=0
FAIL=0

assert() {
  local label="$1" cond="$2"
  if [ "$cond" -eq 1 ]; then
    echo "  ok   $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL $label"
    FAIL=$((FAIL + 1))
  fi
}

MARKER='DIET MODE ACTIVE'
SANDBOX=$(mktemp -d -t sspower-dietoff-XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT

# --- diet-activate.js -------------------------------------------------------
echo "[diet-activate.js]"

# (1) SSPOWER_DIET=off -> no directive.
out=$(CLAUDE_CONFIG_DIR="$SANDBOX/a1" SSPOWER_DIET=off \
  node "$HOOKS/diet-activate.js" </dev/null 2>&1); rc=$?
assert "off: exit 0" "$([ "$rc" -eq 0 ] && echo 1 || echo 0)"
assert "off: no marker" \
  "$(printf '%s' "$out" | grep -qF "$MARKER" && echo 0 || echo 1)"
assert "off: empty stdout" \
  "$([ -z "$out" ] && echo 1 || echo 0)"

# (2) unset -> normal directive present.
out=$(CLAUDE_CONFIG_DIR="$SANDBOX/a2" node "$HOOKS/diet-activate.js" \
  </dev/null 2>&1); rc=$?
assert "unset: exit 0" "$([ "$rc" -eq 0 ] && echo 1 || echo 0)"
assert "unset: marker present" \
  "$(printf '%s' "$out" | grep -qF "$MARKER" && echo 1 || echo 0)"

# --- diet-track.js ----------------------------------------------------------
echo "[diet-track.js]"

# (3) SSPOWER_DIET=off -> no directive even with an activation prompt.
out=$(printf '{"prompt":"be terse"}' \
  | CLAUDE_CONFIG_DIR="$SANDBOX/t1" SSPOWER_DIET=off \
    node "$HOOKS/diet-track.js" 2>&1); rc=$?
assert "off: exit 0" "$([ "$rc" -eq 0 ] && echo 1 || echo 0)"
assert "off: no marker" \
  "$(printf '%s' "$out" | grep -qF "$MARKER" && echo 0 || echo 1)"
assert "off: empty stdout" \
  "$([ -z "$out" ] && echo 1 || echo 0)"

# (4) unset -> directive present. The "/diet full" prompt writes the
# active flag then the same invocation reads it back and emits the
# per-turn reinforcement (sandboxed config dir, real user config
# untouched).
out=$(printf '{"prompt":"/diet full"}' \
  | CLAUDE_CONFIG_DIR="$SANDBOX/t2" node "$HOOKS/diet-track.js" 2>&1); rc=$?
assert "unset: exit 0" "$([ "$rc" -eq 0 ] && echo 1 || echo 0)"
assert "unset: marker present" \
  "$(printf '%s' "$out" | grep -qF "$MARKER" && echo 1 || echo 0)"

echo
echo "passed: $PASS"
echo "failed: $FAIL"
[ "$FAIL" -eq 0 ]
