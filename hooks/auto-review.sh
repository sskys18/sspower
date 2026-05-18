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
#   SSPOWER_REVIEW_CACHE_TTL   (default 3600s = 60min)
#   SSPOWER_REVIEW_MAX_ROUNDS  (default 3)
#   SSPOWER_REVIEW_AUTO_APPLY  (default on; set off to disable patch apply)
#   SSPOWER_SECURITY_REVIEW    (default on;     set off to skip security pass)
#   SSPOWER_SECURITY_EFFORT    (default xhigh;  off|low|medium|high|xhigh)
#   SSPOWER_SANITY_REVIEW      (default off;    set on to enable sanity pass)
#   SSPOWER_SANITY_EFFORT      (default medium; off|low|medium|high|xhigh)
#                              Sanity runs only at round 0 on non-strict
#                              branches. Purpose: break round-escalation
#                              loops by downgrading noisy main verdicts to
#                              advisory when a second reviewer disagrees.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_log.sh
. "$SCRIPT_DIR/_log.sh"

# ---------- Bypasses + re-entry guards ----------
[ "${SSPOWER_AUTO_REVIEW:-on}" = "off" ] && exit 0
[ "${SSPOWER_REVIEW_IN_FLIGHT:-0}" = "1" ] && exit 0
[ "${SSPOWER_REVIEW_DEPTH:-0}" -ge 1 ] && exit 0

command -v jq &>/dev/null || exit 0
command -v node &>/dev/null || exit 0
command -v python3 &>/dev/null || exit 0

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

PARSED=$(printf '%s' "$CMD" | python3 "$SCRIPT_DIR/_parse-git-cmd.py" 2>/dev/null)

# ---------- Chokepoint detection ----------
# Note: `gh pr merge` is intentionally excluded. By merge time the PR diff
# was already reviewed at `gh pr create` / `gh pr ready` time, and the
# local branch diff that this hook computes is not necessarily the diff
# being merged (PR head may diverge from local HEAD). Reviewing the wrong
# diff here would only produce noise without adding safety.
INV=$(printf '%s' "$PARSED" | jq -c '
  [.invocations[]
   | select(
       (.tool == "git" and (.subcommand == "push" or .subcommand == "merge"))
       or (.tool == "gh" and (.subcommand == "pr create" or .subcommand == "pr ready"))
     )
  ] | .[0] // empty
' 2>/dev/null)
[ -z "$INV" ] && exit 0

CHOKE_POS=$(printf '%s' "$INV" | jq -r '.chain_position // 0')
CHOKE_TOOL=$(printf '%s' "$INV" | jq -r '.tool // "?"')
CHOKE_SUB=$(printf '%s' "$INV" | jq -r '.subcommand // "?"')

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
  log_event warn hook.auto-review kind=deny_predecessor tool="$CHOKE_TOOL" subcommand="$CHOKE_SUB" chain_position="$CHOKE_POS"
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
  log_event warn hook.auto-review kind=deny_successor tool="$CHOKE_TOOL" subcommand="$CHOKE_SUB" chain_position="$CHOKE_POS"
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

# ---------- Branch-pattern tier classification ----------
# Patterns can be overridden via SSPOWER_REVIEW_SKIP_PATTERN / SSPOWER_REVIEW_STRICT_PATTERN.
# Defaults: wip/tmp/draft skip review; main/master/prod/release/* always strict (xhigh).
SKIP_PATTERN="${SSPOWER_REVIEW_SKIP_PATTERN:-wip/*|tmp/*|draft/*|scratch/*}"
STRICT_PATTERN="${SSPOWER_REVIEW_STRICT_PATTERN:-main|master|prod|production|release/*}"

case "$BRANCH" in
  $SKIP_PATTERN)
    log_event info hook.auto-review kind=branch_skip branch="$BRANCH" pattern="$SKIP_PATTERN"
    exit 0
    ;;
  $STRICT_PATTERN) BRANCH_TIER="strict" ;;
  *)               BRANCH_TIER="tiered" ;;
esac
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
  log_event warn hook.auto-review kind=deny_rounds_cap branch="$BRANCH" rounds="$ROUNDS/$ROUNDS_CAP"
  deny "Codex auto-review: ${ROUNDS_CAP} rounds did not converge for branch '$BRANCH'. Review manually, fix locally, then 'rm $ROUNDS_FILE' to retry. Or bypass: SSPOWER_AUTO_REVIEW=off."
fi

# ---------- Diff-stability bypass setup (checked after DIFF_HASH computed) ----------
LAST_DENY_FILE=""
if [ -n "$REPO_ROOT" ]; then
  LAST_DENY_FILE="$REPO_ROOT/.git/sspower-review-last-deny-$SAFE_BRANCH"
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
CACHE_TTL="${SSPOWER_REVIEW_CACHE_TTL:-3600}"

# ---------- Diff-stability bypass ----------
# Same diff hash denied 2x consecutively → user pushing same changes, codex stuck.
# Bypass review (let push through) so user can break the loop. Manual fix needed.
if [ -n "$LAST_DENY_FILE" ] && [ -f "$LAST_DENY_FILE" ] && [ "$ROUNDS" -ge 1 ]; then
  LAST_DENIED_HASH=$(cat "$LAST_DENY_FILE" 2>/dev/null || true)
  if [ -n "$LAST_DENIED_HASH" ] && [ "$LAST_DENIED_HASH" = "$DIFF_HASH" ]; then
    log_event warn hook.auto-review kind=diff_stable_bypass branch="$BRANCH" hash="${DIFF_HASH:0:12}" rounds="$ROUNDS"
    echo "[auto-review] WARNING: identical diff denied previously (round $ROUNDS). Bypassing review to break loop. Fix locally before pushing again." >&2
    exit 0
  fi
fi

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
  # ---------- Round-aware profile tier (main review) ----------
  if [ -n "${SSPOWER_REVIEW_PROFILE:-}" ]; then
    ROUND_PROFILE="$SSPOWER_REVIEW_PROFILE"
  elif [ "$BRANCH_TIER" = "strict" ]; then
    ROUND_PROFILE="deep"
  else
    case "$ROUNDS" in
      0) ROUND_PROFILE="normal" ;;
      1) ROUND_PROFILE="normal" ;;
      *) ROUND_PROFILE="deep" ;;
    esac
  fi
  # Back-compat shim: downstream timeout (:409) + logs (:440,:645) still read
  # ROUND_EFFORT. Derive it from the chosen profile so `set -u` stays happy
  # and the timeout case keeps working. (MAIN review itself uses --profile.)
  case "$ROUND_PROFILE" in
    deep)   ROUND_EFFORT="xhigh" ;;
    quick)  ROUND_EFFORT="low" ;;
    *)      ROUND_EFFORT="high" ;;   # normal
  esac
  log_event info hook.auto-review kind=tier_chosen branch="$BRANCH" tier="$BRANCH_TIER" round="$((ROUNDS+1))/$ROUNDS_CAP" profile="$ROUND_PROFILE" effort="$ROUND_EFFORT"

  # Main review prompt (general bugs/regressions/docs drift)
  MAIN_PROMPT_FILE=$(mktemp -t sspower-autoreview-main-XXXXXX)
  cat > "$MAIN_PROMPT_FILE" <<EOF
Review the branch diff at $DIFF_FILE before push. Flag bugs, regressions,
missing tests. Also flag docs drift: code changes that contradict CLAUDE.md,
README, or docs/ in the repo root (${REPO_ROOT:-cwd}) without updating those
files. Read the repo to verify; do not rely on the diff alone.

Do NOT focus on security here — a separate security pass runs in parallel.
Avoid duplicating security findings.

For each issue set severity:
  - "blocking" only if correctness or data-loss.
  - "advisory" for style, naming, doc-only nits, minor refactors.

For mechanical fixes (typos, missing imports, simple refactors), include
'suggested_patch' as a unified diff against current HEAD. For
design/architecture issues that need human judgment, set
'suggested_patch' to null. The schema requires the field on every issue.

Verdicts:
  - "approve"                  : no issues, ship it.
  - "approve-with-followups"   : only advisory issues; ship and follow up.
  - "needs-attention"          : at least one blocking issue.

Do NOT propose stylistic refactors or unrequested features beyond what's
necessary to fix the diff.
EOF

  # Security review prompt (senior security engineer perspective)
  SEC_PROMPT_FILE=$(mktemp -t sspower-autoreview-sec-XXXXXX)
  cat > "$SEC_PROMPT_FILE" <<EOF
Act as a senior security engineer. Review the branch diff at $DIFF_FILE for
security vulnerabilities and defensive gaps. Read the repo at
${REPO_ROOT:-cwd} to verify; do not rely on the diff alone.

Specifically look for:
  - Authentication/authorization bugs (missing checks, broken access control,
    IDOR, privilege escalation, session/token mishandling)
  - Input validation: injection (SQL, NoSQL, command, LDAP, XPath), XSS,
    CSRF, SSRF, path traversal, open redirect, HTTP header injection
  - Secrets exposure: hardcoded credentials, tokens in logs/errors/git,
    insecure storage, env var leaks
  - Crypto misuse: weak algorithms, hardcoded keys/IVs, insecure random,
    bad signature verification, padding oracles, missing HMAC
  - Race conditions, TOCTOU, insecure deserialization
  - Insecure defaults (open ports, debug enabled, permissive CORS, weak TLS)
  - Dependency risks: known-vulnerable libs introduced/upgraded
  - Logging/monitoring gaps for security events
  - Insufficient rate limiting, DoS amplification

For each issue set severity:
  - "blocking" for any exploitable vuln, data exposure, or auth bypass.
  - "advisory" for hardening recommendations and defense-in-depth.

For mechanical fixes (input sanitization stub, missing auth check, secret
removal), include 'suggested_patch' as unified diff. For design issues set
'suggested_patch' to null.

Verdicts:
  - "approve"                  : no security issues found.
  - "approve-with-followups"   : only advisory hardening notes; ship + follow up.
  - "needs-attention"          : at least one blocking security issue.

Be precise. Cite file:line. Avoid speculative threats not realized in this diff.
EOF

  # Sanity / second-opinion review prompt. Runs in parallel at round 0 only,
  # to break false-deny loops: when the main reviewer flags noise (style,
  # speculative refactor, low-effort hallucination), sanity acts as a second
  # pair of eyes focused strictly on real correctness blockers.
  SANITY_PROMPT_FILE=$(mktemp -t sspower-autoreview-sanity-XXXXXX)
  cat > "$SANITY_PROMPT_FILE" <<EOF
Act as a second pair of eyes on the branch diff at $DIFF_FILE. Your sole
job is to independently judge whether the diff has any **blocking** bug:
correctness regression, data loss / corruption, crash, broken contract
with callers, or auth/permission bypass that the main reviewer might
have missed OR exaggerated.

Read the repo at ${REPO_ROOT:-cwd} to verify. Do NOT rely on the diff
alone.

EXPLICITLY IGNORE:
  - Style, naming, formatting, comment density
  - "Could be refactored / abstracted / simplified"
  - Test coverage suggestions (unless the change visibly broke a test)
  - Documentation drift (covered by main reviewer)
  - Speculative future scenarios not realized in this diff
  - Performance micro-optimizations

For each real blocker found:
  - severity: "blocking" only if there is a concrete failure mode the
    reader can name in one sentence (e.g., "passes null to .toLowerCase()
    when input.email is undefined → TypeError on signup").
  - severity: "advisory" for anything you would mention but would not
    block a push for.

If you find nothing concrete, return verdict "approve" with empty
issues list. Do not invent issues to look thorough.

Verdicts:
  - "approve"                  : no real blocker.
  - "approve-with-followups"   : only advisory observations.
  - "needs-attention"          : at least one concrete blocking bug.

For mechanical fixes include 'suggested_patch' as unified diff. For
design issues set 'suggested_patch' to null.
EOF

  MAIN_BRIDGE_ARGS=(review --prompt "@$MAIN_PROMPT_FILE" --profile "$ROUND_PROFILE")
  [ -n "$REPO_ROOT" ] && MAIN_BRIDGE_ARGS+=(--cd "$REPO_ROOT")

  SSPOWER_SECURITY_REPOS="${SSPOWER_SECURITY_REPOS:-/Users/sskys/blockwavelabs/custody-dashboard-solution:/Users/sskys/blockwavelabs/danal/pay-chain:/Users/sskys/blockwavelabs/danal/danalstable-frontend:/Users/sskys/blockwavelabs/danal/danalstablecoin-backend:/Users/sskys/blockwavelabs/infinite-block/security}"
  SEC_EFFORT="${SSPOWER_SECURITY_EFFORT:-xhigh}"
  SECURITY_ENABLED=0
  _repo_root="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
  if [ "$BRANCH_TIER" = "strict" ]; then
    SECURITY_ENABLED=1
  elif [ -n "$_repo_root" ]; then
    _OLDIFS="$IFS"; IFS=':'
    for _p in $SSPOWER_SECURITY_REPOS; do
      case "$_repo_root" in "$_p"*) SECURITY_ENABLED=1 ;; esac
    done
    IFS="$_OLDIFS"
  fi
  # SSPOWER_SECURITY_REVIEW=on force-enables (overrides path/branch gating).
  if [ "${SSPOWER_SECURITY_REVIEW:-}" = "on" ]; then SECURITY_ENABLED=1; fi
  # Explicit OFF is authoritative and applied LAST — you can never run a
  # security review with `--effort off`, so SEC_EFFORT=off (or REVIEW=off)
  # disables regardless of a REVIEW=on force-enable above.
  if [ "$SEC_EFFORT" = "off" ] || [ "${SSPOWER_SECURITY_REVIEW:-}" = "off" ]; then SECURITY_ENABLED=0; fi
  SEC_BRIDGE_ARGS=(review --prompt "@$SEC_PROMPT_FILE" --effort "$SEC_EFFORT")
  [ -n "$REPO_ROOT" ] && SEC_BRIDGE_ARGS+=(--cd "$REPO_ROOT")

  # Sanity reviewer: round 0 only, parallel with main + security.
  # Purpose: break the round 0 → 1 → 2 → cap loop when main @ low/high
  # produces a noisy needs-attention. Runs at medium effort with a
  # blocker-only prompt; if main says deny but sanity says approve,
  # we downgrade main's findings to advisory followups instead of
  # blocking the push and forcing another round.
  SANITY_EFFORT="${SSPOWER_SANITY_EFFORT:-medium}"
  SANITY_ENABLED=0
  if [ "${SSPOWER_SANITY_REVIEW:-off}" = "on" ] && [ "$BRANCH_TIER" != "strict" ] && [ "$SANITY_EFFORT" != "off" ]; then
    SANITY_ENABLED=1
  fi
  SANITY_BRIDGE_ARGS=(review --prompt "@$SANITY_PROMPT_FILE" --effort "$SANITY_EFFORT")
  [ -n "$REPO_ROOT" ] && SANITY_BRIDGE_ARGS+=(--cd "$REPO_ROOT")

  # Tier-aware timeout: max(main, security) since they run in parallel
  if [ -n "${SSPOWER_REVIEW_TIMEOUT:-}" ]; then
    REVIEW_TIMEOUT="$SSPOWER_REVIEW_TIMEOUT"
  else
    case "$ROUND_EFFORT" in
      low|minimal) MAIN_TIMEOUT=60 ;;
      medium)      MAIN_TIMEOUT=90 ;;
      high)        MAIN_TIMEOUT=120 ;;
      xhigh)       MAIN_TIMEOUT=180 ;;
      *)           MAIN_TIMEOUT=90 ;;
    esac
    case "$SEC_EFFORT" in
      low|minimal) SEC_TIMEOUT=60 ;;
      medium)      SEC_TIMEOUT=90 ;;
      high)        SEC_TIMEOUT=120 ;;
      xhigh)       SEC_TIMEOUT=180 ;;
      *)           SEC_TIMEOUT=180 ;;
    esac
    case "$SANITY_EFFORT" in
      low|minimal) SANITY_TIMEOUT=60 ;;
      medium)      SANITY_TIMEOUT=90 ;;
      high)        SANITY_TIMEOUT=120 ;;
      xhigh)       SANITY_TIMEOUT=180 ;;
      *)           SANITY_TIMEOUT=90 ;;
    esac
    REVIEW_TIMEOUT=$MAIN_TIMEOUT
    [ "$SEC_TIMEOUT"    -gt "$REVIEW_TIMEOUT" ] && REVIEW_TIMEOUT=$SEC_TIMEOUT
    [ "$SANITY_ENABLED" = "1" ] && [ "$SANITY_TIMEOUT" -gt "$REVIEW_TIMEOUT" ] && REVIEW_TIMEOUT=$SANITY_TIMEOUT
  fi

  # ---------- Spawn parallel reviews ----------
  MAIN_RESULT_FILE=$(mktemp -t sspower-autoreview-mainresult-XXXXXX)
  SEC_RESULT_FILE=$(mktemp -t sspower-autoreview-secresult-XXXXXX)
  SANITY_RESULT_FILE=$(mktemp -t sspower-autoreview-sanityresult-XXXXXX)

  log_event info hook.auto-review kind=parallel_review_start branch="$BRANCH" \
    main_effort="$ROUND_PROFILE" \
    sec_effort="$([ "$SECURITY_ENABLED" = "1" ] && echo "$SEC_EFFORT" || echo "off")" \
    sanity_effort="$([ "$SANITY_ENABLED" = "1" ] && echo "$SANITY_EFFORT" || echo "off")" \
    timeout="${REVIEW_TIMEOUT}s"

  if command -v timeout &>/dev/null; then
    timeout "$MAIN_TIMEOUT" node "$BRIDGE" "${MAIN_BRIDGE_ARGS[@]}" > "$MAIN_RESULT_FILE" 2>/dev/null &
    MAIN_PID=$!
    if [ "$SECURITY_ENABLED" = "1" ]; then
      timeout "$SEC_TIMEOUT" node "$BRIDGE" "${SEC_BRIDGE_ARGS[@]}" > "$SEC_RESULT_FILE" 2>/dev/null &
      SEC_PID=$!
    fi
    if [ "$SANITY_ENABLED" = "1" ]; then
      timeout "$SANITY_TIMEOUT" node "$BRIDGE" "${SANITY_BRIDGE_ARGS[@]}" > "$SANITY_RESULT_FILE" 2>/dev/null &
      SANITY_PID=$!
    fi
  else
    node "$BRIDGE" "${MAIN_BRIDGE_ARGS[@]}" > "$MAIN_RESULT_FILE" 2>/dev/null &
    MAIN_PID=$!
    if [ "$SECURITY_ENABLED" = "1" ]; then
      node "$BRIDGE" "${SEC_BRIDGE_ARGS[@]}" > "$SEC_RESULT_FILE" 2>/dev/null &
      SEC_PID=$!
    fi
    if [ "$SANITY_ENABLED" = "1" ]; then
      node "$BRIDGE" "${SANITY_BRIDGE_ARGS[@]}" > "$SANITY_RESULT_FILE" 2>/dev/null &
      SANITY_PID=$!
    fi
  fi

  wait "$MAIN_PID" 2>/dev/null || true
  [ "$SECURITY_ENABLED" = "1" ] && wait "$SEC_PID" 2>/dev/null || true
  [ "$SANITY_ENABLED" = "1" ] && wait "$SANITY_PID" 2>/dev/null || true

  MAIN_RAW=$(cat "$MAIN_RESULT_FILE" 2>/dev/null)
  SEC_RAW=$(cat "$SEC_RESULT_FILE" 2>/dev/null)
  SANITY_RAW=$(cat "$SANITY_RESULT_FILE" 2>/dev/null)
  rm -f "$MAIN_PROMPT_FILE" "$SEC_PROMPT_FILE" "$SANITY_PROMPT_FILE" "$MAIN_RESULT_FILE" "$SEC_RESULT_FILE" "$SANITY_RESULT_FILE"

  if [ -z "$MAIN_RAW" ] && [ -z "$SEC_RAW" ] && [ -z "$SANITY_RAW" ]; then
    log_event warn hook.auto-review kind=codex_timeout_allow timeout="${REVIEW_TIMEOUT}s" branch="$BRANCH" reason="all_failed"
    echo "[auto-review] WARNING: all reviewers failed/timed out (${REVIEW_TIMEOUT}s); allowing push without review." >&2
    exit 0
  fi

  # If one failed, treat that side as approve to not block on infra error
  # Default the MAIN verdict to "unknown" (denies) on parse failure: a
  # garbled main response must NOT slip through as approve. The SECURITY
  # verdict, in contrast, defaults to "approve" when the reviewer was
  # disabled (SEC_RAW empty by design); only treat empty as "unknown" if
  # the security reviewer was supposed to run.
  MAIN_VERDICT=$(echo "$MAIN_RAW" | jq -r '.verdict // "unknown"' 2>/dev/null || echo "unknown")
  if [ "$SECURITY_ENABLED" = "1" ]; then
    SEC_VERDICT=$(echo "$SEC_RAW" | jq -r '.verdict // "unknown"' 2>/dev/null || echo "unknown")
  else
    SEC_VERDICT="approve"
  fi
  if [ "$SANITY_ENABLED" = "1" ]; then
    SANITY_VERDICT=$(echo "$SANITY_RAW" | jq -r '.verdict // "unknown"' 2>/dev/null || echo "unknown")
  else
    SANITY_VERDICT="n/a"
  fi

  case "$MAIN_VERDICT" in
    approve|approve-with-followups|needs-attention) ;;
    *) MAIN_VERDICT="unknown" ;;
  esac
  case "$SEC_VERDICT" in
    approve|approve-with-followups|needs-attention) ;;
    *) SEC_VERDICT="unknown" ;;
  esac
  case "$SANITY_VERDICT" in
    approve|approve-with-followups|needs-attention|n/a) ;;
    *) SANITY_VERDICT="unknown" ;;
  esac

  # Sanity downgrade: at round 0, if main says "needs-attention" but sanity
  # independently says "approve" (or approve-with-followups), the second
  # pair of eyes did not see a real blocker — treat main's findings as
  # advisory rather than blocking. This breaks round 0 → 1 → 2 → cap loops
  # where main @ low effort produces a noisy false deny.
  # Sanity is NEVER allowed to flip an "approve" main into a deny.
  SANITY_DOWNGRADED=0
  EFFECTIVE_MAIN_VERDICT="$MAIN_VERDICT"
  if [ "$SANITY_ENABLED" = "1" ] \
     && [ "$MAIN_VERDICT" = "needs-attention" ] \
     && { [ "$SANITY_VERDICT" = "approve" ] || [ "$SANITY_VERDICT" = "approve-with-followups" ]; }; then
    EFFECTIVE_MAIN_VERDICT="approve-with-followups"
    SANITY_DOWNGRADED=1
  fi

  # Combined verdict: any unknown denies; otherwise needs-attention > followups > approve.
  # Security keeps full blocking power. Main is mediated through EFFECTIVE_MAIN_VERDICT.
  if [ "$EFFECTIVE_MAIN_VERDICT" = "unknown" ] || [ "$SEC_VERDICT" = "unknown" ]; then
    COMBINED_VERDICT="unknown"
  elif [ "$EFFECTIVE_MAIN_VERDICT" = "needs-attention" ] || [ "$SEC_VERDICT" = "needs-attention" ]; then
    COMBINED_VERDICT="needs-attention"
  elif [ "$EFFECTIVE_MAIN_VERDICT" = "approve-with-followups" ] || [ "$SEC_VERDICT" = "approve-with-followups" ]; then
    COMBINED_VERDICT="approve-with-followups"
  else
    COMBINED_VERDICT="approve"
  fi

  # Merge issue lists; tag each by source. When sanity downgrades, main's
  # blockers are re-tagged as advisory so they land in followups.md instead
  # of producing a deny payload.
  if [ "$SANITY_DOWNGRADED" = "1" ]; then
    MAIN_ISSUES=$(echo "$MAIN_RAW" | jq -c '[(.issues // [])[] | . + {_source:"main", severity:"advisory", _downgraded_by:"sanity"}]' 2>/dev/null || echo "[]")
  else
    MAIN_ISSUES=$(echo "$MAIN_RAW" | jq -c '[(.issues // [])[] | . + {_source:"main"}]' 2>/dev/null || echo "[]")
  fi
  SEC_ISSUES=$(echo "$SEC_RAW"  | jq -c '[(.issues // [])[] | . + {_source:"security"}]' 2>/dev/null || echo "[]")
  if [ "$SANITY_ENABLED" = "1" ]; then
    SANITY_ISSUES=$(echo "$SANITY_RAW" | jq -c '[(.issues // [])[] | . + {_source:"sanity"}]' 2>/dev/null || echo "[]")
  else
    SANITY_ISSUES="[]"
  fi
  COMBINED_ISSUES=$(echo "${MAIN_ISSUES:-[]} ${SEC_ISSUES:-[]} ${SANITY_ISSUES:-[]}" | jq -s 'add // []' 2>/dev/null || echo "[]")

  # Drop _main/_security fields — they were unused downstream and including
  # them via --argjson breaks the entire jq call when raw responses contain
  # extra text or invalid JSON, leaving RESULT="" and VERDICT="unknown"
  # despite COMBINED_VERDICT being correct (caused spurious deny loops).
  # Fallback to unknown (denies) if jq still fails — never pass-through a
  # verdict assembled from data we couldn't parse.
  RESULT=$(jq -n --arg v "$COMBINED_VERDICT" --argjson i "$COMBINED_ISSUES" '{verdict:$v, issues:$i}' 2>/dev/null)
  if [ -z "$RESULT" ]; then
    RESULT='{"verdict":"unknown","issues":[{"severity":"blocking","summary":"verdict assembly failed"}]}'
  fi

  log_event info hook.auto-review kind=parallel_review_done branch="$BRANCH" main_verdict="$MAIN_VERDICT" sec_verdict="$SEC_VERDICT" sanity_verdict="$SANITY_VERDICT" sanity_downgraded="$SANITY_DOWNGRADED" combined="$COMBINED_VERDICT"

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
        mkdir -p "$REPO_ROOT/.claude/sspower"
        FOLLOWUPS_FILE="$REPO_ROOT/.claude/sspower/followups.md"
        {
          echo
          echo "## Round $((ROUNDS + 1)) — $(date +%Y-%m-%d) advisory followups"
          echo "$RESULT" | jq -r '.issues // [] | map(select(.severity == "advisory")) | .[] | "- [" + (.file // "?") + ":" + ((.line_start // 0)|tostring) + "] " + (.title // "untitled") + " — " + (.recommendation // "")'
        } >> "$FOLLOWUPS_FILE"
      fi
    fi
    [ -n "$ROUNDS_FILE" ] && rm -f "$ROUNDS_FILE"  # reset on convergence
[ -n "$LAST_DENY_FILE" ] && rm -f "$LAST_DENY_FILE"  # clear stability tracker
    exit 0
    ;;
esac

# ---------- Apply suggested patches (if any) ----------
APPLIED=0
APPLIED_COUNT=0
if [ "${SSPOWER_REVIEW_AUTO_APPLY:-on}" != "off" ] && [ -n "$REPO_ROOT" ]; then
  PATCH_DIR="$REPO_ROOT/.claude/sspower/proposed-fixes"
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

# Persist denied diff hash for next-run stability bypass detection.
[ -n "$LAST_DENY_FILE" ] && echo "$DIFF_HASH" > "$LAST_DENY_FILE"

log_event warn hook.auto-review kind=deny_verdict verdict="${VERDICT:-unknown}" branch="$BRANCH" round="$NEW_ROUNDS/$ROUNDS_CAP" applied="$APPLIED" effort="${ROUND_EFFORT:-default}"
jq -n --arg reason "$REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
exit 0
