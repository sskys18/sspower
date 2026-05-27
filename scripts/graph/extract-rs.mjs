// scripts/graph/extract-rs.mjs
import { runRulesBatch } from './astgrep.mjs';
import crypto from 'node:crypto';
import fsSync from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const RULE_DIR = path.join(path.dirname(url.fileURLToPath(import.meta.url)), 'rules');
const RULE_FILES = ['rs-function.yml', 'rs-impl.yml', 'rs-method.yml', 'rs-call.yml', 'rs-use.yml'];
const RULES_INLINE = RULE_FILES
  .map(f => fsSync.readFileSync(path.join(RULE_DIR, f), 'utf8').trim())
  .join('\n---\n');
const RULE_ID = {
  function: 'rs-function',
  impl:     'rs-impl',
  method:   'rs-method',
  call:     'rs-call',
  import:   'rs-use',
};

function spanSha8(text) {
  return crypto.createHash('sha256').update(text).digest('hex').slice(0, 8);
}

function nameFromFnText(text) {
  const m = text.match(/^(?:pub\s+(?:\(\s*\w+\s*\)\s+)?)?(?:async\s+)?(?:unsafe\s+)?(?:const\s+)?fn\s+([A-Za-z_]\w*)/);
  return m?.[1] ?? null;
}

function nameFromImplText(text) {
  const m = text.match(/^impl(?:<[^>]*>)?\s+(?:[A-Za-z_]\w*(?:<[^>]*>)?\s+for\s+)?([A-Za-z_]\w*)/);
  return m?.[1] ?? null;
}

function nameFromCallText(text) {
  const macro = text.match(/^([A-Za-z_]\w*)!/);
  if (macro) return macro[1];
  const m = text.match(/^([A-Za-z_]\w*(?:(?:::|\.)[A-Za-z_]\w*)*)/);
  if (!m) return null;
  // Resolver (resolve.mjs:174) splits calleeIdent on `.` to derive
  // bareName / localName. Rust path syntax (`Type::method`) would
  // collapse to a single token and drop the edge. Normalize `::` to
  // `.` so qualified calls reach the resolver's member-call branch.
  return m[1].replace(/::/g, '.');
}

function firstLine(text) {
  return text.split('\n', 1)[0].slice(0, 200);
}

function splitTopLevelComma(text) {
  const parts = [];
  let start = 0;
  let depth = 0;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (ch === '{') depth++;
    else if (ch === '}') depth--;
    else if (ch === ',' && depth === 0) {
      parts.push(text.slice(start, i));
      start = i + 1;
    }
  }
  parts.push(text.slice(start));
  return parts;
}

function parseUseLeaf(text) {
  const asMatch = text.trim().match(/^([A-Za-z_]\w*|\*)\s+as\s+([A-Za-z_]\w*)$/);
  if (asMatch) return { imported: asMatch[1], local: asMatch[2] };
  const leaf = text.trim();
  if (!leaf) return null;
  return { imported: leaf, local: leaf };
}

function parseUse(text, line) {
  const m = text.trim().match(/^use\s+([\s\S]*);$/);
  if (!m) return [];
  const spec = m[1].trim();
  const imports = [];

  const braced = spec.match(/^(.*)::\{([\s\S]*)\}$/);
  if (braced) {
    const moduleSpec = braced[1].trim();
    const names = splitTopLevelComma(braced[2])
      .map(parseUseLeaf)
      .filter(Boolean);
    if (names.length > 0) imports.push({ moduleSpec, names, line });
    return imports;
  }

  if (spec.endsWith('::*')) {
    imports.push({ moduleSpec: spec.slice(0, -3), names: [{ imported: '*', local: '*' }], line });
    return imports;
  }

  const parts = spec.split('::').map(s => s.trim()).filter(Boolean);
  if (parts.length === 0) return imports;
  const leaf = parts.pop();
  const moduleSpec = parts.join('::');
  const parsed = parseUseLeaf(leaf);
  if (moduleSpec && parsed) imports.push({ moduleSpec, names: [parsed], line });
  return imports;
}

export async function extractFile({ absPath, source: _source, language = 'rust' }) {
  const buckets = await runRulesBatch(RULES_INLINE, absPath);
  const fns     = buckets.get(RULE_ID.function) ?? [];
  const impls   = buckets.get(RULE_ID.impl)     ?? [];
  const methods = buckets.get(RULE_ID.method)   ?? [];
  const calls   = buckets.get(RULE_ID.call)     ?? [];
  const imps    = buckets.get(RULE_ID.import)   ?? [];

  const implRanges = [];
  for (const m of impls) {
    const name = nameFromImplText(m.text);
    if (!name) continue;
    implRanges.push({ name, byteStart: m.byteStart, byteEnd: m.byteEnd });
  }

  const methodStarts = new Set(methods.map(m => m.byteStart));
  const nodes = [];

  for (const m of fns) {
    if (methodStarts.has(m.byteStart)) continue;
    const name = nameFromFnText(m.text);
    if (!name) continue;
    nodes.push({
      kind: 'function', name, qualifiedName: name,
      startLine: m.startLine, endLine: m.endLine,
      byteStart: m.byteStart, byteEnd: m.byteEnd,
      signature: firstLine(m.text), spanSha8: spanSha8(m.text), language,
    });
  }

  for (const m of methods) {
    const name = nameFromFnText(m.text);
    if (!name) continue;
    const enclosing = implRanges
      .filter(r => r.byteStart <= m.byteStart && r.byteEnd >= m.byteEnd)
      .sort((a, b) => (b.byteEnd - b.byteStart) - (a.byteEnd - a.byteStart))
      .pop();
    const qualifiedName = enclosing ? `${enclosing.name}.${name}` : name;
    nodes.push({
      kind: 'method', name, qualifiedName,
      startLine: m.startLine, endLine: m.endLine,
      byteStart: m.byteStart, byteEnd: m.byteEnd,
      signature: firstLine(m.text), spanSha8: spanSha8(m.text), language,
    });
  }

  const imports = imps.flatMap(m => parseUse(m.text, m.startLine));

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
