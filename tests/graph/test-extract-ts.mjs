#!/usr/bin/env node
import { extractFile } from '../../scripts/graph/extract-ts.mjs';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';

const ROOT = path.resolve(import.meta.dirname, '..', '..');
const fixture = path.join(ROOT, '__tests__', 'graph-fixtures', 'ts-js', 'sample-input.ts');
const source = await fs.readFile(fixture, 'utf8');

const { nodes, imports, callSites } = await extractFile({
  absPath: fixture,
  source,
  language: 'typescript',
});

const names = nodes.map(n => n.qualifiedName).sort();
assert.deepEqual(names, ['A', 'A.shared', 'B', 'B.shared', 'ambiguous', 'caller', 'helper']);

const helper = nodes.find(n => n.qualifiedName === 'helper');
assert.equal(helper.kind, 'function');
assert.equal(helper.startLine, 5);
assert.equal(helper.endLine, 7);
assert.equal(helper.spanSha8.length, 8);
assert.ok(helper.signature.startsWith('function helper'));

const aShared = nodes.find(n => n.qualifiedName === 'A.shared');
assert.equal(aShared.kind, 'method');
assert.equal(aShared.name, 'shared');
assert.equal(aShared.startLine, 14);

assert.equal(imports.length, 0);

const inAmbiguous = callSites.filter(c => c.callerQualifiedName === 'ambiguous');
assert.equal(inAmbiguous.length, 2);
assert.deepEqual(inAmbiguous.map(c => c.calleeIdent).sort(), ['a.shared', 'b.shared']);

const inCaller = callSites.filter(c => c.callerQualifiedName === 'caller');
assert.equal(inCaller.length, 1);
assert.equal(inCaller[0].calleeIdent, 'helper');
assert.equal(inCaller[0].line, 10);

console.log('OK extract-ts');
