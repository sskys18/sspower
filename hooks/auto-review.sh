#!/usr/bin/env bash
# sspower auto-review hook (PreToolUse:Bash)
#
# Fires before every Bash call. Acts when the command is a chokepoint:
#   - `git push ...`         (local -> remote)
#   - `gh pr create ...`     (open PR)
#   - `gh pr ready ...`      (mark draft PR ready for review)
# Runs a Codex review of the branch diff vs upstream (or main) and blocks
# the action if the verdict is not `approve`.
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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./_git-cmd-detect.sh
. "$SCRIPT_DIR/_git-cmd-detect.sh"
SUBCMD=$(git_subcommand "$CMD")

# Chokepoints: git push, git merge (local merge into main bypasses push),
# gh pr create / ready. Pipelines/subshells deliberately allowed through.
TRIGGER=0
case "$SUBCMD" in
  push|merge) TRIGGER=1 ;;
esac
if [ "$TRIGGER" -eq 0 ] && echo "$CMD" | grep -Eq '^[[:space:]]*gh[[:space:]]+pr[[:space:]]+(create|ready)([[:space:]]|$)'; then
  TRIGGER=1
fi
if [ "$TRIGGER" -eq 0 ]; then
  exit 0
fi

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
BRIDGE="$PLUGIN_ROOT/scripts/codex-bridge.mjs"
if [ ! -f "$BRIDGE" ]; then
  exit 0
fi

# Determine the diff range.
# - For push / gh pr: review what HEAD adds over upstream (or main/master).
# - For merge: review what the source branch will add over current HEAD.
DIFF_FILE=$(mktemp -t sspower-autoreview-XXXXXX)
trap 'rm -f "$DIFF_FILE"' EXIT

if [ "$SUBCMD" = "merge" ]; then
  # Extract the first positional arg (branch/ref to merge in).
  MERGE_SRC=""
  # shellcheck disable=SC2086
  set -- $CMD
  saw_subcmd=0
  for tok in "$@"; do
    if [ "$saw_subcmd" -eq 0 ]; then
      [ "$tok" = "merge" ] && saw_subcmd=1
      continue
    fi
    case "$tok" in
      -*) continue ;;
      *) MERGE_SRC="$tok"; break ;;
    esac
  done
  if [ -z "$MERGE_SRC" ] || ! git rev-parse --verify --quiet "$MERGE_SRC" >/dev/null; then
    # Can't resolve target (e.g. `git merge --abort`, `git merge --continue`,
    # or a missing arg). Don't block.
    exit 0
  fi
  if ! git diff "HEAD...$MERGE_SRC" > "$DIFF_FILE" 2>/dev/null; then
    exit 0
  fi
else
  BASE=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
  if [ -z "$BASE" ]; then
    for cand in main master; do
      if git show-ref --verify --quiet "refs/heads/$cand"; then BASE="$cand"; break; fi
    done
  fi
  if [ -z "$BASE" ]; then
    # Nothing to compare against; let the action through.
    exit 0
  fi
  if ! git diff "$BASE"..HEAD > "$DIFF_FILE" 2>/dev/null; then
    exit 0
  fi
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

REASON=$(printf 'Codex auto-review blocked this push/PR.\n%s\n\nFix the issues, commit, and try again. Bypass with SSPOWER_AUTO_REVIEW=off only for emergencies.' "$SUMMARY")

jq -n --arg reason "$REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
exit 0
