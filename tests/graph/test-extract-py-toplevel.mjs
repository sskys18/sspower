import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { extractFile } from '../../scripts/graph/extract-py.mjs';

const fixtureDir = await fs.mkdtemp(path.join(process.cwd(), 'tests/graph/.tmp-python-toplevel-'));
const absPath = path.join(fixtureDir, 'script.py');
const source = 'x = 1\nacquire_lock(x)\n';

try {
  await fs.writeFile(absPath, source);

  // Default behavior (no rootDir): falls back to process.cwd().
  const extractedCwd = await extractFile({ absPath, source, language: 'python' });
  const expectedQualifiedName = path
    .relative(process.cwd(), absPath)
    .replace(/\.py$/, '')
    .split(path.sep)
    .join('/');

  const moduleNode = extractedCwd.nodes.find(n => n.kind === 'module');
  assert(moduleNode);
  assert.equal(moduleNode.name, 'script');
  assert.equal(moduleNode.qualifiedName, expectedQualifiedName);
  assert(
    extractedCwd.callSites.some(c =>
      c.callerQualifiedName === moduleNode.qualifiedName &&
      c.calleeIdent === 'acquire_lock'
    )
  );

  // With explicit rootDir: qname is stable regardless of ambient cwd.
  // Pass a deliberately different root so the relative path differs from
  // the cwd-based variant — proves rootDir wins.
  const extractedRoot = await extractFile({
    absPath, source, language: 'python', rootDir: fixtureDir,
  });
  const moduleNodeRoot = extractedRoot.nodes.find(n => n.kind === 'module');
  assert(moduleNodeRoot);
  assert.equal(moduleNodeRoot.qualifiedName, 'script',
    `rootDir-relative qname expected 'script', got '${moduleNodeRoot.qualifiedName}'`);

  console.log('OK');
} finally {
  await fs.unlink(absPath).catch(() => {});
  await fs.rmdir(fixtureDir).catch(() => {});
}
