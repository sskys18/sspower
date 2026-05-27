import path from 'node:path';
import { graphDirFor, withDb } from './db.mjs';
import { status, callers, callees, nodeLookup } from './query.mjs';
import { trace } from './trace.mjs';
import { impact } from './impact.mjs';
import { context as contextQuery } from './context.mjs';

function noIndex(cwd) {
  return { ok: false, reason: 'no-index', dbPath: path.join(graphDirFor(cwd), 'index.sqlite') };
}

export async function queryStatus(cwd) {
  const graphDir = graphDirFor(cwd);
  return withDb(graphDir, db => db === null ? noIndex(cwd) : status(db, graphDir));
}

export async function queryCallers(cwd, name, { limit = 50, disambiguate = false } = {}) {
  return withDb(graphDirFor(cwd), db => {
    if (db === null) return { matches: [], targets: [], reason: 'no-index' };
    return callers(db, name, { limit, disambiguate });
  });
}

export async function queryCallees(cwd, name, { limit = 50 } = {}) {
  return withDb(graphDirFor(cwd), db => {
    if (db === null) return { matches: [], sources: [], reason: 'no-index' };
    return callees(db, name, { limit });
  });
}

export async function queryTrace(cwd, from, to, { maxHops = 6, limit = 50 } = {}) {
  return withDb(graphDirFor(cwd), db => {
    if (db === null) return { paths: [], reason: 'no-index' };
    return trace(db, from, to, { maxHops, limit });
  });
}

export async function queryImpact(cwd, filePath, { limit = 50 } = {}) {
  const absFile = path.resolve(cwd, filePath);
  return withDb(graphDirFor(cwd), db => {
    if (db === null) {
      return { target_file: absFile, direct_count: 0, transitive_count: 0, files: [], reason: 'no-index' };
    }
    return impact(db, absFile, { limit });
  });
}

export async function queryNode(cwd, name) {
  return withDb(graphDirFor(cwd), db => {
    if (db === null) return [];
    return nodeLookup(db, name);
  });
}

export async function queryContext(cwd, task) {
  if (typeof task !== 'string') throw new Error('task must be string');
  if (task.length > 500) task = task.slice(0, 500);
  return withDb(graphDirFor(cwd), db => {
    if (db === null) return { hits: [], total_chars: 0, reason: 'no-index' };
    return contextQuery(db, task);
  });
}
