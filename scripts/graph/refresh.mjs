// scripts/graph/refresh.mjs
// Two-phase refresh per spec §3.1 transaction body.
//
// Pipeline: readDirty -> dedupe -> stat-reconcile -> reverseImportClosure
// -> in-memory extract (upsert ∪ relink only; delete files need no
// extraction) -> BEGIN IMMEDIATE -> phase 1a (deletes) -> 1b (upserts) ->
// 1c (relink drops outbound edges only) -> 2 (insert resolved edges for
// upsert ∪ relink using rebuilt imports table) -> COMMIT -> truncate
// dirty.
//
// Thrash guard >500 dirty records -> {fullRebuild:true}. Closure cap
// (>0.5 × |files|) -> {fullRebuild:true}. Extraction failure >25% on
// upsert+relink set -> throw and preserve the index.

import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { readDirty, dedupeDirty, reconcileWithStat, truncateDirty } from './dirty.mjs';
import { reverseImportClosure } from './closure.mjs';
import { extractorFor } from './extract.mjs';
import { resolveModule, resolveEdges } from './resolve.mjs';
import { openDb, initSchema, nodeId } from './db.mjs';
import { writeVersionFields } from './session-refresh.mjs';

const THRASH_THRESHOLD = 500;

function languageFor(filePath) {
  const ext = path.extname(filePath);
  if (ext === '.ts' || ext === '.tsx' || ext === '.mts' || ext === '.cts') return 'typescript';
  if (ext === '.js' || ext === '.jsx' || ext === '.mjs' || ext === '.cjs') return 'javascript';
  if (ext === '.py') return 'python';
  if (ext === '.go') return 'go';
  if (ext === '.rs') return 'rust';
  return null;
}

function sha8Content(content) {
  return crypto.createHash('sha256').update(content).digest('hex').slice(0, 8);
}

export async function refresh({ rootDir, graphDir, log = () => {} }) {
  const dbPath = path.join(graphDir, 'index.sqlite');
  const db = openDb(dbPath);
  initSchema(db);
  const run = (sql) => db.exec(sql);

  // 0. Read + dedupe + stat reconcile.
  const raw = await readDirty(graphDir);
  if (raw.length > THRASH_THRESHOLD) {
    log(`thrash: ${raw.length} dirty records > ${THRASH_THRESHOLD}, full rebuild`);
    db.close();
    return { fullRebuild: true, reason: 'thrash', dirtyCount: raw.length };
  }
  const deduped = dedupeDirty(raw);
  const reconciled = await reconcileWithStat(deduped);
  if (reconciled.size === 0) {
    db.close();
    log('refresh: empty dirty queue, nothing to do');
    return { fullRebuild: false, fileCount: 0, nodeCount: 0, edgeCount: 0 };
  }

  // 1. Closure walk.
  const fileCount = db.prepare('SELECT COUNT(*) AS c FROM files').get().c;
  const closure = reverseImportClosure({ db, seed: reconciled, fileCount });
  if (closure.fullRebuild) {
    log(`closure fullRebuild: seed exceeds safety cap`);
    db.close();
    return { fullRebuild: true, reason: 'closure-cap', dirtyCount: raw.length };
  }

  // 2. Extract upsert + relink files.
  const perFile = [];
  let extractFailures = 0;
  for (const [absPath, op] of closure) {
    if (op === 'delete') continue;
    const lang = languageFor(absPath);
    if (!lang) {
      log(`skip ${absPath}: no extractor for extension`);
      continue;
    }
    let source;
    try { source = await fs.readFile(absPath, 'utf8'); }
    catch (e) {
      log(`skip read ${absPath}: ${e.message}`);
      extractFailures++;
      continue;
    }
    let extracted;
    try {
      const ex = await extractorFor(lang);
      extracted = await ex.extractFile({ absPath, source, language: lang, rootDir });
    } catch (e) {
      log(`skip extract ${absPath}: ${e.message}`);
      extractFailures++;
      continue;
    }
    const idedNodes = extracted.nodes.map(n => ({
      ...n,
      id: nodeId(absPath, n.qualifiedName, n.spanSha8),
      filePath: absPath,
    }));
    perFile.push({
      filePath: absPath, language: lang, content: source, extracted, idedNodes,
      contentHash: sha8Content(source),
      op,
    });
  }
  const targetCount = [...closure.values()].filter(op => op !== 'delete').length;
  if (targetCount > 0 && extractFailures / targetCount > 0.25) {
    db.close();
    throw new Error(`refresh aborted: ${extractFailures}/${targetCount} failed (>25%). Index untouched.`);
  }

  // 3. Build importedNamesByFile (mirror build.mjs Phase 2).
  const importedNamesByFile = new Map();
  for (const f of perFile) {
    const map = {};
    for (const imp of f.extracted.imports) {
      const resolved = resolveModule(f.filePath, imp.moduleSpec, f.language);
      if (!resolved) continue;
      for (const n of imp.names) {
        map[n.local] = { path: resolved, imported: n.imported };
      }
    }
    importedNamesByFile.set(f.filePath, map);
  }

  // 4. Transaction.
  const now = Math.floor(Date.now() / 1000);
  const insFile   = db.prepare('INSERT INTO files(path, content_hash, language, indexed_at, node_count) VALUES (?, ?, ?, ?, ?)');
  const insNode   = db.prepare('INSERT INTO nodes(id, kind, name, qualified_name, file_path, language, start_line, end_line, signature, span_sha8, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)');
  const insImport = db.prepare('INSERT OR IGNORE INTO imports(importer_path, imported_path) VALUES (?, ?)');
  const insEdge   = db.prepare('INSERT OR IGNORE INTO edges(source, target, kind, line, confidence) VALUES (?, ?, ?, ?, ?)');
  const delFile           = db.prepare('DELETE FROM files          WHERE path = ?');
  const delImportsByT     = db.prepare('DELETE FROM imports        WHERE imported_path = ?');
  const delNodesByFile    = db.prepare('DELETE FROM nodes          WHERE file_path = ?');
  const delImportsByI     = db.prepare('DELETE FROM imports        WHERE importer_path = ?');
  const delFilesByPath    = db.prepare('DELETE FROM files          WHERE path = ?');
  const delEdgesBySrcFile = db.prepare(
    'DELETE FROM edges WHERE source IN (SELECT id FROM nodes WHERE file_path = ?)'
  );

  run('BEGIN IMMEDIATE');
  try {
    for (const [P, op] of closure) {
      if (op !== 'delete') continue;
      delFile.run(P);
      delImportsByT.run(P);
    }
    for (const f of perFile) {
      if (f.op !== 'upsert') continue;
      delNodesByFile.run(f.filePath);
      delImportsByI.run(f.filePath);
      delFilesByPath.run(f.filePath);
      insFile.run(f.filePath, f.contentHash, f.language, now, f.idedNodes.length);
      for (const n of f.idedNodes) {
        insNode.run(n.id, n.kind, n.name, n.qualifiedName, f.filePath, n.language, n.startLine, n.endLine, n.signature, n.spanSha8, now);
      }
      for (const imp of f.extracted.imports) {
        const resolved = resolveModule(f.filePath, imp.moduleSpec, f.language);
        if (resolved) insImport.run(f.filePath, resolved);
      }
    }
    for (const [P, op] of closure) {
      if (op !== 'relink') continue;
      delEdgesBySrcFile.run(P);
    }
    const allNodes = db.prepare(
      'SELECT id, name, qualified_name AS qualifiedName, file_path AS filePath FROM nodes'
    ).all();
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
    for (const e of edges) {
      insEdge.run(e.source, e.target, e.kind, e.line, e.confidence);
    }
    // P4 Express route-handler edges (mirror build.mjs). Same resolution
    // ladder: import → same-file top-level → cross-graph fallback.
    const nodesByFileAndQname = new Map();
    const nodesByName = new Map();
    const pushM = (m, k, v) => { const a = m.get(k); if (a) a.push(v); else m.set(k, [v]); };
    for (const n of allNodes) {
      pushM(nodesByFileAndQname, `${n.filePath}::${n.qualifiedName}`, n);
      pushM(nodesByName, n.name, n);
    }
    for (const f of perFile) {
      const requests = f.extracted.routeHandlerRequests ?? [];
      const importMap = importedNamesByFile.get(f.filePath) ?? {};
      for (const req of requests) {
        const routeId = nodeId(req.routeFile, req.routeQualifiedName, req.routeSpanSha8);
        const entry = importMap[req.handlerName];
        let placed = false;
        if (entry) {
          const lookupName = (entry.imported === '*' || entry.imported === 'default')
            ? req.handlerName : entry.imported;
          const imported = nodesByFileAndQname.get(`${entry.path}::${lookupName}`) ?? [];
          if (imported.length > 0) {
            for (const t of imported) insEdge.run(routeId, t.id, 'routes', req.line, 2);
            placed = true;
          }
        }
        if (!placed) {
          const intra = nodesByFileAndQname.get(`${req.routeFile}::${req.handlerName}`) ?? [];
          if (intra.length > 0) {
            for (const t of intra) insEdge.run(routeId, t.id, 'routes', req.line, 1);
            placed = true;
          }
        }
        if (!placed) {
          const amb = nodesByName.get(req.handlerName) ?? [];
          for (const t of amb) {
            if (t.id === routeId) continue;
            insEdge.run(routeId, t.id, 'routes', req.line, 0);
          }
        }
      }
    }
    run('COMMIT');
  } catch (e) {
    run('ROLLBACK');
    db.close();
    throw e;
  }

  await truncateDirty(graphDir);

  const nodeCount = db.prepare('SELECT COUNT(*) AS c FROM nodes').get().c;
  const edgeCount = db.prepare('SELECT COUNT(*) AS c FROM edges').get().c;
  log(`refresh: ${closure.size} files touched (${perFile.length} extracted), ${nodeCount} nodes, ${edgeCount} edges total`);

  // Merge-write: preserve git_filesethash so session-refresh's hash
  // gate stays valid after an incremental refresh.
  await writeVersionFields(graphDir, {
    schema: 1,
    ast_grep: process.env.AST_GREP_VERSION ?? 'unknown',
    built_at: now,
    last_refresh: now,
  });

  db.close();
  return {
    fullRebuild: false,
    fileCount: closure.size,
    nodeCount,
    edgeCount,
    extractFailures,
  };
}
