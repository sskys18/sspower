#!/usr/bin/env bash
# sspower auto plan-review hook (PreToolUse:Bash)
#
# Fires before `git commit`. Asks git itself (`git commit --dry-run
# --porcelain --no-verify <args>`) which files THIS specific commit
# would record. If any of those are plan markdown (docs/plans/*.md),
# runs Codex `review` and blocks the commit unless the verdict is
# `approve`.
#
# Asking git is the only sound way to handle the full surface of
# commit semantics: -a, -i / --include, -o / --only, pathspec
# directories and globs, --pathspec-from-file, etc. All previous
# attempts to predict this from the bash command string left
# bypassable gaps; git is the oracle.
#
# Pairs with auto-review.sh which gates at push/PR time.
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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PARSED=$(printf '%s' "$CMD" | python3 "$SCRIPT_DIR/_parse-git-cmd.py" 2>/dev/null)
SUBCMD=$(printf '%s' "$PARSED" | jq -r '.subcommand' 2>/dev/null)
WORK_DIR=$(printf '%s' "$PARSED" | jq -r '.work_dir' 2>/dev/null)
if [ "$SUBCMD" != "commit" ]; then
  exit 0
fi

# A user-typed `git commit --dry-run` shouldn't trigger a real review --
# they're already only previewing.
if printf '%s' "$PARSED" | jq -e '.subcommand_args | index("--dry-run")' >/dev/null 2>&1; then
  exit 0
fi

# Reconstruct the commit args (everything after `commit`) into a bash
# array, preserving shell-quoted whitespace.
COMMIT_ARGS=()
while IFS= read -r arg; do
  COMMIT_ARGS+=("$arg")
done < <(printf '%s' "$PARSED" | jq -r '.subcommand_args[]?')

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

REPO_ROOT=$(git_in_repo rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$REPO_ROOT" ]; then
  exit 0
fi

# Ask git what THIS commit would record. Porcelain v1 output:
#   XY filename
# X = index status, Y = working-tree status. Files that will be
# committed have X in [ACDMRTU] (i.e. not space, not '?').
PLAN_RX='(^|/)docs/plans/[^/]+\.md$'
DRY=""
if [ ${#COMMIT_ARGS[@]} -gt 0 ]; then
  DRY=$(git_in_repo commit --dry-run --porcelain --no-verify "${COMMIT_ARGS[@]}" 2>/dev/null || true)
else
  DRY=$(git_in_repo commit --dry-run --porcelain --no-verify 2>/dev/null || true)
fi

# Pull names of files whose first column indicates "in this commit".
# `awk '/^[ACDMRTU]/ {print substr($0,4)}'` keeps everything from col 4
# onward, which is the path (handles spaces in filenames; rename
# entries `R  old -> new` are uncommon in commits but the trailing
# `-> new` would still get matched against PLAN_RX).
PLANS=$(printf '%s\n' "$DRY" | awk '/^[ACDMRTU]/ {print substr($0,4)}' | grep -E "$PLAN_RX" || true)

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
  # Read the exact bytes git would record. For staged-only files this
  # is `git show :file`. For files staged by --dry-run from worktree
  # (because of -a, pathspec, -i, etc.), git's index reflects the
  # post-stage state for the duration of the dry-run only -- so we
  # always source from the working tree when a worktree-affecting flag
  # is present, with symlink and out-of-repo guards.
  STAGED_FILE=$(mktemp -t sspower-spec-staged-XXXXXX)
  USE_WORKTREE=0
  case " ${COMMIT_ARGS[*]:-} " in
    *" -a "*|*" --all "*|*" -am "*|*" -avm "*|*" -i "*|*" --include "*|*" -o "*|*" --only "*|*" --patch "*|*" -p "*)
      USE_WORKTREE=1 ;;
  esac
  # Pathspec (positional, non-flag arg) also implies worktree source.
  if [ "$USE_WORKTREE" -eq 0 ]; then
    saw_dashdash=0
    for a in "${COMMIT_ARGS[@]:-}"; do
      if [ "$saw_dashdash" -eq 1 ]; then USE_WORKTREE=1; break; fi
      case "$a" in
        --) saw_dashdash=1 ;;
        --*=*) ;;
        --*|-*) ;;
        *) USE_WORKTREE=1; break ;;
      esac
    done
  fi

  if [ "$USE_WORKTREE" -eq 1 ]; then
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
    REAL=$(python3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$ABS" 2>/dev/null)
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
Review the plan at $STAGED_FILE (committed version of $f).
Flag missing acceptance criteria, ambiguous steps, unstated assumptions,
risk gaps, contradictions, and unspecified verification. Out of scope:
stylistic prose nits. If sound, return verdict approve.
EOF

  RESULT=$(node "$BRIDGE" review --prompt "@$PROMPT" 2>/dev/null || true)
  rm -f "$PROMPT" "$STAGED_FILE"

  if [ -z "$RESULT" ]; then
    echo "[auto-spec-gate] WARNING: codex review failed for $f; allowing commit." >&2
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

REASON=$(printf 'Codex review blocked this commit (plan files).%s\n\nFix the issues, restage, recommit. Bypass: SSPOWER_AUTO_REVIEW=off only for emergencies.' "$ISSUES")

jq -n --arg reason "$REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
exit 0
