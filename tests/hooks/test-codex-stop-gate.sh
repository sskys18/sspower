#!/usr/bin/env bash
# test-codex-stop-gate: .codex/codex-lsp-stop.sh advisory vs block
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SH="$ROOT/.codex/codex-lsp-stop.sh"
FAIL=0; pass(){ echo "PASS: $1"; }; fail(){ echo "FAIL: $1"; FAIL=1; }

TMP="$(mktemp -d)" || { echo "FAIL: mktemp"; exit 1; }
git -C "$TMP" init -q || { echo "FAIL: git-init"; rm -rf "$TMP"; exit 1; }
git -C "$TMP" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init || { echo "FAIL: git-commit"; rm -rf "$TMP"; exit 1; }
IN="{\"session_id\":\"x\",\"cwd\":\"$TMP\",\"hook_event_name\":\"Stop\"}"

# (a) clean tree, advisory (env unset) -> exit 0, no decision:block
OUT="$(printf '%s' "$IN" | env -u SSPOWER_CODEX_STOP_GATE bash "$SH" 2>/dev/null)"; RC=$?
{ [ $RC -eq 0 ] && ! echo "$OUT" | grep -q '"decision":"block"'; } && pass "clean-advisory" || fail "clean-advisory (rc=$RC out=$OUT)"

# (b) clean tree, block mode -> still exit 0, no block (nothing to fix)
OUT="$(printf '%s' "$IN" | SSPOWER_CODEX_STOP_GATE=1 bash "$SH" 2>/dev/null)"; RC=$?
{ [ $RC -eq 0 ] && ! echo "$OUT" | grep -q '"decision":"block"'; } && pass "clean-blockmode" || fail "clean-blockmode (rc=$RC out=$OUT)"

# (c) bad cwd -> fail-open exit 0, no block
OUT="$(printf '%s' '{"cwd":"/nonexistent/xyz","hook_event_name":"Stop"}' | SSPOWER_CODEX_STOP_GATE=1 bash "$SH" 2>/dev/null)"; RC=$?
{ [ $RC -eq 0 ] && ! echo "$OUT" | grep -q '"decision":"block"'; } && pass "fail-open" || fail "fail-open (rc=$RC out=$OUT)"

rm -rf "$TMP"
[ $FAIL -eq 0 ] && echo "PASS: test-codex-stop-gate" || { echo "FAIL: test-codex-stop-gate"; exit 1; }
