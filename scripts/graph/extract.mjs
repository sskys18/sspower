// scripts/graph/extract.mjs
// Per-language extractor dispatcher. Used by both build.mjs (via Task 8)
// and refresh.mjs (Task 4). Each language module must export
// `extractFile({ absPath, source, language })` returning the same shape:
// `{ nodes, imports, callSites }`.
import * as ts from './extract-ts.mjs';

export async function extractorFor(language) {
  switch (language) {
    case 'typescript':
    case 'javascript':
      return { extractFile: ts.extractFile };
    case 'python': {
      const py = await import('./extract-py.mjs');
      return { extractFile: py.extractFile };
    }
    case 'go': {
      const go = await import('./extract-go.mjs');
      return { extractFile: go.extractFile };
    }
    case 'rust': {
      const rs = await import('./extract-rs.mjs');
      return { extractFile: rs.extractFile };
    }
    default:
      throw new Error(`no extractor for language: ${language}`);
  }
}
