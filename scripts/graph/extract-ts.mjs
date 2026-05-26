// scripts/graph/extract-ts.mjs
import { runRule } from './astgrep.mjs';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import url from 'node:url';

const RULE_DIR = path.join(path.dirname(url.fileURLToPath(import.meta.url)), 'rules');
const RULES = {
  function: path.join(RULE_DIR, 'ts-function.yml'),
  arrow: path.join(RULE_DIR, 'ts-arrow.yml'),
  class: path.join(RULE_DIR, 'ts-class.yml'),
  method: path.join(RULE_DIR, 'ts-method.yml'),
  call: path.join(RULE_DIR, 'ts-call.yml'),
  import: path.join(RULE_DIR, 'ts-import.yml'),
};

export function spanSha8(text) {
  return crypto.createHash('sha256').update(text).digest('hex').slice(0, 8);
}

function nameFromFunctionText(text) {
  const m = text.match(/^(?:async\s+)?function\s+\*?\s*([A-Za-z_$][\w$]*)/);
  return m ? m[1] : null;
}

function nameFromMethodText(text) {
  const MODIFIERS = new Set(['async', 'static', 'get', 'set', 'public', 'private', 'protected', 'readonly', '*']);
  const tokens = text.split(/[\s(*]+/).filter(Boolean);
  for (const t of tokens) {
    if (!MODIFIERS.has(t)) return t.replace(/^\*/, '');
  }
  return null;
}

function nameFromClassText(text) {
  const m = text.match(/^class\s+([A-Za-z_$][\w$]*)/);
  return m ? m[1] : null;
}

function nameFromArrowDeclarator(text) {
  const m = text.match(/^([A-Za-z_$][\w$]*)/);
  return m ? m[1] : null;
}

function firstLineOf(text) {
  return text.split('\n', 1)[0].slice(0, 200);
}

async function scanPathFor({ absPath, source, language }) {
  if (language !== 'javascript') return { scanPath: absPath, cleanup: async () => {} };
  const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'sspower-graph-'));
  const scanPath = path.join(tmpDir, `${path.basename(absPath)}.ts`);
  await fs.writeFile(scanPath, source, 'utf8');
  return {
    scanPath,
    cleanup: async () => {
      await fs.unlink(scanPath).catch(() => {});
      await fs.rmdir(tmpDir).catch(() => {});
    },
  };
}

export async function extractFile({ absPath, source, language = 'typescript' }) {
  const { scanPath, cleanup } = await scanPathFor({ absPath, source, language });
  let fns;
  let arrows;
  let classes;
  let methods;
  let calls;
  let imps;
  try {
    [fns, arrows, classes, methods, calls, imps] = await Promise.all([
      runRule(RULES.function, scanPath),
      runRule(RULES.arrow, scanPath),
      runRule(RULES.class, scanPath),
      runRule(RULES.method, scanPath),
      runRule(RULES.call, scanPath),
      runRule(RULES.import, scanPath),
    ]);
  } finally {
    await cleanup();
  }

  const nodes = [];

  for (const m of fns) {
    const name = nameFromFunctionText(m.text);
    if (!name) continue;
    nodes.push({
      kind: 'function', name, qualifiedName: name,
      startLine: m.startLine, endLine: m.endLine,
      byteStart: m.byteStart, byteEnd: m.byteEnd,
      signature: firstLineOf(m.text),
      spanSha8: spanSha8(m.text),
      language,
    });
  }

  for (const m of arrows) {
    const name = nameFromArrowDeclarator(m.text);
    if (!name) continue;
    nodes.push({
      kind: 'function', name, qualifiedName: name,
      startLine: m.startLine, endLine: m.endLine,
      byteStart: m.byteStart, byteEnd: m.byteEnd,
      signature: firstLineOf(m.text),
      spanSha8: spanSha8(m.text),
      language,
    });
  }

  const classRanges = [];
  for (const m of classes) {
    const name = nameFromClassText(m.text);
    if (!name) continue;
    classRanges.push({ name, byteStart: m.byteStart, byteEnd: m.byteEnd });
    nodes.push({
      kind: 'class', name, qualifiedName: name,
      startLine: m.startLine, endLine: m.endLine,
      byteStart: m.byteStart, byteEnd: m.byteEnd,
      signature: firstLineOf(m.text),
      spanSha8: spanSha8(m.text),
      language,
    });
  }

  for (const m of methods) {
    const name = nameFromMethodText(m.text);
    if (!name) continue;
    const enclosing = classRanges
      .filter(c => c.byteStart <= m.byteStart && c.byteEnd >= m.byteEnd)
      .sort((a, b) => (b.byteEnd - b.byteStart) - (a.byteEnd - a.byteStart))
      .pop();
    const qualifiedName = enclosing ? `${enclosing.name}.${name}` : name;
    nodes.push({
      kind: 'method', name, qualifiedName,
      startLine: m.startLine, endLine: m.endLine,
      byteStart: m.byteStart, byteEnd: m.byteEnd,
      signature: firstLineOf(m.text),
      spanSha8: spanSha8(m.text),
      language,
    });
  }

  const imports = imps.map(m => {
    const specMatch = m.text.match(/from\s+['"]([^'"]+)['"]/) || m.text.match(/import\s+['"]([^'"]+)['"]/);
    const moduleSpec = specMatch ? specMatch[1] : null;
    const names = [];
    const braced = m.text.match(/\{([^}]*)\}/);
    if (braced) {
      for (const part of braced[1].split(',')) {
        const t = part.trim();
        if (!t) continue;
        const asMatch = t.match(/^(\S+)\s+as\s+(\S+)$/);
        names.push(asMatch ? { imported: asMatch[1], local: asMatch[2] } : { imported: t, local: t });
      }
    }
    const defMatch = m.text.match(/^import\s+([A-Za-z_$][\w$]*)\s*[,{]/)
      || m.text.match(/^import\s+([A-Za-z_$][\w$]*)\s+from/);
    if (defMatch) names.push({ imported: 'default', local: defMatch[1] });
    const nsMatch = m.text.match(/import\s+\*\s+as\s+([A-Za-z_$][\w$]*)/);
    if (nsMatch) names.push({ imported: '*', local: nsMatch[1] });
    return { moduleSpec, names, line: m.startLine };
  }).filter(i => i.moduleSpec);

  const callableRanges = nodes
    .filter(n => n.kind === 'function' || n.kind === 'method')
    .map(n => ({ qualifiedName: n.qualifiedName, byteStart: n.byteStart, byteEnd: n.byteEnd }));

  // ts-call.yml is a plain `kind: call_expression` rule with NO metavariable
  // captures, so derive the callee identifier from the matched text. Handles:
  //   foo(...)                  -> 'foo'
  //   ns.helper(...)            -> 'ns.helper'   (member call; resolver splits)
  //   this.method(...)          -> 'this.method' (treated like member; bareName='method')
  //   await foo(...)            -> 'foo' (matched node text starts at call_expression, not the await)
  //   new Foo(...)              -> 'Foo' (constructor; tracked as a call edge)
  //   foo?.bar(...)             -> 'foo?.bar' (optional chaining preserved; bareName='bar')
  // Anything that doesn't start with an identifier (computed member, IIFE,
  // template call) is dropped -- P1 known limit, documented in section 5.
  const IDENT_PREFIX = /^([A-Za-z_$][\w$]*(?:\??\.[A-Za-z_$][\w$]*)*)/;
  const callSites = [];
  for (const c of calls) {
    const callMatch = c.text.match(IDENT_PREFIX);
    if (!callMatch) continue;
    const effectiveIdent = callMatch[1];
    const enclosing = callableRanges
      .filter(r => r.byteStart <= c.byteStart && r.byteEnd >= c.byteEnd)
      .sort((a, b) => (b.byteEnd - b.byteStart) - (a.byteEnd - a.byteStart))
      .pop();
    if (!enclosing) continue; // top-level call -> no source node (P1: skip)
    callSites.push({
      callerQualifiedName: enclosing.qualifiedName,
      calleeIdent: effectiveIdent,
      line: c.startLine,
    });
  }

  return { nodes, imports, callSites };
}
