#!/usr/bin/env node
// Regression: a full build must truncate the dirty JSONL queue, so a
// refresh that fell through to full-rebuild does not leave entries
// behind to re-trigger the same fallback on the next session.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import fsSync from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { build } from '../../scripts/graph/build.mjs';

const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'sspower-build-dirty-'));
const graphDir = path.join(tmp, '.claude', 'graph');
await fs.mkdir(graphDir, { recursive: true });
await fs.writeFile(path.join(tmp, 'a.ts'), `export function foo() {}\n`);
await fs.writeFile(path.join(tmp, 'b.ts'), `export function bar() {}\n`);

// Seed the dirty queue with stale entries (simulates a refresh that
// signalled fullRebuild without itself draining the queue).
const dirtyPath = path.join(graphDir, 'dirty');
await fs.writeFile(dirtyPath,
  JSON.stringify({ op: 'upsert', path: path.join(tmp, 'a.ts') }) + '\n' +
  JSON.stringify({ op: 'upsert', path: path.join(tmp, 'b.ts') }) + '\n'
);
assert(fsSync.existsSync(dirtyPath), 'pre-condition: dirty file written');
const beforeSize = fsSync.statSync(dirtyPath).size;
assert(beforeSize > 0, 'pre-condition: dirty has entries');

await build({ rootDir: tmp, graphDir, log: () => {} });

// After a successful build the dirty file must be empty (or absent).
const exists = fsSync.existsSync(dirtyPath);
if (exists) {
  const after = fsSync.readFileSync(dirtyPath, 'utf8');
  assert.equal(after, '', `dirty queue must be cleared after build, got: ${JSON.stringify(after)}`);
}

await fs.rm(tmp, { recursive: true, force: true });
console.log('OK build clears dirty queue');
