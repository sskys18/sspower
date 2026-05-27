// scripts/graph/extract-go.mjs
import { runRulesBatch } from './astgrep.mjs';
import crypto from 'node:crypto';
import fsSync from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const RULE_DIR = path.join(path.dirname(url.fileURLToPath(import.meta.url)), 'rules');
const RULE_FILES = ['go-function.yml', 'go-method.yml', 'go-call.yml', 'go-import.yml'];
const RULES_INLINE = RULE_FILES
  .map(f => fsSync.readFileSync(path.join(RULE_DIR, f), 'utf8').trim())
  .join('\n---\n');
const RULE_ID = { function: 'go-function', method: 'go-method', call: 'go-call', import: 'go-import' };

function spanSha8(text) {
  return crypto.createHash('sha256').update(text).digest('hex').slice(0, 8);
}

function nameFromFuncText(text) {
  const m = text.match(/^func\s+([A-Z][A-Za-z0-9_]*|[a-z][A-Za-z0-9_]*)/);
  return m?.[1] ?? null;
}

function nameFromMethodText(text) {
  const m = text.match(/^func\s+\(\s*\w+\s+\*?(\w+)\s*\)\s+([A-Za-z_]\w*)/);
  return m ? `${m[1]}.${m[2]}` : null;
}

function nameFromCallText(text) {
  const IDENT_PREFIX = /^([A-Za-z_$][\w$]*(?:\??\.[A-Za-z_$][\w$]*)*)/;
  const m = text.match(IDENT_PREFIX);
  return m ? m[1] : null;
}

function firstLine(text) {
  return text.split('\n', 1)[0].slice(0, 200);
}

function parseImports(text, line) {
  const imports = [];
  const pushSpec = (moduleSpec) => {
    const local = moduleSpec.split('/').at(-1);
    imports.push({ moduleSpec, names: [{ imported: '*', local }], line });
  };

  const single = text.match(/^import\s+"([^"]+)"/);
  if (single) {
    pushSpec(single[1]);
    return imports;
  }

  const block = text.match(/^import\s*\(([\s\S]*)\)/);
  if (block) {
    for (const m of block[1].matchAll(/"([^"]+)"/g)) pushSpec(m[1]);
  }
  return imports;
}

export async function extractFile({ absPath, source: _source, language = 'go' }) {
  const buckets = await runRulesBatch(RULES_INLINE, absPath);
  const fns     = buckets.get(RULE_ID.function) ?? [];
  const methods = buckets.get(RULE_ID.method)   ?? [];
  const calls   = buckets.get(RULE_ID.call)     ?? [];
  const imps    = buckets.get(RULE_ID.import)   ?? [];

  const nodes = [];

  for (const m of fns) {
    const name = nameFromFuncText(m.text);
    if (!name) continue;
    nodes.push({
      kind: 'function', name, qualifiedName: name,
      startLine: m.startLine, endLine: m.endLine,
      byteStart: m.byteStart, byteEnd: m.byteEnd,
      signature: firstLine(m.text), spanSha8: spanSha8(m.text), language,
    });
  }

  for (const m of methods) {
    const qualifiedName = nameFromMethodText(m.text);
    if (!qualifiedName) continue;
    const name = qualifiedName.split('.').at(-1);
    nodes.push({
      kind: 'method', name, qualifiedName,
      startLine: m.startLine, endLine: m.endLine,
      byteStart: m.byteStart, byteEnd: m.byteEnd,
      signature: firstLine(m.text), spanSha8: spanSha8(m.text), language,
    });
  }

  const imports = imps.flatMap(m => parseImports(m.text, m.startLine));

  const callableRanges = nodes
    .filter(n => n.kind === 'function' || n.kind === 'method')
    .map(n => ({ qualifiedName: n.qualifiedName, byteStart: n.byteStart, byteEnd: n.byteEnd }));

  const callSites = [];
  for (const c of calls) {
    const calleeIdent = nameFromCallText(c.text);
    if (!calleeIdent) continue;
    const enclosing = callableRanges
      .filter(r => r.byteStart <= c.byteStart && r.byteEnd >= c.byteEnd)
      .sort((a, b) => (b.byteEnd - b.byteStart) - (a.byteEnd - a.byteStart))
      .pop();
    if (!enclosing) continue;
    callSites.push({ callerQualifiedName: enclosing.qualifiedName, calleeIdent, line: c.startLine });
  }

  return { nodes, imports, callSites };
}
