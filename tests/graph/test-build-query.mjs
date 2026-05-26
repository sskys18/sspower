#!/usr/bin/env node
import { build } from '../../scripts/graph/build.mjs';
import { openDb, initSchema } from '../../scripts/graph/db.mjs';
import { callers, callees, nodeLookup, status } from '../../scripts/graph/query.mjs';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const ROOT = path.resolve(import.meta.dirname, '..', '..');

// Case A: fixture pack ts-js
{
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'sspower-build-'));
  const fixtureSrc = path.join(ROOT, '__tests__/graph-fixtures/ts-js');
  fs.cpSync(fixtureSrc, tmp, { recursive: true });

  const graphDir = path.join(tmp, '.claude', 'graph');
  const result = await build({ rootDir: tmp, graphDir, log: () => {} });
  assert.ok(result.nodeCount >= 5, `nodes=${result.nodeCount}`);

  const db = openDb(path.join(graphDir, 'index.sqlite'));
  initSchema(db);

  const r = callers(db, 'helper');
  assert.equal(r.targets.length, 1);
  assert.equal(r.matches.length, 1, `helper callers=${JSON.stringify(r)}`);
  assert.equal(r.matches[0].src_qname, 'caller');
  assert.equal(r.matches[0].confidence, 1);

  const amb = nodeLookup(db, 'ambiguous');
  assert.equal(amb.length, 1);
  assert.equal(amb[0].qualified_name, 'ambiguous');

  const s = status(db, graphDir);
  assert.equal(s.ok, true);
  assert.ok(s.fileCount >= 1);
  assert.ok(s.nodeCount >= 5);

  db.close();
  fs.rmSync(tmp, { recursive: true });
  console.log('OK build+query on ts-js fixture');
}

// Case B: P1 acceptance -- build the live plugin repo, callers of cmdImplement
{
  const graphDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sspower-graph-live-'));
  const result = await build({ rootDir: ROOT, graphDir, log: () => {} });
  assert.ok(result.nodeCount > 100, `expected many nodes, got ${result.nodeCount}`);

  const db = openDb(path.join(graphDir, 'index.sqlite'));
  initSchema(db);
  const r = callers(db, 'cmdImplement');
  assert.ok(r.matches.length >= 1, `cmdImplement callers=${JSON.stringify(r.matches)}`);
  const fromMainAt2061 = r.matches.find(m =>
    m.src_qname === 'main' && m.src_file.endsWith('codex-bridge.mjs') && m.line === 2061);
  assert.ok(fromMainAt2061, `expected main@codex-bridge.mjs:2061, got: ${JSON.stringify(r.matches.map(m => `${m.src_qname}@${m.src_file}:${m.line}`))}`);
  console.log('OK live-repo cmdImplement callers contain main@codex-bridge.mjs:2061');

  db.close();
  fs.rmSync(graphDir, { recursive: true });
}

console.log('OK build+query');
