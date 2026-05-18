#!/usr/bin/env bash
# test-lsp-check: codex-bridge.mjs lsp-check JSON contract
set -u
BRIDGE="$(cd "$(dirname "$0")/../.." && pwd)/scripts/codex-bridge.mjs"
FAIL=0
pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; FAIL=1; }

# (a) clean tree (no changed source files) -> decision clean, exit 0
TMP="$(mktemp -d)" || { echo "FAIL: mktemp"; exit 1; }
git -C "$TMP" init -q || { echo "FAIL: git-init"; rm -rf "$TMP"; exit 1; }
git -C "$TMP" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init || { echo "FAIL: git-commit"; rm -rf "$TMP"; exit 1; }
OUT="$(node "$BRIDGE" lsp-check --cd "$TMP" 2>/dev/null)"; RC=$?
echo "$OUT" | grep -q '"decision":"clean"' && [ $RC -eq 0 ] && pass "clean-tree" || fail "clean-tree (rc=$RC out=$OUT)"

# (b) missing --cd -> fail-open: decision clean, exit 0 (never crash)
OUT="$(node "$BRIDGE" lsp-check --cd /nonexistent/xyz 2>/dev/null)"; RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -q '"decision":"clean"' && pass "fail-open-badcwd" || fail "fail-open-badcwd (rc=$RC out=$OUT)"

# (c) output is single-line JSON with required keys
NLINES="$(printf '%s' "$OUT" | awk 'END{print NR}')"
[ "$NLINES" -eq 1 ] && pass "json-single-line" || fail "json-single-line (lines=$NLINES)"
echo "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);if("decision"in j&&"status"in j&&"errors"in j&&"total_errors"in j)process.exit(0);process.exit(1)})' && pass "json-shape" || fail "json-shape"

rm -rf "$TMP"
[ $FAIL -eq 0 ] && echo "PASS: test-lsp-check" || { echo "FAIL: test-lsp-check"; exit 1; }
