// scripts/graph/extract-ts.mjs
import { runRulesBatch } from './astgrep.mjs';
import crypto from 'node:crypto';
import fsSync from 'node:fs';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import url from 'node:url';

const RULE_DIR = path.join(path.dirname(url.fileURLToPath(import.meta.url)), 'rules');
const RULE_FILES = [
  'ts-function.yml',
  'ts-arrow.yml',
  'ts-class.yml',
  'ts-method.yml',
  'ts-call.yml',
  'ts-import.yml',
  'ts-express-route.yml',
  'ts-express-router.yml',
  'ts-express-mount.yml',
];
// Concat all rule docs into one `---`-separated inline-rules payload at
// module init. ast-grep tags each match with its rule `id`, so the call
// site recovers per-rule buckets.
const RULES_INLINE = RULE_FILES
  .map(f => fsSync.readFileSync(path.join(RULE_DIR, f), 'utf8').trim())
  .join('\n---\n');
const RULE_ID = {
  function:      'ts-function',
  arrow:         'ts-arrow',
  class:         'ts-class',
  method:        'ts-method',
  call:          'ts-call',
  import:        'ts-import',
  expressRoute:  'ts-express-route',
  expressRouter: 'ts-express-router',
  expressMount:  'ts-express-mount',
};

// Parse an Express route call's match text into { method, path, handlerName }.
// match.text examples:
//   "app.get('/health', handleHealth)"
//   "r.post(\"/users\", createUser)"
//   "app.delete('/items/:id', handleDelete)"
//   "app.post('/items', (req, res) => { ... })"          -> handler=null
//   "router.route('/x').get(handlerA, handlerB)"         -> path='/x'
// Returns null when the match text doesn't fit (defensive — surfaces as
// dedupe miss, not extractor crash).
const ROUTE_METHODS = new Set(['get', 'post', 'put', 'delete', 'patch', 'all']);
function parseExpressRoute(text) {
  // Try chained `.route(path).METHOD(...)` first — outer call is METHOD,
  // path is the arg to the inner `.route(...)`.
  const chained = text.match(/\.route\(\s*(['"`])([^'"`]*)\1\s*\)\s*\.([a-z]+)\s*\(\s*([\s\S]*)\)\s*$/);
  if (chained) {
    const method = chained[3].toLowerCase();
    if (!ROUTE_METHODS.has(method)) return null;
    return {
      method: method.toUpperCase(),
      path: chained[2],
      handlerName: firstIdentArg(chained[4]),
    };
  }
  // Direct `<ident>.METHOD(path, handler...)` form.
  const direct = text.match(/^([\s\S]*?)\.([a-z]+)\s*\(\s*(['"`])([^'"`]*)\3\s*(?:,\s*([\s\S]*))?\)\s*$/);
  if (!direct) return null;
  const method = direct[2].toLowerCase();
  if (!ROUTE_METHODS.has(method)) return null;
  return {
    method: method.toUpperCase(),
    path: direct[4],
    handlerName: direct[5] ? firstIdentArg(direct[5]) : null,
  };
}

// Pull the first argument identifier from a comma-separated handler list.
// Returns null for inline arrows / function expressions / non-identifiers.
function firstIdentArg(text) {
  const trimmed = text.trim();
  // First arg: split at top-level comma. Cheap approximation: first
  // identifier-only token. Inline arrow `(req,res)=>...` will not match.
  const m = trimmed.match(/^([A-Za-z_$][\w$]*)\s*(?:,|$)/);
  return m ? m[1] : null;
}

// Parse a mount `app.use('/prefix', router)` match into { prefix, routerName }.
function parseExpressMount(text) {
  const m = text.match(/\.use\s*\(\s*(['"`])([^'"`]*)\1\s*,\s*([A-Za-z_$][\w$]*)\s*\)\s*$/);
  if (!m) return null;
  return { prefix: m[2], routerName: m[3] };
}

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
  // Preserve JSX-ness: `.jsx` → temp `.tsx` so JSX syntax still parses under
  // the TypeScript grammar. Plain `.js`/`.mjs`/`.cjs` → temp `.ts`.
  const ext = path.extname(absPath).toLowerCase();
  const isJsx = ext === '.jsx';
  const tmpExt = isJsx ? '.tsx' : '.ts';
  const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'sspower-graph-'));
  const scanPath = path.join(tmpDir, `${path.basename(absPath)}${tmpExt}`);
  await fs.writeFile(scanPath, source, 'utf8');
  return {
    scanPath,
    cleanup: async () => {
      await fs.unlink(scanPath).catch(() => {});
      await fs.rmdir(tmpDir).catch(() => {});
    },
  };
}

export async function extractFile({ absPath, source, language = 'typescript', rootDir }) {
  const { scanPath, cleanup } = await scanPathFor({ absPath, source, language });
  let buckets;
  try {
    buckets = await runRulesBatch(RULES_INLINE, scanPath);
  } finally {
    await cleanup();
  }
  const fns     = buckets.get(RULE_ID.function) ?? [];
  const arrows  = buckets.get(RULE_ID.arrow)    ?? [];
  const classes = buckets.get(RULE_ID.class)    ?? [];
  const methods = buckets.get(RULE_ID.method)   ?? [];
  const calls   = buckets.get(RULE_ID.call)     ?? [];
  const imps    = buckets.get(RULE_ID.import)   ?? [];
  const routesA = buckets.get(RULE_ID.expressRoute)  ?? [];
  const routesB = buckets.get(RULE_ID.expressRouter) ?? [];
  const mounts  = buckets.get(RULE_ID.expressMount)  ?? [];

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

  // ---- Express routes ----------------------------------------------------
  // ts-express-route and ts-express-router patterns overlap on the direct
  // `<ident>.METHOD(path, ...)` form (one is `$APP.METHOD`, the other
  // `$ROUTER.METHOD` -- both match any identifier receiver). Collect both
  // buckets, dedupe by (file, start_line, end_line, METHOD, PATH_LITERAL)
  // BEFORE emitting -- otherwise every Express call produces 2 route nodes.
  // Last-write-wins on the tuple key (rule order is stable).
  const routeSeen = new Map();
  const routeHandlerRequests = [];
  for (const m of [...routesA, ...routesB]) {
    const parsed = parseExpressRoute(m.text);
    if (!parsed) continue;
    const dedupeKey = `${absPath}:${m.startLine}:${m.endLine}:${parsed.method}:${parsed.path}`;
    if (routeSeen.has(dedupeKey)) continue;
    const name = `${parsed.method} ${parsed.path}`;
    const relPath = rootDir ? path.relative(rootDir, absPath) : absPath;
    const qualifiedName = `${relPath}::${name}`;
    const handlerLabel = parsed.handlerName ?? 'anonymous';
    const signature = `${parsed.method} ${parsed.path} ${handlerLabel}`;
    const node = {
      kind: 'route', name, qualifiedName,
      startLine: m.startLine, endLine: m.endLine,
      byteStart: m.byteStart, byteEnd: m.byteEnd,
      signature,
      spanSha8: spanSha8(m.text),
      language,
    };
    routeSeen.set(dedupeKey, node);
    nodes.push(node);
    // Named handler -> routes-kind edge request. Inline arrows leave the
    // route node alone; the inline body is already captured in span_sha8.
    if (parsed.handlerName) {
      routeHandlerRequests.push({
        routeQualifiedName: qualifiedName,
        routeSpanSha8: node.spanSha8,
        routeFile: absPath,
        handlerName: parsed.handlerName,
        line: m.startLine,
      });
    }
  }

  // Mount calls (`app.use('/prefix', router)`) are parsed for the cross-file
  // expansion pass in build.mjs (P5+). P4 emits bare router routes
  // (`GET /users`, not `GET /api/v1/users`); the mounts list is returned
  // so a future expansion pass can join prefix + imported router routes
  // without re-extracting. No node/edge emitted from mount alone in P4.
  const routeMounts = [];
  for (const m of mounts) {
    const parsed = parseExpressMount(m.text);
    if (!parsed) continue;
    routeMounts.push({
      prefix: parsed.prefix,
      routerLocalName: parsed.routerName,
      line: m.startLine,
    });
  }

  return { nodes, imports, callSites, routeHandlerRequests, routeMounts };
}
