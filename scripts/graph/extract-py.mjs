// scripts/graph/extract-py.mjs
import { runRulesBatch } from './astgrep.mjs';
import crypto from 'node:crypto';
import fsSync from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const RULE_DIR = path.join(path.dirname(url.fileURLToPath(import.meta.url)), 'rules');
const RULE_FILES = ['py-function.yml', 'py-class.yml', 'py-method.yml', 'py-call.yml', 'py-import.yml'];
const RULES_INLINE = RULE_FILES
  .map(f => fsSync.readFileSync(path.join(RULE_DIR, f), 'utf8').trim())
  .join('\n---\n');
const RULE_ID = {
  function: 'py-function',
  class:    'py-class',
  method:   'py-method',
  call:     'py-call',
  import:   'py-import',
};

function spanSha8(text) {
  return crypto.createHash('sha256').update(text).digest('hex').slice(0, 8);
}

function nameFromDefText(text) {
  const m = text.match(/^(?:async\s+)?def\s+([A-Za-z_]\w*)/);
  return m?.[1] ?? null;
}

function nameFromClassText(text) {
  const m = text.match(/^class\s+([A-Za-z_]\w*)/);
  return m?.[1] ?? null;
}

function firstLine(text) {
  return text.split('\n', 1)[0].slice(0, 200);
}

function moduleNameFromPath(absPath) {
  return path.basename(absPath, path.extname(absPath));
}

function moduleQualifiedNameFromPath(absPath) {
  // Graph builds run from the project root, so cwd-relative paths are stable module qualified names.
  return path.relative(process.cwd(), absPath).replace(/\.py$/, '').split(path.sep).join('/');
}

export async function extractFile({ absPath, source, language = 'python' }) {
  const buckets = await runRulesBatch(RULES_INLINE, absPath);
  const fns     = buckets.get(RULE_ID.function) ?? [];
  const classes = buckets.get(RULE_ID.class)    ?? [];
  const methods = buckets.get(RULE_ID.method)   ?? [];
  const calls   = buckets.get(RULE_ID.call)     ?? [];
  const imps    = buckets.get(RULE_ID.import)   ?? [];

  const classRanges = [];
  const nodes = [];

  for (const m of classes) {
    const name = nameFromClassText(m.text);
    if (!name) continue;
    classRanges.push({ name, byteStart: m.byteStart, byteEnd: m.byteEnd });
    nodes.push({
      kind: 'class', name, qualifiedName: name,
      startLine: m.startLine, endLine: m.endLine,
      byteStart: m.byteStart, byteEnd: m.byteEnd,
      signature: firstLine(m.text), spanSha8: spanSha8(m.text), language,
    });
  }

  const methodSet = new Set();
  for (const m of methods) {
    const name = nameFromDefText(m.text);
    if (!name) continue;
    const enclosing = classRanges
      .filter(c => c.byteStart <= m.byteStart && c.byteEnd >= m.byteEnd)
      .sort((a, b) => (b.byteEnd - b.byteStart) - (a.byteEnd - a.byteStart))
      .pop();
    const qualifiedName = enclosing ? `${enclosing.name}.${name}` : name;
    methodSet.add(`${m.byteStart}:${m.byteEnd}`);
    nodes.push({
      kind: 'method', name, qualifiedName,
      startLine: m.startLine, endLine: m.endLine,
      byteStart: m.byteStart, byteEnd: m.byteEnd,
      signature: firstLine(m.text), spanSha8: spanSha8(m.text), language,
    });
  }

  for (const m of fns) {
    if (methodSet.has(`${m.byteStart}:${m.byteEnd}`)) continue;
    const name = nameFromDefText(m.text);
    if (!name) continue;
    nodes.push({
      kind: 'function', name, qualifiedName: name,
      startLine: m.startLine, endLine: m.endLine,
      byteStart: m.byteStart, byteEnd: m.byteEnd,
      signature: firstLine(m.text), spanSha8: spanSha8(m.text), language,
    });
  }

  const imports = imps.map(m => {
    const text = m.text;
    const out = { moduleSpec: null, names: [], line: m.startLine };
    const fromMatch = text.match(/^from\s+([.\w]+)\s+import\s+(.+?)(?:$|\n)/s);
    if (fromMatch) {
      out.moduleSpec = fromMatch[1];
      const names = fromMatch[2].replace(/[()\\]/g, ' ');
      for (const part of names.split(',')) {
        const piece = part.trim().replace(/\s*#.*$/, '');
        if (!piece) continue;
        const asMatch = piece.match(/^([A-Za-z_]\w*|\*)\s+as\s+([A-Za-z_]\w*)$/);
        if (asMatch) out.names.push({ imported: asMatch[1], local: asMatch[2] });
        else if (piece === '*') out.names.push({ imported: '*', local: '*' });
        else out.names.push({ imported: piece, local: piece });
      }
      return out;
    }
    const importMatch = text.match(/^import\s+([.\w]+)(?:\s+as\s+([A-Za-z_]\w*))?/);
    if (importMatch) {
      out.moduleSpec = importMatch[1];
      const local = importMatch[2] ?? importMatch[1].split('.')[0];
      out.names.push({ imported: '*', local });
      return out;
    }
    return out;
  }).filter(i => i.moduleSpec);

  let callableRanges = nodes
    .filter(n => n.kind === 'function' || n.kind === 'method')
    .map(n => ({ qualifiedName: n.qualifiedName, byteStart: n.byteStart, byteEnd: n.byteEnd }));

  const IDENT_PREFIX = /^([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)/;
  const callSites = [];
  for (const c of calls) {
    const match = c.text.match(IDENT_PREFIX);
    if (!match) continue;
    let enclosing = callableRanges
      .filter(r => r.byteStart <= c.byteStart && r.byteEnd >= c.byteEnd)
      .sort((a, b) => (b.byteEnd - b.byteStart) - (a.byteEnd - a.byteStart))
      .pop();
    if (!enclosing) {
      const name = moduleNameFromPath(absPath);
      const qualifiedName = moduleQualifiedNameFromPath(absPath);
      const byteEnd = Buffer.byteLength(source, 'utf8');
      const moduleNode = {
        kind: 'module', name, qualifiedName,
        startLine: 1, endLine: source.split('\n').length,
        byteStart: 0, byteEnd,
        signature: name, spanSha8: spanSha8(source), language,
      };
      nodes.push(moduleNode);
      enclosing = { qualifiedName, byteStart: 0, byteEnd };
      callableRanges = [...callableRanges, enclosing];
    }
    if (!enclosing) continue;
    callSites.push({ callerQualifiedName: enclosing.qualifiedName, calleeIdent: match[1], line: c.startLine });
  }

  return { nodes, imports, callSites };
}
