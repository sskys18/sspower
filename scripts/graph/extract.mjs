// scripts/graph/extract.mjs
// Per-language extractor dispatcher. Used by both build.mjs and refresh.mjs.
// Each language module must export `extractFile({ absPath, source, language })`
// returning the same shape: `{ nodes, imports, callSites }`.
//
// Python/Go/Rust modules are lazy-imported and may not exist yet (they land
// in Tasks 9/10/11). When a module is missing the dispatcher returns a
// no-op extractor that emits zero nodes — the walker can include those file
// extensions safely before the extractor lands, without exploding the
// build's >25% extraction-failure abort.
import * as ts from './extract-ts.mjs';

async function loadOrNoop(specifier) {
  try {
    return await import(specifier);
  } catch (e) {
    if (e?.code === 'ERR_MODULE_NOT_FOUND') {
      return { extractFile: async () => ({ nodes: [], imports: [], callSites: [] }) };
    }
    throw e;
  }
}

export async function extractorFor(language) {
  switch (language) {
    case 'typescript':
    case 'javascript':
      return { extractFile: ts.extractFile };
    case 'python': return await loadOrNoop('./extract-py.mjs');
    case 'go':     return await loadOrNoop('./extract-go.mjs');
    case 'rust':   return await loadOrNoop('./extract-rs.mjs');
    default:
      throw new Error(`no extractor for language: ${language}`);
  }
}
