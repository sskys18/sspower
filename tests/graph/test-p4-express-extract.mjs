#!/usr/bin/env node
// P4 Task 5: Express fixture P/R + dedupe assertions.
// Builds a temporary graph index over __tests__/graph-fixtures/express/,
// reads kind=route nodes + kind=routes edges, scores precision/recall
// against expected.json. Also asserts the ts-express-route /
// ts-express-router rule-overlap dedupe: app.get('/health', handleHealth)
// must produce exactly 1 route node, not 2.

import { build } from '../../scripts/graph/build.mjs';
import { openDb, initSchema } from '../../scripts/graph/db.mjs';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const ROOT = path.resolve(import.meta.dirname, '..', '..');
const FIXTURE_SRC = path.join(ROOT, '__tests__/graph-fixtures/express');
const expected = JSON.parse(fs.readFileSync(path.join(FIXTURE_SRC, 'expected.json'), 'utf8'));

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'sspower-p4-express-'));
fs.cpSync(FIXTURE_SRC, tmp, { recursive: true });

const graphDir = path.join(tmp, '.claude', 'graph');
const result = await build({ rootDir: tmp, graphDir, log: () => {} });
assert.ok(result.nodeCount > 0, `nodes=${result.nodeCount}`);

const db = openDb(path.join(graphDir, 'index.sqlite'));
initSchema(db);

// ---- Nodes ----
const routeRows = db.prepare(
  "SELECT name, file_path AS file FROM nodes WHERE kind='route' ORDER BY file_path, start_line"
).all();
// File path in DB is absolute; normalize to basename so it matches expected.
const actualNodes = routeRows.map(r => ({
  file: path.basename(r.file),
  kind: 'route',
  name: r.name,
}));

const expectedNodes = expected.nodes;
const nodeKey = n => `${n.file}::${n.kind}::${n.name}`;
const actualNodeKeys = new Set(actualNodes.map(nodeKey));
const expectedNodeKeys = new Set(expectedNodes.map(nodeKey));

let truePositives = 0;
for (const k of actualNodeKeys) if (expectedNodeKeys.has(k)) truePositives++;
const precision = actualNodeKeys.size === 0 ? 0 : truePositives / actualNodeKeys.size;
const recall    = expectedNodeKeys.size === 0 ? 1 : truePositives / expectedNodeKeys.size;

console.log(`actual route nodes (${actualNodes.length}):`);
for (const n of actualNodes) console.log(`  ${n.file}\t${n.name}`);
console.log(`precision=${precision.toFixed(3)} recall=${recall.toFixed(3)}`);

assert.ok(precision >= expected.precision_min, `precision ${precision} < ${expected.precision_min}`);
assert.ok(recall    >= expected.recall_min,    `recall ${recall} < ${expected.recall_min}`);

// ---- Dedupe: GET /health appears exactly once ----
const healthMatches = db.prepare(
  "SELECT id, file_path, start_line, end_line FROM nodes WHERE kind='route' AND name='GET /health'"
).all();
assert.equal(healthMatches.length, 1, `dedupe failed: GET /health emitted ${healthMatches.length} nodes (expected 1)`);

// Dedupe sanity: every (file_path, start_line, end_line, name) tuple must
// be unique among route nodes. Without dedupe, both ts-express-route and
// ts-express-router rules emit the same direct-form match → 2 nodes per
// call.
const tupleCounts = db.prepare(
  "SELECT file_path, start_line, end_line, name, COUNT(*) AS c FROM nodes WHERE kind='route' GROUP BY file_path, start_line, end_line, name HAVING c > 1"
).all();
assert.equal(tupleCounts.length, 0, `dedupe failed: ${JSON.stringify(tupleCounts)}`);

// ---- Edges (kind=routes) ----
const edgeRows = db.prepare(`
  SELECT n_src.name AS src_name, n_tgt.name AS tgt_name, e.kind
  FROM edges e
  JOIN nodes n_src ON e.source = n_src.id
  JOIN nodes n_tgt ON e.target = n_tgt.id
  WHERE e.kind = 'routes'
  ORDER BY n_src.name, n_tgt.name
`).all();
console.log(`actual routes edges (${edgeRows.length}):`);
for (const e of edgeRows) console.log(`  ${e.src_name} -> ${e.tgt_name}`);

const expectedEdgeKeys = new Set(expected.edges.map(e => `${e.src_name} -> ${e.tgt_name}`));
const actualEdgeKeys = new Set(edgeRows.map(e => `${e.src_name} -> ${e.tgt_name}`));
let edgeTP = 0;
for (const k of actualEdgeKeys) if (expectedEdgeKeys.has(k)) edgeTP++;
const edgeRecall = expectedEdgeKeys.size === 0 ? 1 : edgeTP / expectedEdgeKeys.size;
console.log(`edge recall=${edgeRecall.toFixed(3)}`);
assert.ok(edgeRecall >= 0.70, `edge recall ${edgeRecall} < 0.70`);

db.close();
fs.rmSync(tmp, { recursive: true });
console.log('OK p4-express-extract');
