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

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Resolve the git subcommand robustly (handles `git -c X commit`,
# `git --no-pager commit`, `FOO=bar git commit`, etc.). Pipelines and
# subshells are intentionally allowed through as caller-side bypass.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./_git-cmd-detect.sh
. "$SCRIPT_DIR/_git-cmd-detect.sh"
SUBCMD=$(git_subcommand "$CMD")
if [ "$SUBCMD" != "commit" ]; then
  exit 0
fi

# Staged plan markdown only.
STAGED=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null \
  | grep -E '(^|/)docs/plans/[^/]+\.md$' || true)
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
  # Review the staged version, not the working tree.
  STAGED_FILE=$(mktemp -t sspower-spec-staged-XXXXXX)
  if ! git show ":$f" > "$STAGED_FILE" 2>/dev/null; then
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
