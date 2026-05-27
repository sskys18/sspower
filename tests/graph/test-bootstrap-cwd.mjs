import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import url from 'node:url';

const PLUGIN_ROOT = path.resolve(url.fileURLToPath(import.meta.url), '../../..');
const FIXTURE = path.join(PLUGIN_ROOT, '__tests__', 'graph-fixtures', 'ts-js');

const r = spawnSync('bash', [path.join(PLUGIN_ROOT, 'bin', 'sspower-graph-bootstrap.sh'), '--print-cwd'], {
  cwd: FIXTURE,
  env: { ...process.env, CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT, NODE: process.execPath },
  encoding: 'utf8',
});

assert.equal(r.status, 0, `bootstrap exit=${r.status} stderr=${r.stderr}`);
assert.equal(r.stdout.trim(), FIXTURE, `expected cwd preserved (${FIXTURE}) got (${r.stdout.trim()})`);
console.log('OK');
