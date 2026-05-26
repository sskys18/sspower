// scripts/graph/query.mjs
import fs from 'node:fs';
import path from 'node:path';

export const MAX_RESULTS = 50;

export function status(db, graphDir) {
  const dbPath = path.join(graphDir, 'index.sqlite');
  const exists = fs.existsSync(dbPath);
  if (!exists) return { ok: false, reason: 'no-index', dbPath };
  const fileCount = db.prepare('SELECT COUNT(*) AS c FROM files').get().c;
  const nodeCount = db.prepare('SELECT COUNT(*) AS c FROM nodes').get().c;
  const edgeCount = db.prepare('SELECT COUNT(*) AS c FROM edges').get().c;
  const lastIndexed = db.prepare('SELECT MAX(indexed_at) AS m FROM files').get().m;
  const dirtyPath = path.join(graphDir, 'dirty');
  let dirtyCount = 0;
  if (fs.existsSync(dirtyPath)) {
    dirtyCount = fs.readFileSync(dirtyPath, 'utf8').split('\n').filter(Boolean).length;
  }
  return { ok: true, fileCount, nodeCount, edgeCount, lastIndexed, dirtyCount };
}

export function nodeLookup(db, name) {
  const rows = db.prepare(
    `SELECT * FROM nodes WHERE name = ? OR qualified_name = ? ORDER BY file_path, start_line LIMIT ?`
  ).all(name, name, MAX_RESULTS);
  return rows;
}

export function callers(db, name, { limit = MAX_RESULTS, disambiguate = false } = {}) {
  const targets = db.prepare(
    `SELECT id, name, qualified_name, file_path, start_line FROM nodes
       WHERE name = ? OR qualified_name = ?`
  ).all(name, name);
  if (targets.length === 0) return { matches: [], targets: [] };
  if (targets.length > 1 && !disambiguate) {
    return { matches: [], targets, ambiguous: true };
  }
  const targetIds = targets.map(t => t.id);
  const placeholders = targetIds.map(() => '?').join(',');
  const rows = db.prepare(
    `SELECT e.source, e.target, e.line, e.confidence,
            src.qualified_name AS src_qname, src.file_path AS src_file, src.start_line AS src_start,
            tgt.qualified_name AS tgt_qname, tgt.file_path AS tgt_file, tgt.start_line AS tgt_start
       FROM edges e
       JOIN nodes src ON e.source = src.id
       JOIN nodes tgt ON e.target = tgt.id
       WHERE e.target IN (${placeholders})
       ORDER BY src.file_path, e.line
       LIMIT ?`
  ).all(...targetIds, Math.min(limit, MAX_RESULTS));
  return { matches: rows, targets };
}

export function callees(db, name, { limit = MAX_RESULTS } = {}) {
  const sources = db.prepare(
    `SELECT id FROM nodes WHERE name = ? OR qualified_name = ?`
  ).all(name, name);
  if (sources.length === 0) return { matches: [], sources: [] };
  const ids = sources.map(s => s.id);
  const placeholders = ids.map(() => '?').join(',');
  const rows = db.prepare(
    `SELECT e.source, e.target, e.line, e.confidence,
            src.qualified_name AS src_qname, src.file_path AS src_file,
            tgt.qualified_name AS tgt_qname, tgt.file_path AS tgt_file, tgt.start_line AS tgt_start
       FROM edges e
       JOIN nodes src ON e.source = src.id
       JOIN nodes tgt ON e.target = tgt.id
       WHERE e.source IN (${placeholders})
       ORDER BY tgt.file_path, e.line
       LIMIT ?`
  ).all(...ids, Math.min(limit, MAX_RESULTS));
  return { matches: rows, sources };
}
