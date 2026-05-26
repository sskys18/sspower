// scripts/graph/resolve.mjs
import fs from 'node:fs';
import path from 'node:path';

const TS_EXTS = ['.ts', '.tsx', '.mts', '.cts'];
const JS_EXTS = ['.js', '.jsx', '.mjs', '.cjs'];
const ALL_EXTS = [...TS_EXTS, ...JS_EXTS];

export function resolveModule(importerAbs, moduleSpec) {
  if (!moduleSpec.startsWith('./') && !moduleSpec.startsWith('../') && !moduleSpec.startsWith('/')) {
    return null;  // bare module (npm pkg etc.) — external
  }
  const importerDir = path.dirname(importerAbs);
  const base = path.resolve(importerDir, moduleSpec);
  if (fs.existsSync(base) && fs.statSync(base).isFile()) return base;
  for (const ext of ALL_EXTS) {
    const candidate = base + ext;
    if (fs.existsSync(candidate) && fs.statSync(candidate).isFile()) return candidate;
  }
  for (const ext of ALL_EXTS) {
    const candidate = path.join(base, `index${ext}`);
    if (fs.existsSync(candidate) && fs.statSync(candidate).isFile()) return candidate;
  }
  return null;
}

export function resolveEdges({ nodes, callSites }) {
  const byQualified = new Map();
  const byName = new Map();
  const byFileAndName = new Map();
  for (const n of nodes) {
    pushMap(byQualified, n.qualifiedName, n);
    pushMap(byName, n.name, n);
    pushMap(byFileAndName, `${n.filePath}::${n.name}`, n);
  }

  const edges = [];
  for (const cs of callSites) {
    const callerNode = byQualified.get(cs.callerQualifiedName)?.find(n => n.filePath === cs.callerFile);
    if (!callerNode) continue;
    const parts = cs.calleeIdent.split('.');
    const localName = parts[0].replace(/\?$/, '');  // strip optional chaining on receiver
    const bareName = parts.at(-1);
    const isMemberCall = parts.length > 1;

    // Cross-file import resolution.
    //   Direct call `foo()`     → look up the local binding `foo` in importedNames.
    //   Member call `foo.bar()` → only use importedNames if `foo` is a namespace
    //                              (* as foo) or a default import; otherwise `foo`
    //                              is a local receiver and `bar` is a property,
    //                              NOT an imported binding. Without this guard,
    //                              `import { bar }` + a separate `foo.bar()` call
    //                              would forge a false conf=2 edge to the import.
    let entry;
    if (isMemberCall) {
      const receiver = cs.importedNames?.[localName];
      if (receiver && (receiver.imported === '*' || receiver.imported === 'default')) {
        entry = receiver;
      }
    } else {
      entry = cs.importedNames?.[localName];
    }
    if (entry) {
      const lookupName = (entry.imported === '*' || entry.imported === 'default')
        ? bareName  // namespace member calls (`ns.foo()` with bareName='foo')
        : entry.imported;
      const imported = byFileAndName.get(`${entry.path}::${lookupName}`) ?? [];
      if (imported.length > 0) {
        for (const target of imported) {
          edges.push(edge(callerNode.id, target.id, cs.line, 2));
        }
        continue;
      }
    }

    // Step 1: intra-file. Single match → confidence=1. Multiple matches
    // (e.g., two methods named `shared` in classes A and B sharing the same
    // file) → ambiguous, emit confidence=0 for each — the resolver cannot
    // pick without type information.
    const intra = byFileAndName.get(`${cs.callerFile}::${bareName}`) ?? [];
    if (intra.length === 1) {
      edges.push(edge(callerNode.id, intra[0].id, cs.line, 1));
      continue;
    }
    if (intra.length > 1) {
      for (const target of intra) {
        edges.push(edge(callerNode.id, target.id, cs.line, 0));
      }
      continue;
    }

    // Step 3: ambiguous same-name fallback across the entire graph.
    const ambiguous = byName.get(bareName) ?? [];
    for (const target of ambiguous) {
      if (target.id === callerNode.id) continue;
      edges.push(edge(callerNode.id, target.id, cs.line, 0));
    }
  }
  return edges;
}

function edge(source, target, line, confidence) {
  return { source, target, kind: 'calls', line, confidence };
}

function pushMap(map, key, value) {
  const arr = map.get(key);
  if (arr) arr.push(value);
  else map.set(key, [value]);
}
