import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import os from 'node:os';

export const STATE_DIR = process.env.SSPOWER_SESSION_STATE_DIR
  ?? path.join(os.homedir(), '.claude', 'state', 'sspower', 'sessions');
export const STALE_MS = 24 * 60 * 60 * 1000;

export function projectHash(cwd) {
  const real = fs.realpathSync(cwd);
  return crypto.createHash('sha256').update(real).digest('hex').slice(0, 8);
}

export function statePathFor(cwd) {
  return path.join(STATE_DIR, `${projectHash(cwd)}.json`);
}

export function readSessionState(cwd) {
  let stat;
  try { stat = fs.statSync(statePathFor(cwd)); }
  catch { return { sessionId: null, source: 'missing' }; }
  if (Date.now() - stat.mtimeMs > STALE_MS) return { sessionId: null, source: 'stale' };

  let rec;
  try { rec = JSON.parse(fs.readFileSync(statePathFor(cwd), 'utf8')); }
  catch (e) { return { sessionId: null, source: e instanceof SyntaxError ? 'bad_json' : 'unreadable' }; }
  if (!rec.session_id || !rec.cwd) return { sessionId: null, source: 'missing_fields' };

  let recReal, mcpReal;
  try {
    recReal = fs.realpathSync(rec.cwd);
    mcpReal = fs.realpathSync(cwd);
  } catch {
    return { sessionId: null, source: 'cwd_unresolvable' };
  }
  if (recReal !== mcpReal) return { sessionId: null, source: 'cwd_mismatch' };
  return { sessionId: rec.session_id, source: 'claude_session_id', startedTs: rec.started_ts };
}
