import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawnSync } from 'node:child_process';
import url from 'node:url';

process.env.SSPOWER_SESSION_STATE_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-session-contract-state-'));
const { readSessionState } = await import('../../scripts/graph/session-state.mjs');

const PLUGIN_ROOT = path.resolve(url.fileURLToPath(import.meta.url), '../../..');
const FIXTURE_A = fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-ctr-a-'));
const FIXTURE_B = fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-ctr-b-'));
fs.mkdirSync(path.join(FIXTURE_A, '.claude', 'graph'), { recursive: true });
fs.mkdirSync(path.join(FIXTURE_B, '.claude', 'graph'), { recursive: true });

function runHook(cwd, sessionId) {
  const payload = JSON.stringify({
    session_id: sessionId,
    cwd,
    source: 'startup',
    hook_event_name: 'SessionStart',
    transcript_path: '/dev/null',
  });
  const r = spawnSync('bash', [path.join(PLUGIN_ROOT, 'hooks', 'session-start')], {
    input: payload,
    encoding: 'utf8',
    env: { ...process.env, CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT, SSPOWER_SESSION_STATE_DIR: process.env.SSPOWER_SESSION_STATE_DIR },
  });
  assert.equal(r.status, 0, `session-start failed: ${r.stderr}`);
}

runHook(FIXTURE_A, '01-SESSION-A');
const realA = fs.realpathSync(FIXTURE_A);
const rA = readSessionState(realA);
assert.equal(rA.sessionId, '01-SESSION-A', `expected A; got ${JSON.stringify(rA)}`);

runHook(FIXTURE_B, '01-SESSION-B');
const rA2 = readSessionState(realA);
const rB = readSessionState(fs.realpathSync(FIXTURE_B));
assert.equal(rA2.sessionId, '01-SESSION-A', 'project A overwritten by project B');
assert.equal(rB.sessionId, '01-SESSION-B');

const probe = spawnSync('bash', [
  path.join(PLUGIN_ROOT, 'bin', 'sspower-graph-bootstrap.sh'),
  '--probe-session',
], {
  cwd: FIXTURE_A,
  env: {
    ...process.env,
    CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT,
    NODE: process.execPath,
    SSPOWER_SESSION_STATE_DIR: process.env.SSPOWER_SESSION_STATE_DIR,
  },
  encoding: 'utf8',
});
assert.equal(probe.status, 0, `probe stderr=${probe.stderr}`);
assert.equal(probe.stdout.trim(), '01-SESSION-A');

console.log('OK');
