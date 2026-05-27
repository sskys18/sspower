import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { readSessionState, statePathFor } from '../session-state.mjs';

export const SPOOL_DIR = process.env.SSPOWER_GRAPH_STATE_DIR
  ?? path.join(os.homedir(), '.claude', 'state', 'sspower', 'graph-mcp');
export const SESSIONS_PATH = path.join(SPOOL_DIR, 'sessions.json');
const MAX_RECORD_BYTES = 4096;
const LOCK_PATH = path.join(SPOOL_DIR, '.sessions.lock');
const MAX_SESSIONS = 500;
const ARCHIVE_RETENTION_DAYS = 60;
const sessionCache = new Map();
const PROCESS_BOOT_SEED = `${Date.now()}:${Math.random()}`;

function ensureSpool() {
  fs.mkdirSync(SPOOL_DIR, { recursive: true, mode: 0o700 });
}

function degradedId(cwd) {
  const seed = `${process.pid}:${PROCESS_BOOT_SEED}:${cwd}`;
  return 'deg-' + crypto.createHash('sha256').update(seed).digest('hex').slice(0, 12);
}

function resolveSession(cwd) {
  let real;
  try { real = fs.realpathSync(cwd); } catch { real = cwd; }
  let currentMtime = 0;
  try { currentMtime = fs.statSync(statePathFor(real)).mtimeMs; } catch {}
  const hit = sessionCache.get(real);
  if (hit && hit.stateMtimeMs === currentMtime) return hit;
  const r = readSessionState(real);
  const out = r.sessionId
    ? { sid: r.sessionId, source: 'claude_session_id', stateMtimeMs: currentMtime }
    : { sid: degradedId(real), source: 'degraded:' + r.source, stateMtimeMs: currentMtime };
  sessionCache.set(real, out);
  return out;
}

export function recordEvent({ tool, ok, duration_ms, cwd }) {
  ensureSpool();
  const { sid, source } = resolveSession(cwd);
  const base = {
    ts: new Date().toISOString(),
    tool,
    ok: !!ok,
    duration_ms,
    cwd,
    session_source: source,
    schema: 1,
  };
  let record = JSON.stringify(base) + '\n';
  if (Buffer.byteLength(record, 'utf8') > MAX_RECORD_BYTES) {
    record = JSON.stringify({ ...base, cwd: cwd.slice(-200), truncated: true }) + '\n';
  }
  fs.appendFileSync(path.join(SPOOL_DIR, `${sid}.${process.pid}.jsonl`), record, { mode: 0o600 });
}

function isEligible(cwd) {
  return fs.existsSync(path.join(cwd, '.claude', 'graph'));
}

function withLock(fn) {
  let fd;
  for (let i = 0; i < 10; i++) {
    try {
      fd = fs.openSync(LOCK_PATH, fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_RDWR, 0o600);
      break;
    } catch (e) {
      if (e.code !== 'EEXIST') throw e;
      try {
        const st = fs.statSync(LOCK_PATH);
        if (Date.now() - st.mtimeMs > 30_000) fs.rmSync(LOCK_PATH);
      } catch {}
      const until = Date.now() + 100;
      while (Date.now() < until) {}
    }
  }
  if (!fd) throw new Error(`metric.reconcile: could not acquire lock at ${LOCK_PATH}`);
  try { return fn(); } finally { fs.closeSync(fd); try { fs.rmSync(LOCK_PATH); } catch {} }
}

function readSessions() {
  if (!fs.existsSync(SESSIONS_PATH)) return { schema_version: 1, updated: null, sessions: [] };
  try {
    const j = JSON.parse(fs.readFileSync(SESSIONS_PATH, 'utf8'));
    if (!Array.isArray(j.sessions)) return { schema_version: 1, updated: null, sessions: [] };
    return j;
  } catch {
    return { schema_version: 1, updated: null, sessions: [] };
  }
}

function p95(arr) {
  if (!arr.length) return null;
  const sorted = [...arr].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * 0.95))];
}

export function aggregate({ window = 50 } = {}) {
  const j = readSessions();
  const sorted = [...j.sessions].sort((a, b) =>
    (b.session_end_ts ?? b.last_call_ts ?? '').localeCompare(a.session_end_ts ?? a.last_call_ts ?? ''));
  const eligible = sorted.filter(s => s.eligible).slice(0, window);
  const ineligible = sorted.filter(s => !s.eligible).slice(0, window).length;
  const sessions_with_call = eligible.filter(s => s.tool_calls > 0).length;
  const eligible_sessions_total = eligible.length;
  const adoption_rate = eligible_sessions_total ? sessions_with_call / eligible_sessions_total : 0;
  const gate_met = eligible_sessions_total >= window && eligible.every(s => s.tool_calls > 0);

  const tool_histogram = {};
  const pooled = {};
  for (const s of eligible) {
    for (const [tool, n] of Object.entries(s.tool_counts ?? {})) {
      tool_histogram[tool] = (tool_histogram[tool] ?? 0) + n;
    }
    for (const [tool, samples] of Object.entries(s.tool_durations ?? {})) {
      pooled[tool] = pooled[tool] ?? [];
      pooled[tool].push(...samples);
    }
  }
  const p95_duration_ms_by_tool = {};
  for (const [tool, samples] of Object.entries(pooled)) {
    p95_duration_ms_by_tool[tool] = p95(samples);
  }

  const totBad = eligible.reduce((a, s) => a + (s.bad_lines ?? 0), 0);
  const totAll = eligible.reduce((a, s) => a + (s.total_lines ?? 0), 0);
  return {
    window,
    eligible_sessions_total,
    sessions_with_call,
    adoption_rate,
    tool_histogram,
    p95_duration_ms_by_tool,
    degraded_session_id_count: eligible.filter(s => s.degraded).length,
    degraded_jsonl_parse_ratio: totAll ? totBad / totAll : 0,
    ineligible_sessions_excluded: ineligible,
    gate_met,
    sessions_total: sorted.length,
  };
}

function writeSessionsAtomic(obj) {
  const tmp = SESSIONS_PATH + '.tmp.' + process.pid;
  fs.writeFileSync(tmp, JSON.stringify(obj, null, 2), { mode: 0o600 });
  fs.renameSync(tmp, SESSIONS_PATH);
}

function projectHashFor(cwd) {
  let real;
  try { real = fs.realpathSync(cwd); } catch { real = cwd; }
  return crypto.createHash('sha256').update(real).digest('hex').slice(0, 8);
}

function cliArg(argv, key) {
  const i = argv.indexOf(`--${key}`);
  return i > -1 ? argv[i + 1] : null;
}

export async function reconcile({ session, cwd, reason }) {
  ensureSpool();
  const all = fs.readdirSync(SPOOL_DIR);
  const matching = all.filter(f => f.startsWith(`${session}.`) && f.endsWith('.jsonl'));
  let realCwd;
  try { realCwd = fs.realpathSync(cwd); } catch { realCwd = cwd; }
  for (const f of all) {
    if (!f.startsWith('deg-') || !f.endsWith('.jsonl')) continue;
    if (matching.includes(f)) continue;
    try {
      const first = fs.readFileSync(path.join(SPOOL_DIR, f), 'utf8').split('\n').find(Boolean);
      if (!first) continue;
      const rec = JSON.parse(first);
      let recReal;
      try { recReal = fs.realpathSync(rec.cwd); } catch { recReal = rec.cwd; }
      if (recReal === realCwd) matching.push(f);
    } catch {}
  }

  const events = [];
  let badLines = 0;
  let totalLines = 0;
  for (const f of matching) {
    let text;
    try { text = fs.readFileSync(path.join(SPOOL_DIR, f), 'utf8'); }
    catch { badLines++; continue; }
    for (const line of text.split('\n')) {
      if (!line) continue;
      totalLines++;
      try { events.push(JSON.parse(line)); } catch { badLines++; }
    }
  }
  events.sort((a, b) => String(a.ts).localeCompare(String(b.ts)));

  const tool_counts = {};
  const tool_durations = {};
  for (const ev of events) {
    tool_counts[ev.tool] = (tool_counts[ev.tool] ?? 0) + 1;
    tool_durations[ev.tool] = tool_durations[ev.tool] ?? [];
    if (tool_durations[ev.tool].length < 200) tool_durations[ev.tool].push(ev.duration_ms);
  }

  const session_source = events[0]?.session_source ?? 'claude_session_id';
  const row = {
    session_id: session,
    schema_version: 2,
    duration_samples_cap: 200,
    session_source,
    eligible: isEligible(cwd),
    tool_calls: events.length,
    tool_counts,
    tool_durations,
    unique_tools: [...new Set(events.map(e => e.tool))],
    first_call_ts: events[0]?.ts ?? null,
    last_call_ts: events[events.length - 1]?.ts ?? null,
    session_end_ts: new Date().toISOString(),
    project_hash: projectHashFor(cwd),
    cwd,
    end_reason: reason ?? null,
    zero_call_reason: events.length === 0 ? 'no_mcp_invocations' : null,
    degraded: session_source.startsWith('degraded'),
    bad_lines: badLines,
    total_lines: totalLines,
  };

  withLock(() => {
    const j = readSessions();
    j.sessions.push(row);
    j.sessions.sort((a, b) => (b.session_end_ts ?? b.last_call_ts ?? '').localeCompare(a.session_end_ts ?? a.last_call_ts ?? ''));
    if (j.sessions.length > MAX_SESSIONS) j.sessions.length = MAX_SESSIONS;
    j.updated = new Date().toISOString();
    writeSessionsAtomic(j);
  });

  const archDir = path.join(SPOOL_DIR, 'archive', new Date().toISOString().slice(0, 7).replace('-', ''));
  fs.mkdirSync(archDir, { recursive: true, mode: 0o700 });
  for (const f of matching) {
    try { fs.renameSync(path.join(SPOOL_DIR, f), path.join(archDir, f)); } catch {}
  }
  try {
    const archRoot = path.join(SPOOL_DIR, 'archive');
    const cutoffMs = Date.now() - ARCHIVE_RETENTION_DAYS * 24 * 60 * 60 * 1000;
    for (const d of fs.readdirSync(archRoot)) {
      const p = path.join(archRoot, d);
      if (fs.statSync(p).mtimeMs < cutoffMs) fs.rmSync(p, { recursive: true, force: true });
    }
  } catch {}
  return row;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const argv = process.argv.slice(2);
  if (argv[0] === 'reconcile') {
    const session = cliArg(argv, 'session');
    const cwd = cliArg(argv, 'cwd');
    const reason = cliArg(argv, 'reason');
    if (!session || !cwd) {
      process.stderr.write('reconcile: --session and --cwd required\n');
      process.exit(2);
    }
    reconcile({ session, cwd, reason }).then(() => process.exit(0)).catch(e => {
      process.stderr.write(`reconcile error: ${e.message}\n`);
      process.exit(1);
    });
  } else if (argv[0] === 'aggregate') {
    process.stdout.write(JSON.stringify(aggregate({ window: Number(cliArg(argv, 'window') ?? 50) }), null, 2) + '\n');
  } else {
    process.stderr.write(`metric.mjs: unknown command ${argv[0]}\n`);
    process.exit(2);
  }
}
