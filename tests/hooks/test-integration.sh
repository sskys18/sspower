#!/usr/bin/env bash
# Hook integration tests — Track B P6 cleanup C4 (spec §9 "hook
# integration tests green").
#
# Drives the REAL PreToolUse:Bash hook (hooks/auto-review.sh) end to
# end. The ONLY mock is the external boundary: a stub codex-bridge.mjs
# (selected via CLAUDE_PLUGIN_ROOT) that records argv and never calls
# Codex/network. Every assertion is isolated and hermetic — all state
# (log file, verdict cache, git repo, rounds file, bridge args) lives
# under a per-run mktemp dir wiped on EXIT.
#
# NOTE ON TASK WORDING (deviation, see report):
#   The task references a hook "chained-shell-check.sh" and a chained
#   `git commit && echo`. No such hook exists — chain policy lives in
#   hooks/auto-review.sh:91-116. And `git commit` is NOT a chokepoint
#   (auto-review.sh:65-72 triggers only on git push/merge, gh pr
#   create/ready), so `git commit && echo` would exit 0 with no
#   decision. We exercise the REAL chain branch with `git push && echo`
#   (DENY) and `git push > /tmp/f` (ALLOW), driving the real hook.
#
# Groups:
#   (a) chain policy   — push&&echo DENY, push>file ALLOW, ls sanity ALLOW
#   (b) round cap      — rounds file == cap → deny_rounds_cap, no spawn
#   (c) verdict cache  — same diff hash twice → 2nd cache-served, no spawn
#
# Cache-hit observability: hooks/auto-review.sh emits NO log line on a
# cache hit (the cached RESULT is read silently at :245-252). The real
# observable cache-hit signals, asserted below, are:
#   - bridge NOT spawned on run 2 (stub args file empty)
#   - rounds counter NOT incremented on run 2 (auto-review.sh:599 gates
#     the increment on CACHE_HIT=0)
#   - the codex-spawn-only log line `kind=parallel_review_done` appears
#     exactly once (run 1 miss) across both runs

set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOKS="$ROOT/hooks"
REVIEW="$HOOKS/auto-review.sh"

PASS=0
FAIL=0

assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "  ok   $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL $label"
    echo "       want: $want"
    echo "       got : $got"
    FAIL=$((FAIL + 1))
  fi
}

# Hard dependency gate: the real hook bails early (auto-review.sh:50-52)
# without jq/node/python3. Skip cleanly rather than emit false FAILs.
for dep in jq node python3 git; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    echo "  skip — $dep not installed; auto-review.sh is inert without it"
    echo
    echo "passed: 0"
    echo "failed: 0"
    exit 0
  fi
done

WORK=$(mktemp -d -t sspower-hookint-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ---- Stub bridge: external boundary only (no Codex / no network) -----
# Records argv to SSPOWER_TEST_ARGS_FILE and prints a verdict. Selected
# by the real hook via CLAUDE_PLUGIN_ROOT (auto-review.sh:141).
#
# Verdict is configurable so the verdict-ASSEMBLY group can drive
# distinct per-reviewer responses without ever calling Codex:
#   - default (env unset)        -> {"verdict":"approve",...} (keeps the
#                                    chain/cap/cache groups unchanged)
#   - SSPOWER_STUB_MAIN_VERDICT  -> verdict for the MAIN reviewer
#       (the hook invokes main with `--profile`; auto-review.sh:387)
#   - SSPOWER_STUB_SEC_VERDICT   -> verdict for the SECURITY reviewer
#       (invoked with `--effort`; auto-review.sh:409). Sanity also uses
#       `--effort` but is disabled by default (SSPOWER_SANITY_REVIEW
#       unset, auto-review.sh:420) so `--effort` == security here.
#   - SSPOWER_STUB_RAW           -> emit this raw string verbatim
#       (used to drive the unparseable -> RESULT="" -> unknown path;
#        auto-review.sh:586-589)
# A reviewer with verdict "skip" prints nothing (empty stdout) to
# exercise the empty-RAW branch (auto-review.sh:512 default "unknown").
STUB_ROOT="$WORK/stub"
mkdir -p "$STUB_ROOT/scripts"
cat > "$STUB_ROOT/scripts/codex-bridge.mjs" <<'STUB'
import fs from "node:fs";
try { fs.appendFileSync(process.env.SSPOWER_TEST_ARGS_FILE, JSON.stringify(process.argv.slice(2)) + "\n"); } catch {}
const argv = process.argv.slice(2);
const isMain = argv.includes("--profile");
const raw = process.env.SSPOWER_STUB_RAW;
if (raw !== undefined && raw !== "") { process.stdout.write(raw); process.exit(0); }
let v = isMain
  ? (process.env.SSPOWER_STUB_MAIN_VERDICT || "approve")
  : (process.env.SSPOWER_STUB_SEC_VERDICT || "approve");
if (v === "skip") { process.exit(0); }  // empty stdout -> hook sees ""
const issues = v === "approve" ? [] : [{
  severity: v === "needs-attention" ? "blocking" : "advisory",
  title: (isMain ? "MAIN" : "SEC") + " issue " + v,
  file: "x.txt", line_start: 1,
  recommendation: "fix it", suggested_patch: null
}];
console.log(JSON.stringify({ verdict: v, strengths: [], issues, assessment: "stub" }));
STUB

ARGS_FILE="$WORK/bridge-args.txt"
LOG_FILE="$WORK/codex.log"

# Build a reviewable repo using the established recipe
# (auto-review-detect.sh:329-340): base commit on main + a divergent
# `feat` branch with upstream set so `git diff main..HEAD` is non-empty
# and the branch tier is "tiered" (not wip/tmp/draft → not skipped).
#
# Echoes the CANONICAL repo path (`pwd -P`). On macOS `mktemp -d`
# returns /var/folders/... but the hook keys ROUNDS_FILE/REPO_ROOT off
# `git rev-parse --show-toplevel` which resolves the /private symlink.
# Reading the rounds file via the unresolved path would diverge from
# where the hook writes it. Callers must use the echoed real path.
make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  (
    cd "$dir"
    # All git chatter to stderr-null so the ONLY thing on stdout (the
    # captured value) is the canonical path from the final `pwd -P`.
    {
      git init -q -b main 2>/dev/null || { git init -q; git symbolic-ref HEAD refs/heads/main 2>/dev/null || true; }
      git config user.email t@t
      git config user.name t
      git config commit.gpgsign false
      echo a > a.txt && git add a.txt && git commit -q -m init
      git checkout -q -b feat
      echo b > b.txt && git add b.txt && git commit -q -m feat
      git branch --set-upstream-to=main feat
    } >/dev/null 2>&1
    pwd -P
  )
}

# Invoke the REAL hook with a sandboxed env and a PreToolUse JSON on
# stdin. Extra env passed as space-separated KEY=VAL pairs.
#
# The ambient test env may carry SSPOWER_AUTO_REVIEW=off or the
# re-entry guards (auto-review.sh:46-48 would short-circuit before any
# branch under test). Force the active path deterministically: -u VAR
# clears guards, SSPOWER_AUTO_REVIEW=on re-enables. extra_env is
# applied LAST so a test can still set its own knobs.
run_hook() {
  local repo="$1" cmd="$2" extra_env="${3:-}"
  ( cd "$repo" && env \
      -u SSPOWER_REVIEW_IN_FLIGHT \
      -u SSPOWER_REVIEW_DEPTH \
      SSPOWER_AUTO_REVIEW=on \
      CLAUDE_PLUGIN_ROOT="$STUB_ROOT" \
      SSPOWER_TEST_ARGS_FILE="$ARGS_FILE" \
      SSPOWER_LOG_FILE="$LOG_FILE" \
      XDG_CACHE_HOME="$WORK/.cache" \
      $extra_env \
      bash "$REVIEW" <<HOOKIN
{"tool_name":"Bash","tool_input":{"command":"$cmd"}}
HOOKIN
  )
}

# =====================================================================
# (a) Chain policy — real chokepoint chain branch (auto-review.sh:91-116)
# =====================================================================
echo "[(a) chain policy]"
REPO_A=$(make_repo "$WORK/repo_a")

# Non-pipe successor after chokepoint -> DENY (auto-review.sh:113-116).
# Deny contract (auto-review.sh:79-89): JSON
#   {"hookSpecificOutput":{"permissionDecision":"deny",...}} on stdout,
# exit 0. ALLOW = exit 0 with no deny JSON.
: > "$ARGS_FILE"
out=$(run_hook "$REPO_A" 'git push && echo done' 2>/dev/null); rc=$?
assert_eq "push && echo: exit 0" "0" "$rc"
assert_eq "push && echo: deny emitted" "1" \
  "$(printf '%s' "$out" | grep -c '"permissionDecision": "deny"' || true)"
assert_eq "push && echo: no codex spawn" "0" \
  "$(test -s "$ARGS_FILE" && echo 1 || echo 0)"

# Standalone chokepoint with read-only file redirect -> ALLOW (no deny).
# `>` redirection is not a chained successor (it's stripped by the
# parser); the hook proceeds to the (stubbed) bridge.
: > "$ARGS_FILE"
out=$(run_hook "$REPO_A" 'git push > /tmp/sspower_int_f' 2>/dev/null); rc=$?
rm -f /tmp/sspower_int_f
assert_eq "push > file: exit 0" "0" "$rc"
assert_eq "push > file: NOT denied" "0" \
  "$(printf '%s' "$out" | grep -c '"permissionDecision": "deny"' || true)"
assert_eq "push > file: bridge reached (real allow path)" "1" \
  "$(test -s "$ARGS_FILE" && echo 1 || echo 0)"

# Clearly-safe non-chokepoint -> ALLOW, hook is inert (no INV match,
# auto-review.sh:73). exit 0, empty stdout, no spawn.
: > "$ARGS_FILE"
out=$(run_hook "$REPO_A" 'ls -la' 2>/dev/null); rc=$?
assert_eq "ls -la: exit 0" "0" "$rc"
assert_eq "ls -la: empty stdout" "" "$out"
assert_eq "ls -la: no codex spawn" "0" \
  "$(test -s "$ARGS_FILE" && echo 1 || echo 0)"

# =====================================================================
# (b) Round cap — auto-review.sh:202-211 deny_rounds_cap short-circuit
# =====================================================================
echo "[(b) round cap]"
REPO_B=$(make_repo "$WORK/repo_b")
CAP=2  # exercise the SSPOWER_REVIEW_MAX_ROUNDS knob (default is 3)

# Rounds file path/branch-slug derivation per auto-review.sh:178-198:
#   ROUNDS_FILE = $REPO_ROOT/.git/sspower-review-rounds-<SAFE_BRANCH>
#   where REPO_ROOT = `git rev-parse --show-toplevel` (canonical) and
#   SAFE_BRANCH = branch with '/' -> '_'. Branch is `feat`. REPO_B is
#   already the canonical path (make_repo echoes `pwd -P`).
ROUNDS_FILE_B="$REPO_B/.git/sspower-review-rounds-feat"
printf '%s' "$CAP" > "$ROUNDS_FILE_B"

: > "$ARGS_FILE"
out=$(run_hook "$REPO_B" 'git push' "SSPOWER_REVIEW_MAX_ROUNDS=$CAP" 2>/dev/null); rc=$?
assert_eq "rounds==cap: exit 0" "0" "$rc"
assert_eq "rounds==cap: deny emitted" "1" \
  "$(printf '%s' "$out" | grep -c '"permissionDecision": "deny"' || true)"
assert_eq "rounds==cap: deny reason names rounds" "1" \
  "$(printf '%s' "$out" | grep -c 'rounds did not converge' || true)"
# Cap check (auto-review.sh:208) precedes any bridge spawn (:468):
# prove ZERO Codex invocation.
assert_eq "rounds==cap: no codex spawn" "0" \
  "$(test -s "$ARGS_FILE" && echo 1 || echo 0)"
# Real short-circuit log signal (auto-review.sh:209).
assert_eq "rounds==cap: deny_rounds_cap logged" "1" \
  "$(grep -c 'kind="deny_rounds_cap"' "$LOG_FILE" 2>/dev/null; true)"
# Counter must NOT advance past the cap (no increment on the deny path).
assert_eq "rounds==cap: counter unchanged" "$CAP" \
  "$(cat "$ROUNDS_FILE_B" 2>/dev/null || echo MISSING)"

# Below cap (rounds=0, fresh) the same push must NOT short-circuit: it
# reaches the stub bridge — proves the cap branch is the cause above,
# not some unrelated early exit.
rm -f "$ROUNDS_FILE_B"
: > "$ARGS_FILE"
out=$(run_hook "$REPO_B" 'git push' "SSPOWER_REVIEW_MAX_ROUNDS=$CAP" 2>/dev/null); rc=$?
assert_eq "rounds<cap: exit 0" "0" "$rc"
assert_eq "rounds<cap: no rounds-cap deny" "0" \
  "$(printf '%s' "$out" | grep -c 'rounds did not converge' || true)"
assert_eq "rounds<cap: bridge reached" "1" \
  "$(test -s "$ARGS_FILE" && echo 1 || echo 0)"

# =====================================================================
# (c) Verdict cache hit — auto-review.sh:219-252, 599
# =====================================================================
echo "[(c) verdict cache]"
# Fresh log so parallel_review_done count is scoped to this group.
: > "$LOG_FILE"
REPO_C=$(make_repo "$WORK/repo_c")

# The stub bridge returns verdict "approve". On a converging verdict
# auto-review.sh:618 DELETES the rounds file (reset on convergence), so
# the rounds counter is NOT a stable cache-hit signal here. The hook
# emits NO log line on a cache hit (the cached RESULT is read silently
# at :245-252). The real, observable cache-hit signals are therefore:
#   1. bridge NOT spawned on run 2 (stub args file empty), and
#   2. the spawn-only log line `kind=parallel_review_done`
#      (auto-review.sh:591, inside the `if [ -z "$RESULT" ]` block)
#      stays at exactly 1 across both runs.

# Run 1: cache MISS -> stub bridge runs, writes the verdict cache, logs
# parallel_review_done once.
: > "$ARGS_FILE"
out=$(run_hook "$REPO_C" 'git push' 2>/dev/null); rc=$?
assert_eq "run1 (miss): exit 0" "0" "$rc"
assert_eq "run1 (miss): bridge spawned" "1" \
  "$(test -s "$ARGS_FILE" && echo 1 || echo 0)"
assert_eq "run1 (miss): parallel_review_done logged once" "1" \
  "$(grep -c 'kind="parallel_review_done"' "$LOG_FILE" 2>/dev/null; true)"

# Run 2: identical repo state + identical diff -> same DIFF_HASH ->
# cache HIT. Stub bridge must NOT run; no new parallel_review_done line
# (it lives inside the spawn-only block).
: > "$ARGS_FILE"
out=$(run_hook "$REPO_C" 'git push' 2>/dev/null); rc=$?
assert_eq "run2 (hit): exit 0" "0" "$rc"
assert_eq "run2 (hit): NO codex spawn (cache-served)" "0" \
  "$(test -s "$ARGS_FILE" && echo 1 || echo 0)"
assert_eq "run2 (hit): parallel_review_done still once total" "1" \
  "$(grep -c 'kind="parallel_review_done"' "$LOG_FILE" 2>/dev/null; true)"

# Sanity: the cache file the hook keyed on actually exists under the
# sandboxed XDG_CACHE_HOME (proves we exercised the real cache path and
# never touched ~/.cache).
assert_eq "verdict cache file present in sandbox" "1" \
  "$(ls "$WORK"/.cache/sspower/verdicts/*.json >/dev/null 2>&1 && echo 1 || echo 0)"

# =====================================================================
# (d) Verdict ASSEMBLY — spec §9 P6 / C4 third area (auto-review.sh
#     :505-688). Drives the REAL hook with verdict-configurable stub
#     reviewers; asserts the COMBINED_VERDICT precedence ladder
#     (:552-562), the fail-closed unknown default (:512,:554,:586-589),
#     the deny payload + `kind="deny_verdict"` log (:660-687,:680), the
#     approve happy-path (:604-622), and the multi-source merge with
#     `_source` tagging (:564-578). Each subtest uses a FRESH repo so
#     REPO_ROOT differs -> distinct DIFF_HASH (:225) -> no cross-subtest
#     verdict-cache bleed. SSPOWER_REVIEW_CACHE_TTL=0 defangs the cache
#     entirely so every invocation re-runs assembly.
echo "[(d) verdict assembly]"
NO_CACHE='SSPOWER_REVIEW_CACHE_TTL=0 SSPOWER_REVIEW_AUTO_APPLY=off'

# --- (d3) approve happy-path control: assembly -> allow, NO deny ------
# Establishes discrimination: the deny cases below are not blanket-deny.
REPO_D3=$(make_repo "$WORK/repo_d3")
: > "$ARGS_FILE"; : > "$LOG_FILE"
out=$(run_hook "$REPO_D3" 'git push' \
  "$NO_CACHE SSPOWER_STUB_MAIN_VERDICT=approve" 2>/dev/null); rc=$?
assert_eq "(d3) approve: exit 0" "0" "$rc"
assert_eq "(d3) approve: NOT denied" "0" \
  "$(printf '%s' "$out" | grep -c '"permissionDecision": "deny"' || true)"
assert_eq "(d3) approve: combined=approve logged" "1" \
  "$(grep -c 'combined="approve"' "$LOG_FILE" 2>/dev/null; true)"
assert_eq "(d3) approve: no deny_verdict log" "0" \
  "$(grep -c 'kind="deny_verdict"' "$LOG_FILE" 2>/dev/null; true)"

# --- (d1) needs-attention -> DENY + deny_verdict + issue surfaced ----
# auto-review.sh:556 (needs-attention precedence), :680 (deny_verdict
# log), :660-687 (deny payload echoes SUMMARY incl. the issue title).
REPO_D1=$(make_repo "$WORK/repo_d1")
: > "$ARGS_FILE"; : > "$LOG_FILE"
out=$(run_hook "$REPO_D1" 'git push' \
  "$NO_CACHE SSPOWER_STUB_MAIN_VERDICT=needs-attention" 2>/dev/null); rc=$?
assert_eq "(d1) needs-attention: exit 0" "0" "$rc"
assert_eq "(d1) needs-attention: DENY emitted" "1" \
  "$(printf '%s' "$out" | grep -c '"permissionDecision": "deny"' || true)"
assert_eq "(d1) needs-attention: deny_verdict logged" "1" \
  "$(grep -c 'kind="deny_verdict"' "$LOG_FILE" 2>/dev/null; true)"
# Anchor on the deny_verdict line specifically: `main_verdict="..."`
# (parallel_review_done, :591) also contains verdict="needs-attention"
# as a substring, so match the leading-space `kind="deny_verdict"
# verdict="..."` shape (:680) to avoid the false double count.
assert_eq "(d1) needs-attention: verdict in deny_verdict log" "1" \
  "$(grep -c 'kind="deny_verdict" verdict="needs-attention"' "$LOG_FILE" 2>/dev/null; true)"
assert_eq "(d1) needs-attention: combined logged" "1" \
  "$(grep -c 'combined="needs-attention"' "$LOG_FILE" 2>/dev/null; true)"
# Deny payload assembly surfaces the issue title (SUMMARY, :661-668).
assert_eq "(d1) needs-attention: issue title in deny reason" "1" \
  "$(printf '%s' "$out" | grep -c 'MAIN issue needs-attention' || true)"
assert_eq "(d1) needs-attention: no codex/network spawn" "1" \
  "$(test -s "$ARGS_FILE" && echo 1 || echo 0)"  # stub ran, real codex did NOT

# --- (d2) unparseable RESULT -> fail-closed unknown -> DENY ----------
# Stub emits raw non-JSON. jq parse of MAIN_RAW fails -> MAIN_VERDICT
# defaults "unknown" (:512) -> COMBINED unknown (:554) -> not in the
# approve case (:604) -> deny. Proves the safety fallback.
REPO_D2=$(make_repo "$WORK/repo_d2")
: > "$ARGS_FILE"; : > "$LOG_FILE"
out=$(run_hook "$REPO_D2" 'git push' \
  "$NO_CACHE SSPOWER_STUB_RAW=not-json-at-all" 2>/dev/null); rc=$?
assert_eq "(d2) unparseable: exit 0" "0" "$rc"
assert_eq "(d2) unparseable: fail-closed DENY" "1" \
  "$(printf '%s' "$out" | grep -c '"permissionDecision": "deny"' || true)"
assert_eq "(d2) unparseable: deny_verdict verdict=unknown" "1" \
  "$(grep -c 'kind="deny_verdict" verdict="unknown"' "$LOG_FILE" 2>/dev/null; true)"
assert_eq "(d2) unparseable: combined=unknown logged" "1" \
  "$(grep -c 'combined="unknown"' "$LOG_FILE" 2>/dev/null; true)"

# --- (d2b) empty MAIN reviewer (sec present) -> unknown -> DENY ------
# IMPORTANT real-hook behavior (auto-review.sh:500-504): if MAIN_RAW
# AND SEC_RAW AND SANITY_RAW are ALL empty, the hook treats it as
# infra failure -> kind="codex_timeout_allow" -> exit 0 (ALLOW, NOT
# deny). So an empty MAIN alone with security disabled would ALLOW.
# To isolate the "empty single reviewer -> unknown -> deny" assembly
# path we keep SECURITY enabled returning approve: MAIN_RAW="" (jq //
# "unknown", :512) but SEC_RAW present -> not all-empty -> COMBINED
# unknown (:554) -> fail-closed deny. This also documents the
# all-empty allow carve-out so the test encodes the true contract.
REPO_D2B=$(make_repo "$WORK/repo_d2b")
: > "$ARGS_FILE"; : > "$LOG_FILE"
out=$(run_hook "$REPO_D2B" 'git push' \
  "$NO_CACHE SSPOWER_SECURITY_REVIEW=on SSPOWER_SECURITY_EFFORT=medium SSPOWER_STUB_MAIN_VERDICT=skip SSPOWER_STUB_SEC_VERDICT=approve" 2>/dev/null); rc=$?
assert_eq "(d2b) empty-main: exit 0" "0" "$rc"
assert_eq "(d2b) empty-main: fail-closed DENY" "1" \
  "$(printf '%s' "$out" | grep -c '"permissionDecision": "deny"' || true)"
assert_eq "(d2b) empty-main: main_verdict=unknown logged" "1" \
  "$(grep -c 'main_verdict="unknown"' "$LOG_FILE" 2>/dev/null; true)"
assert_eq "(d2b) empty-main: combined=unknown logged" "1" \
  "$(grep -c 'combined="unknown"' "$LOG_FILE" 2>/dev/null; true)"
assert_eq "(d2b) empty-main: NOT codex_timeout_allow (sec present)" "0" \
  "$(grep -c 'kind="codex_timeout_allow"' "$LOG_FILE" 2>/dev/null; true)"

# --- (d4) multi-source precedence: main approve + security blocks ----
# SSPOWER_SECURITY_REVIEW=on force-enables the security reviewer
# (auto-review.sh:404) regardless of repo path. Main=approve,
# Security=needs-attention. COMBINED must resolve to needs-attention
# (security keeps full blocking power, :556) and the merged issue list
# must carry the security source tag (:572,:578) — surfaced via the
# SEC issue title in the deny payload.
REPO_D4=$(make_repo "$WORK/repo_d4")
: > "$ARGS_FILE"; : > "$LOG_FILE"
out=$(run_hook "$REPO_D4" 'git push' \
  "$NO_CACHE SSPOWER_SECURITY_REVIEW=on SSPOWER_SECURITY_EFFORT=medium SSPOWER_STUB_MAIN_VERDICT=approve SSPOWER_STUB_SEC_VERDICT=needs-attention" 2>/dev/null); rc=$?
assert_eq "(d4) main-ok+sec-block: exit 0" "0" "$rc"
assert_eq "(d4) main-ok+sec-block: DENY (security blocks)" "1" \
  "$(printf '%s' "$out" | grep -c '"permissionDecision": "deny"' || true)"
assert_eq "(d4) main-ok+sec-block: combined=needs-attention" "1" \
  "$(grep -c 'combined="needs-attention"' "$LOG_FILE" 2>/dev/null; true)"
# Per-source verdicts both logged on parallel_review_done (:591).
assert_eq "(d4) main verdict=approve logged" "1" \
  "$(grep -c 'main_verdict="approve"' "$LOG_FILE" 2>/dev/null; true)"
assert_eq "(d4) sec verdict=needs-attention logged" "1" \
  "$(grep -c 'sec_verdict="needs-attention"' "$LOG_FILE" 2>/dev/null; true)"
# Merged issue list carries the SECURITY source's issue (merge :572,:578).
assert_eq "(d4) security issue surfaced in deny reason" "1" \
  "$(printf '%s' "$out" | grep -c 'SEC issue needs-attention' || true)"

# --- (d5) precedence: followups < needs-attention ---------------------
# Main approve-with-followups + security needs-attention -> the
# needs-attention rung wins over the followups rung (:556 before :558).
REPO_D5=$(make_repo "$WORK/repo_d5")
: > "$ARGS_FILE"; : > "$LOG_FILE"
out=$(run_hook "$REPO_D5" 'git push' \
  "$NO_CACHE SSPOWER_SECURITY_REVIEW=on SSPOWER_SECURITY_EFFORT=medium SSPOWER_STUB_MAIN_VERDICT=approve-with-followups SSPOWER_STUB_SEC_VERDICT=needs-attention" 2>/dev/null); rc=$?
assert_eq "(d5) fups+block: DENY" "1" \
  "$(printf '%s' "$out" | grep -c '"permissionDecision": "deny"' || true)"
assert_eq "(d5) fups+block: combined=needs-attention (block wins)" "1" \
  "$(grep -c 'combined="needs-attention"' "$LOG_FILE" 2>/dev/null; true)"

echo
echo "passed: $PASS"
echo "failed: $FAIL"
[ "$FAIL" -eq 0 ]
