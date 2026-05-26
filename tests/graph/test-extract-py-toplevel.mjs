import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { extractFile } from '../../scripts/graph/extract-py.mjs';

const fixtureDir = await fs.mkdtemp(path.join(process.cwd(), 'tests/graph/.tmp-python-toplevel-'));
const absPath = path.join(fixtureDir, 'script.py');
const source = 'x = 1\nacquire_lock(x)\n';

try {
  await fs.writeFile(absPath, source);

  const extracted = await extractFile({ absPath, source, language: 'python' });
  const expectedQualifiedName = path
    .relative(process.cwd(), absPath)
    .replace(/\.py$/, '')
    .split(path.sep)
    .join('/');

  const moduleNode = extracted.nodes.find(n => n.kind === 'module');
  assert(moduleNode);
  assert.equal(moduleNode.name, 'script');
  assert.equal(moduleNode.qualifiedName, expectedQualifiedName);
  assert(
    extracted.callSites.some(c =>
      c.callerQualifiedName === moduleNode.qualifiedName &&
      c.calleeIdent === 'acquire_lock'
    )
  );

  console.log('OK');
} finally {
  await fs.unlink(absPath).catch(() => {});
  await fs.rmdir(fixtureDir).catch(() => {});
}
