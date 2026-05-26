#!/usr/bin/env node
import { openDb, initSchema } from '../../scripts/graph/db.mjs';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'sspower-graph-'));
const dbPath = path.join(tmp, 'index.sqlite');

const db = openDb(dbPath);
initSchema(db);

const tables = db.prepare(
  "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
).all().map(r => r.name);
assert.deepEqual(
  tables.filter(t => !t.startsWith('nodes_fts') && !t.startsWith('sqlite_')),
  ['edges', 'files', 'imports', 'nodes'],
  `tables=${JSON.stringify(tables)}`
);

const fts = db.prepare(
  "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'nodes_fts%'"
).all().map(r => r.name);
assert.ok(fts.includes('nodes_fts'), `fts tables=${JSON.stringify(fts)}`);

const triggers = db.prepare(
  "SELECT name FROM sqlite_master WHERE type='trigger' ORDER BY name"
).all().map(r => r.name);
assert.deepEqual(triggers, ['nodes_ad', 'nodes_ai', 'nodes_au']);

initSchema(db);  // idempotency

const mode = db.prepare('PRAGMA journal_mode').get().journal_mode;
assert.equal(mode, 'wal');

const fk = db.prepare('PRAGMA foreign_keys').get().foreign_keys;
assert.equal(fk, 1);

db.close();
fs.rmSync(tmp, { recursive: true });
console.log('OK schema test');
