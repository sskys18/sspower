#!/usr/bin/env node
import { resolveModule, resolveEdges } from '../../scripts/graph/resolve.mjs';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

// resolveModule: relative + extension search
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'sspower-resolve-'));
fs.writeFileSync(path.join(tmp, 'util.ts'), '');
fs.writeFileSync(path.join(tmp, 'index.ts'), '');
fs.mkdirSync(path.join(tmp, 'lib'));
fs.writeFileSync(path.join(tmp, 'lib', 'index.ts'), '');

assert.equal(
  resolveModule(path.join(tmp, 'app.ts'), './util'),
  path.join(tmp, 'util.ts')
);
assert.equal(
  resolveModule(path.join(tmp, 'app.ts'), './lib'),
  path.join(tmp, 'lib', 'index.ts')
);
assert.equal(
  resolveModule(path.join(tmp, 'app.ts'), 'react'),
  null  // bare module -> external
);
fs.rmSync(tmp, { recursive: true });

// resolveEdges: confidence assignment
const intraFile = '/tmp/a.ts';
const otherFile = '/tmp/b.ts';
const nodes = [
  { id: 'a#caller#11111111', name: 'caller', qualifiedName: 'caller', filePath: intraFile },
  { id: 'a#helper#22222222', name: 'helper', qualifiedName: 'helper', filePath: intraFile },
  { id: 'b#helper#33333333', name: 'helper', qualifiedName: 'helper', filePath: otherFile },
];
const callSites = [
  { callerQualifiedName: 'caller', calleeIdent: 'helper', line: 10, callerFile: intraFile, importedNames: {} },
];
const intraEdges = resolveEdges({ nodes, callSites });
assert.equal(intraEdges.length, 1);
assert.equal(intraEdges[0].confidence, 1, `expected intra=1, got ${intraEdges[0].confidence}`);
assert.equal(intraEdges[0].source, 'a#caller#11111111');
assert.equal(intraEdges[0].target, 'a#helper#22222222');

// Imported (conf=2): caller in b.ts calls something imported from a.ts
const importedCall = [{
  callerQualifiedName: 'main', calleeIdent: 'helper', line: 3, callerFile: otherFile,
  importedNames: { helper: { path: intraFile, imported: 'helper' } },
}];
const nodes2 = [
  ...nodes,
  { id: 'b#main#44444444', name: 'main', qualifiedName: 'main', filePath: otherFile },
];
const importedEdges = resolveEdges({ nodes: nodes2, callSites: importedCall });
assert.equal(importedEdges.length, 1);
assert.equal(importedEdges[0].confidence, 2);
assert.equal(importedEdges[0].target, 'a#helper#22222222');

// Imported with alias (conf=2): `import { helper as h } from './a'; h()`.
// callerIdent='h' but resolver MUST look up by imported='helper' in a.ts.
const aliasCall = [{
  callerQualifiedName: 'main', calleeIdent: 'h', line: 7, callerFile: otherFile,
  importedNames: { h: { path: intraFile, imported: 'helper' } },
}];
const aliasEdges = resolveEdges({ nodes: nodes2, callSites: aliasCall });
assert.equal(aliasEdges.length, 1, `alias should resolve, got ${aliasEdges.length} edges`);
assert.equal(aliasEdges[0].confidence, 2);
assert.equal(aliasEdges[0].target, 'a#helper#22222222');

// Ambiguous via cross-graph fallback (conf=0): caller in c.ts has no import -> fall back to all-same-name nodes
const ambigCall = [{
  callerQualifiedName: 'caller2', calleeIdent: 'helper', line: 5, callerFile: '/tmp/c.ts',
  importedNames: {},
}];
const nodes3 = [
  ...nodes,
  { id: 'c#caller2#55555555', name: 'caller2', qualifiedName: 'caller2', filePath: '/tmp/c.ts' },
];
const ambigEdges = resolveEdges({ nodes: nodes3, callSites: ambigCall });
// helper exists in BOTH a.ts and b.ts -> 2 ambiguous edges
assert.equal(ambigEdges.length, 2, `expected 2 ambiguous edges, got ${ambigEdges.length}`);
for (const e of ambigEdges) assert.equal(e.confidence, 0);

// Ambiguous via intra-file multi-match (conf=0): two methods named `shared` in
// the same file (the ts-js fixture case). Single-file lookup yields >1 -> conf=0.
const sharedFile = '/tmp/shared.ts';
const nodes4 = [
  { id: 'sh#caller#aaaaaaaa', name: 'caller', qualifiedName: 'caller', filePath: sharedFile },
  { id: 'sh#A.shared#bbbbbbbb', name: 'shared', qualifiedName: 'A.shared', filePath: sharedFile },
  { id: 'sh#B.shared#cccccccc', name: 'shared', qualifiedName: 'B.shared', filePath: sharedFile },
];
const multiCall = [
  { callerQualifiedName: 'caller', calleeIdent: 'a.shared', line: 10, callerFile: sharedFile, importedNames: {} },
];
const multiEdges = resolveEdges({ nodes: nodes4, callSites: multiCall });
assert.equal(multiEdges.length, 2, `intra-file multi-match should emit 2 edges, got ${multiEdges.length}`);
for (const e of multiEdges) assert.equal(e.confidence, 0, `intra-file multi-match must be ambiguous (conf=0), got ${e.confidence}`);

// Member call MUST NOT forge a false conf=2 edge through a same-named import.
// Regression: `foo.bar()` where `bar` is imported from elsewhere but `foo` is
// a local receiver. The pre-fix resolver looked up importedNames[bareName='bar']
// and incorrectly produced an import edge.
const appFile  = '/tmp/app.ts';
const modFile  = '/tmp/mod.ts';
const memberNodes = [
  { id: 'app#caller#xxxxxxxx', name: 'caller', qualifiedName: 'caller', filePath: appFile },
  { id: 'mod#bar#yyyyyyyy',    name: 'bar',    qualifiedName: 'bar',    filePath: modFile },
];
const memberCall = [{
  callerQualifiedName: 'caller', calleeIdent: 'foo.bar', line: 3, callerFile: appFile,
  // `import { bar } from './mod'` — local binding 'bar' present, but the
  // call is `foo.bar()`, NOT `bar()`. Resolver MUST ignore the import here.
  importedNames: { bar: { path: modFile, imported: 'bar' } },
}];
const memberEdges = resolveEdges({ nodes: memberNodes, callSites: memberCall });
const forged = memberEdges.find(e => e.target === 'mod#bar#yyyyyyyy' && e.confidence === 2);
assert.ok(!forged, `member call foo.bar() must not forge conf=2 edge through imported bar: ${JSON.stringify(memberEdges)}`);

// Namespace member: `import * as ns from './mod'; ns.bar()` → conf=2.
const nsCall = [{
  callerQualifiedName: 'caller', calleeIdent: 'ns.bar', line: 4, callerFile: appFile,
  importedNames: { ns: { path: modFile, imported: '*' } },
}];
const nsEdges = resolveEdges({ nodes: memberNodes, callSites: nsCall });
assert.equal(nsEdges.length, 1, `namespace member should resolve, got ${nsEdges.length}`);
assert.equal(nsEdges[0].confidence, 2);
assert.equal(nsEdges[0].target, 'mod#bar#yyyyyyyy');

// Regression: `import { helper } from './mod'` must resolve to the top-level
// `helper` export in mod.ts, NOT every class method also named `helper`.
const modWithMethod = '/tmp/mod2.ts';
const appFile2 = '/tmp/app2.ts';
const qnameNodes = [
  { id: 'app#caller#aaaaaaaa', name: 'caller', qualifiedName: 'caller', filePath: appFile2 },
  { id: 'mod#helper-top#bbbbbbbb', name: 'helper', qualifiedName: 'helper', filePath: modWithMethod },
  { id: 'mod#C.helper#cccccccc',   name: 'helper', qualifiedName: 'C.helper', filePath: modWithMethod },
];
const qnameCall = [{
  callerQualifiedName: 'caller', calleeIdent: 'helper', line: 5, callerFile: appFile2,
  importedNames: { helper: { path: modWithMethod, imported: 'helper' } },
}];
const qnameEdges = resolveEdges({ nodes: qnameNodes, callSites: qnameCall });
assert.equal(qnameEdges.length, 1, `named import must match top-level only, got ${qnameEdges.length} edges: ${JSON.stringify(qnameEdges)}`);
assert.equal(qnameEdges[0].target, 'mod#helper-top#bbbbbbbb');
assert.equal(qnameEdges[0].confidence, 2);

console.log('OK resolve');
