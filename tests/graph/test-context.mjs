#!/usr/bin/env node
import { build } from '../../scripts/graph/build.mjs';
import { openDb, initSchema } from '../../scripts/graph/db.mjs';
import { context } from '../../scripts/graph/context.mjs';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const ROOT = path.resolve(import.meta.dirname, '..', '..');

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'sspower-context-'));
fs.cpSync(path.join(ROOT, '__tests__/graph-fixtures/ts-js'), tmp, { recursive: true });
const graphDir = path.join(tmp, '.claude', 'graph');
await build({ rootDir: tmp, graphDir, log: () => {} });

const db = openDb(path.join(graphDir, 'index.sqlite'));
initSchema(db);

const r = context(db, 'helper');
assert.ok(r.hits.length >= 1, `expected hits, got ${JSON.stringify(r)}`);
assert.ok(r.hits[0].qname);
assert.ok(typeof r.total_chars === 'number');
assert.ok(r.total_chars <= 4096, `budget overrun: ${r.total_chars}`);

const empty = context(db, 'zzz_no_match_token_xyz');
assert.equal(empty.hits.length, 0);

db.close();
fs.rmSync(tmp, { recursive: true });
console.log('OK context');
