#!/bin/bash
# test-complete.sh — mock-based test for `codex-bridge.mjs complete --json`
#
# Validates spec §6.2:
#   - Returns valid OpenAI-shape chat.completion JSON on success
#   - Hard system directive is prepended to the prompt
#   - --sandbox read-only is passed to underlying codex CLI
#   - --timeout is enforced (wall-clock kill on long-running codex)
#   - Error path emits stderr JSON {"error":{"type":"...","message":"..."}}
#
# Uses a PATH-shim stub for `codex` so no real Codex auth/network is needed.

set -uo pipefail

BRIDGE="$(cd "$(dirname "$0")/../.." && pwd)/scripts/codex-bridge.mjs"

if [ ! -f "$BRIDGE" ]; then
  echo "FAIL: bridge not found at $BRIDGE"
  exit 1
fi

# Working dir for the stub + per-test artifacts.
TMP=$(mktemp -d -t sspower-complete-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
export TMP

# ── Stub codex on PATH ────────────────────────────────────────────────
# The bridge resolves codex via `which codex`, so prepending TMP to PATH
# is sufficient. The stub:
#   - writes its argv (one per line) to $TMP/last-argv
#   - writes its stdin to $TMP/last-stdin
#   - emits canned JSONL on stdout, canned final message to the -o file
#   - mode controlled via CODEX_STUB_MODE env: normal | slow | error
#
# We write the stub to disk so the bridge's `which codex` resolves it.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/codex" <<'STUB'
#!/bin/bash
# Mock codex CLI for sspower bridge tests.
# Honors a subset of `codex exec` flags: -o <file>, -m, -c, --sandbox, --json, --ephemeral

# Record argv (one per line for easy grepping)
printf '%s\n' "$@" > "$TMP/last-argv"

# Record stdin (the prompt)
cat > "$TMP/last-stdin"

# Find -o <file> in argv to know where to write the result
result_file=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then
    result_file="$a"
  fi
  prev="$a"
done

mode="${CODEX_STUB_MODE:-normal}"

case "$mode" in
  slow)
    # Sleep longer than the test's timeout; bridge must kill us.
    sleep 30
    exit 0
    ;;
  error)
    echo "codex: simulated rate limit error (429)" >&2
    exit 1
    ;;
  no_session)
    # Emit a result without session id / usage, to exercise the fallback paths.
    if [ -n "$result_file" ]; then
      printf 'plain-answer-without-meta' > "$result_file"
    fi
    exit 0
    ;;
  normal|*)
    # Emit canned JSONL with session id and token usage.
    cat <<'JSONL'
{"type":"thread.started","thread_id":"sess-mock-0001"}
{"type":"item.completed","item":{"type":"agent_message","text":"42"}}
{"type":"turn.completed","usage":{"input_tokens":11,"output_tokens":2,"total_tokens":13}}
JSONL
    if [ -n "$result_file" ]; then
      printf '42' > "$result_file"
    fi
    exit 0
    ;;
esac
STUB
chmod +x "$TMP/bin/codex"

export PATH="$TMP/bin:$PATH"

PASS=0
FAIL=0
fail() {
  echo "FAIL: $1"
  FAIL=$((FAIL + 1))
}
pass() {
  echo "PASS: $1"
  PASS=$((PASS + 1))
}

# Helper: run bridge with stub, capture stdout/stderr/exit.
run_bridge() {
  local mode="$1"; shift
  CODEX_STUB_MODE="$mode" node "$BRIDGE" complete --json "$@" \
    > "$TMP/stdout" 2> "$TMP/stderr"
  echo $? > "$TMP/exit"
}

# ── Test 1: happy path — OpenAI shape returned ────────────────────────
run_bridge normal --prompt "what is the answer?"
EXIT=$(cat "$TMP/exit")
if [ "$EXIT" != "0" ]; then
  fail "T1 happy-path: expected exit 0, got $EXIT (stderr: $(cat "$TMP/stderr"))"
else
  # Parse the OpenAI shape with node — avoid jq dependency assumptions.
  RESULT=$(node -e '
    const j=JSON.parse(require("fs").readFileSync("'"$TMP"'/stdout","utf8"));
    const ok =
      j.object === "chat.completion" &&
      Array.isArray(j.choices) && j.choices.length === 1 &&
      j.choices[0].message?.role === "assistant" &&
      typeof j.choices[0].message?.content === "string" &&
      j.choices[0].finish_reason === "stop" &&
      j.usage && typeof j.usage.prompt_tokens === "number" &&
      typeof j.usage.completion_tokens === "number" &&
      typeof j.usage.total_tokens === "number" &&
      typeof j.id === "string" && j.id.length > 0 &&
      typeof j.model === "string" && j.model.length > 0;
    process.stdout.write(ok ? "ok" : "bad:" + JSON.stringify(j));
  ' 2>&1)
  if [ "$RESULT" = "ok" ]; then
    pass "T1 happy-path: OpenAI-shape JSON returned"
  else
    fail "T1 happy-path: shape check failed → $RESULT"
  fi

  # Token usage round-trips from the stub's turn.completed event.
  TOTAL=$(node -e 'const j=JSON.parse(require("fs").readFileSync("'"$TMP"'/stdout","utf8")); process.stdout.write(String(j.usage.total_tokens))')
  if [ "$TOTAL" = "13" ]; then
    pass "T1b usage: total_tokens=13 (from turn.completed)"
  else
    fail "T1b usage: expected total_tokens=13, got $TOTAL"
  fi
fi

# ── Test 2: hard system directive prepended ───────────────────────────
# Stub captured stdin to $TMP/last-stdin — check it starts with the directive.
DIRECTIVE_HEAD="You are a single-turn extractor. Do NOT call any tool."
if grep -F -q "$DIRECTIVE_HEAD" "$TMP/last-stdin"; then
  # Must appear BEFORE the user prompt.
  DIRECTIVE_LINE=$(grep -F -n "$DIRECTIVE_HEAD" "$TMP/last-stdin" | head -1 | cut -d: -f1)
  PROMPT_LINE=$(grep -F -n "what is the answer?" "$TMP/last-stdin" | head -1 | cut -d: -f1)
  if [ -n "$DIRECTIVE_LINE" ] && [ -n "$PROMPT_LINE" ] && [ "$DIRECTIVE_LINE" -lt "$PROMPT_LINE" ]; then
    pass "T2 directive: hard directive prepended before user prompt"
  else
    fail "T2 directive: ordering wrong (directive line=$DIRECTIVE_LINE prompt line=$PROMPT_LINE)"
  fi
else
  fail "T2 directive: missing in stdin"
fi

# ── Test 3: --sandbox read-only passed to codex ───────────────────────
# Each argv arg is one line in last-argv. Look for the pair.
if grep -q '^--sandbox$' "$TMP/last-argv"; then
  SANDBOX_LINE=$(grep -n '^--sandbox$' "$TMP/last-argv" | head -1 | cut -d: -f1)
  NEXT_LINE=$((SANDBOX_LINE + 1))
  SANDBOX_VAL=$(sed -n "${NEXT_LINE}p" "$TMP/last-argv")
  if [ "$SANDBOX_VAL" = "read-only" ]; then
    pass "T3 sandbox: --sandbox read-only passed"
  else
    fail "T3 sandbox: expected 'read-only', got '$SANDBOX_VAL'"
  fi
else
  fail "T3 sandbox: --sandbox flag missing from codex argv"
fi

# ── Test 3b: --json flag passed to codex (for JSONL stdout parsing) ───
if grep -q '^--json$' "$TMP/last-argv"; then
  pass "T3b json: --json passed to codex (enables JSONL event stream)"
else
  fail "T3b json: --json flag missing from codex argv"
fi

# ── Test 3c: reasoning.effort=minimal applied by default ──────────────
if grep -q 'reasoning.effort="minimal"' "$TMP/last-argv"; then
  pass "T3c effort: reasoning.effort=minimal applied by default"
else
  fail "T3c effort: minimal effort not in codex argv (got: $(grep '^-c$' -A1 "$TMP/last-argv" | tr '\n' ' '))"
fi

# ── Test 4: --system message included in prompt ───────────────────────
run_bridge normal --prompt "hello" --system "You are concise."
EXIT=$(cat "$TMP/exit")
if [ "$EXIT" = "0" ] && grep -F -q "You are concise." "$TMP/last-stdin"; then
  pass "T4 system: --system text included in prompt sent to codex"
else
  fail "T4 system: missing system text (exit=$EXIT)"
fi

# ── Test 5: timeout enforcement ───────────────────────────────────────
# Use the slow stub mode + a short 2s timeout. Bridge must SIGTERM the child
# and exit nonzero with timeout error JSON on stderr.
T_START=$(date +%s)
run_bridge slow --prompt "hang" --timeout 2000
T_ELAPSED=$(( $(date +%s) - T_START ))
EXIT=$(cat "$TMP/exit")
if [ "$EXIT" = "0" ]; then
  fail "T5 timeout: expected nonzero exit, got 0"
elif [ "$T_ELAPSED" -gt 15 ]; then
  # Must terminate well before the stub's 30s sleep. Allow 5s for SIGKILL grace.
  fail "T5 timeout: bridge took ${T_ELAPSED}s — not enforcing wall-clock kill"
else
  # Confirm error JSON shape on stderr (per spec).
  ETYPE=$(node -e '
    const s=require("fs").readFileSync("'"$TMP"'/stderr","utf8");
    let found = "NOT_FOUND";
    for (const line of s.split("\n")) {
      const t = line.trim();
      if (!t.startsWith("{")) continue;
      try { const j=JSON.parse(t); if (j.error && j.error.type) { found = j.error.type; break; } } catch {}
    }
    process.stdout.write(found);
  ' 2>&1)
  if [ "$ETYPE" = "timeout" ]; then
    pass "T5 timeout: bridge killed child + emitted error.type=timeout (${T_ELAPSED}s)"
  else
    fail "T5 timeout: error.type expected 'timeout', got '$ETYPE'"
  fi
fi

# ── Test 6: error path — codex exits nonzero ──────────────────────────
run_bridge error --prompt "fail please"
EXIT=$(cat "$TMP/exit")
if [ "$EXIT" = "0" ]; then
  fail "T6 error-path: expected nonzero exit, got 0"
else
  # Spec error JSON shape: {"error":{"type":"...","message":"..."}}
  SHAPE_OK=$(node -e '
    const s=require("fs").readFileSync("'"$TMP"'/stderr","utf8");
    let out = "BAD";
    for (const line of s.split("\n")) {
      const t = line.trim();
      if (!t.startsWith("{")) continue;
      try {
        const j=JSON.parse(t);
        if (j.error && typeof j.error.type === "string" && typeof j.error.message === "string") {
          out = "ok:" + j.error.type;
          break;
        }
      } catch {}
    }
    process.stdout.write(out);
  ' 2>&1)
  case "$SHAPE_OK" in
    ok:*)
      pass "T6 error-path: stderr emits {error:{type,message}} (type=${SHAPE_OK#ok:})"
      ;;
    *)
      fail "T6 error-path: stderr lacks expected shape (got: $SHAPE_OK)"
      ;;
  esac
fi

# ── Test 7: missing --prompt → error ──────────────────────────────────
CODEX_STUB_MODE=normal node "$BRIDGE" complete --json > "$TMP/stdout" 2> "$TMP/stderr"
EXIT=$?
if [ "$EXIT" = "0" ]; then
  fail "T7 no-prompt: expected nonzero exit, got 0"
else
  if grep -q '"error"' "$TMP/stderr"; then
    pass "T7 no-prompt: error emitted on missing --prompt"
  else
    fail "T7 no-prompt: nonzero exit but no error JSON (stderr: $(cat "$TMP/stderr"))"
  fi
fi

# ── Test 8: --model override flows to codex argv ──────────────────────
run_bridge normal --prompt "hi" --model "gpt-test-9000"
EXIT=$(cat "$TMP/exit")
if [ "$EXIT" = "0" ]; then
  # Codex argv should contain -m gpt-test-9000.
  M_LINE=$(grep -n '^-m$' "$TMP/last-argv" | head -1 | cut -d: -f1)
  if [ -n "$M_LINE" ]; then
    NEXT=$((M_LINE + 1))
    M_VAL=$(sed -n "${NEXT}p" "$TMP/last-argv")
    if [ "$M_VAL" = "gpt-test-9000" ]; then
      pass "T8 model: --model override passed to codex"
    else
      fail "T8 model: expected 'gpt-test-9000', got '$M_VAL'"
    fi
  else
    fail "T8 model: -m flag missing"
  fi

  # And the response payload's model field reflects the override.
  M_OUT=$(node -e 'const j=JSON.parse(require("fs").readFileSync("'"$TMP"'/stdout","utf8")); process.stdout.write(j.model)')
  if [ "$M_OUT" = "gpt-test-9000" ]; then
    pass "T8b model: response.model echoes --model override"
  else
    fail "T8b model: response.model expected 'gpt-test-9000', got '$M_OUT'"
  fi
else
  fail "T8 model: bridge exit $EXIT (stderr: $(cat "$TMP/stderr"))"
fi

# ── Test 9: missing token usage → zeros + warning, exit still 0 ───────
run_bridge no_session --prompt "ping"
EXIT=$(cat "$TMP/exit")
if [ "$EXIT" = "0" ]; then
  TOTAL=$(node -e 'const j=JSON.parse(require("fs").readFileSync("'"$TMP"'/stdout","utf8")); process.stdout.write(String(j.usage.total_tokens))')
  CONTENT=$(node -e 'const j=JSON.parse(require("fs").readFileSync("'"$TMP"'/stdout","utf8")); process.stdout.write(j.choices[0].message.content)')
  if [ "$TOTAL" = "0" ] && [ "$CONTENT" = "plain-answer-without-meta" ]; then
    pass "T9 missing-usage: usage zeros emitted, content preserved"
  else
    fail "T9 missing-usage: total=$TOTAL content=$CONTENT"
  fi
  if grep -q "usage tokens missing" "$TMP/stderr"; then
    pass "T9b missing-usage: stderr warning surfaced"
  else
    fail "T9b missing-usage: warning not on stderr"
  fi
else
  fail "T9 missing-usage: exit $EXIT (stderr: $(cat "$TMP/stderr"))"
fi

# ── Summary ───────────────────────────────────────────────────────────
echo ""
echo "──────────────────────────────────────────────"
echo "Tests: PASS=$PASS  FAIL=$FAIL"
echo "──────────────────────────────────────────────"
[ "$FAIL" -eq 0 ]
