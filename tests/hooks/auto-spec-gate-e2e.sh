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

# Staged symlink must be refused, NOT reviewed.
echo "[e2e: staged symlink]"
(
  cd "$WORK"
  rm -f docs/plans/sym.md
  ln -s /etc/passwd docs/plans/sym.md
  git add docs/plans/sym.md
)
out=$(run_gate 'git commit -m foo' approve 2>&1); rc=$?
assert_eq "staged symlink: exit"            "0" "$rc"
assert_eq "staged symlink: warned"          "1" "$(printf '%s' "$out" | grep -c 'staged symlink' || true)"
assert_eq "staged symlink: no bridge call"  "0" "$(call_count)"

echo
echo "passed: $PASS"
echo "failed: $FAIL"
[ "$FAIL" -eq 0 ]
