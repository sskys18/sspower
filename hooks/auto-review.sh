#!/usr/bin/env bash
# sspower auto-review hook (PreToolUse:Bash)
#
# Fires before every Bash call. Acts when the command is a chokepoint:
#   - `git push ...`         (local -> remote)
#   - `git merge ...`        (local merge that bypasses push)
#   - `gh pr create ...`     (open PR)
#   - `gh pr ready ...`      (mark draft PR ready for review)
#   - `gh pr merge ...`      (merge PR)
# Runs a Codex review of the branch diff vs upstream (or main).
#
# Loop guards (in order):
#   - SSPOWER_AUTO_REVIEW=off            : full bypass.
#   - SSPOWER_REVIEW_IN_FLIGHT=1         : re-entry guard set by codex-bridge
#                                          before spawning codex.
#   - SSPOWER_REVIEW_DEPTH >= 1          : depth backstop.
#   - .sspower-skip-auto-review at repo  : per-repo opt-out.
#   - Verdict cache (~/.cache/sspower)   : same diff hash -> reuse verdict.
#   - Round counter (.git/sspower-...)   : N rounds w/o approve -> deny + cap.
#
# Chain policy: read-only output pipes after the chokepoint are allowed
# (`git push 2>&1 | tail -40`). Any predecessor or non-pipe successor
# is denied.
#
# Tunables (env):
#   SSPOWER_REVIEW_TIMEOUT     (default 90s)
#   SSPOWER_REVIEW_CACHE_TTL   (default 600s = 10min)
#   SSPOWER_REVIEW_MAX_ROUNDS  (default 3)
#   SSPOWER_REVIEW_AUTO_APPLY  (default on; set off to disable patch apply)

set -u

# ---------- Bypasses + re-entry guards ----------
[ "${SSPOWER_AUTO_REVIEW:-on}" = "off" ] && exit 0
[ "${SSPOWER_REVIEW_IN_FLIGHT:-0}" = "1" ] && exit 0
[ "${SSPOWER_REVIEW_DEPTH:-0}" -ge 1 ] && exit 0

command -v jq &>/dev/null || exit 0
command -v node &>/dev/null || exit 0
command -v python3 &>/dev/null || exit 0

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PARSED=$(printf '%s' "$CMD" | python3 "$SCRIPT_DIR/_parse-git-cmd.py" 2>/dev/null)

# ---------- Chokepoint detection ----------
INV=$(printf '%s' "$PARSED" | jq -c '
  [.invocations[]
   | select(
       (.tool == "git" and (.subcommand == "push" or .subcommand == "merge"))
       or (.tool == "gh" and (.subcommand == "pr create" or .subcommand == "pr ready" or .subcommand == "pr merge"))
     )
  ] | .[0] // empty
' 2>/dev/null)
[ -z "$INV" ] && exit 0

CHOKE_POS=$(printf '%s' "$INV" | jq -r '.chain_position // 0')

deny() {
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

# ---------- Chain policy ----------
# Anything before the chokepoint -> deny (predecessor may mutate state).
if [ "$CHOKE_POS" -gt 0 ]; then
  deny "Codex auto-review: a command preceding the git/gh chokepoint may mutate HEAD, cwd, or index before review runs. Use 'git -C <path>' instead of 'cd <path> && git ...'. Run the chokepoint as its own Bash call. Bypass: SSPOWER_AUTO_REVIEW=off only for emergencies."
fi

# After the chokepoint: only `|` to read-only consumers allowed.
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
  deny "Codex auto-review: only read-only output pipes (tail/head/grep/jq/sed/awk/...) allowed after a git/gh chokepoint. Other chained commands may run conditionally on push outcome. Capture output to a file then read separately: 'git push > /tmp/push.log 2>&1' on its own line. Bypass: SSPOWER_AUTO_REVIEW=off."
fi

# ---------- Resolve target repo ----------
TOOL=$(printf '%s' "$INV" | jq -r '.tool')
SUBCMD=$(printf '%s' "$INV" | jq -r '.subcommand')
WORK_DIR=$(printf '%s' "$INV" | jq -r '.work_dir')
MERGE_SOURCES=()
while IFS= read -r r; do
  [ -n "$r" ] && MERGE_SOURCES+=("$r")
done < <(printf '%s' "$INV" | jq -r '.merge_sources[]?')

GIT_OPTS=()
[ -n "$WORK_DIR" ] && GIT_OPTS+=(-C "$WORK_DIR")
git_in_repo() {
  if [ ${#GIT_OPTS[@]} -gt 0 ]; then
    git "${GIT_OPTS[@]}" "$@"
  else
    git "$@"
  fi
}

# Per-repo bypass file.
SKIP_REPO_ROOT=$(git_in_repo rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$SKIP_REPO_ROOT" ] && [ -f "$SKIP_REPO_ROOT/.sspower-skip-auto-review" ] && exit 0

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
BRIDGE="$PLUGIN_ROOT/scripts/codex-bridge.mjs"
[ ! -f "$BRIDGE" ] && exit 0

# ---------- Diff resolution ----------
DIFF_FILE=$(mktemp -t sspower-autoreview-XXXXXX)
trap 'rm -f "$DIFF_FILE"' EXIT

if [ "$SUBCMD" = "merge" ]; then
  [ ${#MERGE_SOURCES[@]} -eq 0 ] && exit 0
  : > "$DIFF_FILE"
  REVIEWABLE=0
  for src in "${MERGE_SOURCES[@]}"; do
    git_in_repo rev-parse --verify --quiet "$src" >/dev/null || continue
    {
      echo
      echo "=== merging $src ==="
      git_in_repo diff "HEAD...$src" 2>/dev/null || true
    } >> "$DIFF_FILE"
    REVIEWABLE=1
  done
  [ "$REVIEWABLE" -eq 0 ] && exit 0
else
  BASE=$(git_in_repo rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
  if [ -z "$BASE" ]; then
    for cand in main master; do
      if git_in_repo show-ref --verify --quiet "refs/heads/$cand"; then BASE="$cand"; break; fi
    done
  fi
  [ -z "$BASE" ] && exit 0
  git_in_repo diff "$BASE"..HEAD > "$DIFF_FILE" 2>/dev/null || exit 0
fi
[ ! -s "$DIFF_FILE" ] && exit 0

REPO_ROOT=$(git_in_repo rev-parse --show-toplevel 2>/dev/null || true)

# ---------- Iteration cap (per branch) ----------
BRANCH=$(git_in_repo rev-parse --abbrev-ref HEAD 2>/dev/null || echo "_detached_")
SAFE_BRANCH=$(printf '%s' "$BRANCH" | tr '/' '_')
if [ -n "$REPO_ROOT" ]; then
  ROUNDS_FILE="$REPO_ROOT/.git/sspower-review-rounds-$SAFE_BRANCH"
else
  ROUNDS_FILE=""
fi
ROUNDS=0
if [ -n "$ROUNDS_FILE" ] && [ -f "$ROUNDS_FILE" ]; then
  ROUNDS=$(cat "$ROUNDS_FILE" 2>/dev/null || echo 0)
  case "$ROUNDS" in ''|*[!0-9]*) ROUNDS=0 ;; esac
fi
ROUNDS_CAP="${SSPOWER_REVIEW_MAX_ROUNDS:-3}"
if [ "$ROUNDS" -ge "$ROUNDS_CAP" ]; then
  deny "Codex auto-review: ${ROUNDS_CAP} rounds did not converge for branch '$BRANCH'. Review manually, fix locally, then 'rm $ROUNDS_FILE' to retry. Or bypass: SSPOWER_AUTO_REVIEW=off."
fi

# ---------- Verdict cache ----------
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/sspower/verdicts"
mkdir -p "$CACHE_DIR"
HEAD_SHA=$(git_in_repo rev-parse HEAD 2>/dev/null || echo "")
DIFF_SHA=$(sha256sum "$DIFF_FILE" 2>/dev/null | cut -d' ' -f1)
[ -z "$DIFF_SHA" ] && DIFF_SHA=$(shasum -a 256 "$DIFF_FILE" 2>/dev/null | cut -d' ' -f1)
HASH_INPUT=$(printf '%s|%s|%s|%s' "${REPO_ROOT:-}" "$HEAD_SHA" "$BRANCH" "$DIFF_SHA")
DIFF_HASH=$(printf '%s' "$HASH_INPUT" | sha256sum 2>/dev/null | cut -d' ' -f1)
[ -z "$DIFF_HASH" ] && DIFF_HASH=$(printf '%s' "$HASH_INPUT" | shasum -a 256 | cut -d' ' -f1)
CACHE_FILE="$CACHE_DIR/$DIFF_HASH.json"
CACHE_TTL="${SSPOWER_REVIEW_CACHE_TTL:-600}"

RESULT=""
CACHE_HIT=0
if [ -f "$CACHE_FILE" ]; then
  MTIME=$(stat -f %m "$CACHE_FILE" 2>/dev/null || stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)
  AGE=$(( $(date +%s) - MTIME ))
  if [ "$AGE" -lt "$CACHE_TTL" ]; then
    RESULT=$(cat "$CACHE_FILE")
    CACHE_HIT=1
  fi
fi

# ---------- Run codex on cache miss ----------
if [ -z "$RESULT" ]; then
  PROMPT_FILE=$(mktemp -t sspower-autoreview-prompt-XXXXXX)
  cat > "$PROMPT_FILE" <<EOF
Review the branch diff at $DIFF_FILE before push. Flag bugs, regressions,
missing tests, and security issues. Also flag docs drift: code changes
that contradict CLAUDE.md, README, or docs/ in the repo root (${REPO_ROOT:-cwd})
without updating those files. Read the repo to verify; do not rely on the
diff alone.

For each issue set severity:
  - "blocking" only if correctness, security, or data-loss.
  - "advisory" for style, naming, doc-only nits, minor refactors.

For mechanical fixes (typos, missing imports, simple refactors), include
'suggested_patch' as a unified diff against current HEAD. Omit for
design/architecture issues that need human judgment.

Verdicts:
  - "approve"                  : no issues, ship it.
  - "approve-with-followups"   : only advisory issues; ship and follow up.
  - "needs-attention"          : at least one blocking issue.

Do NOT propose stylistic refactors or unrequested features beyond what's
necessary to fix the diff.
EOF
  BRIDGE_ARGS=(review --prompt "@$PROMPT_FILE")
  [ -n "$REPO_ROOT" ] && BRIDGE_ARGS+=(--cd "$REPO_ROOT")

  REVIEW_TIMEOUT="${SSPOWER_REVIEW_TIMEOUT:-90}"
  if command -v timeout &>/dev/null; then
    RESULT=$(timeout "$REVIEW_TIMEOUT" node "$BRIDGE" "${BRIDGE_ARGS[@]}" 2>/dev/null || true)
  else
    RESULT=$(node "$BRIDGE" "${BRIDGE_ARGS[@]}" 2>/dev/null || true)
  fi
  rm -f "$PROMPT_FILE"

  if [ -z "$RESULT" ]; then
    echo "[auto-review] WARNING: codex review failed/timed out (${REVIEW_TIMEOUT}s); allowing push without review." >&2
    exit 0
  fi
  echo "$RESULT" > "$CACHE_FILE"
fi

VERDICT=$(echo "$RESULT" | jq -r '.verdict // empty' 2>/dev/null)

# Increment rounds only on real codex calls (not cache hits).
if [ "$CACHE_HIT" = "0" ] && [ -n "$ROUNDS_FILE" ]; then
  echo $((ROUNDS + 1)) > "$ROUNDS_FILE"
fi

# ---------- Approve paths ----------
case "$VERDICT" in
  approve|approve-with-followups)
    if [ "$VERDICT" = "approve-with-followups" ] && [ -n "$REPO_ROOT" ]; then
      ADV_COUNT=$(echo "$RESULT" | jq -r '[.issues // [] | .[] | select(.severity == "advisory")] | length' 2>/dev/null)
      if [ "${ADV_COUNT:-0}" -gt 0 ]; then
        mkdir -p "$REPO_ROOT/.sspower"
        FOLLOWUPS_FILE="$REPO_ROOT/.sspower/followups.md"
        {
          echo
          echo "## Round $((ROUNDS + 1)) — $(date +%Y-%m-%d) advisory followups"
          echo "$RESULT" | jq -r '.issues // [] | map(select(.severity == "advisory")) | .[] | "- [" + (.file // "?") + ":" + ((.line_start // 0)|tostring) + "] " + (.title // "untitled") + " — " + (.recommendation // "")'
        } >> "$FOLLOWUPS_FILE"
      fi
    fi
    [ -n "$ROUNDS_FILE" ] && rm -f "$ROUNDS_FILE"  # reset on convergence
    exit 0
    ;;
esac

# ---------- Apply suggested patches (if any) ----------
APPLIED=0
APPLIED_COUNT=0
if [ "${SSPOWER_REVIEW_AUTO_APPLY:-on}" != "off" ] && [ -n "$REPO_ROOT" ]; then
  PATCH_DIR="$REPO_ROOT/.sspower/proposed-fixes"
  mkdir -p "$PATCH_DIR"
  PATCH_FILE="$PATCH_DIR/round-$((ROUNDS + 1)).patch"
  echo "$RESULT" | jq -r '
    .issues // []
    | map(select(.suggested_patch != null and .suggested_patch != ""))
    | .[]
    | .suggested_patch
  ' > "$PATCH_FILE" 2>/dev/null || true

  if [ -s "$PATCH_FILE" ]; then
    if git_in_repo apply --check "$PATCH_FILE" 2>/dev/null; then
      if git_in_repo apply --3way "$PATCH_FILE" 2>/dev/null; then
        APPLIED=1
        APPLIED_COUNT=$(echo "$RESULT" | jq -r '[.issues // [] | .[] | select(.suggested_patch != null and .suggested_patch != "")] | length' 2>/dev/null)
      fi
    fi
  else
    rm -f "$PATCH_FILE"
  fi
fi

# ---------- Build deny payload ----------
SUMMARY=$(echo "$RESULT" | jq -r '
  if (.issues // [] | length) == 0 then
    "verdict: " + (.verdict // "unknown")
  else
    "verdict: " + (.verdict // "unknown") + "\n" +
    (.issues | map("- [" + (.severity // "?") + "] " + (.title // "untitled")) | join("\n"))
  end
' 2>/dev/null)

NEW_ROUNDS=$((ROUNDS + 1))
if [ "$APPLIED" = "1" ]; then
  REASON=$(printf 'Codex auto-review blocked (round %s/%s).\n%s\n\n%s suggested patch(es) AUTO-APPLIED to your working tree. Review the changes, re-stage, commit, and push again.\n\nBypass: SSPOWER_AUTO_REVIEW=off (emergencies). Auto-apply off: SSPOWER_REVIEW_AUTO_APPLY=off.' "$NEW_ROUNDS" "$ROUNDS_CAP" "$SUMMARY" "$APPLIED_COUNT")
else
  REASON=$(printf 'Codex auto-review blocked (round %s/%s).\n%s\n\nFix the issues, commit, and push again. Bypass: SSPOWER_AUTO_REVIEW=off.' "$NEW_ROUNDS" "$ROUNDS_CAP" "$SUMMARY")
fi

jq -n --arg reason "$REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
exit 0
