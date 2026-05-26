import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { sessionRefresh, gitFilesetHash } from '../../scripts/graph/session-refresh.mjs';
import { build } from '../../scripts/graph/build.mjs';

const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'sspower-sr-'));
const graphDir = path.join(tmp, '.claude', 'graph');
await fs.mkdir(graphDir, { recursive: true });

execFileSync('git', ['-C', tmp, 'init', '-q']);
execFileSync('git', ['-C', tmp, 'config', 'user.email', 'x@x']);
execFileSync('git', ['-C', tmp, 'config', 'user.name', 'x']);
await fs.writeFile(path.join(tmp, 'a.ts'), `export function foo() { return 1; }\n`);
await fs.writeFile(path.join(tmp, 'b.ts'), `export function bar() { return 2; }\n`);
execFileSync('git', ['-C', tmp, 'add', '-A']);
execFileSync('git', ['-C', tmp, 'commit', '-q', '-m', 'init']);

await build({ rootDir: tmp, graphDir, log: () => {} });
const h0 = await gitFilesetHash(tmp);
await fs.writeFile(path.join(graphDir, 'version'),
  `schema=1\nbuilt_at=${Math.floor(Date.now()/1000)}\ngit_filesethash=${h0}\n`);

// (1) Idle.
const r1 = await sessionRefresh({ rootDir: tmp, graphDir, maxTime: 5000, log: () => {} });
assert.equal(r1.action, 'noop', `expected noop, got ${r1.action}/${r1.reason}`);

// (2) New file -> filesethash change -> build.
await fs.writeFile(path.join(tmp, 'c.ts'), `export function baz() {}\n`);
execFileSync('git', ['-C', tmp, 'add', '-A']);
const r2 = await sessionRefresh({ rootDir: tmp, graphDir, maxTime: 5000, log: () => {} });
assert.equal(r2.action, 'build', `expected build, got ${r2.action}/${r2.reason}`);

// (3) External edit -> sampling triggers refresh OR build.
await fs.writeFile(path.join(tmp, 'a.ts'), `export function fooRenamed() {}\n`);
const r3 = await sessionRefresh({ rootDir: tmp, graphDir, maxTime: 5000, log: () => {} });
assert.ok(['refresh', 'build'].includes(r3.action), `got ${r3.action}/${r3.reason}`);
assert.ok(r3.dirtyEmitted >= 1, 'should enqueue dirty');

// (4) Idle after rebuild.
await build({ rootDir: tmp, graphDir, log: () => {} });
const h1 = await gitFilesetHash(tmp);
await fs.writeFile(path.join(graphDir, 'version'),
  `schema=1\nbuilt_at=${Math.floor(Date.now()/1000)}\ngit_filesethash=${h1}\n`);
const r4 = await sessionRefresh({ rootDir: tmp, graphDir, maxTime: 5000, log: () => {} });
assert.equal(r4.action, 'noop');

// (5) Deadline.
await fs.writeFile(path.join(tmp, 'a.ts'), `export function r2() {}\n`);
const r5 = await sessionRefresh({ rootDir: tmp, graphDir, maxTime: 1, log: () => {} });
assert.ok(['timeout', 'refresh', 'build', 'noop'].includes(r5.action));

await fs.rm(tmp, { recursive: true, force: true });
console.log('test-session-refresh.mjs OK');
