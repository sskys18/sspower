#!/usr/bin/env node
import { build } from '../../scripts/graph/build.mjs';
import { openDb, initSchema } from '../../scripts/graph/db.mjs';
import { trace } from '../../scripts/graph/trace.mjs';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const ROOT = path.resolve(import.meta.dirname, '..', '..');

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'sspower-trace-'));
fs.cpSync(path.join(ROOT, '__tests__/graph-fixtures/ts-js'), tmp, { recursive: true });
const graphDir = path.join(tmp, '.claude', 'graph');
await build({ rootDir: tmp, graphDir, log: () => {} });

const db = openDb(path.join(graphDir, 'index.sqlite'));
initSchema(db);

{
  const r = trace(db, 'caller', 'helper');
  assert.equal(r.paths.length, 1, `expected 1 path, got ${JSON.stringify(r)}`);
  assert.equal(r.paths[0].hops, 1);
  assert.equal(r.paths[0].from, 'caller');
  assert.equal(r.paths[0].to, 'helper');
}

{
  const r = trace(db, 'caller', 'nonexistent_symbol_xyz');
  assert.equal(r.paths.length, 0);
  assert.equal(r.reason, 'endpoint-not-found');
}

{
  const r = trace(db, 'caller', 'caller');
  assert.equal(r.paths.length, 0, 'self-trace should yield no nontrivial path');
}

db.close();
fs.rmSync(tmp, { recursive: true });
console.log('OK trace');
