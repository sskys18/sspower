import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

process.env.SSPOWER_SESSION_STATE_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-session-state-'));
const { readSessionState, statePathFor } = await import('../../scripts/graph/session-state.mjs');

const T = fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-test-'));
const realT = fs.realpathSync(T);

let r = readSessionState(realT);
assert.equal(r.sessionId, null);
assert.equal(r.source, 'missing');

fs.mkdirSync(path.dirname(statePathFor(realT)), { recursive: true });
fs.writeFileSync(statePathFor(realT), JSON.stringify({
  session_id: '01HXY',
  cwd: realT,
  started_ts: new Date().toISOString(),
}));
r = readSessionState(realT);
assert.equal(r.sessionId, '01HXY');
assert.equal(r.source, 'claude_session_id');

fs.writeFileSync(statePathFor(realT), JSON.stringify({
  session_id: '01HXZ',
  cwd: '/some/other/path',
  started_ts: new Date().toISOString(),
}));
r = readSessionState(realT);
assert.equal(r.sessionId, null);
assert.equal(r.source, 'cwd_unresolvable');

const valid = JSON.stringify({ session_id: '01HXX', cwd: realT, started_ts: new Date().toISOString() });
fs.writeFileSync(statePathFor(realT), valid);
const past = (Date.now() - 25 * 60 * 60 * 1000) / 1000;
fs.utimesSync(statePathFor(realT), past, past);
r = readSessionState(realT);
assert.equal(r.sessionId, null);
assert.equal(r.source, 'stale');

console.log('OK');
