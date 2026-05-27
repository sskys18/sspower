// tests/graph/test-refresh.mjs
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { build } from '../../scripts/graph/build.mjs';
import { refresh } from '../../scripts/graph/refresh.mjs';
import { openDb, initSchema } from '../../scripts/graph/db.mjs';

async function snapshot(gd) {
  const db = openDb(path.join(gd, 'index.sqlite'));
  initSchema(db);
  const q = (s) => db.prepare(s).all();
  const out = {
    nodes:   q('SELECT id, kind, name, qualified_name, file_path, start_line, end_line FROM nodes ORDER BY id'),
    edges:   q('SELECT source, target, kind, line, confidence FROM edges ORDER BY source, target, kind, line'),
    imports: q('SELECT importer_path, imported_path FROM imports ORDER BY importer_path, imported_path'),
    files:   q('SELECT path, language FROM files ORDER BY path'),
  };
  db.close();
  return out;
}

async function append(gd, op, p) {
  await fs.appendFile(path.join(gd, 'dirty'), JSON.stringify({ op, path: p }) + '\n');
}

const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'sspower-refresh-'));
const gd  = path.join(tmp, '.claude', 'graph');
await fs.mkdir(gd, { recursive: true });
const a = path.join(tmp, 'a.ts');
const b = path.join(tmp, 'b.ts');
const c = path.join(tmp, 'c.ts');
// Fill with 12 unrelated files to keep the closure cap (50%) from
// firing on tiny test fixtures. refresh of one upsert seed will pull
// at most 2 files into working (b + its importer a), well under 50%.
await fs.writeFile(b, `export function helper() { return 42; }\n`);
await fs.writeFile(a, `import { helper } from './b';\nexport function caller() { return helper(); }\n`);
await fs.writeFile(c, `export const unrelated = 1;\n`);
for (let i = 0; i < 12; i++) {
  await fs.writeFile(path.join(tmp, `pad${i}.ts`), `export const pad${i} = ${i};\n`);
}

await build({ rootDir: tmp, graphDir: gd, log: () => {} });

await fs.writeFile(b, `export function helper2() { return 42; }\n`);
await append(gd, 'upsert', b);
const r1 = await refresh({ rootDir: tmp, graphDir: gd, log: () => {} });
assert.equal(r1.fullRebuild, false, `expected partial refresh, got fullRebuild reason=${r1.reason}`);
const after = await snapshot(gd);
await fs.writeFile(path.join(gd, 'dirty'), '');
await build({ rootDir: tmp, graphDir: gd, log: () => {} });
const full = await snapshot(gd);
assert.deepEqual(after.nodes,   full.nodes,   'nodes after refresh must match full rebuild');
assert.deepEqual(after.edges,   full.edges,   'edges mismatch');
assert.deepEqual(after.imports, full.imports, 'imports mismatch');
assert.deepEqual(after.files,   full.files,   'files mismatch');

await fs.unlink(c);
await append(gd, 'delete', c);
const r2 = await refresh({ rootDir: tmp, graphDir: gd, log: () => {} });
assert.equal(r2.fullRebuild, false);
const files2 = (await snapshot(gd)).files.map(f => f.path);
assert.ok(!files2.includes(c), 'c.ts must be removed');
assert.ok(files2.includes(a) && files2.includes(b));

const thrash = [];
for (let i = 0; i < 501; i++) thrash.push(JSON.stringify({ op: 'upsert', path: a }) + '\n');
await fs.writeFile(path.join(gd, 'dirty'), thrash.join(''));
const r3 = await refresh({ rootDir: tmp, graphDir: gd, log: () => {} });
assert.equal(r3.fullRebuild, true);

await fs.writeFile(path.join(gd, 'dirty'), '');
const r4 = await refresh({ rootDir: tmp, graphDir: gd, log: () => {} });
assert.equal(r4.fullRebuild, false);
assert.equal(r4.fileCount, 0);

await fs.rm(tmp, { recursive: true, force: true });
console.log('test-refresh.mjs OK');
