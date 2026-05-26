#!/usr/bin/env node
import { walkSources } from '../../scripts/graph/walk.mjs';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

// Case A: non-git directory - recursive walk with sensible filters.
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'sspower-walk-'));
fs.writeFileSync(path.join(tmp, 'a.ts'), '');
fs.writeFileSync(path.join(tmp, 'b.js'), '');
fs.writeFileSync(path.join(tmp, 'c.md'), '');
fs.mkdirSync(path.join(tmp, 'node_modules'));
fs.writeFileSync(path.join(tmp, 'node_modules', 'x.ts'), '');
fs.mkdirSync(path.join(tmp, '.git'));
fs.writeFileSync(path.join(tmp, '.git', 'config'), '');

const got = [];
for await (const p of walkSources(tmp)) got.push(p);
const rels = got.map(p => path.relative(tmp, p)).sort();
assert.deepEqual(rels, ['a.ts', 'b.js'], `got ${JSON.stringify(rels)}`);
fs.rmSync(tmp, { recursive: true });

// Case B: real git repo - uses `git ls-files`.
const repo = fs.mkdtempSync(path.join(os.tmpdir(), 'sspower-walk-git-'));
execFileSync('git', ['init', '-q'], { cwd: repo });
execFileSync('git', ['config', 'user.email', 't@t'], { cwd: repo });
execFileSync('git', ['config', 'user.name', 't'], { cwd: repo });
fs.writeFileSync(path.join(repo, 'x.ts'), '');
fs.writeFileSync(path.join(repo, 'y.js'), '');
fs.writeFileSync(path.join(repo, 'untracked.ts'), '');
execFileSync('git', ['add', 'x.ts', 'y.js'], { cwd: repo });
execFileSync('git', ['commit', '-q', '-m', 'init'], { cwd: repo });

const gotGit = [];
for await (const p of walkSources(repo)) gotGit.push(p);
const relsGit = gotGit.map(p => path.relative(repo, p)).sort();
assert.deepEqual(relsGit, ['untracked.ts', 'x.ts', 'y.js'], `git case got ${JSON.stringify(relsGit)}`);
fs.rmSync(repo, { recursive: true });

console.log('OK walk');
