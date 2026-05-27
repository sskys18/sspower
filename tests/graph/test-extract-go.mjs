import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { extractFile } from '../../scripts/graph/extract-go.mjs';

const absPath = path.resolve('__tests__/graph-fixtures/go/main.go');
const source = await fs.readFile(absPath, 'utf8');
const extracted = await extractFile({ absPath, source, language: 'go' });

const nodes = new Set(extracted.nodes.map(n => `${n.kind}:${n.qualifiedName}`));
assert(nodes.has('function:main'));
assert(nodes.has('method:Worker.Run'));

const imports = extracted.imports.map(i => `${i.moduleSpec}:${i.names.map(n => `${n.imported}->${n.local}`).join(',')}`);
assert(imports.includes('fixture/sample/util:*->util'));

const callSites = extracted.callSites.map(c => `${c.callerQualifiedName}->${c.calleeIdent}`);
assert.equal(callSites.length, 3);
assert(callSites.includes('main->util.Calc'));
assert(callSites.includes('main->println'));
assert(callSites.includes('Worker.Run->util.Calc'));

const utilPath = path.resolve('__tests__/graph-fixtures/go/util/util.go');
const utilSource = await fs.readFile(utilPath, 'utf8');
const utilExtracted = await extractFile({ absPath: utilPath, source: utilSource, language: 'go' });
const utilNodes = new Set(utilExtracted.nodes.map(n => `${n.kind}:${n.qualifiedName}`));
assert(utilNodes.has('function:Calc'));

console.log('OK');
