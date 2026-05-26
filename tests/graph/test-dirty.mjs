// tests/graph/test-dirty.mjs
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { readDirty, dedupeDirty, reconcileWithStat, truncateDirty } from '../../scripts/graph/dirty.mjs';

const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'sspower-dirty-'));
const graphDir = path.join(tmp, '.claude', 'graph');
await fs.mkdir(graphDir, { recursive: true });

// (1) Empty/missing dirty file -> empty array.
const empty = await readDirty(graphDir);
assert.deepEqual(empty, []);

// (2) JSONL parsing.
const existing = path.join(tmp, 'a.ts');
const missing  = path.join(tmp, 'b.ts');
await fs.writeFile(existing, 'export const x = 1;\n');
await fs.writeFile(path.join(graphDir, 'dirty'),
  [
    JSON.stringify({ op: 'upsert', path: existing }),
    JSON.stringify({ op: 'upsert', path: existing }),
    JSON.stringify({ op: 'delete', path: existing }),
    JSON.stringify({ op: 'delete', path: missing }),
  ].join('\n') + '\n');
const records = await readDirty(graphDir);
assert.equal(records.length, 4);
assert.equal(records[0].op, 'upsert');
assert.equal(records[2].op, 'delete');

// (3) Dedupe last-wins.
const deduped = dedupeDirty(records);
assert.equal(deduped.size, 2);
assert.equal(deduped.get(existing), 'delete');
assert.equal(deduped.get(missing),  'delete');

// (4) Stat reconcile: delete on existing file -> upsert.
const reconciled = await reconcileWithStat(deduped);
assert.equal(reconciled.get(existing), 'upsert');
assert.equal(reconciled.get(missing),  'delete');

// (5) upsert on missing -> delete.
const onlyUpsert = new Map([[missing, 'upsert']]);
const r2 = await reconcileWithStat(onlyUpsert);
assert.equal(r2.get(missing), 'delete');

// (6) Malformed line throws with file:lineno.
await fs.writeFile(path.join(graphDir, 'dirty'),
  JSON.stringify({ op: 'upsert', path: existing }) + '\n' + 'not-json\n');
let threw = false;
try { await readDirty(graphDir); }
catch (e) { threw = true; assert.match(e.message, /malformed dirty record/i); }
assert.ok(threw, 'malformed JSONL must throw');

// (7) Unknown op rejected.
await fs.writeFile(path.join(graphDir, 'dirty'),
  JSON.stringify({ op: 'rebuild', path: existing }) + '\n');
let threw2 = false;
try { await readDirty(graphDir); }
catch (e) { threw2 = true; assert.match(e.message, /unknown op/i); }
assert.ok(threw2);

// (8) truncateDirty clears file but does not unlink.
await fs.writeFile(path.join(graphDir, 'dirty'),
  JSON.stringify({ op: 'upsert', path: existing }) + '\n');
await truncateDirty(graphDir);
const after = await fs.readFile(path.join(graphDir, 'dirty'), 'utf8');
assert.equal(after, '');

await fs.rm(tmp, { recursive: true, force: true });
console.log('test-dirty.mjs OK');
