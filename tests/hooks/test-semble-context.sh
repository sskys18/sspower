#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
H="$ROOT/hooks/semble-context.sh"
# jq is a test-harness dependency (assertions parse JSON). Absent -> SKIP, not
# FAIL: the hooks themselves fail-open without jq; that path is asserted via
# the deterministic no-tool shim, not here.
command -v jq >/dev/null 2>&1 || { echo "SKIP: test-semble-context (no jq - harness dep)"; exit 0; }
FAIL=0; ok(){ echo "PASS: $1"; }; bad(){ echo "FAIL: $1"; FAIL=1; }
skip(){ echo "SKIP: $1"; }

# R1 / determinism: positive-inject assertions run ONLY if a real semble_rs
# PROBE succeeds within a short timeout (covers absent / cold-uninstallable /
# broken binary). HAVE_SEMBLE=1 means the exact command shape the hook uses
# actually produced output here & now. Otherwise the same prompt must
# fail-open empty - asserted instead - so the suite is green either way.
HAVE_SEMBLE=0
if command -v semble_rs >/dev/null 2>&1; then
  if command -v gtimeout >/dev/null 2>&1; then _PT=(gtimeout 20)
  elif command -v timeout >/dev/null 2>&1; then _PT=(timeout 20)
  elif command -v perl >/dev/null 2>&1; then _PT=(perl -e 'alarm shift; exec @ARGV' 20)
  else _PT=(); fi
  PROBE_OUT="$(${_PT[@]+"${_PT[@]}"} semble_rs plan "probe codex bridge resume" "$(pwd)" 2>/dev/null || true)"
  if [[ -n "$PROBE_OUT" ]]; then
    HAVE_SEMBLE=1
  else
    skip "semble_rs present but probe failed/timed out/empty -> treating as absent (fail-open path)"
  fi
fi

# All gate-test prompts are >=20 chars so the `<20` length gate does NOT pre-empt
# the gate under test (length gate runs before slash/opt-out/read-intent).

setup_gate_env() {
  GATE_TMP="$(mktemp -d)"
  GATE_OLD_HOME="$HOME"
  export HOME="$GATE_TMP"
  GATE_OLD_PATH="$PATH"
  GATE_SHIM="$GATE_TMP/bin"
  mkdir -p "$GATE_SHIM"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$GATE_SHIM/semble_rs"
  chmod +x "$GATE_SHIM/semble_rs"
  export PATH="$GATE_SHIM:$PATH"
}

teardown_gate_env() {
  export PATH="$GATE_OLD_PATH"
  export HOME="$GATE_OLD_HOME"
  [ -n "${GATE_TMP:-}" ] && [ -d "$GATE_TMP" ] && rm -R "$GATE_TMP"
  unset GATE_TMP GATE_OLD_HOME GATE_OLD_PATH GATE_SHIM
}

ran_hook() { printf '%s' "$1" | bash "${2:-$H}" >/dev/null 2>&1; }
ran_hook_stderr() { printf '%s' "$1" | bash "${2:-$H}" 2>&1 >/dev/null; }
skipped_no_intent() {
  grep -q 'kind=skip reason=no-coding-intent' "$HOME/.claude/sspower/codex.log" 2>/dev/null
}

# consolidated intent gate: coding intent passes the gate
setup_gate_env
ran_hook "$(printf '{"prompt":"please fix the bug in auth code","cwd":"%s"}' "$(pwd)")"
if skipped_no_intent; then bad "intent gate: coding intent passed"; else ok "intent gate: coding intent passed"; fi
teardown_gate_env

# consolidated intent gate: non-coding prompt reaches the gate and skips
setup_gate_env
ran_hook "$(printf '{"prompt":"compare the repository purpose today","cwd":"%s"}' "$(pwd)")"
if skipped_no_intent; then ok "intent gate: non-coding skipped"; else bad "intent gate: non-coding skipped"; fi
teardown_gate_env

# consolidated intent gate: file extension signal widened beyond legacy regex
setup_gate_env
ran_hook "$(printf '{"prompt":"take a look at the handler.ts file","cwd":"%s"}' "$(pwd)")"
if skipped_no_intent; then bad "intent gate: .ts mention passed"; else ok "intent gate: .ts mention passed"; fi
teardown_gate_env

# read-verb prompts exit at semble-context's own read-verb gate before the
# consolidated intent gate.
setup_gate_env
OUT="$(printf '{"prompt":"what is this repository for","cwd":"%s"}' "$(pwd)" | bash "$H")"
[[ -z "$OUT" ]] && ok "read-verb own gate empty" || bad "read-verb own gate empty ($OUT)"
teardown_gate_env

# unset-variable safety: using USER_PROMPT under set -u must not leak an
# unbound-variable crash to stderr.
setup_gate_env
ERR="$(ran_hook_stderr "$(printf '{"prompt":"please fix the bug in auth code","cwd":"%s"}' "$(pwd)")")"
if printf '%s' "$ERR" | grep -q 'USER_PROMPT: unbound variable'; then
  bad "intent gate: USER_PROMPT bound"
else
  ok "intent gate: USER_PROMPT bound"
fi
teardown_gate_env

# _intent.sh missing: fail open to the exact legacy regex.
setup_gate_env
COPY="$GATE_TMP/copy"
mkdir -p "$COPY/hooks"
cp "$H" "$COPY/hooks/semble-context.sh"
cp "$ROOT/hooks/_log.sh" "$COPY/hooks/_log.sh"
ran_hook "$(printf '{"prompt":"please fix the bug in auth code","cwd":"%s"}' "$(pwd)")" "$COPY/hooks/semble-context.sh"
if skipped_no_intent; then bad "intent missing: legacy coding passed"; else ok "intent missing: legacy coding passed"; fi
rm -f "$HOME/.claude/sspower/codex.log"
ran_hook "$(printf '{"prompt":"compare the repository purpose today","cwd":"%s"}' "$(pwd)")" "$COPY/hooks/semble-context.sh"
if skipped_no_intent; then ok "intent missing: legacy non-coding skipped"; else bad "intent missing: legacy non-coding skipped"; fi
teardown_gate_env

# 1. read-intent ("what is" ..., >=20) -> no output
OUT="$(printf '{"prompt":"what is the codex bridge resume repair mechanism?","cwd":"%s"}' "$(pwd)" | "$H")"
[[ -z "$OUT" ]] && ok "read-intent skip" || bad "read-intent skip ($OUT)"

# 2. slash command (>=20, leading /) -> no output
OUT="$(printf '{"prompt":"/handoff please summarize the whole working session","cwd":"%s"}' "$(pwd)" | "$H")"
[[ -z "$OUT" ]] && ok "slash skip" || bad "slash skip"

# 3. opt-out prefix (>=20) -> no output
OUT="$(printf '{"prompt":"nosemble: fix the resume loop bug right now","cwd":"%s"}' "$(pwd)" | "$H")"
[[ -z "$OUT" ]] && ok "nosemble: opt-out" || bad "nosemble: opt-out"

# 4. disabled env -> no output even on coding intent
OUT="$(SSPOWER_SEMBLE=0 sh -c "printf '{\"prompt\":\"fix the codex resume bug\",\"cwd\":\"$(pwd)\"}' | '$H'")"
[[ -z "$OUT" ]] && ok "SSPOWER_SEMBLE=0" || bad "SSPOWER_SEMBLE=0"

# 5. coding intent in git repo -> inject IF semble present, else fail-open empty
OUT="$(printf '{"prompt":"fix the codex bridge resume repair loop","cwd":"%s"}' "$(pwd)" | "$H")"
if (( HAVE_SEMBLE )); then
  echo "$OUT" | jq -e '.hookSpecificOutput.additionalContext | startswith("[semble_rs repo orientation")' >/dev/null 2>&1 \
    && ok "coding-intent inject" || bad "coding-intent inject ($OUT)"
else
  [[ -z "$OUT" ]] && ok "coding-intent fail-open (no semble)" || bad "coding-intent (no semble, expected empty) ($OUT)"
fi

# 5b. HARD cap: with a tiny MAX, the semble payload after the fixed prefix line
# must not exceed MAX (+ the short truncation marker). semble-only.
if (( HAVE_SEMBLE )); then
  OUT="$(printf '{"prompt":"fix the codex bridge resume repair loop and lsp gate","cwd":"%s"}' "$(pwd)" | SSPOWER_SEMBLE_MAX_CHARS=64 "$H")"
  CTX="$(echo "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""')"
  # strip the fixed prefix line; remaining payload must be <= 64 + marker(16)
  PAY="${CTX#*$'\n'}"
  if [[ -n "$CTX" ]] && (( ${#PAY} <= 80 )); then ok "hard cap (payload ${#PAY} <= 80)"; else bad "hard cap (payload ${#PAY})"; fi
else
  skip "hard cap (no semble)"
fi

# 6. fail-open when semble_rs binary is genuinely absent - deterministic:
#    build a flat PATH shim with every needed tool symlinked EXCEPT semble_rs.
SHIM="$(mktemp -d 2>/dev/null || true)"
if [[ -z "${SHIM:-}" || ! -d "$SHIM" ]]; then
  skip "fail-open no-semble (no writable temp dir for shim)"
else
  cleanup_shim() {
    [[ -n "${SHIM:-}" && -d "$SHIM" ]] || return 0
    rm -f "$SHIM"/* 2>/dev/null || true
    rmdir "$SHIM" 2>/dev/null || true
  }
  trap cleanup_shim EXIT
  for b in bash sh jq git date dirname cat tr grep sed mkdir printf perl python3 node env timeout gtimeout; do
    p="$(command -v "$b" 2>/dev/null)" && ln -s "$p" "$SHIM/$b" 2>/dev/null
  done
  OUT="$(printf '{"prompt":"fix the resume bug now","cwd":"%s"}' "$(pwd)" | PATH="$SHIM" "$H")"
  [[ -z "$OUT" ]] && ok "fail-open no-semble (deterministic shim)" || bad "fail-open no-semble ($OUT)"
fi

[[ $FAIL -eq 0 ]] && echo "PASS: test-semble-context" || { echo "FAIL: test-semble-context"; exit 1; }
