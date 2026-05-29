#!/usr/bin/env bash
# sspower flow - plan->plan-review->exec->test->review->merge pipeline state machine.
#
# State: ~/.claude/sspower/flow-state.json  { version, flows: { <cwd>: {...} } }
# Keyed by working directory so multiple projects each carry their own flow.
#
# Subcommands:
#   start <task>     begin a flow at the PLAN stage
#   set-plan <path>  record the plan-file path (required before leaving PLAN)
#   advance          move to the next stage (merge -> done clears the flow)
#   back             return to EXEC - valid only from test/review/merge
#   status           print the current stage line (default)
#   orders           print ONLY the current stage's marching orders (for the hook)
#   abort            clear the flow for this directory
#
# render_orders() is the SINGLE source of truth for stage instructions:
# both `advance`/`start`/`back` (shown to the model in-terminal) and the
# `orders` subcommand (consumed by hooks/prompt-submit) call it. This is
# what makes same-turn auto-advance work - `advance` prints the next
# stage's full instructions, not just a status line.
set -uo pipefail
umask 077

STATE_DIR="${HOME}/.claude/sspower"
STATE_FILE="${STATE_DIR}/flow-state.json"
STAGES=(brainstorm plan plan-review exec test review merge)
TOTAL_STAGES="${#STAGES[@]}"
# plugin root = scripts/.. - used to build absolute paths in stage orders.
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
FLOW_SH="${PLUGIN_ROOT}/scripts/flow.sh"

die() { echo "flow: $*" >&2; exit 1; }

# Flow state key: the absolute git common dir (stable across all worktrees of
# one repo); falls back to physical cwd outside a git repo. Bare
# --git-common-dir is cwd-relative (.git vs ../.git) — force absolute.
flow_key() {
  local k
  k="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
    && [ -n "$k" ] && { printf '%s' "$k"; return; }
  pwd -P
}

# current-stage: bare stage token or empty; ALWAYS exit 0 (per-event hook
# consumer must never wedge on dep gaps). Must precede the jq hard-die.
if [ "${1:-}" = "current-stage" ]; then
  command -v jq >/dev/null 2>&1 || { printf ''; exit 0; }
  _k="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; [ -z "$_k" ] && _k="$(pwd -P)"
  [ -f "${HOME}/.claude/sspower/flow-state.json" ] || { printf ''; exit 0; }
  jq -r --arg c "$_k" '.flows[$c].stage // empty' \
    "${HOME}/.claude/sspower/flow-state.json" 2>/dev/null || printf ''
  exit 0
fi

command -v jq >/dev/null 2>&1 || die "jq is required"

CWD="$(flow_key)"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$STATE_DIR" || die "cannot create $STATE_DIR"
[ -L "$STATE_FILE" ] && die "refusing to follow symlink: $STATE_FILE"

# --- serialize state access -------------------------------------------
# flow-state.json is shared across projects; concurrent flow.sh runs would
# read-modify-write-clobber each other's flows entry. An atomic-mkdir mutex
# serializes the whole (short-lived) invocation. A lock held >~10s is
# presumed stale and broken. Released on EXIT (covers `die`'s exit 1 too).
_FLOW_LOCK="${STATE_DIR}/.flow.lock"
_flow_locked=0
_flow_unlock() { [ "$_flow_locked" = 1 ] && rmdir "$_FLOW_LOCK" 2>/dev/null; _flow_locked=0; }
trap '_flow_unlock' EXIT
_flow_tries=0
_flow_breaks=0
while :; do
  if mkdir "$_FLOW_LOCK" 2>/dev/null; then _flow_locked=1; break; fi
  _flow_tries=$((_flow_tries + 1))
  if [ "$_flow_tries" -gt 200 ]; then           # ~10s → presume holder dead
    rmdir "$_FLOW_LOCK" 2>/dev/null || true     # break the stale lock, then
    _flow_tries=0                               # resume waiting — a fresh
    _flow_breaks=$((_flow_breaks + 1))          # holder is live, not stale
    [ "$_flow_breaks" -gt 3 ] && \
      die "cannot acquire state lock ($_FLOW_LOCK) — remove it manually"
  fi
  sleep 0.05
done
# invariant past this point: _flow_locked=1 (every state write holds the
# mutex; an unacquirable lock dies above rather than writing unlocked).

# First-use init — inside the lock, so concurrent first runs cannot race
# to create the state file.
[ -f "$STATE_FILE" ] || printf '{"version":1,"flows":{}}\n' > "$STATE_FILE"
chmod 600 "$STATE_FILE" 2>/dev/null || true

# Migration: legacy pwd-keyed flows → common-dir key (one-time, in-lock).
_legacy="$(pwd -P)"
if [ "$_legacy" != "$CWD" ]; then
  jq --arg old "$_legacy" --arg new "$CWD" '
    if (.flows[$old] != null) and (.flows[$new] == null)
    then .flows[$new] = .flows[$old] | del(.flows[$old]) else . end' \
    "$STATE_FILE" > "${STATE_FILE}.mig" 2>/dev/null \
    && mv "${STATE_FILE}.mig" "$STATE_FILE" || rm -f "${STATE_FILE}.mig"
fi

jq_get() { jq -r --arg c "$CWD" "$1" "$STATE_FILE" 2>/dev/null; }

jq_set() {
  # $1 = jq filter mutating the document; $2.. = extra jq args (e.g. --arg t X)
  local filter="$1"; shift
  local tmp
  tmp="$(mktemp "${STATE_DIR}/.flow.XXXXXX")" || die "mktemp failed"
  if jq --arg c "$CWD" --arg n "$NOW" "$@" "$filter" "$STATE_FILE" > "$tmp"; then
    mv "$tmp" "$STATE_FILE"
  else
    rm -f "$tmp"; die "state write failed"
  fi
}

idx_of() {
  local i
  for i in "${!STAGES[@]}"; do
    [ "${STAGES[$i]}" = "$1" ] && { echo "$i"; return 0; }
  done
  echo -1
}

stage="$(jq_get '.flows[$c].stage // empty')"
task="$(jq_get '.flows[$c].task // empty')"
plan_path="$(jq_get '.flows[$c].plan_path // empty')"
design_path="$(jq_get '.flows[$c].design_path // empty')"
wt="$(jq_get '.flows[$c].worktree // false')"
wt_path="$(jq_get '.flows[$c].worktree_path // empty')"

# --- review markers -----------------------------------------------------
# Marker root derives from the SAME git-common-dir as the state key, so markers
# are stable across worktrees (show-toplevel differs per worktree → would
# fragment, codex plan-review). dirname(common-dir) = main worktree root.
_common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
if [ -n "$_common" ]; then MARK_DIR="$(dirname "$_common")/.claude/sspower"; else MARK_DIR="$(pwd -P)/.claude/sspower"; fi
_sha8() { git hash-object "$1" 2>/dev/null | cut -c1-8; }   # file content hash

# set_review <kind> <verdict> : kind = design|plan
set_review() {
  local kind="$1" verdict="$2" path hash
  case "$kind" in
    design) path="$design_path" ;;
    plan)   path="$plan_path" ;;
    *) die "set_review: kind must be design|plan" ;;
  esac
  [ -n "$path" ] && [ -f "$path" ] || die "$kind review: recorded $kind file missing ($path)"
  case "$verdict" in approve) ;; *) die "$kind review: verdict must be exactly 'approve' (got: $verdict)" ;; esac
  hash="$(_sha8 "$path")"
  mkdir -p "$MARK_DIR"
  printf '{"verdict":"%s","file_hash":"%s","ts":"%s"}\n' "$verdict" "$hash" "$NOW" \
    > "${MARK_DIR}/${kind}-review.${hash}.json"
  echo "flow: ${kind}-review recorded (approve, ${hash})"
}

# review_ok <kind> : 0 if a marker matches the CURRENT file hash
review_ok() {
  local kind="$1" path hash
  case "$kind" in design) path="$design_path" ;; plan) path="$plan_path" ;; esac
  [ -n "$path" ] && [ -f "$path" ] || return 1
  hash="$(_sha8 "$path")"
  [ -f "${MARK_DIR}/${kind}-review.${hash}.json" ]
}

print_status() {
  if [ -z "$stage" ]; then
    echo "flow: idle (no active flow in $CWD)"
    return
  fi
  local i; i="$(idx_of "$stage")"
  echo "flow: ${stage} ($((i + 1))/${TOTAL_STAGES}) - task: ${task}${plan_path:+ - plan: ${plan_path}}"
}

# SINGLE source of truth for stage marching orders. Emits the instruction
# paragraph for $1; emits nothing for idle/unknown stages.
render_orders() {
  local s="$1" n ref=""
  n="$(idx_of "$s")"; n=$((n + 1))
  [ -n "$plan_path" ] && ref=" Plan file: ${plan_path}."
  local t="${TOTAL_STAGES}"
  case "$s" in
    plan)
      printf 'FLOW[plan %d/%d] - task: "%s". Stage = PLAN. Invoke the sspower:writing-plans skill. Produce the plan only - no implementation code. When the plan file exists, run: bash "%s" set-plan <path-to-plan>, then bash "%s" advance. Auto-advance is on - drive the whole pipeline yourself, stop only on failure.' \
        "$n" "$t" "$task" "$FLOW_SH" "$FLOW_SH" ;;
    plan-review)
      printf 'FLOW[plan-review %d/%d] - task: "%s".%s Stage = PLAN-REVIEW. Review the plan: run `node "%s/scripts/codex-bridge.mjs" plan-review --cd "%s" --prompt @%s`. Fix every high/medium finding inline and re-run until the verdict is approve or approve-with-followups. Then run: bash "%s" advance.' \
        "$n" "$t" "$task" "$ref" "$PLUGIN_ROOT" "$CWD" "${plan_path:-<plan-path>}" "$FLOW_SH" ;;
    exec)
      printf 'FLOW[exec %d/%d] - task: "%s".%s Stage = EXEC. Plan approved. Invoke sspower:executing-plans (or test-driven-development for a feature/bugfix) and implement the plan. If the work is fan-out-shaped (many independent files/sites, >=8), first invoke sspower:dispatching-parallel-agents to route - small batches via the Task tool, large (>=8 units) or verification-heavy work via sspower:orchestrating-workflows (a native Workflow); keep git out of fan-out agents. When implementation is complete, run: bash "%s" advance.' \
        "$n" "$t" "$task" "$ref" "$FLOW_SH" ;;
    test)
      printf 'FLOW[test %d/%d] - task: "%s". Stage = TEST. Invoke sspower:verification-before-completion. Run tests, type-check, lint - real commands, real output. PASS -> run: bash "%s" advance. FAIL -> run: bash "%s" back (returns to EXEC), fix, retry. Never advance with failures outstanding.' \
        "$n" "$t" "$task" "$FLOW_SH" "$FLOW_SH" ;;
    review)
      printf 'FLOW[review %d/%d] - task: "%s". Stage = REVIEW. Invoke sspower:requesting-code-review on the diff. For a broad multi-dimension pass, sspower:orchestrating-workflows can fan out adversarial verifiers (incl. a codex lens) in the background. If a blocker needs a code change, run: bash "%s" back. When the review is clean, run: bash "%s" advance - moves to MERGE.' \
        "$n" "$t" "$task" "$FLOW_SH" "$FLOW_SH" ;;
    merge)
      printf 'FLOW[merge %d/%d] - task: "%s". Stage = MERGE. Auto-finish: (1) Align docs (handoff.md / CLAUDE.md / touched design docs) with the latest code; show diffs before staging. (2) Write commit message to /tmp/sspower-flow-commit.txt (Conventional Commits, terse, why-over-what). (3) Stage specific paths, then: git -C "%s" commit -F /tmp/sspower-flow-commit.txt (standalone, no chained ops). (4) git -C "%s" push (standalone). (5) Check current branch with: git -C "%s" rev-parse --abbrev-ref HEAD. If on a feature branch: confirm with the user, then git -C "%s" checkout main, git -C "%s" merge --no-ff <branch> (standalone), git -C "%s" push (standalone). If already on main: skip the checkout+merge step. (6) Invoke the sspower:handoff skill (or `/handoff`) to write the next-session resume doc. (7) Run: bash "%s" advance - completes and clears the flow. Hard rules: chokepoints (commit/push/merge) MUST be standalone Bash calls — no &&, ;, ||. Auto-review hook gates them on the REVIEW-stage codex verdict — if it denies, run: bash "%s" back, fix, retry. To skip the merge stage for a flow that does not need a branch merge, run: bash "%s" advance now (clears the flow without further action).' \
        "$n" "$t" "$task" "$CWD" "$CWD" "$CWD" "$CWD" "$CWD" "$CWD" "$FLOW_SH" "$FLOW_SH" "$FLOW_SH" ;;
    *)
      : ;;
  esac
}

# status line + the next stage's marching orders - what the model sees
# in-terminal after start/advance/back, so it can continue the same turn.
print_stage() {
  print_status
  local o; o="$(render_orders "$stage")"
  [ -n "$o" ] && { echo; echo "$o"; }
}

cmd="${1:-status}"
case "$cmd" in
  start)
    shift
    start_stage="plan"
    if [ "${1:-}" = "--stage" ]; then start_stage="${2:?--stage requires a value}"; shift 2; fi
    case "$start_stage" in brainstorm|plan) ;; *) die "start --stage must be brainstorm|plan" ;; esac
    task="$*"
    [ -n "$task" ] || die "usage: flow start [--stage brainstorm|plan] <task>"
    [ -z "$stage" ] || die "flow already active (${stage}) - abort it first"
    jq_set '.flows[$c] = {stage:$s,task:$t,plan_path:"",design_path:"",worktree:false,worktree_path:"",started:$n,updated:$n}' --arg t "$task" --arg s "$start_stage"
    stage="$start_stage"; print_stage
    ;;
  set-plan)
    [ -n "$stage" ] || die "no active flow - run: flow start <task>"
    shift
    path="$*"
    [ -n "$path" ] || die "usage: flow set-plan <path-to-plan-file>"
    jq_set '.flows[$c].plan_path = $p | .flows[$c].updated = $n' --arg p "$path"
    plan_path="$path"
    echo "flow: plan recorded - $path"
    ;;
  set-design)
    [ -n "$stage" ] || die "no active flow"
    shift; p="$*"; [ -n "$p" ] || die "usage: flow set-design <path>"
    jq_set '.flows[$c].design_path = $p | .flows[$c].updated = $n' --arg p "$p"
    design_path="$p"; echo "flow: design recorded - $p" ;;
  set-design-review) shift; set_review design "${1:-}" ;;
  set-plan-review)   shift; set_review plan   "${1:-}" ;;
  enter-worktree)
    [ -n "$stage" ] || die "no active flow"
    shift; p="$*"; [ -n "$p" ] || die "usage: flow enter-worktree <path>"
    [ -d "$p" ] || git worktree add "$p" >/dev/null 2>&1 || die "could not create worktree $p"
    wt_abs="$(cd "$p" && pwd -P)"
    jq_set '.flows[$c].worktree = true | .flows[$c].worktree_path = $p | .flows[$c].updated = $n' --arg p "$wt_abs"
    echo "flow: worktree recorded - $wt_abs"
    echo "NEXT: run subsequent tools with cwd=$wt_abs (or 'git -C $wt_abs'), then: bash \"$FLOW_SH\" advance" ;;
  advance)
    [ -n "$stage" ] || die "no active flow - run: flow start <task>"
    # Enforce the CURRENT stage's exit gate before computing the next stage.
    # Every die names its unblock command (wedge-safety, D-HF5).
    case "$stage" in
      brainstorm)
        [ -n "$design_path" ] || die "design path required - run: flow set-design <path>"
        review_ok design || die "design-review not approved - run codex plan-review, then: flow set-design-review approve" ;;
      plan)
        [ -z "$plan_path" ] && die "plan path required - run: flow set-plan <path>" ;;
      plan-review)
        review_ok plan || die "plan-review not approved - run codex plan-review, then: flow set-plan-review approve"
        # if worktree opted-in, it must exist + cwd inside before entering exec
        if [ "$wt" = "true" ]; then
          [ -n "$wt_path" ] && [ -d "$wt_path" ] || die "worktree opted-in but missing - run: flow enter-worktree <path>"
          case "$(pwd -P)" in "$wt_path"*) ;; *) die "cwd not inside worktree $wt_path - cd there first, then advance" ;; esac
        fi ;;
      test)
        [ -f "${MARK_DIR}/test-result.json" ] || echo "flow: WARN no test-result.json - advancing test->review without a test artifact (soft gate)" >&2 ;;
    esac
    i="$(idx_of "$stage")"
    [ "$i" -ge 0 ] || die "corrupt state (stage=$stage)"
    if [ "$i" -ge $((${#STAGES[@]} - 1)) ]; then
      jq_set 'del(.flows[$c])'
      echo "flow: complete - pipeline finished, state cleared"
    else
      next="${STAGES[$((i + 1))]}"
      jq_set '.flows[$c].stage = $s | .flows[$c].updated = $n' --arg s "$next"
      stage="$next"; print_stage
    fi
    ;;
  back)
    [ -n "$stage" ] || die "no active flow"
    case "$stage" in
      test|review|merge) ;;
      *) die "back is valid only from test/review/merge (current stage: $stage)" ;;
    esac
    jq_set '.flows[$c].stage = "exec" | .flows[$c].updated = $n'
    stage="exec"; print_stage
    ;;
  abort)
    [ -n "$stage" ] || { echo "flow: idle - nothing to abort"; exit 0; }
    jq_set 'del(.flows[$c])'
    echo "flow: aborted - state cleared for $CWD"
    ;;
  orders) render_orders "$stage" ;;
  status) print_status ;;
  *) die "unknown subcommand: $cmd (use start|set-plan|set-design|set-design-review|set-plan-review|enter-worktree|advance|back|status|orders|abort|current-stage)" ;;
esac
