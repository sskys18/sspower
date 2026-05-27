#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
git init -q .
cat > a.ts <<'TS'
export function helper() { return 1; }
TS
cat > b.ts <<'TS'
import { helper } from './a';
export function caller() { return helper(); }
TS
for i in $(seq 1 12); do
  echo "export const pad$i = $i;" > "pad$i.ts"
done
git add .
git -c user.email=test@x -c user.name=test commit -q -m init

node "$HERE/bin/sspower-graph.mjs" build --cwd "$TMP" >/dev/null

echo "export function helper2() { return 2; }" > a.ts
CLAUDE_PLUGIN_ROOT="$HERE" python3 "$HERE/scripts/graph-append-dirty.py" \
  --graph-dir "$TMP/.claude/graph" --op upsert --path "$TMP/a.ts"

OUT="$(node "$HERE/bin/sspower-graph.mjs" refresh --cwd "$TMP" 2>&1)"
echo "$OUT" | grep -q "files touched" || { echo "FAIL: refresh did not run -- $OUT"; exit 1; }

DIRTY_LINES="$(wc -l < "$TMP/.claude/graph/dirty" 2>/dev/null || echo 0)"
[[ "$DIRTY_LINES" -eq 0 ]] || { echo "FAIL: dirty not truncated ($DIRTY_LINES)"; exit 1; }

node "$HERE/bin/sspower-graph.mjs" status --cwd "$TMP" | grep -q "files="

echo "test-refresh-cli.sh OK"
