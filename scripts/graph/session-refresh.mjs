// scripts/graph/session-refresh.mjs
// SessionStart sweep planner — Step 0 (git filesethash NEW-FILE detect) +
// Step 1 (rowid-stride sampling for external edits) + Step 2 (return
// recommendation). Time-budgeted. Returns {action, reason, dirtyEmitted,
// sampleSize, divergenceRate}.
//
// Pure planner. The CLI verb wraps the recommendation with the appropriate
// locked operation (refresh-unlocked OR build-unlocked) under
// graph-with-lock.py.

import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { openDb, initSchema } from './db.mjs';

const pExec = promisify(execFile);
const SAMPLE_TARGET = 200;
const DIVERGENCE_THRESHOLD = 0.05;
const MIN_SAMPLE_FOR_REBUILD = 50;

export async function gitFilesetHash(rootDir) {
  try {
    const tracked = (await pExec('git', ['-C', rootDir, 'ls-files', '-z'],
      { encoding: 'buffer', maxBuffer: 100 * 1024 * 1024 })).stdout;
    const others = (await pExec('git', ['-C', rootDir, 'ls-files', '--others', '--exclude-standard', '-z'],
      { encoding: 'buffer', maxBuffer: 100 * 1024 * 1024 })).stdout;
    const buf = Buffer.concat([tracked, others]);
    return crypto.createHash('sha256').update(buf).digest('hex').slice(0, 8);
  } catch { return null; }
}

async function readVersionField(graphDir, field) {
  try {
    const raw = await fs.readFile(path.join(graphDir, 'version'), 'utf8');
    for (const line of raw.split('\n')) {
      const [k, ...rest] = line.split('=');
      if (k === field) return rest.join('=').trim();
    }
  } catch (e) { if (e.code !== 'ENOENT') throw e; }
  return null;
}

async function writeVersionField(graphDir, field, value) {
  const p = path.join(graphDir, 'version');
  let raw = '';
  try { raw = await fs.readFile(p, 'utf8'); } catch (e) { if (e.code !== 'ENOENT') throw e; }
  const lines = raw.split('\n').filter(l => l && !l.startsWith(`${field}=`));
  lines.push(`${field}=${value}`);
  await fs.writeFile(p, lines.join('\n') + '\n');
}

async function appendDirty(graphDir, op, absPath) {
  await fs.appendFile(path.join(graphDir, 'dirty'),
    JSON.stringify({ op, path: absPath }) + '\n');
}

async function contentHash(filePath) {
  try {
    const buf = await fs.readFile(filePath);
    return crypto.createHash('sha256').update(buf).digest('hex').slice(0, 8);
  } catch (e) {
    if (e.code === 'ENOENT') return null;
    throw e;
  }
}

export async function sessionRefresh({ rootDir, graphDir, maxTime = 5000, log = () => {} }) {
  const t0 = Date.now();
  const deadline = t0 + maxTime;
  const dbPath = path.join(graphDir, 'index.sqlite');
  try { await fs.stat(dbPath); } catch { return { action: 'noop', reason: 'no-index' }; }

  // Step 0: filesethash.
  const cur = await gitFilesetHash(rootDir);
  if (cur !== null) {
    const stored = await readVersionField(graphDir, 'git_filesethash');
    if (stored !== cur) {
      await writeVersionField(graphDir, 'git_filesethash', cur);
      log(`filesethash changed (${stored ?? 'unset'} -> ${cur}); build`);
      return { action: 'build', reason: 'filesethash-changed', dirtyEmitted: 0 };
    }
  }

  // Step 1: rowid-stride sampling.
  const db = openDb(dbPath);
  initSchema(db);
  let rows;
  try {
    const total = db.prepare('SELECT COUNT(*) AS c FROM files').get().c;
    if (total === 0) { db.close(); return { action: 'noop', reason: 'fresh-index', dirtyEmitted: 0 }; }
    const sampleSize = Math.min(SAMPLE_TARGET, total);
    if (total <= sampleSize) {
      rows = db.prepare('SELECT path, content_hash FROM files ORDER BY rowid').all();
    } else {
      const stride = Math.max(1, Math.ceil(total / sampleSize));
      let off = Math.floor(Math.random() * stride);
      const stmt = db.prepare('SELECT path, content_hash FROM files WHERE rowid % ? = ? ORDER BY rowid LIMIT ?');
      rows = stmt.all(stride, off, sampleSize);
      if (rows.length === 0) {
        for (let i = 0; i < 3; i++) {
          off = Math.floor(Math.random() * stride);
          rows = stmt.all(stride, off, sampleSize);
          if (rows.length) break;
        }
        if (rows.length === 0) {
          rows = db.prepare('SELECT path, content_hash FROM files ORDER BY rowid LIMIT ?').all(sampleSize);
        }
      }
    }
  } finally { db.close(); }

  let changed = 0;
  let dirtyEmitted = 0;
  for (const r of rows) {
    if (Date.now() > deadline) {
      return { action: 'timeout', reason: 'deadline', dirtyEmitted, sampleSize: rows.length };
    }
    const disk = await contentHash(r.path);
    if (disk === null) { await appendDirty(graphDir, 'delete', r.path); dirtyEmitted++; changed++; }
    else if (disk !== r.content_hash) { await appendDirty(graphDir, 'upsert', r.path); dirtyEmitted++; changed++; }
  }

  if (rows.length === 0) return { action: 'noop', reason: 'empty-sample', dirtyEmitted, sampleSize: 0 };
  const rate = changed / rows.length;
  if (rate > DIVERGENCE_THRESHOLD && rows.length >= MIN_SAMPLE_FOR_REBUILD) {
    return { action: 'build', reason: 'high-divergence', dirtyEmitted, sampleSize: rows.length, divergenceRate: rate };
  }
  if (dirtyEmitted > 0) {
    return { action: 'refresh', reason: 'low-divergence', dirtyEmitted, sampleSize: rows.length, divergenceRate: rate };
  }
  return { action: 'noop', reason: 'no-divergence', dirtyEmitted, sampleSize: rows.length, divergenceRate: rate };
}
