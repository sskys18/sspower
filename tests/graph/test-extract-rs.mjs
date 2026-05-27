import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { extractFile } from '../../scripts/graph/extract-rs.mjs';

const absPath = path.resolve('__tests__/graph-fixtures/rust/src/main.rs');
const source = await fs.readFile(absPath, 'utf8');
const extracted = await extractFile({ absPath, source, language: 'rust' });

const nodes = new Set(extracted.nodes.map(n => `${n.kind}:${n.qualifiedName}`));
assert(nodes.has('function:main'));
assert(nodes.has('function:caller'));
assert(nodes.has('method:Worker.run'));

const imports = extracted.imports.map(i => `${i.moduleSpec}:${i.names.map(n => `${n.imported}->${n.local}`).join(',')}`);
assert(imports.includes('util:calc->calc'));

const callSites = extracted.callSites.map(c => `${c.callerQualifiedName}->${c.calleeIdent}`);
assert.equal(callSites.length, 4);
assert(callSites.includes('main->caller'));
assert(callSites.includes('main->println'));
assert(callSites.includes('caller->calc'));
assert(callSites.includes('Worker.run->calc'));

const utilPath = path.resolve('__tests__/graph-fixtures/rust/src/util.rs');
const utilSource = await fs.readFile(utilPath, 'utf8');
const utilExtracted = await extractFile({ absPath: utilPath, source: utilSource, language: 'rust' });
const utilNodes = new Set(utilExtracted.nodes.map(n => `${n.kind}:${n.qualifiedName}`));
assert(utilNodes.has('function:calc'));

// Qualified `Type::method(...)` calls must normalize the path separator to
// `.` so resolver (resolve.mjs:174) can split calleeIdent into receiver/leaf.
// Without this, real Rust call sites would never produce edges.
{
  const probeSrc = `fn entry() {
    let x = MyStruct::new();
    let y = nested::mod_name::helper();
    let z = receiver.member();
}\n`;
  const probePath = '/tmp/sspower-extract-rs-probe.rs';
  await fs.writeFile(probePath, probeSrc);
  const probe = await extractFile({ absPath: probePath, source: probeSrc, language: 'rust' });
  const callIdents = probe.callSites.map(c => c.calleeIdent);
  assert(callIdents.includes('MyStruct.new'), `expected MyStruct.new, got ${callIdents}`);
  assert(callIdents.includes('nested.mod_name.helper'), `expected nested.mod_name.helper, got ${callIdents}`);
  assert(callIdents.includes('receiver.member'), `expected receiver.member, got ${callIdents}`);
  assert(!callIdents.some(c => c.includes('::')), `no calleeIdent should contain ::, got ${callIdents}`);
  await fs.unlink(probePath);
}

console.log('OK');
