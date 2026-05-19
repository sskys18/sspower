#!/usr/bin/env bash
set -uo pipefail
H="$(cd "$(dirname "$0")/../.." && pwd)/hooks/semble-context.sh"
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
  if ${_PT[@]+"${_PT[@]}"} semble_rs plan "probe codex bridge resume" "$(pwd)" >/dev/null 2>&1; then
    HAVE_SEMBLE=1
  else
    skip "semble_rs present but probe failed/timed out -> treating as absent (fail-open path)"
  fi
fi

# All gate-test prompts are >=20 chars so the `<20` length gate does NOT pre-empt
# the gate under test (length gate runs before slash/opt-out/read-intent).

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
