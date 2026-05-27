import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawnSync } from 'node:child_process';
import url from 'node:url';

const PLUGIN_ROOT = path.resolve(url.fileURLToPath(import.meta.url), '../../..');

const tmp1 = fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-pre-foreign-'));
fs.writeFileSync(path.join(tmp1, '.mcp.json'), JSON.stringify({
  mcpServers: { 'sspower-graph': { command: '/usr/bin/some-other-tool' } },
}));
let r = spawnSync('bash', [path.join(PLUGIN_ROOT, 'bin', 'sspower-graph-bootstrap.sh'), '--print-cwd'], {
  cwd: tmp1,
  env: { ...process.env, CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT, NODE: process.execPath, HOME: tmp1 },
  encoding: 'utf8',
});
assert.equal(r.status, 78, `case 1 expected 78, got ${r.status} stderr=${r.stderr}`);
assert.ok(r.stderr.includes('collision'), 'case 1 stderr mentions collision');
console.log('preflight foreign collision OK');

r = spawnSync('bash', [path.join(PLUGIN_ROOT, 'bin', 'sspower-graph-bootstrap.sh'), '--print-cwd'], {
  cwd: PLUGIN_ROOT,
  env: { ...process.env, CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT, NODE: process.execPath, HOME: fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-pre-home-')) },
  encoding: 'utf8',
});
assert.equal(r.status, 0, `case 2 (own .mcp.json) expected 0, got ${r.status} stderr=${r.stderr}`);
console.log('preflight own-config skip OK');

const tmp3 = fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-pre-tpl-'));
fs.writeFileSync(path.join(tmp3, '.mcp.json'), JSON.stringify({
  mcpServers: { 'sspower-graph': { command: '${CLAUDE_PLUGIN_ROOT}/bin/sspower-graph-bootstrap.sh' } },
}));
r = spawnSync('bash', [path.join(PLUGIN_ROOT, 'bin', 'sspower-graph-bootstrap.sh'), '--print-cwd'], {
  cwd: tmp3,
  env: { ...process.env, CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT, NODE: process.execPath, HOME: tmp3 },
  encoding: 'utf8',
});
assert.equal(r.status, 0, `case 3 (template match) expected 0, got ${r.status} stderr=${r.stderr}`);
console.log('preflight template-match accept OK');
