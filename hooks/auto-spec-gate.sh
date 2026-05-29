#!/usr/bin/env bash
# sspower auto plan-review hook (PreToolUse:Bash)
#
# STATUS: INTENTIONALLY UNWIRED since c884a04 (decision D-A5). NOT registered in
# hooks.json — does not fire. Plan-review enforcement was repackaged as an
# explicit codex plan-review call inside the writing-plans / brainstorming
# skills (SKILL.md HARD-GATEs). This script is kept functional + e2e-tested
# (tests/hooks/auto-spec-gate-e2e.sh) as a re-wireable component. Do NOT re-wire
# without revisiting D-A5 (it would re-introduce the commit-time double-gate
# that was deliberately removed). See docs/specs/2026-05-29-hardened-autosteer-
# flow-design.md for the marker-based successor.
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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_log.sh
. "$SCRIPT_DIR/_log.sh"
trap '_sspower_exit_guard $? "0" hook.auto-spec-gate' EXIT

if [ "${SSPOWER_AUTO_REVIEW:-on}" = "off" ]; then
  exit 0
fi
# Re-entry guards: codex-bridge sets these before spawning, prevents recursion.
[ "${SSPOWER_REVIEW_IN_FLIGHT:-0}" = "1" ] && exit 0
[ "${SSPOWER_REVIEW_DEPTH:-0}" -ge 1 ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v node >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

PARSED=$(printf '%s' "$CMD" | python3 "$SCRIPT_DIR/_parse-git-cmd.py" 2>/dev/null)

# Locate the FIRST `git commit` invocation. Chains like `cd && git
# commit`, `(git commit)`, `env FOO=bar git commit` resolve here.
INV=$(printf '%s' "$PARSED" | jq -c '[.invocations[] | select(.tool=="git" and .subcommand=="commit")] | .[0] // empty' 2>/dev/null)
if [ -z "$INV" ]; then
  exit 0
fi

# CHAIN POLICY. Predecessors may modify worktree/index after this
# PreToolUse hook runs, leaving the review blind. Successors may also
# run conditionally on commit outcome. Allow only read-only output
# pipes after the chokepoint (`git commit ... 2>&1 | tee log`).
CHOKE_POS=$(printf '%s' "$INV" | jq -r '.chain_position // 0')

deny_chain() {
  local reason="$1"
  jq -n --arg reason "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

if [ "$CHOKE_POS" -gt 0 ]; then
  log_event warn hook.auto-spec-gate kind=deny_predecessor chain_position="$CHOKE_POS"
  deny_chain "Codex auto plan-review: a command preceding 'git commit' may modify worktree or index between this gate and the commit. Use 'git -C <path>' instead of 'cd <path> && git commit'. Run the commit as its own Bash call. Bypass: SSPOWER_AUTO_REVIEW=off only for emergencies."
fi

TAIL_VERDICT=$(printf '%s' "$PARSED" | jq -r --argjson pos "$CHOKE_POS" '
  ([.segments | to_entries[] | select(.key > $pos) | .value]) as $tail
  | if ($tail | length) == 0 then "ok"
    else
      ($tail
       | map(
           if (.op == "|" or .op == "|&") and .consumer_class == "readonly" then "ok"
           else "bad"
           end
         )
       | if any(. == "bad") then "bad" else "ok" end)
    end
' 2>/dev/null)

if [ "$TAIL_VERDICT" = "bad" ]; then
  log_event warn hook.auto-spec-gate kind=deny_successor chain_position="$CHOKE_POS"
  deny_chain "Codex auto plan-review: only read-only output pipes (tail/head/grep/jq/...) allowed after 'git commit'. Conditional/sequential operators (&&, ||, ;, &) leave the gate blind to outcome. Run the commit on its own line. Bypass: SSPOWER_AUTO_REVIEW=off."
fi

WORK_DIR=$(printf '%s' "$INV" | jq -r '.work_dir' 2>/dev/null)
USES_WORKTREE=$(printf '%s' "$INV" | jq -r '.commit_uses_worktree' 2>/dev/null)

# Skip user-typed `git commit --dry-run` (preview only).
if printf '%s' "$INV" | jq -e '.subcommand_args | index("--dry-run")' >/dev/null 2>&1; then
  exit 0
fi

# Reconstruct the commit args (everything after `commit`) into a bash
# array, preserving shell-quoted whitespace.
COMMIT_ARGS=()
while IFS= read -r arg; do
  COMMIT_ARGS+=("$arg")
done < <(printf '%s' "$INV" | jq -r '.subcommand_args[]?')

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
# Porcelain v1 line:  `XY filename` for non-renames,
#                     `RY oldname -> newname` for renames/copies.
# We want the name actually in the commit -- new name for renames.
# Also strip surrounding double-quotes that git adds when the path
# has special chars.
extract_plans() {
  awk '
    /^[ACDMRTU]/ {
      s = substr($0, 4)
      n = index(s, " -> ")
      if (n > 0) s = substr(s, n + 4)
      if (length(s) >= 2 && substr(s, 1, 1) == "\"" && substr(s, length(s), 1) == "\"") {
        s = substr(s, 2, length(s) - 2)
        gsub(/\\\\/, "\\", s)
        gsub(/\\"/, "\"", s)
      }
      print s
    }
  '
}

PLANS=$(printf '%s\n' "$DRY" | extract_plans | grep -E "$PLAN_RX" || true)

# Detect interactive patch mode -- `-p` / `--patch`. The user picks
# hunks at commit time, so the dry-run output can't predict what
# actually lands. Conservative: treat ALL worktree-modified plans as
# in-scope. False positives (user ultimately picks no plan hunks) just
# trigger an extra review; false negatives are not acceptable.
INTERACTIVE_PATCH=0
for a in "${COMMIT_ARGS[@]:-}"; do
  case "$a" in
    -p|--patch|--interactive)
      INTERACTIVE_PATCH=1
      break ;;
    -*p*)
      # Short combo containing 'p'. Skip combos starting with a value-
      # taking short flag (-Skeyid, -mmsg, etc.).
      case "$a" in
        -[SCcmFt]*) ;;
        *) INTERACTIVE_PATCH=1; break ;;
      esac
      ;;
  esac
done
if [ "$INTERACTIVE_PATCH" -eq 1 ]; then
  WORKTREE_PLANS=$(git_in_repo diff --name-only --diff-filter=ACMR 2>/dev/null \
    | grep -E "$PLAN_RX" || true)
  PLANS=$(printf '%s\n%s\n' "$PLANS" "$WORKTREE_PLANS" | awk 'NF && !seen[$0]++')
fi

if [ -z "$PLANS" ]; then
  exit 0
fi

# Pre-existing index entries (before this commit's args could have
# staged anything). Used for per-file source decisions when --include
# is given: index entries source from `git show :path`; everything
# else this commit pulls in sources from the working tree.
PRE_INDEX=$(git_in_repo diff --cached --name-only 2>/dev/null || true)

# Was -i / --include given? With -i, the per-file source is mixed:
# previously-staged entries -> index; newly-listed pathspecs -> worktree.
INCLUDE_MODE=0
for a in "${COMMIT_ARGS[@]:-}"; do
  case "$a" in
    -i|--include) INCLUDE_MODE=1; break ;;
    -[SCcmFt]*) ;;
    -*i*) INCLUDE_MODE=1; break ;;
  esac
done

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
BRIDGE="$PLUGIN_ROOT/scripts/codex-bridge.mjs"
if [ ! -f "$BRIDGE" ]; then
  exit 0
fi

ISSUES=""
ANY_FAIL=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  # Per-file source decision:
  #   - With --include: pre-existing index entries -> index source;
  #     everything else this commit drags in -> worktree.
  #   - Otherwise: USES_WORKTREE (from parser) applies to all files.
  # Symlink refusals are HARD blocks (ANY_FAIL=1, ISSUES updated) so
  # the gate denies the commit instead of silently skipping.
  STAGED_FILE=$(mktemp -t sspower-spec-staged-XXXXXX)
  FILE_USES_WORKTREE="$USES_WORKTREE"
  if [ "$INCLUDE_MODE" -eq 1 ]; then
    if printf '%s\n' "$PRE_INDEX" | grep -Fqx "$f"; then
      FILE_USES_WORKTREE=false
    else
      FILE_USES_WORKTREE=true
    fi
  fi

  if [ "$FILE_USES_WORKTREE" = "true" ]; then
    ABS="$REPO_ROOT/$f"
    if [ -L "$ABS" ]; then
      ANY_FAIL=1
      ISSUES+=$'\n\n== '"$f"' =='$'\nverdict: blocked\n- [critical] worktree symlink refused (would leak filesystem contents to review)'
      echo "[auto-spec-gate] BLOCK: refusing symlink at $f." >&2
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
      *) ANY_FAIL=1
         ISSUES+=$'\n\n== '"$f"' =='$'\nverdict: blocked\n- [critical] resolves outside repo (refused)'
         echo "[auto-spec-gate] BLOCK: $f resolves outside repo." >&2
         rm -f "$STAGED_FILE"
         continue ;;
    esac
    cp -P "$ABS" "$STAGED_FILE" || { rm -f "$STAGED_FILE"; continue; }
  else
    # Index source. Staged symlinks (mode 120000) hold the link target
    # string as content, not a plan. Refuse + block.
    MODE=$(git_in_repo ls-files --stage -- "$f" 2>/dev/null | awk '{print $1}' | head -1)
    if [ "$MODE" = "120000" ]; then
      ANY_FAIL=1
      ISSUES+=$'\n\n== '"$f"' =='$'\nverdict: blocked\n- [critical] staged symlink refused (mode 120000)'
      echo "[auto-spec-gate] BLOCK: refusing staged symlink at $f." >&2
      rm -f "$STAGED_FILE"
      continue
    fi
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
    log_event warn hook.auto-spec-gate kind=codex_failed_allow plan="$f"
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

log_event warn hook.auto-spec-gate kind=deny_plan_review
jq -n --arg reason "$REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
exit 0
