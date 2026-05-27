import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import url from 'node:url';

process.env.SSPOWER_GRAPH_STATE_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-state-'));
process.env.SSPOWER_SESSION_STATE_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-session-state-'));
const { recordEvent, SPOOL_DIR } = await import('../../scripts/graph/mcp-tools/metric.mjs');
const { statePathFor } = await import('../../scripts/graph/session-state.mjs');

const real = fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-metric-'));
fs.mkdirSync(path.dirname(statePathFor(real)), { recursive: true });
fs.writeFileSync(statePathFor(real), JSON.stringify({
  session_id: 'metric-test-sid',
  cwd: real,
  started_ts: new Date().toISOString(),
}));

const orig = process.cwd();
process.chdir(real);
recordEvent({ tool: 'graph_status', ok: true, duration_ms: 12, cwd: real });
recordEvent({ tool: 'graph_callers', ok: false, duration_ms: 99, cwd: real });
process.chdir(orig);

const files = fs.readdirSync(SPOOL_DIR).filter(f => f.startsWith('metric-test-sid.'));
assert.equal(files.length, 1, `expected 1 spool file, got ${files.length}`);
const lines = fs.readFileSync(path.join(SPOOL_DIR, files[0]), 'utf8').trim().split('\n');
assert.equal(lines.length, 2);
const e1 = JSON.parse(lines[0]);
assert.equal(e1.tool, 'graph_status');
assert.equal(e1.ok, true);
assert.equal(e1.schema, 1);
console.log('recordEvent OK');

await new Promise(r => setTimeout(r, 20));
fs.writeFileSync(statePathFor(real), JSON.stringify({
  session_id: 'metric-test-sid-2',
  cwd: real,
  started_ts: new Date().toISOString(),
}));
process.chdir(real);
recordEvent({ tool: 'graph_status', ok: true, duration_ms: 1, cwd: real });
process.chdir(orig);
const after = fs.readdirSync(SPOOL_DIR).filter(f => f.endsWith('.jsonl'));
const sids = new Set(after.map(f => f.split('.')[0]));
assert.ok(sids.has('metric-test-sid'), 'old sid spool still present');
assert.ok(sids.has('metric-test-sid-2'), 'new sid not picked up — cache stale');
console.log('cache invalidation OK');

const metricMod = await import('../../scripts/graph/mcp-tools/metric.mjs');
const { reconcile, SESSIONS_PATH } = metricMod;
if (fs.existsSync(SESSIONS_PATH)) fs.rmSync(SESSIONS_PATH);
await reconcile({ session: 'metric-test-sid', cwd: real, reason: 'user_exit' });
const sj = JSON.parse(fs.readFileSync(SESSIONS_PATH, 'utf8'));
assert.equal(sj.sessions.length, 1);
assert.equal(sj.sessions[0].session_id, 'metric-test-sid');
assert.equal(sj.sessions[0].tool_calls, 2);
assert.equal(sj.sessions[0].eligible, false, 'no .claude/graph/ in tmp = ineligible');
console.log('reconcile OK');

fs.mkdirSync(path.join(real, '.claude', 'graph'), { recursive: true });
fs.writeFileSync(path.join(real, '.claude', 'graph', 'index.sqlite'), '');
fs.rmSync(SESSIONS_PATH, { force: true });
process.chdir(real);
recordEvent({ tool: 'graph_status', ok: true, duration_ms: 1, cwd: real });
process.chdir(orig);
await reconcile({ session: 'metric-test-sid-2', cwd: real, reason: 'user_exit' });
const sj2 = JSON.parse(fs.readFileSync(SESSIONS_PATH, 'utf8'));
assert.equal(sj2.sessions[0].eligible, true, '.claude/graph/ present = eligible');
console.log('reconcile eligibility OK');

fs.rmSync(SESSIONS_PATH, { force: true });
const { spawn } = await import('node:child_process');
const sidA = 'concurrent-a', sidB = 'concurrent-b';
const realA = fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-conc-a-'));
const realB = fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-conc-b-'));
for (const [r, sid] of [[realA, sidA], [realB, sidB]]) {
  fs.mkdirSync(path.dirname(statePathFor(r)), { recursive: true });
  fs.writeFileSync(statePathFor(r), JSON.stringify({ session_id: sid, cwd: r, started_ts: new Date().toISOString() }));
  fs.mkdirSync(path.join(r, '.claude', 'graph'), { recursive: true });
  process.chdir(r);
  recordEvent({ tool: 'graph_status', ok: true, duration_ms: 1, cwd: r });
}
process.chdir(orig);

const PLUGIN_ROOT_STR = path.resolve(url.fileURLToPath(import.meta.url), '../../..');
const procs = [sidA, sidB].map(sid => spawn(process.execPath, [
  path.join(PLUGIN_ROOT_STR, 'scripts', 'graph', 'mcp-tools', 'metric.mjs'),
  'reconcile', '--session', sid, '--cwd', sid === sidA ? realA : realB,
], {
  env: {
    ...process.env,
    SSPOWER_GRAPH_STATE_DIR: process.env.SSPOWER_GRAPH_STATE_DIR,
    SSPOWER_SESSION_STATE_DIR: process.env.SSPOWER_SESSION_STATE_DIR,
  },
}));
const results = await Promise.all(procs.map(p => new Promise(r => p.on('exit', c => r(c)))));
assert.deepEqual(results, [0, 0]);
const finalSess = JSON.parse(fs.readFileSync(SESSIONS_PATH, 'utf8')).sessions;
const ids = finalSess.map(s => s.session_id);
assert.ok(ids.includes(sidA), 'concurrent reconcile lost session A');
assert.ok(ids.includes(sidB), 'concurrent reconcile lost session B');
console.log('concurrent reconcile OK');

const { aggregate } = await import('../../scripts/graph/mcp-tools/metric.mjs');
fs.rmSync(SESSIONS_PATH, { force: true });
const sessions = [];
for (let i = 0; i < 50; i++) {
  sessions.push({
    session_id: `synth-${i}`,
    schema_version: 2,
    duration_samples_cap: 200,
    session_source: 'claude_session_id',
    eligible: true,
    tool_calls: 1 + (i % 3),
    tool_counts: { graph_callers: 1 + (i % 3) },
    tool_durations: { graph_callers: Array.from({ length: 1 + (i % 3) }, (_, k) => 10 + k * 5) },
    unique_tools: ['graph_callers'],
    first_call_ts: '2026-05-27T00:00:00Z',
    last_call_ts: '2026-05-27T00:01:00Z',
    session_end_ts: `2026-05-27T${String((i % 5) + 1).padStart(2, '0')}:00:00Z`,
    project_hash: 'aa',
    cwd: '/x',
    end_reason: 'user_exit',
    zero_call_reason: null,
    degraded: false,
    bad_lines: 0,
    total_lines: 1 + (i % 3),
  });
}
fs.mkdirSync(SPOOL_DIR, { recursive: true });
fs.writeFileSync(SESSIONS_PATH, JSON.stringify({ schema_version: 1, sessions }));
const ag = aggregate({ window: 50 });
assert.equal(ag.gate_met, true);
assert.equal(ag.eligible_sessions_total, 50);
assert.equal(ag.sessions_with_call, 50);
const expectedCallers = sessions.reduce((a, s) => a + (s.tool_counts?.graph_callers ?? 0), 0);
assert.equal(ag.tool_histogram.graph_callers, expectedCallers, 'histogram should sum call counts');
assert.ok('graph_callers' in ag.p95_duration_ms_by_tool, 'p95 by tool present');
assert.ok(typeof ag.p95_duration_ms_by_tool.graph_callers === 'number');
assert.equal(ag.degraded_jsonl_parse_ratio, 0);
console.log('aggregate gate OK');

sessions.unshift({
  session_id: 'synth-zero',
  eligible: true,
  tool_calls: 0,
  tool_counts: {},
  tool_durations: {},
  unique_tools: [],
  first_call_ts: null,
  last_call_ts: null,
  session_end_ts: '2026-05-27T10:00:00Z',
  session_source: 'claude_session_id',
  schema_version: 2,
  duration_samples_cap: 200,
  project_hash: 'aa',
  cwd: '/x',
  end_reason: 'user_exit',
  zero_call_reason: 'no_mcp_invocations',
  degraded: false,
  bad_lines: 0,
  total_lines: 0,
});
fs.writeFileSync(SESSIONS_PATH, JSON.stringify({ schema_version: 1, sessions }));
const ag2 = aggregate({ window: 50 });
assert.equal(ag2.gate_met, false);
console.log('aggregate gate-fail OK');
