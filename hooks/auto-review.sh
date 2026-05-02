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
if ! command -v python3 &>/dev/null; then
  exit 0
fi

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PARSED=$(printf '%s' "$CMD" | python3 "$SCRIPT_DIR/_parse-git-cmd.py" 2>/dev/null)
SUBCMD=$(printf '%s' "$PARSED" | jq -r '.subcommand // empty' 2>/dev/null)
WORK_DIR=$(printf '%s' "$PARSED" | jq -r '.work_dir // empty' 2>/dev/null)
# Octopus-safe: collect EVERY positional ref after `merge`, not just
# the first one.
MERGE_SOURCES=()
while IFS= read -r r; do
  [ -n "$r" ] && MERGE_SOURCES+=("$r")
done < <(printf '%s' "$PARSED" | jq -r '.merge_sources[]?')
GIT_OPTS=()
if [ -n "$WORK_DIR" ]; then
  GIT_OPTS+=(-C "$WORK_DIR")
fi
git_in_repo() {
  if [ ${#GIT_OPTS[@]} -gt 0 ]; then
    git "${GIT_OPTS[@]}" "$@"
  else
    git "$@"
  fi
}

# Chokepoints: git push, git merge (local merge bypasses push), gh pr
# create / ready. Pipelines/subshells deliberately allowed through.
TRIGGER=0
case "$SUBCMD" in
  push|merge) TRIGGER=1 ;;
esac
# `gh pr create|ready` doesn't go through `git`, so detect via shlex too.
GH_SUB=$(printf '%s' "$CMD" | python3 -c '
import json, shlex, sys
try:
    toks = shlex.split(sys.stdin.read(), posix=True)
except ValueError:
    toks = []
while toks and "=" in toks[0] and not toks[0].startswith("-") and toks[0][0].isalpha():
    toks.pop(0)
sub = ""
if len(toks) >= 3 and toks[0] == "gh" and toks[1] == "pr" and toks[2] in ("create", "ready"):
    sub = toks[2]
print(sub)
' 2>/dev/null)
if [ -n "$GH_SUB" ]; then
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
  # No resolvable refs (e.g. `git merge --abort`, `--continue`, missing
  # arg) -> let the action through, nothing to review.
  if [ ${#MERGE_SOURCES[@]} -eq 0 ]; then
    exit 0
  fi
  : > "$DIFF_FILE"
  REVIEWABLE=0
  for src in "${MERGE_SOURCES[@]}"; do
    if ! git_in_repo rev-parse --verify --quiet "$src" >/dev/null; then
      continue
    fi
    {
      echo
      echo "=== merging $src ==="
      git_in_repo diff "HEAD...$src" 2>/dev/null || true
    } >> "$DIFF_FILE"
    REVIEWABLE=1
  done
  if [ "$REVIEWABLE" -eq 0 ]; then
    exit 0
  fi
else
  BASE=$(git_in_repo rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
  if [ -z "$BASE" ]; then
    for cand in main master; do
      if git_in_repo show-ref --verify --quiet "refs/heads/$cand"; then BASE="$cand"; break; fi
    done
  fi
  if [ -z "$BASE" ]; then
    # Nothing to compare against; let the action through.
    exit 0
  fi
  if ! git_in_repo diff "$BASE"..HEAD > "$DIFF_FILE" 2>/dev/null; then
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
