// scripts/graph/resolve.mjs
import fs from 'node:fs';
import path from 'node:path';

const TS_EXTS = ['.ts', '.tsx', '.mts', '.cts'];
const JS_EXTS = ['.js', '.jsx', '.mjs', '.cjs'];
const ALL_EXTS = [...TS_EXTS, ...JS_EXTS];

export function resolveModule(importerAbs, moduleSpec, language) {
  switch (language) {
    case 'python': return resolveModulePy(importerAbs, moduleSpec);
    case 'go':     return resolveModuleGo(importerAbs, moduleSpec);
    case 'rust':   return resolveModuleRs(importerAbs, moduleSpec);
    case 'typescript':
    case 'javascript':
    default:       return resolveModuleTs(importerAbs, moduleSpec);
  }
}

function resolveModuleTs(importerAbs, moduleSpec) {
  if (!moduleSpec.startsWith('./') && !moduleSpec.startsWith('../') && !moduleSpec.startsWith('/')) {
    return null;
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

// Per-language module resolvers — real bodies land with the extractor
// for each language (Task 9 = Python, Task 10 = Go, Task 11 = Rust).
function resolveModulePy(importerAbs, moduleSpec) {
  const importerDir = path.dirname(importerAbs);

  // Relative dots: ".x", "..pkg.mod", "."
  if (moduleSpec.startsWith('.')) {
    const dots = moduleSpec.match(/^\.+/)[0].length;
    let base = importerDir;
    for (let i = 1; i < dots; i++) base = path.dirname(base);
    const rest = moduleSpec.slice(dots).replace(/\./g, '/');
    const candidate = rest ? path.join(base, rest) : base;
    const py = candidate + '.py';
    const initF = path.join(candidate, '__init__.py');
    if (fs.existsSync(py) && fs.statSync(py).isFile()) return py;
    if (fs.existsSync(initF) && fs.statSync(initF).isFile()) return initF;
    return null;
  }

  // Absolute (top-level pkg). Search the project root for a matching path.
  // Walk up from importerDir looking for the FIRST ancestor that contains a
  // matching <spec>.py OR <spec>/__init__.py. This matches CPython's
  // sys.path-first-hit behavior for in-repo packages without simulating sys.path.
  const rel = moduleSpec.replace(/\./g, '/');
  let dir = importerDir;
  for (let i = 0; i < 10; i++) {
    const py = path.join(dir, rel + '.py');
    const initF = path.join(dir, rel, '__init__.py');
    if (fs.existsSync(py) && fs.statSync(py).isFile()) return py;
    if (fs.existsSync(initF) && fs.statSync(initF).isFile()) return initF;
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return null;
}
function resolveModuleGo(importerAbs, moduleSpec) {
  // Walk up from importerDir looking for go.mod; read its `module X` line.
  let dir = path.dirname(importerAbs);
  let modRoot = null, modPath = null;
  for (let i = 0; i < 10; i++) {
    const gomod = path.join(dir, 'go.mod');
    if (fs.existsSync(gomod)) {
      const m = fs.readFileSync(gomod, 'utf8').match(/^module\s+(\S+)/m);
      if (m) { modRoot = dir; modPath = m[1]; }
      break;
    }
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  if (!modRoot || !modPath) return null;
  // moduleSpec must start with modPath to be local; external pkgs return null.
  if (moduleSpec === modPath) return modRoot;
  if (!moduleSpec.startsWith(modPath + '/')) return null;
  const rel = moduleSpec.slice(modPath.length + 1);
  const dirCandidate = path.join(modRoot, rel);
  if (!fs.existsSync(dirCandidate) || !fs.statSync(dirCandidate).isDirectory()) return null;
  // Return the first .go file in the dir (extractor processes each file
  // separately; the import resolves to the package dir but we need a file
  // path. Pick lexicographically smallest .go file in the dir).
  const files = fs.readdirSync(dirCandidate).filter(f => f.endsWith('.go')).sort();
  if (files.length === 0) return null;
  return path.join(dirCandidate, files[0]);
}
function resolveModuleRs(_importerAbs, _moduleSpec) { return null; }

export function resolveEdges({ nodes, callSites }) {
  const byQualified = new Map();
  const byName = new Map();
  const byFileAndName = new Map();
  const byFileAndQualified = new Map();  // for import-resolution: match top-level
                                          // exports (qname == name) but NOT class
                                          // methods that happen to share a name.
  for (const n of nodes) {
    pushMap(byQualified, n.qualifiedName, n);
    pushMap(byName, n.name, n);
    pushMap(byFileAndName, `${n.filePath}::${n.name}`, n);
    pushMap(byFileAndQualified, `${n.filePath}::${n.qualifiedName}`, n);
  }

  const edges = [];
  for (const cs of callSites) {
    const callerNode = byQualified.get(cs.callerQualifiedName)?.find(n => n.filePath === cs.callerFile);
    if (!callerNode) continue;
    const parts = cs.calleeIdent.split('.');
    const localName = parts[0].replace(/\?$/, '');  // strip optional chaining on receiver
    const bareName = parts.at(-1);
    const isMemberCall = parts.length > 1;

    // Resolution order (JS scoping):
    //   Direct call `foo()`:
    //     1. Same-file local definition of `foo` (could be a nested function
    //        shadowing an outer import) -> wins over import.
    //     2. Imported binding `foo` -> conf=2.
    //     3. Cross-graph same-name fallback -> conf=0.
    //   Member call `foo.bar()`:
    //     1. Namespace/default import on `foo` -> resolve `bar` in that path,
    //        conf=2. NEVER use intra-file by bareName for member calls
    //        (`foo.bar` is NOT method `bar` defined in the same file).
    //     2. Cross-graph same-name fallback on `bar` -> conf=0.

    if (!isMemberCall) {
      // Step 1: intra-file lookup wins. Bare direct calls only target
      // LEXICAL/TOP-LEVEL symbols (qualifiedName === name) — a class method
      // `C.helper` MUST NOT capture a bare `helper()` call just because
      // they share a bare name. Class methods are reached via member-call
      // path (`this.helper()`, `obj.helper()`) or — for now — via the
      // cross-graph ambiguous fallback when the call site is itself a
      // method body referring to a sibling method.
      const intraAll = byFileAndName.get(`${cs.callerFile}::${bareName}`) ?? [];
      const intra = intraAll.filter(n => n.qualifiedName === n.name);
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
    }

    // Step 2: imports.
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
      // Match by qualified_name so `import { helper }` resolves to the
      // top-level `helper` export, NOT every class method named `helper`.
      const imported = byFileAndQualified.get(`${entry.path}::${lookupName}`) ?? [];
      if (imported.length > 0) {
        for (const target of imported) {
          edges.push(edge(callerNode.id, target.id, cs.line, 2));
        }
        continue;
      }
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
