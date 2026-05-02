#!/usr/bin/env bash
# sspower auto plan-review hook (PreToolUse:Bash)
#
# Fires before `git commit`. If staged files include plan markdown
# (docs/plans/*.md), runs Codex `review` (quality-review schema) on each
# and blocks the commit if any verdict is not `approve`. Pairs with
# auto-review.sh which gates at push/PR time.
#
# We use `review` not `spec-review` here because spec-review's schema
# (compliant/non-compliant) is for spec-vs-impl comparison; a standalone
# plan critique fits the quality-review verdict enum (approve/
# needs-attention).
#
# Bypass: SSPOWER_AUTO_REVIEW=off (emergencies only).

set -u

if [ "${SSPOWER_AUTO_REVIEW:-on}" = "off" ]; then
  exit 0
fi
command -v jq >/dev/null 2>&1 || exit 0
command -v node >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Parse the bash command with shell-aware tokenisation. Handles
# `git -c "user.name=foo bar" commit`, `FOO="a b" git commit`,
# `git commit -a`/`-am`, etc. Pipelines and subshells are intentionally
# treated as caller-side bypass.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PARSED=$(printf '%s' "$CMD" | python3 "$SCRIPT_DIR/_parse-git-cmd.py" 2>/dev/null)
SUBCMD=$(printf '%s' "$PARSED" | jq -r '.subcommand // empty' 2>/dev/null)
COMMIT_ALL=$(printf '%s' "$PARSED" | jq -r '.commit_all // false' 2>/dev/null)
if [ "$SUBCMD" != "commit" ]; then
  exit 0
fi

# Plan markdown that this commit will record. For plain `git commit`,
# only the index counts. For `git commit -a`, also include unstaged
# tracked modifications since `-a` auto-stages them at commit time.
STAGED=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null \
  | grep -E '(^|/)docs/plans/[^/]+\.md$' || true)
if [ "$COMMIT_ALL" = "true" ]; then
  UNSTAGED=$(git diff --name-only --diff-filter=ACM 2>/dev/null \
    | grep -E '(^|/)docs/plans/[^/]+\.md$' || true)
  STAGED=$(printf '%s\n%s\n' "$STAGED" "$UNSTAGED" | awk 'NF && !seen[$0]++')
fi
if [ -z "$STAGED" ]; then
  exit 0
fi

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
BRIDGE="$PLUGIN_ROOT/scripts/codex-bridge.mjs"
if [ ! -f "$BRIDGE" ]; then
  exit 0
fi

ISSUES=""
ANY_FAIL=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  # Review the version that this commit will record:
  #   - `git commit -a` records the working-tree content of any tracked
  #     modified file (re-stages it). Always prefer working tree.
  #   - plain `git commit` records the index version.
  STAGED_FILE=$(mktemp -t sspower-spec-staged-XXXXXX)
  if [ "$COMMIT_ALL" = "true" ] && [ -f "$f" ]; then
    cp "$f" "$STAGED_FILE" || { rm -f "$STAGED_FILE"; continue; }
  elif ! git show ":$f" > "$STAGED_FILE" 2>/dev/null; then
    rm -f "$STAGED_FILE"
    continue
  fi

  PROMPT=$(mktemp -t sspower-spec-prompt-XXXXXX)
  cat > "$PROMPT" <<EOF
Review the plan at $STAGED_FILE (staged version of $f).
Flag missing acceptance criteria, ambiguous steps, unstated assumptions,
risk gaps, contradictions, and unspecified verification. Out of scope:
stylistic prose nits. If sound, return verdict approve.
EOF

  # Use 'review' (quality-review schema: approve/needs-attention) for
  # consistency with the push-time gate. spec-review schema uses
  # compliant/non-compliant and assumes spec-vs-impl comparison, which
  # doesn't fit a standalone plan critique.
  RESULT=$(node "$BRIDGE" review --prompt "@$PROMPT" 2>/dev/null || true)
  rm -f "$PROMPT" "$STAGED_FILE"

  if [ -z "$RESULT" ]; then
    # Bridge offline: fail open with stderr warning, skip this file.
    echo "[auto-spec-gate] WARNING: codex spec-review failed for $f; allowing commit." >&2
    continue
  fi

  V=$(echo "$RESULT" | jq -r '.verdict // empty' 2>/dev/null)
  if [ "$V" = "approve" ]; then
    continue
  fi

  ANY_FAIL=1
  SUMMARY=$(echo "$RESULT" | jq -r '
    if (.issues // [] | length) == 0 then
      "verdict: " + (.verdict // "unknown")
    else
      "verdict: " + (.verdict // "unknown") + "\n" +
      (.issues | map("- [" + (.severity // "?") + "] " + (.title // "untitled")) | join("\n"))
    end
  ' 2>/dev/null)
  ISSUES+=$'\n\n== '"$f"' =='$'\n'"$SUMMARY"
done <<< "$STAGED"

if [ "$ANY_FAIL" -eq 0 ]; then
  exit 0
fi

REASON=$(printf 'Codex spec-review blocked this commit (plan files).%s\n\nFix the issues, restage, recommit. Bypass: SSPOWER_AUTO_REVIEW=off only for emergencies.' "$ISSUES")

jq -n --arg reason "$REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
exit 0
