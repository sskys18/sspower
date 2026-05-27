// scripts/graph/impact.mjs
export const MAX_RESULTS = 50;

export function impact(db, filePath, { limit = MAX_RESULTS } = {}) {
  const direct = db.prepare(`
    SELECT DISTINCT src.id, src.qualified_name, src.file_path
      FROM edges e
      JOIN nodes src ON e.source = src.id
      JOIN nodes tgt ON e.target = tgt.id
     WHERE tgt.file_path = ?
  `).all(filePath);
  const visited = new Set(direct.map(d => d.id));
  const frontier = [...direct.map(d => d.id)];
  const stmtIn = db.prepare(`
    SELECT src.id, src.qualified_name, src.file_path
      FROM edges e
      JOIN nodes src ON e.source = src.id
     WHERE e.target = ?
  `);
  const transitive = [...direct];
  while (frontier.length && transitive.length < limit) {
    const cur = frontier.shift();
    for (const row of stmtIn.all(cur)) {
      if (visited.has(row.id)) continue;
      visited.add(row.id);
      transitive.push(row);
      frontier.push(row.id);
    }
  }
  const byFile = new Map();
  for (const t of transitive) {
    if (!byFile.has(t.file_path)) byFile.set(t.file_path, []);
    byFile.get(t.file_path).push(t.qualified_name);
  }
  return {
    target_file: filePath,
    direct_count: direct.length,
    transitive_count: transitive.length,
    files: [...byFile.entries()].map(([file_path, qnames]) => ({ file_path, qnames })),
  };
}
