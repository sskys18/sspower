# Implementation Plan — Hardened auto-steer flow

Spec: `docs/specs/2026-05-29-hardened-autosteer-flow-design.md` (D-HF1..6).
Decisions: D-HF1 (funnel/soft-ask), D-HF2 (stages+narrow design intent),
D-HF3 (advance-gating+markers), D-HF4 (flow-fence), D-HF5 (wedge-safety),
D-HF6 (fences main-thread-only; Workflow subagents exempt — `[High]`: hooks
DO fire for subagents).

TDD throughout. **Commits are SUPERVISOR-run** (the executing agent reports each
task group done; the main thread / human commits — a codex worker must not
commit). All new shell code: `set -uo pipefail`, fail-open in hooks, `bash -n`
before commit.

> **Codex plan-review applied (2 med / 3 low + 2 structural):** worktree is now a
> **property, not a stage** (the stage was unreachable — chicken-egg on `wt`);
> marker root derives from the **same git-common-dir** as the state key (was
> `show-toplevel`, which differs per worktree); `--stage` parsing guarded under
> `set -u`. Remaining med/low (test `grep -F`, hooks.json order, setup guards,
> stale line-numbers — treat line refs as hints, anchor on text) are resolved
> per-task during TDD execution.

## Files

| File | Action | Responsibility |
|---|---|---|
| `scripts/flow.sh` | modify | stages, state re-key, advance-gating, markers, `current-stage`, `enter-worktree`, `start --stage`, render gate line |
| `hooks/flow-fence.sh` | **new** | PreToolUse fence (Write\|Edit\|MultiEdit\|Bash) — soft-`ask`, subagent-exempt |
| `hooks/hooks.json` | modify | register flow-fence on PreToolUse Write\|Edit\|MultiEdit + Bash |
| `hooks/_intent.sh` | modify | add narrow `design` class |
| `hooks/prompt-submit` | modify | route `design` → `start --stage brainstorm` |
| `tests/hooks/test_flow.sh` | modify | new stages, gate denials, marker hash-staleness, re-key+migration |
| `tests/hooks/test_flow_fence.sh` | **new** | fence allow/ask per stage + subagent-exempt |
| `tests/hooks/test_intent.sh` | modify | `design` vs `multi-step`, `architecture` flow-free |

---

## Task group A — flow.sh state model (re-key + stages + current-stage)

### A1. Test: state keyed by absolute git-common-dir (RED)

Add to `tests/hooks/test_flow.sh` after the existing setup helper:

```bash
# --- git-common-dir re-key: same flow visible from repo root and subdir ---
setup
gitrepo="$(mktemp -d)"; ( cd "$gitrepo" && git init -q )
( cd "$gitrepo" && bash "$FLOW" start "rekey-test" >/dev/null )
mkdir -p "$gitrepo/sub"
out="$( cd "$gitrepo/sub" && bash "$FLOW" current-stage )"
check "flow visible from subdir via common-dir key" "plan" "$out"  # default start = plan stage
( cd "$gitrepo" && bash "$FLOW" abort >/dev/null )
teardown
```

Run: `bash tests/hooks/test_flow.sh` → expect FAIL (no `current-stage` yet; key still `pwd`).

### A2. Implement re-key in flow.sh (GREEN)

In `scripts/flow.sh`, replace the `CWD` assignment (line 35
`CWD="$(pwd -P)"`) with a stable flow key:

```bash
# Flow state key: the absolute git common dir (stable across all worktrees of
# one repo); falls back to physical cwd outside a git repo. Bare
# --git-common-dir is cwd-relative (.git vs ../.git) — force absolute.
flow_key() {
  local k
  k="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
    && [ -n "$k" ] && { printf '%s' "$k"; return; }
  pwd -P
}
CWD="$(flow_key)"
```

One-time migration (insert right after the first-use init at line 68, inside
the lock): if a legacy `pwd -P` entry exists for this repo and no common-dir
entry does, move it.

```bash
# Migration: legacy pwd-keyed flows → common-dir key (one-time, in-lock).
_legacy="$(pwd -P)"
if [ "$_legacy" != "$CWD" ]; then
  jq --arg old "$_legacy" --arg new "$CWD" '
    if (.flows[$old] != null) and (.flows[$new] == null)
    then .flows[$new] = .flows[$old] | del(.flows[$old]) else . end' \
    "$STATE_FILE" > "${STATE_FILE}.mig" 2>/dev/null \
    && mv "${STATE_FILE}.mig" "$STATE_FILE" || rm -f "${STATE_FILE}.mig"
fi
```

### A3. Add `current-stage` subcommand (machine output, fail-open)

`current-stage` must NEVER inherit the top-level `jq`-missing hard-die
(flow.sh:33). Add a dedicated early branch BEFORE the `command -v jq … die`
line (line 33), so missing deps print empty + exit 0:

```bash
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
```

### A4. STAGES array + worktree skip

Replace `STAGES=(plan plan-review exec test review merge)` (anchor: the
`STAGES=` line) with:

```bash
STAGES=(brainstorm plan plan-review exec test review merge)
```

`brainstorm` is naturally skipped by plan-started flows (advance only moves
forward from the start stage). **Worktree is NOT a stage** — it's an optional
*property* (`worktree:true` + `worktree_path`) set by `enter-worktree` during
plan-review/exec; the exec-stage fence/gate enforces "cwd inside the worktree
when `worktree:true`" (B3/D1). This avoids the unreachable-stage chicken-egg
(codex plan-review).

### A5. `start --stage <name>` (design entry)

In the `start)` case (line 147-154), parse an optional `--stage`:

```bash
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
```

Verify A1-A5: `bash -n scripts/flow.sh && bash tests/hooks/test_flow.sh` →
the re-key test passes. **Commit:** `feat(flow): git-common-dir state key + current-stage + brainstorm/worktree stages`.

---

## Task group B — advance-gating + markers

### B1. Marker helpers (design-review + plan-review)

Add near `jq_get` (after line 95). Markers live under the project root, JSON
with verdict+hash+ts; pass-set is **exact `approve`** (matches the shipped
contract that `auto-spec-gate.sh:291` used — D-A5 successor):

```bash
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
```

Add state reads near line 93-95: `design_path="$(jq_get '.flows[$c].design_path // empty')"`, `wt="$(jq_get '.flows[$c].worktree // false')"`, `wt_path="$(jq_get '.flows[$c].worktree_path // empty')"`.

### B2. `set-design`, `set-design-review`, `set-plan-review` subcommands

Add cases alongside `set-plan`:

```bash
  set-design)
    [ -n "$stage" ] || die "no active flow"
    shift; p="$*"; [ -n "$p" ] || die "usage: flow set-design <path>"
    jq_set '.flows[$c].design_path = $p | .flows[$c].updated = $n' --arg p "$p"
    design_path="$p"; echo "flow: design recorded - $p" ;;
  set-design-review) shift; set_review design "${1:-}" ;;
  set-plan-review)   shift; set_review plan   "${1:-}" ;;
```

### B3. Advance-gating + worktree skip

Replace the `advance)` body (lines 164-181) gate logic. Before computing the
next stage, enforce the CURRENT stage's exit gate; after, skip `worktree` when
not opted in:

```bash
  advance)
    [ -n "$stage" ] || die "no active flow - run: flow start <task>"
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
    i="$(idx_of "$stage")"; [ "$i" -ge 0 ] || die "corrupt state (stage=$stage)"
    if [ "$i" -ge $((${#STAGES[@]} - 1)) ]; then
      jq_set 'del(.flows[$c])'; echo "flow: complete - pipeline finished, state cleared"
    else
      next="${STAGES[$((i + 1))]}"
      jq_set '.flows[$c].stage = $s | .flows[$c].updated = $n' --arg s "$next"
      stage="$next"; print_stage
    fi ;;
```

### B4. `enter-worktree` (records + prints; cannot cd caller)

```bash
  enter-worktree)
    [ -n "$stage" ] || die "no active flow"
    shift; p="$*"; [ -n "$p" ] || die "usage: flow enter-worktree <path>"
    [ -d "$p" ] || git worktree add "$p" >/dev/null 2>&1 || die "could not create worktree $p"
    wt_abs="$(cd "$p" && pwd -P)"
    jq_set '.flows[$c].worktree = true | .flows[$c].worktree_path = $p | .flows[$c].updated = $n' --arg p "$wt_abs"
    echo "flow: worktree recorded - $wt_abs"
    echo "NEXT: run subsequent tools with cwd=$wt_abs (or 'git -C $wt_abs'), then: bash \"$FLOW_SH\" advance" ;;
```

### B5. Tests for gating (RED→GREEN)

Add to `test_flow.sh`: assert `advance` from `plan-review` dies without a
plan-review marker; passes after `set-plan-review approve`; marker goes stale
after the plan file changes (re-hash). Example:

```bash
setup
bash "$FLOW" start "gate-test" >/dev/null
echo "plan v1" > "$WORK/plan.md"; bash "$FLOW" set-plan "$WORK/plan.md" >/dev/null
bash "$FLOW" advance >/dev/null  # plan->plan-review
out="$(bash "$FLOW" advance 2>&1)"; rc=$?
check "advance blocked w/o plan-review marker" "plan-review not approved" "$out"
[ "$rc" -ne 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
bash "$FLOW" set-plan-review approve >/dev/null
out="$(bash "$FLOW" advance)"; check "advance ok after approve" "Stage = EXEC" "$out"
teardown
```

Verify: `bash -n scripts/flow.sh && bash tests/hooks/test_flow.sh`.
**Commit:** `feat(flow): advance-gating + hash-keyed review markers + enter-worktree`.

---

## Task group C — render_orders (stage orders + gate line, M3)

### C1. Add brainstorm/worktree stage orders + gate line

In `render_orders` (line 108-135), add cases for `brainstorm` and `worktree`,
and append a gate line to every stage so post-compaction the model sees the
exit condition. Brainstorm:

```bash
    brainstorm)
      printf 'FLOW[brainstorm %d/%d] - task: "%s". Stage = BRAINSTORM. Invoke sspower:brainstorming. Produce a reviewed design doc. When approved, run: bash "%s" set-design <path>, run codex plan-review on it, then: bash "%s" set-design-review approve, then: bash "%s" advance. Gate to advance: design doc recorded + design-review approved.' \
        "$n" "$t" "$task" "$FLOW_SH" "$FLOW_SH" "$FLOW_SH" ;;
```

(No `worktree` stage — it's a property.) Append ` Gate to advance: <X>.` to the
existing plan/plan-review/exec/test/review/merge order strings (one literal
clause each; no new %s). For plan-review add: `Gate to advance: plan-review
marker approved (flow set-plan-review approve). Optional: bash "<flow>"
enter-worktree <path> to isolate before exec.`

### C2. Test

`test_flow.sh`: `check "brainstorm orders" "Stage = BRAINSTORM" "$(... orders at brainstorm)"` and `check "orders carry gate line" "Gate to advance" "$out"`.

**Commit:** `feat(flow): brainstorm/worktree orders + advance-gate hints`.

---

## Task group D — flow-fence.sh (soft-ask, subagent-exempt, M1/D-HF6)

### D1. New hook `hooks/flow-fence.sh`

```bash
#!/usr/bin/env bash
# PreToolUse fence: out-of-phase source mutations -> permission "ask".
# Main-thread only; Workflow/Task subagents EXEMPT (D-HF6). Fail-open: any
# uncertainty -> allow (wedge-priority).
set -uo pipefail
[ "${SSPOWER_FLOW_FENCE:-on}" = "off" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0
INPUT="$(cat 2>/dev/null || true)"

# Subagent-exempt: hooks fire for subagents (D-WF3/D-HF6 [High]); pass when an
# agent context is present.
agent_id="$(printf '%s' "$INPUT" | jq -r '.agent_id // .agent_type // empty' 2>/dev/null || true)"
[ -n "$agent_id" ] && exit 0

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -n "$CWD" ] && [ -d "$CWD" ] && CWD="$(cd "$CWD" && pwd -P)" || CWD="$(pwd -P)"
stage="$(cd "$CWD" 2>/dev/null && bash "$PLUGIN_ROOT/scripts/flow.sh" current-stage 2>/dev/null || true)"
[ -n "$stage" ] || exit 0   # idle -> no fence

tool="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')"
proot="$(cd "$CWD" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$CWD")"

# collect target paths (Write/Edit file_path + MultiEdit edits[])
paths="$(printf '%s' "$INPUT" | jq -r '[.tool_input.file_path // empty, (.tool_input.edits[]?.file_path // empty)] | .[]' 2>/dev/null || true)"

allowed_path() { case "$1" in "$proot"/docs/*|"$proot"/.claude/*|/tmp/*|"$proot"/*plan*.md|"$proot"/*design*.md) return 0;; *) return 1;; esac; }

ask() { printf '%s' "$1" | jq -Rs '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:.}}'; exit 0; }

case "$stage" in
  brainstorm|plan|plan-review)
    while IFS= read -r p; do [ -z "$p" ] && continue
      allowed_path "$p" || ask "FLOW[$stage]: editing $p now skips the plan. Finish the $stage stage first, or allow to override."
    done <<< "$paths" ;;
  test|review|merge)
    while IFS= read -r p; do [ -z "$p" ] && continue
      allowed_path "$p" || ask "FLOW[$stage]: you're past exec. To change code run: flow back (returns to exec). Allow to override."
    done <<< "$paths" ;;
esac
# Bash arm: conservative mutation detection (only in plan-ish stages)
if [ "$tool" = "Bash" ]; then
  case "$stage" in brainstorm|plan|plan-review)
    cmd="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')"
    case "$cmd" in *"sed -i"*|*" tee "*|*">"*|*"git checkout"*|*"git restore"*)
      ask "FLOW[$stage]: that Bash command may write source during $stage. Allow to override." ;;
    esac ;;
  esac
fi
exit 0
```

### D2. Register in `hooks/hooks.json`

Add a PreToolUse entry for `Write|Edit|MultiEdit` and append flow-fence to the
existing Bash chain (after auto-review). Exact JSON:

```json
{ "matcher": "Write|Edit|MultiEdit",
  "hooks": [ { "type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/flow-fence.sh\"" } ] }
```
and add the same command object to the existing `"matcher": "Bash"` hooks array
(last, after `auto-review.sh`).

### D3. New test `tests/hooks/test_flow_fence.sh`

```bash
#!/usr/bin/env bash
set -uo pipefail
HOOK="$(cd "$(dirname "$0")/../.." && pwd)/hooks/flow-fence.sh"
FLOW="$(cd "$(dirname "$0")/../.." && pwd)/scripts/flow.sh"
PASS=0; FAIL=0
ck(){ if printf '%s' "$3" | grep -q "$2"; then echo "ok  - $1"; PASS=$((PASS+1)); else echo "FAIL- $1 (want $2)"; FAIL=$((FAIL+1)); fi; }

R="$(mktemp -d)"; ( cd "$R" && git init -q ); ( cd "$R" && bash "$FLOW" start --stage plan "fence" >/dev/null )

# src write in plan stage -> ask
out="$(printf '{"tool_name":"Write","cwd":"%s","tool_input":{"file_path":"%s/src/x.ts"}}' "$R" "$R" | bash "$HOOK")"
ck "plan: src write -> ask" '"permissionDecision":"ask"' "$out"
# docs write -> allow (empty)
out="$(printf '{"tool_name":"Write","cwd":"%s","tool_input":{"file_path":"%s/docs/x.md"}}' "$R" "$R" | bash "$HOOK")"
ck "plan: docs write -> allow" '^$' "$out"
# subagent context -> exempt (allow) even for src
out="$(printf '{"tool_name":"Write","cwd":"%s","agent_id":"abc","tool_input":{"file_path":"%s/src/x.ts"}}' "$R" "$R" | bash "$HOOK")"
ck "subagent src write -> exempt" '^$' "$out"
# fence off -> allow
out="$(SSPOWER_FLOW_FENCE=off printf '{"tool_name":"Write","cwd":"%s","tool_input":{"file_path":"%s/src/x.ts"}}' "$R" "$R" | SSPOWER_FLOW_FENCE=off bash "$HOOK")"
ck "fence off -> allow" '^$' "$out"

( cd "$R" && bash "$FLOW" abort >/dev/null )
echo "passed:$PASS failed:$FAIL"; [ "$FAIL" -eq 0 ]
```

Verify: `bash -n hooks/flow-fence.sh && bash tests/hooks/test_flow_fence.sh`.
**Commit:** `feat(hooks): flow-fence soft-ask phase fence (subagent-exempt)`.

---

## Task group E — intent design class + routing

### E1. Add narrow `design` class to `hooks/_intent.sh`

Before the multi-step test (line ~115), add a `design` branch matching ONLY
ideation framing (bare build/implement stay multi-step):

```bash
  # design: explicit ideation framing only (narrow — bare build/implement
  # stay multi-step). D-HF2 / codex R2 #5. $p is the lowercased prompt.
  case "$p" in
    "design "*|*" design a "*|*" design the "*|*"how should we structure"*|*"explore options"*|*"brainstorm"*|*"should we "*)
      echo design; return 0 ;;
  esac
```
(Glob, not regex — `"design "*` anchors the literal prefix; the `*" design a "*`
forms catch mid-sentence framing. Place this AFTER the explicit-skill/qa guards
but BEFORE the multi-step action-verb test so bare `build`/`implement` fall
through to multi-step.)

### E2. Route `design` → brainstorm in `hooks/prompt-submit`

In the classify+route block (after line 93 `INTENT=...`), add a `design`
branch mirroring the `multi-step` auto-start but with `--stage brainstorm`:

```bash
  design)
    if ( cd "$CWD" 2>/dev/null && bash "$FLOW_SH" start --stage brainstorm "$TASK" ) >/dev/null 2>&1; then
      ORDERS="$(cd "$CWD" 2>/dev/null && bash "$FLOW_SH" orders 2>/dev/null || true)"
      [ -n "$ORDERS" ] && emit "AUTO-FLOW (design): brainstorm pipeline started. Quick single answer? run: bash \"$FLOW_SH\" abort. Else: ${ORDERS}"
    fi ;;
```

### E3. Tests in `tests/hooks/test_intent.sh`

```bash
ck "design: 'design a cache layer'" design "$(sspower_classify_intent 'design a cache layer')"
ck "design: 'how should we structure X'" design "$(sspower_classify_intent 'how should we structure the auth module')"
ck "multi-step stays: 'build the login page'" multi-step "$(sspower_classify_intent 'build the login page and wire the api')"
ck "architecture stays flow-free: 'what calls foo'" architecture "$(sspower_classify_intent 'what calls foo')"
```

Verify: `bash tests/hooks/test_intent.sh`.
**Commit:** `feat(intent): narrow design class -> brainstorm auto-start`.

---

## Final verification

```bash
bash -n scripts/flow.sh hooks/flow-fence.sh hooks/prompt-submit
bash tests/hooks/test_flow.sh
bash tests/hooks/test_flow_fence.sh
bash tests/hooks/test_intent.sh
python3 -c "import json;json.load(open('hooks/hooks.json'))"  # valid JSON after edit
```

All green → the hardened flow is wired. Wedge-safety check: confirm every
`die` in advance-gating names an unblock command, and `SSPOWER_FLOW_FENCE=off`
+ `flow abort` short-circuit.

## Out of scope (deferred per spec)

- test-artifact writer (`test-result.json`) — soft gate only; decide who emits.
- false-deny allow-list tuning on real monorepos.
- `auto-spec-gate.sh` delete-vs-keep (D-A5 dead code; left documented).
