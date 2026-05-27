// tests/graph/test-closure.mjs
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { openDb, initSchema } from '../../scripts/graph/db.mjs';
import { reverseImportClosure } from '../../scripts/graph/closure.mjs';

const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'sspower-closure-'));
const graphDir = path.join(tmp, '.claude', 'graph');
await fs.mkdir(graphDir, { recursive: true });
const dbPath = path.join(graphDir, 'index.sqlite');
const db = openDb(dbPath);
initSchema(db);

const F = (rel) => path.join(tmp, rel);
const now = Math.floor(Date.now() / 1000);
const ins = db.prepare('INSERT INTO files VALUES (?, ?, ?, ?, ?)');
for (const p of ['a.ts','b.ts','c.ts','d.ts','e.ts','f.ts','g.ts','h.ts']) {
  ins.run(F(p), 'h00d', 'typescript', now, 0);
}
const insImp = db.prepare('INSERT INTO imports VALUES (?, ?)');
insImp.run(F('a.ts'), F('b.ts'));
insImp.run(F('b.ts'), F('c.ts'));
insImp.run(F('d.ts'), F('b.ts'));
insImp.run(F('e.ts'), F('e.ts'));

const insNode = db.prepare('INSERT INTO nodes VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)');
insNode.run('node-f', 'function', 'foo', 'foo', F('f.ts'), 'typescript', 1, 5, 'function foo()', 'aaaaaaaa', now);
insNode.run('node-g', 'function', 'goo', 'goo', F('g.ts'), 'typescript', 1, 5, 'function goo()', 'bbbbbbbb', now);
const insEdge = db.prepare('INSERT INTO edges VALUES (?, ?, ?, ?, ?)');
insEdge.run('node-f', 'node-g', 'calls', 3, 0);

// (1) Linear chain: delete c.ts -> b.ts (relink) and a.ts (relink).
{
  const seed = new Map([[F('c.ts'), 'delete']]);
  const closure = reverseImportClosure({ db, seed, fileCount: 8 });
  assert.equal(closure.size, 4);
  assert.equal(closure.get(F('c.ts')), 'delete');
  assert.equal(closure.get(F('b.ts')), 'relink');
  assert.equal(closure.get(F('a.ts')), 'relink');
  assert.equal(closure.get(F('d.ts')), 'relink');
}

// (2) Upsert c.ts -> same closure shape, seed stays upsert.
{
  const seed = new Map([[F('c.ts'), 'upsert']]);
  const closure = reverseImportClosure({ db, seed, fileCount: 8 });
  assert.equal(closure.get(F('c.ts')), 'upsert');
  assert.equal(closure.get(F('b.ts')), 'relink');
  assert.equal(closure.get(F('a.ts')), 'relink');
  assert.equal(closure.get(F('d.ts')), 'relink');
}

// (3) Fan-in.
{
  const seed = new Map([[F('b.ts'), 'delete']]);
  const closure = reverseImportClosure({ db, seed, fileCount: 8 });
  assert.equal(closure.size, 3);
  assert.equal(closure.get(F('b.ts')), 'delete');
  assert.equal(closure.get(F('a.ts')), 'relink');
  assert.equal(closure.get(F('d.ts')), 'relink');
}

// (4) Cycle.
{
  const seed = new Map([[F('e.ts'), 'upsert']]);
  const closure = reverseImportClosure({ db, seed, fileCount: 8 });
  assert.equal(closure.size, 1);
  assert.equal(closure.get(F('e.ts')), 'upsert');
}

// (5) Edge-only cascade (spec §3.1 K1 — edges union).
{
  const seed = new Map([[F('g.ts'), 'delete']]);
  const closure = reverseImportClosure({ db, seed, fileCount: 8 });
  assert.equal(closure.get(F('g.ts')), 'delete');
  assert.equal(closure.get(F('f.ts')), 'relink');
}

// (6) Safety cap.
{
  const seed = new Map([
    [F('a.ts'), 'upsert'], [F('b.ts'), 'upsert'], [F('c.ts'), 'upsert'],
    [F('d.ts'), 'upsert'], [F('e.ts'), 'upsert'],
  ]);
  const closure = reverseImportClosure({ db, seed, fileCount: 8 });
  assert.equal(closure.fullRebuild, true);
}

// (7) Seed op never overwritten by relink.
{
  const seed = new Map([
    [F('c.ts'), 'delete'],
    [F('b.ts'), 'upsert'],
  ]);
  const closure = reverseImportClosure({ db, seed, fileCount: 8 });
  assert.equal(closure.get(F('b.ts')), 'upsert');
  assert.equal(closure.get(F('c.ts')), 'delete');
  assert.equal(closure.get(F('a.ts')), 'relink');
}

db.close();
await fs.rm(tmp, { recursive: true, force: true });
console.log('test-closure.mjs OK');
