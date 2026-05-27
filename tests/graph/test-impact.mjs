#!/usr/bin/env node
import { build } from '../../scripts/graph/build.mjs';
import { openDb, initSchema } from '../../scripts/graph/db.mjs';
import { impact } from '../../scripts/graph/impact.mjs';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const ROOT = path.resolve(import.meta.dirname, '..', '..');

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'sspower-impact-'));
fs.cpSync(path.join(ROOT, '__tests__/graph-fixtures/ts-js'), tmp, { recursive: true });
const graphDir = path.join(tmp, '.claude', 'graph');
await build({ rootDir: tmp, graphDir, log: () => {} });

const db = openDb(path.join(graphDir, 'index.sqlite'));
initSchema(db);

const sampleFile = path.join(tmp, 'sample-input.ts');
const r = impact(db, sampleFile);
assert.ok(r.direct_count >= 1, `direct callers expected, got ${JSON.stringify(r)}`);
assert.ok(r.transitive_count >= r.direct_count);
assert.ok(Array.isArray(r.files));
assert.equal(r.target_file, sampleFile);

const noFile = impact(db, path.join(tmp, 'does-not-exist.ts'));
assert.equal(noFile.direct_count, 0);
assert.equal(noFile.files.length, 0);

db.close();
fs.rmSync(tmp, { recursive: true });
console.log('OK impact');
