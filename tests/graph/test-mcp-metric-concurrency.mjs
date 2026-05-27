import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

process.env.SSPOWER_GRAPH_STATE_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-state-conc-'));
process.env.SSPOWER_SESSION_STATE_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-session-conc-'));
const { recordEvent, reconcile, SESSIONS_PATH, SPOOL_DIR } = await import('../../scripts/graph/mcp-tools/metric.mjs');
const { statePathFor } = await import('../../scripts/graph/session-state.mjs');

const FIX = fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-conc-'));
fs.mkdirSync(path.join(FIX, '.claude', 'graph'), { recursive: true });
fs.mkdirSync(path.dirname(statePathFor(FIX)), { recursive: true });
fs.writeFileSync(statePathFor(FIX), JSON.stringify({
  session_id: 'conc-test',
  cwd: FIX,
  started_ts: new Date().toISOString(),
}));

const orig = process.cwd();
process.chdir(FIX);
const tasks = [];
for (let i = 0; i < 50; i++) {
  tasks.push(Promise.resolve().then(() => recordEvent({
    tool: i % 2 === 0 ? 'graph_callers' : 'graph_status',
    ok: true,
    duration_ms: i,
    cwd: FIX,
  })));
}
await Promise.all(tasks);
process.chdir(orig);

const spool = fs.readdirSync(SPOOL_DIR).filter(f => f.startsWith('conc-test.'));
assert.equal(spool.length, 1);
const lines = fs.readFileSync(path.join(SPOOL_DIR, spool[0]), 'utf8').trim().split('\n');
assert.equal(lines.length, 50, `expected 50 lines, got ${lines.length}`);
let parsed = 0;
for (const ln of lines) {
  try { JSON.parse(ln); parsed++; } catch {}
}
assert.equal(parsed, 50, `expected 50 parseable lines, got ${parsed}`);

fs.rmSync(SESSIONS_PATH, { force: true });
await reconcile({ session: 'conc-test', cwd: FIX, reason: 'user_exit' });
const row = JSON.parse(fs.readFileSync(SESSIONS_PATH, 'utf8')).sessions.find(s => s.session_id === 'conc-test');
assert.equal(row.tool_calls, 50);
console.log('concurrency 50-parallel OK');
