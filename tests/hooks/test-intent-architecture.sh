#!/usr/bin/env bash
set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")/../../hooks" && pwd)"
source "$HOOKS_DIR/_intent.sh"

assert_class() {
  local prompt="$1" expected="$2"
  local got
  got=$(sspower_classify_intent "$prompt")
  if [ "$got" != "$expected" ]; then
    echo "FAIL: prompt='$prompt' expected=$expected got=$got" >&2
    exit 1
  fi
  echo "OK: '$prompt' -> $expected"
}

# Architecture prompts must NOT be classified as qa.
assert_class "how does X reach Y in this codebase" architecture
assert_class "what calls handleRequest" architecture
assert_class "where is parseConfig used" architecture
assert_class "trace the auth middleware chain" architecture
assert_class "callers of validateInput" architecture
assert_class "callees of dispatchEvent" architecture
assert_class "show the path from controller to db" architecture

# Existing classes still work.
assert_class "what is React" qa
assert_class "fix the bug in auth.ts" simple-coding
assert_class "sspower:writing-plans" explicit-skill

echo "ALL PASS"
