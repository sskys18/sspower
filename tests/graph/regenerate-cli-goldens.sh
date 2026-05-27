#!/usr/bin/env bash
# Regenerate P2 --json stdout goldens. Run only for approved CLI shifts.
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURES_ROOT="$PLUGIN_ROOT/__tests__/graph-fixtures"
GRAPH_BIN="${GRAPH_BIN:-$PLUGIN_ROOT/bin/sspower-graph.mjs}"

for pack in ts-js ts-js-multifile python go rust; do
  PACK="$FIXTURES_ROOT/$pack"
  [ -d "$PACK" ] || continue
  GOLDEN="$PACK/expected/cli-goldens"
  mkdir -p "$GOLDEN"
  rm -f "$GOLDEN"/*.json "$GOLDEN/manifest.json"
  rm -rf "$PACK/.claude/graph"

  node "$GRAPH_BIN" build --cwd "$PACK" --json > "$GOLDEN/build.json"
  node "$GRAPH_BIN" status --cwd "$PACK" --json > "$GOLDEN/status.json"

  node --input-type=module - "$PACK/expected.json" "$GOLDEN/manifest.json" <<'EOF'
import fs from 'node:fs';
const [expectedPath, manifestPath] = process.argv.slice(2);
const expected = JSON.parse(fs.readFileSync(expectedPath, 'utf8'));
const cases = [
  { file: 'build.json', args: ['build'] },
  { file: 'status.json', args: ['status'] },
];
const symbols = new Set();
for (const n of expected.nodes ?? []) {
  if (n.qualifiedName) symbols.add(n.qualifiedName);
}
for (const sym of symbols) {
  const safe = sym.replace(/[^A-Za-z0-9_.-]/g, '_');
  cases.push({ file: `callers-${safe}.json`, args: ['callers', sym] });
  cases.push({ file: `callees-${safe}.json`, args: ['callees', sym] });
  cases.push({ file: `node-${safe}.json`, args: ['node', sym] });
}
for (const e of expected.edges ?? []) {
  const safe = `${e.source}-to-${e.target}`.replace(/[^A-Za-z0-9_.-]/g, '_');
  cases.push({ file: `trace-${safe}.json`, args: ['trace', e.source, e.target] });
}
const files = new Set((expected.nodes ?? []).map(n => n.file).filter(Boolean));
if (files.size === 0) files.add('sample-input.ts');
for (const f of files) {
  const safe = f.replace(/[^A-Za-z0-9_.-]/g, '_');
  cases.push({ file: `impact-${safe}.json`, args: ['impact', f] });
}
const task = [...symbols].slice(0, 3).join(' ') || 'graph context';
cases.push({ file: 'context-default.json', args: ['context', task] });
cases.push({ file: 'refresh.json', args: ['refresh'] });
cases.push({ file: 'session-refresh.json', args: ['session-refresh', '--max-time', '5'] });
fs.writeFileSync(manifestPath, JSON.stringify(cases, null, 2) + '\n');
EOF

  node --input-type=module - "$GRAPH_BIN" "$PACK" "$GOLDEN/manifest.json" "$GOLDEN" <<'EOF'
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
const [graph, pack, manifestPath, goldenDir] = process.argv.slice(2);
const cases = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
for (const c of cases) {
  if (c.file === 'build.json' || c.file === 'status.json') continue;
  const [verb, ...rest] = c.args;
  const r = spawnSync(process.execPath, [graph, verb, '--cwd', pack, '--json', ...rest], { encoding: 'utf8' });
  if (r.status !== 0) continue;
  fs.writeFileSync(path.join(goldenDir, c.file), r.stdout);
}
EOF
done

echo "Regenerated CLI goldens for all fixture packs."
