// scripts/graph/dirty.mjs
// Read + dedupe + stat-reconcile the JSONL dirty queue produced by
// scripts/graph-append-dirty.py.
//
// Spec §3.1 H2* — JSONL only, no text prefixes. Records:
//   {"op":"upsert","path":"/abs/..."}  or  {"op":"delete","path":"/abs/..."}.
// Dedupe rule: LAST record wins per normalized path. Stat reconcile then
// degrades op based on actual disk state (delete -> upsert if file exists,
// upsert -> delete if file missing). The PostToolUse hook is event-ordered
// but `git pull` between session-start and the next refresh can land an
// "upsert" record for a file the pull then deleted; the stat-reconcile
// step is the safety net.
import fs from 'node:fs/promises';
import path from 'node:path';

const VALID_OPS = new Set(['upsert', 'delete']);

export async function readDirty(graphDir) {
  const dirtyPath = path.join(graphDir, 'dirty');
  let raw;
  try { raw = await fs.readFile(dirtyPath, 'utf8'); }
  catch (e) {
    if (e.code === 'ENOENT') return [];
    throw e;
  }
  const out = [];
  let lineNo = 0;
  for (const line of raw.split('\n')) {
    lineNo++;
    if (line === '') continue;
    let rec;
    try { rec = JSON.parse(line); }
    catch (e) { throw new Error(`malformed dirty record at ${dirtyPath}:${lineNo}: ${e.message}`); }
    if (!rec || typeof rec.op !== 'string' || typeof rec.path !== 'string') {
      throw new Error(`malformed dirty record at ${dirtyPath}:${lineNo}: missing op|path`);
    }
    if (!VALID_OPS.has(rec.op)) {
      throw new Error(`unknown op '${rec.op}' at ${dirtyPath}:${lineNo} (allowed: ${[...VALID_OPS].join(',')})`);
    }
    out.push({ op: rec.op, path: path.resolve(rec.path) });
  }
  return out;
}

export function dedupeDirty(records) {
  const m = new Map();
  for (const r of records) m.set(r.path, r.op);
  return m;
}

export async function reconcileWithStat(deduped) {
  const out = new Map();
  for (const [absPath, op] of deduped) {
    let exists = false;
    try { await fs.stat(absPath); exists = true; }
    catch (e) { if (e.code !== 'ENOENT') throw e; }
    if (exists) out.set(absPath, 'upsert');
    else        out.set(absPath, 'delete');
    void op;
  }
  return out;
}

export async function truncateDirty(graphDir) {
  // Called after a successful refresh commits. Caller holds the lock
  // (graph-with-lock.py) so this is race-free vs append.
  const dirtyPath = path.join(graphDir, 'dirty');
  try { await fs.truncate(dirtyPath, 0); }
  catch (e) { if (e.code !== 'ENOENT') throw e; }
}
