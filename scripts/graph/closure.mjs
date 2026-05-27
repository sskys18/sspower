// scripts/graph/closure.mjs
// Fixed-point reverse-import + reverse-edge closure walker.
// Spec §3.1 K1 — closure walks imports UNION edges. The imports table
// alone misses ambiguous-name, route, and `implements` edges that have
// no import provenance.
//
// Returns Map<absPath, op> where op in {"upsert", "delete", "relink"}.
// Seed paths keep their explicit op. Newly discovered reverse importers
// get op="relink" — outbound edges rebuilt, nodes kept.
//
// Safety cap: |working| > 0.5 × |files| returns {fullRebuild: true} —
// caller falls through to a full build.

export function reverseImportClosure({ db, seed, fileCount }) {
  const opFor = new Map();
  for (const [p, op] of seed) opFor.set(p, op);

  const working = new Set();
  const queue = [...seed.keys()];

  const stmtImports = db.prepare(
    'SELECT importer_path FROM imports WHERE imported_path = ?'
  );
  const stmtEdges = db.prepare(
    `SELECT DISTINCT src.file_path AS p
       FROM edges e
       JOIN nodes src ON e.source = src.id
       JOIN nodes tgt ON e.target = tgt.id
      WHERE tgt.file_path = ?`
  );

  while (queue.length) {
    const P = queue.shift();
    if (working.has(P)) continue;
    working.add(P);

    if (working.size > 0.5 * fileCount) {
      return { fullRebuild: true };
    }

    const reverseSet = new Set();
    for (const row of stmtImports.all(P)) reverseSet.add(row.importer_path);
    for (const row of stmtEdges.all(P))   reverseSet.add(row.p);

    for (const I of reverseSet) {
      if (working.has(I)) continue;
      if (!opFor.has(I)) opFor.set(I, 'relink');
      queue.push(I);
    }
  }

  opFor.fullRebuild = false;
  return opFor;
}
