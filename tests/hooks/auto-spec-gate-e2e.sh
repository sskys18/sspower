#!/usr/bin/env bash
# End-to-end tests for auto-spec-gate.sh that actually exercise the
# dry-run discovery + bridge invocation paths -- not just the bypass
# short-circuit. We mock the codex bridge with a tiny shell script
# that returns whatever verdict the test asks for.

set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$ROOT/hooks/auto-spec-gate.sh"

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

# Build a fake plugin root with a stub bridge.
FAKE_ROOT=$(mktemp -d -t sspower-fake-root-XXXXXX)
mkdir -p "$FAKE_ROOT/scripts" "$FAKE_ROOT/hooks"
cp "$ROOT/hooks/_parse-git-cmd.py" "$FAKE_ROOT/hooks/"
cp "$GATE" "$FAKE_ROOT/hooks/"

# Stub bridge: replays $SSPOWER_TEST_VERDICT and writes call markers.
CALL_LOG=$(mktemp -t sspower-fake-bridge-log-XXXXXX)
cat > "$FAKE_ROOT/scripts/codex-bridge.mjs" <<EOF
#!/usr/bin/env node
// Stub for tests. Logs invocation; emits a minimal review JSON.
import { readFileSync } from "fs";
const args = process.argv.slice(2);
const verdict = process.env.SSPOWER_TEST_VERDICT || "approve";
const promptIdx = args.indexOf("--prompt");
let promptPath = "";
if (promptIdx !== -1 && args[promptIdx + 1]?.startsWith("@")) {
  promptPath = args[promptIdx + 1].slice(1);
}
let promptBody = "";
try { promptBody = readFileSync(promptPath, "utf8"); } catch {}
import("fs").then(({ appendFileSync }) => {
  appendFileSync(process.env.SSPOWER_TEST_LOG,
    JSON.stringify({ verdict, prompt_excerpt: promptBody.slice(0, 200) }) + "\n");
});
const out = verdict === "approve"
  ? { verdict: "approve", strengths: [], issues: [], assessment: "ok" }
  : { verdict, strengths: [], issues: [{ severity: "important", title: "test issue" }], assessment: "bad" };
process.stdout.write(JSON.stringify({ structured: out, ...out }));
EOF
chmod +x "$FAKE_ROOT/scripts/codex-bridge.mjs"

trap 'rm -rf "$FAKE_ROOT" "$CALL_LOG"' EXIT

WORK=$(mktemp -d -t sspower-e2e-XXXXXX)
trap 'rm -rf "$FAKE_ROOT" "$CALL_LOG" "$WORK"' EXIT
(
  cd "$WORK"
  git init -q
  git config user.email t@t
  git config user.name t
  git config commit.gpgsign false
  echo init > seed.md
  git add seed.md
  git commit -qm init
  mkdir -p docs/plans
)

run_gate() {
  local cmd="$1"
  local verdict="${2:-approve}"
  : > "$CALL_LOG"
  cd "$WORK" && SSPOWER_TEST_VERDICT="$verdict" SSPOWER_TEST_LOG="$CALL_LOG" \
    CLAUDE_PLUGIN_ROOT="$FAKE_ROOT" \
    bash "$FAKE_ROOT/hooks/auto-spec-gate.sh" <<EOF
{"tool_input":{"command":"$cmd"}}
EOF
}

call_count() { wc -l < "$CALL_LOG" | tr -d ' '; }

# Stage a real plan and verify the bridge is invoked once with verdict
# approve -> exit 0, no deny output.
echo "[e2e: plain commit + plan staged]"
(cd "$WORK" && echo "# plan" > docs/plans/p1.md && git add docs/plans/p1.md)
out=$(run_gate 'git commit -m foo' approve 2>&1); rc=$?
assert_eq "approve: exit"           "0" "$rc"
assert_eq "approve: bridge calls"   "1" "$(call_count)"
assert_eq "approve: no deny"        "0" "$(printf '%s' "$out" | grep -c '"permissionDecision":' || true)"

# Same setup, verdict needs-attention -> exit 0 (deny payload on stdout
# is what blocks; the script itself exits 0).
out=$(run_gate 'git commit -m foo' needs-attention 2>&1); rc=$?
assert_eq "needs-attention: exit"   "0" "$rc"
assert_eq "needs-attention: deny in stdout" "1" "$(printf '%s' "$out" | grep -c '"permissionDecision":' || true)"

# `--pathspec-from-file` reads pathspecs from a file. Must trigger
# worktree-source. p1.md must be tracked first (--pathspec-from-file
# rejects unknown paths), then modified in worktree, then committed via
# the file pathspec.
echo "[e2e: --pathspec-from-file]"
(
  cd "$WORK"
  git reset -q HEAD
  git add docs/plans/p1.md
  git commit -q -m "track p1"
  echo "# pf-worktree" > docs/plans/p1.md
  echo "docs/plans/p1.md" > .pf
)
out=$(run_gate 'git commit -m foo --pathspec-from-file=.pf' approve 2>&1); rc=$?
assert_eq "pathspec-from-file: exit"        "0" "$rc"
assert_eq "pathspec-from-file: bridge call" "1" "$(call_count)"

# Staged symlink must be refused (no bridge call) AND BLOCK the
# commit (deny payload), not silently skip.
echo "[e2e: staged symlink]"
(
  cd "$WORK"
  rm -f docs/plans/sym.md
  ln -s /etc/passwd docs/plans/sym.md
  git add docs/plans/sym.md
)
out=$(run_gate 'git commit -m foo' approve 2>&1); rc=$?
assert_eq "staged symlink: exit"             "0" "$rc"
assert_eq "staged symlink: no bridge call"   "0" "$(call_count)"
assert_eq "staged symlink: deny on stdout"   "1" "$(printf '%s' "$out" | grep -c '"permissionDecision":' || true)"
assert_eq "staged symlink: deny mentions sym" "1" "$(printf '%s' "$out" | grep -c 'staged symlink refused' || true)"

# `-p` / `--patch`: dry-run can't predict interactive selection; gate
# must conservatively cover any worktree-modified plan even if dry-run
# reports nothing in this commit.
echo "[e2e: -p interactive patch]"
(
  cd "$WORK"
  # Reset to a known clean state, commit a tracked plan, then modify
  # it ONLY in the worktree (not staged).
  git reset --hard HEAD -q 2>/dev/null
  rm -rf docs/plans
  mkdir -p docs/plans
  echo "# v1" > docs/plans/i.md
  git add docs/plans/i.md
  git commit -q -m "track i"
  echo "# v2 worktree" > docs/plans/i.md
)
out=$(run_gate 'git commit -m foo -p' approve 2>&1); rc=$?
assert_eq "-p with worktree plan: exit"     "0" "$rc"
assert_eq "-p with worktree plan: bridge"   "1" "$(call_count)"

# `-i` mixed: pre-existing index entry + newly-named pathspec. Index
# entry must be sourced from the index; pathspec from worktree. Easy
# end-to-end: stage one plan, modify another in worktree, commit -i
# with the second plan as pathspec. Both should be reviewed.
echo "[e2e: -i mixed]"
(
  cd "$WORK"
  git reset --hard HEAD -q 2>/dev/null
  rm -rf docs/plans
  mkdir -p docs/plans
  echo "# v1-a" > docs/plans/a.md
  echo "# v1-b" > docs/plans/b.md
  git add docs/plans/a.md docs/plans/b.md
  git commit -q -m "init a b"
  # a.md: stage a new revision
  echo "# v2-a" > docs/plans/a.md
  git add docs/plans/a.md
  # b.md: only modify worktree, do NOT stage
  echo "# v2-b" > docs/plans/b.md
)
out=$(run_gate 'git commit -m foo -i docs/plans/b.md' approve 2>&1); rc=$?
assert_eq "-i mixed: exit"                   "0" "$rc"
assert_eq "-i mixed: 2 bridge calls"         "2" "$(call_count)"

# Chained commands: `cd subdir && git commit` and `(git commit)` and
# `env FOO=bar git commit` must all reach the gate.
echo "[e2e: chained / wrapped commands]"
(
  cd "$WORK"
  git reset --hard HEAD -q 2>/dev/null
  rm -rf docs/plans
  mkdir -p docs/plans
  echo "# v1" > docs/plans/c.md
  git add docs/plans/c.md
)
out=$(run_gate '(git commit -m foo)' approve 2>&1); rc=$?
assert_eq "(commit): bridge fired"  "1" "$(call_count)"

(cd "$WORK" && git reset HEAD -q && git add docs/plans/c.md)
out=$(run_gate 'env FOO=bar git commit -m foo' approve 2>&1); rc=$?
assert_eq "env wrapped: bridge fired" "1" "$(call_count)"

(cd "$WORK" && git reset HEAD -q && git add docs/plans/c.md)
out=$(run_gate 'echo hi && git commit -m foo' approve 2>&1); rc=$?
assert_eq "echo && commit: bridge fired" "1" "$(call_count)"

echo
echo "passed: $PASS"
echo "failed: $FAIL"
[ "$FAIL" -eq 0 ]
