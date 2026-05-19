#!/usr/bin/env bash
# Codex Stop hook (B5). Reads Codex Stop stdin JSON, runs the bridge-direct
# LSP check, and -- only when SSPOWER_CODEX_STOP_GATE=1 -- emits the
# Claude-compatible Stop block contract so Codex keeps fixing. Advisory by
# default (D-B6). Fail-open everywhere (D-B7): any error -> exit 0, no block.
set -u
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
BRIDGE="$SELF_DIR/../scripts/codex-bridge.mjs"
STDIN_JSON="$(cat 2>/dev/null || true)"

CWD="$(printf '%s' "$STDIN_JSON" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);process.stdout.write(String(j.cwd||""))}catch{process.stdout.write("")}})' 2>/dev/null || true)"
[ -z "$CWD" ] && CWD="$(pwd)"

RES="$(node "$BRIDGE" lsp-check --cd "$CWD" 2>/dev/null || true)"
DEC="$(printf '%s' "$RES" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);process.stdout.write(String(j.decision||"clean")+"\t"+(j.total_errors||0)+"\t"+((j.errors||[]).map(e=>e.file).join(", ")))}catch{process.stdout.write("clean\t0\t")}})' 2>/dev/null || printf 'clean\t0\t')"
DECISION="${DEC%%$'\t'*}"
REST="${DEC#*$'\t'}"; NERR="${REST%%$'\t'*}"; FILES="${REST#*$'\t'}"

if [ "$DECISION" != "would-block" ]; then
  exit 0
fi

if [ "${SSPOWER_CODEX_STOP_GATE:-}" = "1" ]; then
  REASON="LSP gate: $NERR error-severity diagnostic(s) remain in: $FILES. Fix ONLY these so the language server is clean, then stop. Do not change unrelated code."
  REASON_JSON="$(printf '%s' "$REASON" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.stringify(s)))' 2>/dev/null || true)"
  # D-B7: infra failure (here, reason JSON-escaping) fails OPEN — never a
  # block, never malformed JSON. A well-formed block is emitted ONLY when
  # the escaped reason was produced cleanly. (Near-unreachable: if node
  # were broken, lsp-check itself would have returned the clean fallback
  # and we'd never enter the would-block branch.)
  case "$REASON_JSON" in
    '"'*'"')
      printf '{"decision":"block","reason":%s}\n' "$REASON_JSON"
      exit 0
      ;;
    *)
      printf '[codex-stop-gate] would-block but reason-escaping failed — failing open (D-B7), no block\n' >&2
      exit 0
      ;;
  esac
fi

printf '[codex-stop-gate] would-block: %s LSP error(s) in %s (advisory; set SSPOWER_CODEX_STOP_GATE=1 to enforce)\n' "$NERR" "$FILES" >&2
exit 0
