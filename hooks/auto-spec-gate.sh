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
WORK_DIR=$(printf '%s' "$PARSED" | jq -r '.work_dir' 2>/dev/null)
# Pathspecs given on the command line (e.g. `git commit docs/plans/x.md`).
# Pathspec commits stage + commit ONLY the listed paths -- index entries
# outside the pathspec are NOT included. So when pathspecs are present
# we must ignore the index and look only at the pathspec set.
PATHSPECS=$(printf '%s' "$PARSED" | jq -r '.commit_pathspecs[]?' 2>/dev/null)
if [ "$SUBCMD" != "commit" ]; then
  exit 0
fi

# All git invocations target the repo named by -C / --git-dir if given;
# otherwise the hook's current cwd. `git -C ""` is invalid, so guard.
GIT_OPTS=()
if [ -n "$WORK_DIR" ]; then
  GIT_OPTS+=(-C "$WORK_DIR")
fi
git_in_repo() {
  # Bash 3.2 + `set -u` treats `"${ARR[@]}"` on an empty array as
  # unbound. Guard explicitly.
  if [ ${#GIT_OPTS[@]} -gt 0 ]; then
    git "${GIT_OPTS[@]}" "$@"
  else
    git "$@"
  fi
}
# Resolve the absolute repo root for safe symlink checks below.
REPO_ROOT=$(git_in_repo rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$REPO_ROOT" ]; then
  exit 0
fi

# Plan markdown that this commit will RECORD. Three modes:
#   1. pathspec form  (git commit <path>...): ONLY pathspec'd files
#      land. Index entries outside the pathspec are NOT in this commit.
#   2. -a / --all     : working tree of every tracked modified file.
#   3. plain commit   : the index, exactly.
PLAN_RX='(^|/)docs/plans/[^/]+\.md$'
SOURCE_MODE=index   # one of: index, worktree
PLANS=""

if [ -n "$PATHSPECS" ]; then
  # Mode 1: pathspecs only. Source = working tree.
  SOURCE_MODE=worktree
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    # Reject pathspec magic, parent escapes, absolute paths -- we don't
    # try to resolve those safely.
    case "$p" in
      :\(*) continue ;;
      /*) continue ;;
      *..*) continue ;;
    esac
    if printf '%s\n' "$p" | grep -Eq "$PLAN_RX"; then
      PLANS=$(printf '%s\n%s\n' "$PLANS" "$p")
    fi
  done <<< "$PATHSPECS"
else
  PLANS=$(git_in_repo diff --cached --name-only --diff-filter=ACM 2>/dev/null \
    | grep -E "$PLAN_RX" || true)
  if [ "$COMMIT_ALL" = "true" ]; then
    SOURCE_MODE=worktree
    UNSTAGED=$(git_in_repo diff --name-only --diff-filter=ACM 2>/dev/null \
      | grep -E "$PLAN_RX" || true)
    PLANS=$(printf '%s\n%s\n' "$PLANS" "$UNSTAGED")
  fi
fi

PLANS=$(printf '%s\n' "$PLANS" | awk 'NF && !seen[$0]++')
if [ -z "$PLANS" ]; then
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
  # Review the exact bytes this commit will record. SOURCE_MODE drives
  # where we read from. For worktree-sourced files, refuse symlinks --
  # an attacker (or an honest mistake) could point a plan path at
  # /etc/passwd, ~/.aws/credentials, etc., and we'd ship those bytes
  # to Codex.
  STAGED_FILE=$(mktemp -t sspower-spec-staged-XXXXXX)
  if [ "$SOURCE_MODE" = "worktree" ]; then
    ABS="$REPO_ROOT/$f"
    if [ -L "$ABS" ]; then
      echo "[auto-spec-gate] WARNING: refusing symlink at $f; skipping." >&2
      rm -f "$STAGED_FILE"
      continue
    fi
    if [ ! -f "$ABS" ]; then
      rm -f "$STAGED_FILE"
      continue
    fi
    # Verify the resolved path is still inside the repo (defence in
    # depth: the pathspec regex already rejected `..` and absolute
    # paths, but a tracked file could still be a regular file with a
    # name like `docs/plans/x.md` that resolves outside via a parent
    # symlink. We check the directory chain.)
    REAL=$(cd "$REPO_ROOT" && python3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$ABS" 2>/dev/null)
    case "$REAL" in
      "$REPO_ROOT"/*) ;;
      *) echo "[auto-spec-gate] WARNING: $f resolves outside repo; skipping." >&2
         rm -f "$STAGED_FILE"
         continue ;;
    esac
    cp -P "$ABS" "$STAGED_FILE" || { rm -f "$STAGED_FILE"; continue; }
  else
    if ! git_in_repo show ":$f" > "$STAGED_FILE" 2>/dev/null; then
      rm -f "$STAGED_FILE"
      continue
    fi
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
done <<< "$PLANS"

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
