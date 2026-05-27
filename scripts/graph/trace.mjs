// scripts/graph/trace.mjs
export const MAX_RESULTS = 50;

export function trace(db, fromName, toName, { maxHops = 6, limit = MAX_RESULTS } = {}) {
  const fromNodes = db.prepare('SELECT id, qualified_name, file_path, start_line FROM nodes WHERE name = ? OR qualified_name = ?').all(fromName, fromName);
  const toNodes   = db.prepare('SELECT id, qualified_name, file_path, start_line FROM nodes WHERE name = ? OR qualified_name = ?').all(toName,   toName);
  if (fromNodes.length === 0 || toNodes.length === 0) return { paths: [], reason: 'endpoint-not-found' };

  const stmtOut = db.prepare('SELECT target, line FROM edges WHERE source = ?');
  const targets = new Set(toNodes.map(n => n.id));
  const paths = [];

  for (const start of fromNodes) {
    const frontier = [[start.id, []]];
    const visited = new Set([start.id]);
    while (frontier.length && paths.length < limit) {
      const [cur, edgesSoFar] = frontier.shift();
      if (edgesSoFar.length > maxHops) continue;
      if (targets.has(cur) && edgesSoFar.length > 0) {
        paths.push({
          from: start.qualified_name,
          to: toNodes.find(n => n.id === cur)?.qualified_name,
          hops: edgesSoFar.length,
          edges: edgesSoFar,
        });
        continue;
      }
      for (const next of stmtOut.all(cur)) {
        if (visited.has(next.target)) continue;
        visited.add(next.target);
        frontier.push([next.target, [...edgesSoFar, { from: cur, to: next.target, line: next.line }]]);
      }
    }
  }
  return { paths, fromCount: fromNodes.length, toCount: toNodes.length };
}
