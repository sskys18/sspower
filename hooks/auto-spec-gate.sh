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
SUBCMD=$(printf '%s' "$PARSED" | jq -r '.subcommand' 2>/dev/null)
COMMIT_ALL=$(printf '%s' "$PARSED" | jq -r '.commit_all' 2>/dev/null)
# Pathspecs given on the command line (e.g. `git commit docs/plans/x.md`).
# `git commit <path>...` stages and commits those paths from the working
# tree, bypassing the index for everything else.
PATHSPECS=$(printf '%s' "$PARSED" | jq -r '.commit_pathspecs[]?' 2>/dev/null)
if [ "$SUBCMD" != "commit" ]; then
  exit 0
fi

# Plan markdown that this commit will record. Sources:
#   - index (`git diff --cached`)             always counted
#   - working tree if `-a`/--all              auto-staged at commit time
#   - working tree for explicit pathspecs     `git commit foo.md`
PLAN_RX='(^|/)docs/plans/[^/]+\.md$'
STAGED=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null \
  | grep -E "$PLAN_RX" || true)
if [ "$COMMIT_ALL" = "true" ]; then
  UNSTAGED=$(git diff --name-only --diff-filter=ACM 2>/dev/null \
    | grep -E "$PLAN_RX" || true)
  STAGED=$(printf '%s\n%s\n' "$STAGED" "$UNSTAGED")
fi
# Add pathspec'd plan files. We accept anything matching the regex,
# even if not currently tracked (e.g. new plan being added by name).
if [ -n "$PATHSPECS" ]; then
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    if printf '%s\n' "$p" | grep -Eq "$PLAN_RX"; then
      STAGED=$(printf '%s\n%s\n' "$STAGED" "$p")
    fi
  done <<< "$PATHSPECS"
fi
STAGED=$(printf '%s\n' "$STAGED" | awk 'NF && !seen[$0]++')
if [ -z "$STAGED" ]; then
  exit 0
fi
# Pathspec commits source from working tree, same as -a.
if [ -n "$PATHSPECS" ]; then
  COMMIT_ALL=true
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
