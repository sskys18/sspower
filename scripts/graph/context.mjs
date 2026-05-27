// scripts/graph/context.mjs
import { callers, callees } from './query.mjs';

const TOP_N = 8;
const MAX_CHARS = 4096;

export function context(db, task) {
  let hits;
  try {
    hits = db.prepare(`
      SELECT rowid FROM nodes_fts WHERE nodes_fts MATCH ? ORDER BY rank LIMIT ?
    `).all(task.replace(/[^A-Za-z0-9_ ]/g, ' '), TOP_N);
  } catch {
    return { hits: [], reason: 'fts-error' };
  }
  const out = [];
  let chars = 0;
  for (const h of hits) {
    const node = db.prepare('SELECT * FROM nodes WHERE rowid = ?').get(h.rowid);
    if (!node) continue;
    const callerRes = callers(db, node.qualified_name, { limit: 5, disambiguate: true });
    const calleeRes = callees(db, node.qualified_name, { limit: 5 });
    const entry = {
      qname: node.qualified_name,
      file: node.file_path,
      line: node.start_line,
      signature: node.signature,
      callers: (callerRes.matches ?? []).slice(0, 5).map(m => ({ qname: m.src_qname, file: m.src_file, line: m.line })),
      callees: (calleeRes.matches ?? []).slice(0, 5).map(m => ({ qname: m.tgt_qname, file: m.tgt_file, line: m.tgt_start })),
    };
    const enc = JSON.stringify(entry);
    if (chars + enc.length > MAX_CHARS) break;
    chars += enc.length;
    out.push(entry);
  }
  return { hits: out, total_chars: chars };
}
