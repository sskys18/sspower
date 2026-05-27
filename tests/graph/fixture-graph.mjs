// tests/graph/fixture-graph.mjs
// Build the graph index for a fixture project on first use. Indexes under
// __tests__/graph-fixtures/*/.claude/graph/ are gitignored, so fresh checkouts
// must materialize them before MCP/CLI tests that read them.
import fs from 'node:fs';
import path from 'node:path';
import { build } from '../../scripts/graph/build.mjs';

export async function ensureFixtureGraph(fixture) {
  const graphDir = path.join(fixture, '.claude', 'graph');
  const dbPath = path.join(graphDir, 'index.sqlite');
  if (fs.existsSync(dbPath)) return;
  fs.mkdirSync(graphDir, { recursive: true, mode: 0o700 });
  await build({ rootDir: fixture, graphDir, log: () => {} });
}
