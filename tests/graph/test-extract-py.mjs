import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { extractFile } from '../../scripts/graph/extract-py.mjs';

const absPath = path.resolve('__tests__/graph-fixtures/python/main.py');
const source = await fs.readFile(absPath, 'utf8');
const extracted = await extractFile({ absPath, source, language: 'python' });

const nodes = new Set(extracted.nodes.map(n => `${n.kind}:${n.qualifiedName}`));
assert(nodes.has('function:caller'));
assert(nodes.has('class:Worker'));
assert(nodes.has('method:Worker.run'));

const imports = new Set(extracted.imports.map(i => i.moduleSpec));
assert(imports.has('helpers'));
assert(imports.has('pkg.util'));

const callSites = extracted.callSites.map(c => `${c.callerQualifiedName}->${c.calleeIdent}`);
assert.equal(callSites.length, 3);
assert(callSites.includes('caller->helper'));
assert(callSites.includes('caller->calc'));
assert(callSites.includes('Worker.run->helper'));

const scriptPath = path.resolve('scripts/graph-append-dirty.py');
const scriptSource = await fs.readFile(scriptPath, 'utf8');
const scriptExtracted = await extractFile({ absPath: scriptPath, source: scriptSource, language: 'python' });
const topLevelCalls = scriptExtracted.callSites.map(c => `${c.callerQualifiedName}->${c.calleeIdent}`);
assert(topLevelCalls.includes('scripts/graph-append-dirty->acquire_lock'));

console.log('OK');
