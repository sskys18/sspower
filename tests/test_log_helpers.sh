#!/usr/bin/env bash
# Test _sspower_exit_guard / _sspower_err_jsonl in hooks/_log.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export SSPOWER_LOG_FILE="$TMP/codex.log"
export SSPOWER_ERRORS_FILE="$TMP/errors.jsonl"
source "$HERE/../hooks/_log.sh"

fail() { echo "FAIL: $1"; exit 1; }

# 1. Expected code -> no row, no log
_sspower_exit_guard 0 "0" hook.test
[ -f "$SSPOWER_ERRORS_FILE" ] && fail "exit 0 wrote a row"

# 2. Expected code 20 (session-start) -> no row
_sspower_exit_guard 20 "0 20" hook.session-start
[ -f "$SSPOWER_ERRORS_FILE" ] && fail "exit 20 in allow-set wrote a row"

# 3. Unexpected code -> one row + one [error] log line
_sspower_exit_guard 1 "0" hook.test
[ -f "$SSPOWER_ERRORS_FILE" ] || fail "exit 1 wrote no row"
rows=$(wc -l < "$SSPOWER_ERRORS_FILE" | tr -d ' ')
[ "$rows" = "1" ] || fail "expected 1 row, got $rows"
grep -q '"category":"hook"' "$SSPOWER_ERRORS_FILE" || fail "category missing"
grep -q '"origin":"plugin"' "$SSPOWER_ERRORS_FILE" || fail "origin missing"
grep -q '"message":"exit 1"' "$SSPOWER_ERRORS_FILE" || fail "message missing"
grep -q '\[error\] hook.test kind="crash" exit="1"' "$SSPOWER_LOG_FILE" || fail "codex.log line missing"

# 4. JSON is valid
python3 -c "import json,sys; [json.loads(l) for l in open('$SSPOWER_ERRORS_FILE')]" \
  || fail "errors.jsonl line is not valid JSON"

# 5. Message with quotes/backslashes is escaped
_sspower_err_jsonl hook plugin hook.test error 'has "quote" and \back'
python3 -c "import json; [json.loads(l) for l in open('$SSPOWER_ERRORS_FILE')]" \
  || fail "escaping produced invalid JSON"

# 6. errors.jsonl is mode 0600
perms=$(stat -f '%Lp' "$SSPOWER_ERRORS_FILE" 2>/dev/null || stat -c '%a' "$SSPOWER_ERRORS_FILE")
[ "$perms" = "600" ] || fail "errors.jsonl perms = $perms, expected 600"

echo "PASS test_log_helpers.sh"
