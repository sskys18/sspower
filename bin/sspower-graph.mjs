#!/usr/bin/env node
// sspower-graph CLI + MCP server.
// P0: graph_status MCP tool. P1: build/build-unlocked/callers/callees/node/status CLI verbs.
//
// `build` re-execs through scripts/graph-with-lock.py so the single-lock
// contract (spec D34/D38) brackets the SQLite transaction across the
// cross-language boundary.

// Runtime gate — must run BEFORE any node:sqlite import (Task 1.5).
// Engine floor 22.5: the node:sqlite module auto-loads from 22.5 without
// `--experimental-sqlite`. On 22.0-22.4 the dynamic import fails — surface
// a clean message instead of a stack trace.
{
  const [major, minor] = process.versions.node.split('.').map(Number);
  if (major < 22 || (major === 22 && minor < 5)) {
    console.error(`error: sspower-graph requires Node >=22.5 (node:sqlite stable surface). Current: ${process.versions.node}`);
    process.exit(2);
  }
}

import path from 'node:path';
import url from 'node:url';
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';

// Read version from package.json for MCP server identity (avoid drift between
// the npm package and the MCP banner).
const HERE = path.dirname(url.fileURLToPath(import.meta.url));
const PLUGIN_ROOT = path.resolve(HERE, '..');
const PKG_VERSION = JSON.parse(fs.readFileSync(path.join(PLUGIN_ROOT, 'package.json'), 'utf8')).version;

const argv = process.argv.slice(2);
const cmd = argv[0];

if (cmd === '--print-cwd') {
  process.stdout.write(process.cwd());
  process.exit(0);
}

if (cmd === '--probe-session') {
  const { readSessionState } = await import('../scripts/graph/session-state.mjs');
  const r = readSessionState(process.cwd());
  if (!r.sessionId) {
    process.stderr.write(`degraded source=${r.source}\n`);
    process.exit(2);
  }
  process.stdout.write(r.sessionId);
  process.exit(0);
}

function usage() {
  console.error(`sspower-graph — symbol graph CLI + MCP server

Usage:
  sspower-graph build [--cwd <dir>]
  sspower-graph refresh [--cwd <dir>]
  sspower-graph session-refresh [--max-time <sec>] [--cwd <dir>]
  sspower-graph callers <name> [--limit N] [--disambiguate] [--json] [--cwd <dir>]
  sspower-graph callees <name> [--limit N] [--json] [--cwd <dir>]
  sspower-graph trace <from> <to> [--max-hops N] [--json] [--cwd <dir>]
  sspower-graph impact <file> [--json] [--cwd <dir>]
  sspower-graph context <task> [--json] [--cwd <dir>]
  sspower-graph node <name> [--json] [--cwd <dir>]
  sspower-graph status [--json] [--cwd <dir>]
  sspower-graph serve --mcp
`);
}

function parseOpts(rest) {
  const opts = { cwd: process.cwd(), limit: 50, disambiguate: false, json: false, maxTime: 5, maxHops: 6, window: 50, positional: [] };
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    if (a === '--cwd') opts.cwd = path.resolve(rest[++i]);
    else if (a === '--limit') opts.limit = parseInt(rest[++i], 10);
    else if (a === '--max-time') opts.maxTime = parseInt(rest[++i], 10);
    else if (a === '--max-hops') opts.maxHops = parseInt(rest[++i], 10);
    else if (a === '--window') opts.window = parseInt(rest[++i], 10);
    else if (a === '--disambiguate') opts.disambiguate = true;
    else if (a === '--json') opts.json = true;
    else opts.positional.push(a);
  }
  return opts;
}

function graphDirFor(cwd) {
  return path.join(cwd, '.claude', 'graph');
}

async function withDb(graphDir, fn) {
  const { openDb, initSchema } = await import(path.join(PLUGIN_ROOT, 'scripts/graph/db.mjs'));
  const dbPath = path.join(graphDir, 'index.sqlite');
  if (!fs.existsSync(dbPath)) {
    console.error(`error: no graph index at ${dbPath}. Run \`sspower-graph build\` first.`);
    process.exit(1);
  }
  const db = openDb(dbPath);
  initSchema(db);
  try { return await fn(db); } finally { db.close(); }
}

function emit(opts, payload, pretty) {
  if (opts.json) {
    process.stdout.write(JSON.stringify(payload, null, 2) + '\n');
  } else {
    process.stdout.write(pretty(payload) + '\n');
  }
}

async function runBuildLocked(opts, { exitOnReturn = true } = {}) {
  const lockWrapper = path.join(PLUGIN_ROOT, 'scripts/graph-with-lock.py');
  const graphDir = graphDirFor(opts.cwd);
  fs.mkdirSync(graphDir, { recursive: true, mode: 0o700 });
  const child = spawnSync('python3', [
    lockWrapper,
    '--graph-dir', graphDir,
    '--',
    process.execPath, url.fileURLToPath(import.meta.url),
    'build-unlocked', '--cwd', opts.cwd,
  ], {
    env: { ...process.env, CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT },
    stdio: 'inherit',
  });
  const status = child.status ?? 1;
  if (exitOnReturn) process.exit(status);
  return status;
}

async function runBuildUnlocked(opts) {
  const { build } = await import(path.join(PLUGIN_ROOT, 'scripts/graph/build.mjs'));
  const graphDir = graphDirFor(opts.cwd);
  fs.mkdirSync(graphDir, { recursive: true, mode: 0o700 });
  const t0 = Date.now();
  const res = await build({
    rootDir: opts.cwd, graphDir,
    log: msg => process.stderr.write(`[build] ${msg}\n`),
  });
  process.stderr.write(`[build] complete in ${Date.now() - t0}ms\n`);
  emit(opts, res, r => `${r.fileCount} files, ${r.nodeCount} nodes, ${r.edgeCount} edges`);
}

async function runRefreshLocked(opts) {
  const lockWrapper = path.join(PLUGIN_ROOT, 'scripts/graph-with-lock.py');
  const graphDir = graphDirFor(opts.cwd);
  fs.mkdirSync(graphDir, { recursive: true, mode: 0o700 });
  const child = spawnSync('python3', [
    lockWrapper,
    '--graph-dir', graphDir,
    '--',
    process.execPath, url.fileURLToPath(import.meta.url),
    'refresh-unlocked', '--cwd', opts.cwd,
  ], {
    env: { ...process.env, CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT },
    stdio: 'inherit',
  });
  if (child.status === 42) {
    process.stderr.write(`[refresh] fall through to full rebuild\n`);
    const child2 = spawnSync('python3', [
      lockWrapper,
      '--graph-dir', graphDir,
      '--',
      process.execPath, url.fileURLToPath(import.meta.url),
      'build-unlocked', '--cwd', opts.cwd,
    ], { env: { ...process.env, CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT }, stdio: 'inherit' });
    process.exit(child2.status ?? 1);
  }
  process.exit(child.status ?? 1);
}

async function runRefreshUnlocked(opts) {
  const { refresh } = await import(path.join(PLUGIN_ROOT, 'scripts/graph/refresh.mjs'));
  const graphDir = graphDirFor(opts.cwd);
  fs.mkdirSync(graphDir, { recursive: true, mode: 0o700 });
  const t0 = Date.now();
  const res = await refresh({
    rootDir: opts.cwd, graphDir,
    log: msg => process.stderr.write(`[refresh] ${msg}\n`),
  });
  process.stderr.write(`[refresh] complete in ${Date.now() - t0}ms\n`);
  if (res.fullRebuild) {
    emit(opts, res, r => `refresh fullRebuild: reason=${r.reason}`);
    process.exit(42);
  }
  emit(opts, res, r => `${r.fileCount} files touched, ${r.nodeCount} nodes, ${r.edgeCount} edges`);
}

async function runSessionRefresh(opts) {
  const sessionMod = await import(path.join(PLUGIN_ROOT, 'scripts/graph/session-refresh.mjs'));
  const graphDir = graphDirFor(opts.cwd);
  if (!fs.existsSync(path.join(graphDir, 'index.sqlite'))) {
    emit(opts, { action: 'noop', reason: 'no-index' }, r => `noop: ${r.reason}`);
    return;
  }
  const maxTimeMs = Math.max(1, (opts.maxTime ?? 5) * 1000);
  const planner = await sessionMod.sessionRefresh({
    rootDir: opts.cwd, graphDir, maxTime: maxTimeMs,
    log: msg => process.stderr.write(`[session-refresh] ${msg}\n`),
  });
  emit(opts, planner, p => `action=${p.action} reason=${p.reason} dirty=${p.dirtyEmitted ?? 0}`);
  if (planner.action === 'build') {
    const status = await runBuildLocked(opts, { exitOnReturn: false });
    if (status === 0 && planner.pendingFilesetHash) {
      await sessionMod.writeVersionField(graphDir, 'git_filesethash', planner.pendingFilesetHash);
    }
    process.exit(status);
  } else if (planner.action === 'refresh') {
    await runRefreshLocked(opts);
  }
}

async function runTrace(opts, fromName, toName) {
  const { queryTrace } = await import(path.join(PLUGIN_ROOT, 'scripts/graph/queries.mjs'));
  const r = await queryTrace(opts.cwd, fromName, toName, { maxHops: opts.maxHops, limit: opts.limit });
  emit(opts, r, p => p.paths.length === 0 ? 'no path' :
    p.paths.map(pp => `${pp.from} -> ... -> ${pp.to} (${pp.hops} hops)`).join('\n'));
}

async function runImpact(opts, filePath) {
  const { queryImpact } = await import(path.join(PLUGIN_ROOT, 'scripts/graph/queries.mjs'));
  const r = await queryImpact(opts.cwd, filePath, { limit: opts.limit });
  emit(opts, r, p => `${p.target_file}\ndirect=${p.direct_count} transitive=${p.transitive_count}\n` +
    p.files.map(f => `  ${f.file_path}\n    ${f.qnames.join(', ')}`).join('\n'));
}

async function runContext(opts, task) {
  const { queryContext } = await import(path.join(PLUGIN_ROOT, 'scripts/graph/queries.mjs'));
  const r = await queryContext(opts.cwd, task);
  emit(opts, r, p => p.hits.length === 0 ? 'no context' :
    p.hits.map(h => `${h.qname}\t${h.file}:${h.line}\t${h.signature ?? ''}`).join('\n'));
}

async function runCallers(opts, name) {
  const { queryCallers } = await import(path.join(PLUGIN_ROOT, 'scripts/graph/queries.mjs'));
  const r = await queryCallers(opts.cwd, name, { limit: opts.limit, disambiguate: opts.disambiguate });
  if (r.ambiguous) {
    emit(opts, r, p => `ambiguous: ${p.targets.length} targets — pass --disambiguate or query a more specific name\n` +
      p.targets.map(t => `  ${t.qualified_name} (${t.file_path}:${t.start_line})`).join('\n'));
    return;
  }
  emit(opts, r, p => p.matches.length === 0 ? 'no callers' :
    p.matches.map(m => `${m.src_file}:${m.line}\t${m.src_qname}\t-> ${m.tgt_qname}\t(conf=${m.confidence})`).join('\n'));
}

async function runCallees(opts, name) {
  const { queryCallees } = await import(path.join(PLUGIN_ROOT, 'scripts/graph/queries.mjs'));
  const r = await queryCallees(opts.cwd, name, { limit: opts.limit });
  emit(opts, r, p => p.matches.length === 0 ? 'no callees' :
    p.matches.map(m => `${m.tgt_file}:${m.tgt_start}\t${m.tgt_qname}\t<- ${m.src_qname}\t(conf=${m.confidence})`).join('\n'));
}

async function runNode(opts, name) {
  const { queryNode } = await import(path.join(PLUGIN_ROOT, 'scripts/graph/queries.mjs'));
  const rows = await queryNode(opts.cwd, name);
  emit(opts, rows, p => p.length === 0 ? 'not found' :
    p.map(n => `${n.file_path}:${n.start_line}-${n.end_line}\t${n.qualified_name}\t${n.kind}\t${n.signature ?? ''}`).join('\n'));
}

async function runStatus(opts) {
  const { queryStatus } = await import(path.join(PLUGIN_ROOT, 'scripts/graph/queries.mjs'));
  const s = await queryStatus(opts.cwd);
  emit(opts, s, p => p.ok
    ? `files=${p.fileCount} nodes=${p.nodeCount} edges=${p.edgeCount} dirty=${p.dirtyCount} last=${p.lastIndexed}`
    : `no index: ${p.dbPath}`);
}

async function runMcpServer() {
  const { Server } = await import('@modelcontextprotocol/sdk/server/index.js');
  const { StdioServerTransport } = await import('@modelcontextprotocol/sdk/server/stdio.js');
  const { ListToolsRequestSchema, CallToolRequestSchema } = await import('@modelcontextprotocol/sdk/types.js');
  const { TOOLS, dispatch } = await import('../scripts/graph/mcp-tools/index.mjs');

  const server = new Server({ name: 'sspower-graph', version: PKG_VERSION }, { capabilities: { tools: {} } });
  server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOLS }));
  server.setRequestHandler(CallToolRequestSchema, async ({ params }) => {
    const t0 = Date.now();
    let ok = true;
    let effectiveCwd = params.arguments?.cwd ?? process.cwd();
    try {
      const result = await dispatch(params.name, params.arguments);
      effectiveCwd = result._effectiveCwd ?? effectiveCwd;
      const { _effectiveCwd, ...client } = result;
      return client;
    } catch (e) {
      ok = false;
      throw e;
    } finally {
      try {
        const { recordEvent } = await import('../scripts/graph/mcp-tools/metric.mjs');
        recordEvent({ tool: params.name, ok, duration_ms: Date.now() - t0, cwd: effectiveCwd });
      } catch (e) {
        if (e.code !== 'ERR_MODULE_NOT_FOUND') process.stderr.write(`metric write failed: ${e.message}\n`);
      }
    }
  });
  await server.connect(new StdioServerTransport());
}

const rest = argv.slice(1);
const opts = parseOpts(rest);

try {
  switch (cmd) {
    case 'build':           await runBuildLocked(opts); break;
    case 'build-unlocked':  await runBuildUnlocked(opts); break;
    case 'refresh':          await runRefreshLocked(opts); break;
    case 'refresh-unlocked': await runRefreshUnlocked(opts); break;
    case 'session-refresh':  await runSessionRefresh(opts); break;
    case 'trace':            if (opts.positional.length < 2) { usage(); process.exit(2); }
                             await runTrace(opts, opts.positional[0], opts.positional[1]); break;
    case 'impact':           if (!opts.positional[0]) { usage(); process.exit(2); }
                             await runImpact(opts, opts.positional[0]); break;
    case 'context':          if (!opts.positional[0]) { usage(); process.exit(2); }
                             await runContext(opts, opts.positional[0]); break;
    case 'callers':         if (!opts.positional[0]) { usage(); process.exit(2); }
                            await runCallers(opts, opts.positional[0]); break;
    case 'callees':         if (!opts.positional[0]) { usage(); process.exit(2); }
                            await runCallees(opts, opts.positional[0]); break;
    case 'node':            if (!opts.positional[0]) { usage(); process.exit(2); }
                            await runNode(opts, opts.positional[0]); break;
    case 'status':          await runStatus(opts); break;
    case 'metric':          {
                              const { aggregate } = await import('../scripts/graph/mcp-tools/metric.mjs');
                              const ag = aggregate({ window: opts.window ?? 50 });
                              emit(opts, ag, a => `gate_met=${a.gate_met} eligible=${a.eligible_sessions_total} with_call=${a.sessions_with_call}`);
                              break;
                            }
    case 'serve':           if (argv[1] === '--mcp') { await runMcpServer(); }
                            else { usage(); process.exit(2); }
                            break;
    default:                usage(); process.exit(2);
  }
} catch (e) {
  process.stderr.write(`error: ${e.message}\n`);
  process.exit(1);
}
