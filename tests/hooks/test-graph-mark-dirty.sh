#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_PLUGIN_ROOT="$HERE"

mkdir -p "$TMP/.claude/graph"
touch "$TMP/.claude/graph/index.sqlite"
echo "test" > "$TMP/foo.ts"
cd "$TMP"
HOOK="$HERE/hooks/graph-mark-dirty.sh"

P1=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s/foo.ts","content":"test"}}' "$TMP")
echo "$P1" | "$HOOK"
LC="$(wc -l < "$TMP/.claude/graph/dirty")"
[[ "$LC" -eq 1 ]] || { echo "FAIL: Write should append 1 line, got $LC"; exit 1; }
grep -qE '"op":\s*"upsert"' "$TMP/.claude/graph/dirty"

echo "$P1" | sed 's/Write/Edit/' | "$HOOK"
LC="$(wc -l < "$TMP/.claude/graph/dirty")"
[[ "$LC" -eq 2 ]] || { echo "FAIL: Edit got $LC"; exit 1; }

echo "second" > "$TMP/bar.ts"
P3=$(printf '{"tool_name":"MultiEdit","tool_input":{"edits":[{"file_path":"%s/foo.ts","old_string":"a","new_string":"b"},{"file_path":"%s/bar.ts","old_string":"c","new_string":"d"}]}}' "$TMP" "$TMP")
echo "$P3" | "$HOOK"
LC="$(wc -l < "$TMP/.claude/graph/dirty")"
[[ "$LC" -eq 4 ]] || { echo "FAIL: MultiEdit total $LC"; exit 1; }

echo '{"tool_name":"Write","tool_input":{"file_path":"/etc/passwd","content":"x"}}' | "$HOOK"
LC="$(wc -l < "$TMP/.claude/graph/dirty")"
[[ "$LC" -eq 4 ]] || { echo "FAIL: outside-cwd not skipped ($LC)"; exit 1; }

P5=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s/README.md","content":"x"}}' "$TMP")
echo "$P5" | "$HOOK"
LC="$(wc -l < "$TMP/.claude/graph/dirty")"
[[ "$LC" -eq 4 ]] || { echo "FAIL: non-source not skipped"; exit 1; }

rm "$TMP/foo.ts"
P6=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s/foo.ts"}}' "$TMP")
echo "$P6" | "$HOOK"
tail -1 "$TMP/.claude/graph/dirty" | grep -qE '"op":\s*"delete"'

TMP2="$(mktemp -d)"
echo "test" > "$TMP2/x.ts"
cd "$TMP2"
P7=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s/x.ts","content":"t"}}' "$TMP2")
echo "$P7" | "$HOOK"
[[ ! -e "$TMP2/.claude/graph/dirty" ]] || { echo "FAIL: hook ran without index"; exit 1; }
rm -rf "$TMP2"

cd "$TMP"
LB="$(wc -l < "$TMP/.claude/graph/dirty")"
echo "not json" | "$HOOK"
LA="$(wc -l < "$TMP/.claude/graph/dirty")"
[[ "$LB" -eq "$LA" ]] || { echo "FAIL: malformed payload appended"; exit 1; }

echo "test-graph-mark-dirty.sh OK"
