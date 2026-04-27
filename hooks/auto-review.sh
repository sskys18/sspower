#!/usr/bin/env bash
# sspower auto-review hook (PreToolUse:Bash)
#
# Fires before every Bash call. Only acts when the command is a `git push`.
# Runs a Codex review of the branch diff vs upstream (or main) and blocks
# the push if the verdict is not `approve`.
#
# Bypass: set SSPOWER_AUTO_REVIEW=off in the env. Useful for emergencies
# and for the hook's own self-tests.
#
# Requires: jq, node, the codex-bridge.mjs script alongside the plugin.

set -u

# Bypass switch.
if [ "${SSPOWER_AUTO_REVIEW:-on}" = "off" ]; then
  exit 0
fi

if ! command -v jq &>/dev/null; then
  exit 0
fi
if ! command -v node &>/dev/null; then
  exit 0
fi

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only intercept `git push` invocations. Match the leading token; ignore
# pipelines/subshells where push is buried.
if ! echo "$CMD" | grep -Eq '^[[:space:]]*git[[:space:]]+push(\b|$)'; then
  exit 0
fi

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
BRIDGE="$PLUGIN_ROOT/scripts/codex-bridge.mjs"
if [ ! -f "$BRIDGE" ]; then
  exit 0
fi

# Determine base branch for diff. Prefer upstream; fall back to main/master.
BASE=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
if [ -z "$BASE" ]; then
  for cand in main master; do
    if git show-ref --verify --quiet "refs/heads/$cand"; then BASE="$cand"; break; fi
  done
fi
if [ -z "$BASE" ]; then
  # Nothing to compare against; let the push through.
  exit 0
fi

DIFF_FILE=$(mktemp -t sspower-autoreview-XXXXXX)
trap 'rm -f "$DIFF_FILE"' EXIT

if ! git diff "$BASE"..HEAD > "$DIFF_FILE" 2>/dev/null; then
  exit 0
fi
if [ ! -s "$DIFF_FILE" ]; then
  # Empty diff (push of merged work, etc.) — nothing to review.
  exit 0
fi

PROMPT_FILE=$(mktemp -t sspower-autoreview-prompt-XXXXXX)
cat > "$PROMPT_FILE" <<EOF
Review the branch diff at $DIFF_FILE before push. Flag bugs, regressions,
missing tests, and security issues. Do NOT propose stylistic refactors or
unrequested features. If everything is fine, return verdict approve.
EOF

# Run bridge synchronously. Capture structured output.
RESULT=$(node "$BRIDGE" review --prompt "@$PROMPT_FILE" 2>/dev/null || true)
rm -f "$PROMPT_FILE"

if [ -z "$RESULT" ]; then
  # Bridge failed (codex offline, model error, etc.). Fail open with a
  # warning to stderr; do not block the push.
  echo "[auto-review] WARNING: codex review failed; allowing push without review." >&2
  exit 0
fi

VERDICT=$(echo "$RESULT" | jq -r '.verdict // empty' 2>/dev/null)
if [ "$VERDICT" = "approve" ]; then
  exit 0
fi

# Build a deny payload with the issues summary so Claude sees why.
SUMMARY=$(echo "$RESULT" | jq -r '
  if (.issues // [] | length) == 0 then
    "verdict: " + (.verdict // "unknown")
  else
    "verdict: " + (.verdict // "unknown") + "\n" +
    (.issues | map("- [" + (.severity // "?") + "] " + (.title // "untitled")) | join("\n"))
  end
' 2>/dev/null)

REASON=$(printf 'Codex auto-review blocked this push.\n%s\n\nFix the issues, commit, and try again. Bypass with SSPOWER_AUTO_REVIEW=off only for emergencies.' "$SUMMARY")

jq -n --arg reason "$REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
exit 0
