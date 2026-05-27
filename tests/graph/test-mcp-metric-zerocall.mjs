import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawnSync } from 'node:child_process';
import url from 'node:url';

process.env.SSPOWER_GRAPH_STATE_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-state-zc-'));
process.env.SSPOWER_SESSION_STATE_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-session-zc-'));
const { SESSIONS_PATH, recordEvent } = await import('../../scripts/graph/mcp-tools/metric.mjs');

const PLUGIN_ROOT = path.resolve(url.fileURLToPath(import.meta.url), '../../..');
const FIX = fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-zc-'));
fs.mkdirSync(path.join(FIX, '.claude', 'graph'), { recursive: true });

const startPayload = JSON.stringify({
  session_id: 'zc-test',
  cwd: FIX,
  source: 'startup',
  hook_event_name: 'SessionStart',
  transcript_path: '/dev/null',
});
let r = spawnSync('bash', [path.join(PLUGIN_ROOT, 'hooks', 'session-start')], {
  input: startPayload,
  encoding: 'utf8',
  env: {
    ...process.env,
    CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT,
    SSPOWER_SESSION_STATE_DIR: process.env.SSPOWER_SESSION_STATE_DIR,
  },
});
assert.equal(r.status, 0, `session-start stderr=${r.stderr}`);

fs.rmSync(SESSIONS_PATH, { force: true });
const endPayload = JSON.stringify({
  session_id: 'zc-test',
  cwd: FIX,
  reason: 'user_exit',
  hook_event_name: 'SessionEnd',
});
r = spawnSync('bash', [path.join(PLUGIN_ROOT, 'hooks', 'graph-metric-reconcile.sh')], {
  input: endPayload,
  encoding: 'utf8',
  env: {
    ...process.env,
    CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT,
    SSPOWER_GRAPH_STATE_DIR: process.env.SSPOWER_GRAPH_STATE_DIR,
    SSPOWER_SESSION_STATE_DIR: process.env.SSPOWER_SESSION_STATE_DIR,
  },
});
assert.equal(r.status, 0, `reconcile stderr=${r.stderr}`);

const sj = JSON.parse(fs.readFileSync(SESSIONS_PATH, 'utf8'));
const row = sj.sessions.find(s => s.session_id === 'zc-test');
assert.ok(row, 'no row written for zero-call session');
assert.equal(row.eligible, true);
assert.equal(row.tool_calls, 0);
assert.equal(row.zero_call_reason, 'no_mcp_invocations');
console.log('zero-call eligible session OK');

const FIX2 = fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-zc-deg-'));
fs.mkdirSync(path.join(FIX2, '.claude', 'graph'), { recursive: true });
const orig = process.cwd();
process.chdir(FIX2);
recordEvent({ tool: 'graph_status', ok: true, duration_ms: 5, cwd: FIX2 });
process.chdir(orig);

const endPayload2 = JSON.stringify({
  session_id: 'deg-recovery-test',
  cwd: FIX2,
  reason: 'user_exit',
  hook_event_name: 'SessionEnd',
});
const r2 = spawnSync('bash', [path.join(PLUGIN_ROOT, 'hooks', 'graph-metric-reconcile.sh')], {
  input: endPayload2,
  encoding: 'utf8',
  env: {
    ...process.env,
    CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT,
    SSPOWER_GRAPH_STATE_DIR: process.env.SSPOWER_GRAPH_STATE_DIR,
    SSPOWER_SESSION_STATE_DIR: process.env.SSPOWER_SESSION_STATE_DIR,
  },
});
assert.equal(r2.status, 0, `degraded reconcile stderr=${r2.stderr}`);
const sj2 = JSON.parse(fs.readFileSync(SESSIONS_PATH, 'utf8'));
const drow = sj2.sessions.find(s => s.session_id === 'deg-recovery-test');
assert.ok(drow, 'no row for degraded recovery');
assert.equal(drow.tool_calls, 1, 'degraded spool was not claimed by cwd-equality');
assert.equal(drow.degraded, true);
console.log('degraded-session reconcile OK');
