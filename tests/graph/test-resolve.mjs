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

// Imported (conf=2): caller in b.ts calls something imported from a.ts.
// Clean node set — b.ts must NOT have its own `helper` for this test,
// otherwise the same-file shadow rule (intra wins) takes over correctly
// but bypasses the import code path under test.
const importNodes = [
  { id: 'a#helper#22222222', name: 'helper', qualifiedName: 'helper', filePath: intraFile },
  { id: 'b#main#44444444',   name: 'main',   qualifiedName: 'main',   filePath: otherFile },
];
const importedCall = [{
  callerQualifiedName: 'main', calleeIdent: 'helper', line: 3, callerFile: otherFile,
  importedNames: { helper: { path: intraFile, imported: 'helper' } },
}];
const importedEdges = resolveEdges({ nodes: importNodes, callSites: importedCall });
assert.equal(importedEdges.length, 1);
assert.equal(importedEdges[0].confidence, 2);
assert.equal(importedEdges[0].target, 'a#helper#22222222');

// Imported with alias (conf=2): `import { helper as h } from './a'; h()`.
// callerIdent='h' but resolver MUST look up by imported='helper' in a.ts.
const aliasCall = [{
  callerQualifiedName: 'main', calleeIdent: 'h', line: 7, callerFile: otherFile,
  importedNames: { h: { path: intraFile, imported: 'helper' } },
}];
const aliasEdges = resolveEdges({ nodes: importNodes, callSites: aliasCall });
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

// Regression: bare direct call `helper()` must NOT resolve to a class
// method `C.helper` in the same file just because they share a bare name.
// The intra-file step is restricted to top-level symbols (qualifiedName == name).
const classFile = '/tmp/class-collide.ts';
const classModFile = '/tmp/class-mod.ts';
const classCollisionNodes = [
  { id: 'cc#caller#a1a1a1a1', name: 'caller',   qualifiedName: 'caller',   filePath: classFile },
  { id: 'cc#C.helper#b1b1b1b1', name: 'helper', qualifiedName: 'C.helper', filePath: classFile },
  { id: 'cm#helper#c1c1c1c1', name: 'helper',   qualifiedName: 'helper',   filePath: classModFile },
];
const classCollisionCall = [{
  callerQualifiedName: 'caller', calleeIdent: 'helper', line: 5, callerFile: classFile,
  importedNames: { helper: { path: classModFile, imported: 'helper' } },
}];
const classCollisionEdges = resolveEdges({ nodes: classCollisionNodes, callSites: classCollisionCall });
assert.equal(classCollisionEdges.length, 1, `class-collision should resolve once, got ${classCollisionEdges.length}`);
assert.equal(classCollisionEdges[0].target, 'cm#helper#c1c1c1c1', `class method C.helper must NOT capture bare helper() call`);
assert.equal(classCollisionEdges[0].confidence, 2);

// Regression: same-file local definition shadows a same-name import.
// `import { helper } from './u'; function caller() { function helper(){}; helper(); }`
// — the inner `helper` is the call target, NOT the imported one.
const shadowApp = '/tmp/shadow-app.ts';
const shadowMod = '/tmp/shadow-mod.ts';
const shadowNodes = [
  { id: 'app#caller#11111100', name: 'caller', qualifiedName: 'caller', filePath: shadowApp },
  { id: 'app#helper#22222200', name: 'helper', qualifiedName: 'helper', filePath: shadowApp },
  { id: 'mod#helper#33333300', name: 'helper', qualifiedName: 'helper', filePath: shadowMod },
];
const shadowCall = [{
  callerQualifiedName: 'caller', calleeIdent: 'helper', line: 8, callerFile: shadowApp,
  importedNames: { helper: { path: shadowMod, imported: 'helper' } },
}];
const shadowEdges = resolveEdges({ nodes: shadowNodes, callSites: shadowCall });
assert.equal(shadowEdges.length, 1, `shadow case should emit 1 edge, got ${shadowEdges.length}: ${JSON.stringify(shadowEdges)}`);
assert.equal(shadowEdges[0].target, 'app#helper#22222200', `local shadow must win, got target ${shadowEdges[0].target}`);
assert.equal(shadowEdges[0].confidence, 1, `local shadow is intra-file conf=1, got ${shadowEdges[0].confidence}`);

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
