// scripts/graph/build.mjs
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { walkSources } from './walk.mjs';
import { extractFile } from './extract-ts.mjs';
import { resolveModule, resolveEdges } from './resolve.mjs';
import { openDb, initSchema, nodeId } from './db.mjs';

function languageFor(filePath) {
  const ext = path.extname(filePath);
  if (ext === '.ts' || ext === '.tsx' || ext === '.mts' || ext === '.cts') return 'typescript';
  return 'javascript';
}

function sha8File(content) {
  return crypto.createHash('sha256').update(content).digest('hex').slice(0, 8);
}

export async function build({ rootDir, graphDir, log = () => {} }) {
  const dbPath = path.join(graphDir, 'index.sqlite');
  const db = openDb(dbPath);
  initSchema(db);

  const allNodes = [];
  const perFile = [];

  // Phase 1: walk + extract per file (no DB writes -- pure in-memory).
  let fileCount = 0;
  for await (const filePath of walkSources(rootDir)) {
    fileCount++;
    let source;
    try { source = await fs.readFile(filePath, 'utf8'); }
    catch (e) { log(`skip read ${filePath}: ${e.message}`); continue; }
    const language = languageFor(filePath);
    let extracted;
    try { extracted = await extractFile({ absPath: filePath, source, language }); }
    catch (e) { log(`skip extract ${filePath}: ${e.message}`); continue; }

    const idedNodes = extracted.nodes.map(n => ({
      ...n,
      id: nodeId(filePath, n.qualifiedName, n.spanSha8),
      filePath,
    }));
    allNodes.push(...idedNodes);
    perFile.push({
      filePath, language, content: source, extracted,
      idedNodes,
      contentHash: sha8File(source),
    });
    if (fileCount % 100 === 0) log(`extracted ${fileCount} files`);
  }
  log(`extract done: ${fileCount} files, ${allNodes.length} nodes`);

  // Phase 2: build import maps in memory (no DB writes).
  // Map shape: local-name -> { path, imported }.
  //   `import { greet } from './u'`        -> { greet: { path:'/abs/u.ts', imported:'greet' } }
  //   `import { greet as g } from './u'`   -> { g:     { path:'/abs/u.ts', imported:'greet' } }
  //   `import x from './u'`                -> { x:     { path:'/abs/u.ts', imported:'default' } }
  //   `import * as ns from './u'`          -> { ns:    { path:'/abs/u.ts', imported:'*' } }
  // The resolver uses `imported` (the upstream name) for the cross-file
  // lookup, NOT `local` -- so aliasing doesn't break attribution.
  const importedNamesByFile = new Map();
  for (const f of perFile) {
    const map = {};
    for (const imp of f.extracted.imports) {
      const resolved = resolveModule(f.filePath, imp.moduleSpec);
      if (!resolved) continue;
      for (const n of imp.names) {
        map[n.local] = { path: resolved, imported: n.imported };
      }
    }
    importedNamesByFile.set(f.filePath, map);
  }

  const enrichedCallSites = [];
  for (const f of perFile) {
    for (const cs of f.extracted.callSites) {
      enrichedCallSites.push({
        ...cs,
        callerFile: f.filePath,
        importedNames: importedNamesByFile.get(f.filePath) ?? {},
      });
    }
  }
  const edges = resolveEdges({ nodes: allNodes, callSites: enrichedCallSites });

  // Phase 3: SINGLE transaction -- destructive wipe + insert. On crash, DB
  // reverts to the previous full-build state. Without this, an interrupted
  // build leaves an empty index.
  const now = Math.floor(Date.now() / 1000);
  const insFile = db.prepare(
    'INSERT INTO files(path, content_hash, language, indexed_at, node_count) VALUES (?, ?, ?, ?, ?)'
  );
  const insNode = db.prepare(
    'INSERT INTO nodes(id, kind, name, qualified_name, file_path, language, start_line, end_line, signature, span_sha8, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)'
  );
  const insImport = db.prepare(
    'INSERT OR IGNORE INTO imports(importer_path, imported_path) VALUES (?, ?)'
  );
  const insEdge = db.prepare(
    'INSERT OR IGNORE INTO edges(source, target, kind, line, confidence) VALUES (?, ?, ?, ?, ?)'
  );

  db.exec('BEGIN IMMEDIATE');
  try {
    db.exec('DELETE FROM edges');
    db.exec('DELETE FROM imports');
    db.exec('DELETE FROM nodes');
    db.exec('DELETE FROM files');

    for (const f of perFile) {
      insFile.run(f.filePath, f.contentHash, f.language, now, f.idedNodes.length);
      for (const n of f.idedNodes) {
        insNode.run(n.id, n.kind, n.name, n.qualifiedName, f.filePath, n.language, n.startLine, n.endLine, n.signature, n.spanSha8, now);
      }
      for (const imp of f.extracted.imports) {
        const resolved = resolveModule(f.filePath, imp.moduleSpec);
        if (resolved) insImport.run(f.filePath, resolved);
      }
    }
    for (const e of edges) {
      insEdge.run(e.source, e.target, e.kind, e.line, e.confidence);
    }
    db.exec('COMMIT');
  } catch (e) {
    db.exec('ROLLBACK');
    throw e;
  }
  log(`build done: ${fileCount} files, ${allNodes.length} nodes, ${edges.length} edges`);

  await fs.writeFile(
    path.join(graphDir, 'version'),
    `schema=1\nast_grep=${process.env.AST_GREP_VERSION ?? 'unknown'}\nbuilt_at=${now}\n`,
    'utf8'
  );

  db.close();
  return { fileCount, nodeCount: allNodes.length, edgeCount: edges.length };
}
