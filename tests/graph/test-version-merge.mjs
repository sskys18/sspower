#!/usr/bin/env node
// Regression: build + refresh must NOT clobber git_filesethash. A naive
// fs.writeFile would drop the SessionStart-managed hash, forcing the
// next session-refresh to trigger a full rebuild.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { build } from '../../scripts/graph/build.mjs';
import { readVersionField, writeVersionFields } from '../../scripts/graph/session-refresh.mjs';

const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'sspower-vmerge-'));
const graphDir = path.join(tmp, '.claude', 'graph');
await fs.mkdir(graphDir, { recursive: true });
await fs.writeFile(path.join(tmp, 'a.ts'), `export function foo() {}\n`);

// Seed git_filesethash as if session-refresh persisted it.
await writeVersionFields(graphDir, { git_filesethash: 'deadbeef' });

await build({ rootDir: tmp, graphDir, log: () => {} });

const after = await readVersionField(graphDir, 'git_filesethash');
assert.equal(after, 'deadbeef',
  `build must preserve git_filesethash, got: ${after}`);

const builtAt = await readVersionField(graphDir, 'built_at');
assert.ok(builtAt && /^\d+$/.test(builtAt),
  `build must write built_at, got: ${builtAt}`);

// Independent field merge.
await writeVersionFields(graphDir, { schema: 1, ast_grep: 'x', other_key: 'y' });
const all = await fs.readFile(path.join(graphDir, 'version'), 'utf8');
assert.match(all, /git_filesethash=deadbeef/, `git_filesethash dropped after merge: ${all}`);
assert.match(all, /other_key=y/, `merge must add new keys: ${all}`);

await fs.rm(tmp, { recursive: true, force: true });
console.log('OK version merge preserves git_filesethash');
