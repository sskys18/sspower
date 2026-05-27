#!/usr/bin/env node
// P4 Task 7: graph_routes MCP tool parity test.
// Spawns the MCP stdio server via the bootstrap shell, lists tools,
// calls graph_routes, and asserts the deep-equal-to-CLI invariant
// (modulo trailing newline -- F1 known gap inherited from P3).

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import url from 'node:url';
import { spawnSync } from 'node:child_process';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const PLUGIN_ROOT = path.resolve(url.fileURLToPath(import.meta.url), '../../..');
const FIXTURE_SRC = path.join(PLUGIN_ROOT, '__tests__', 'graph-fixtures', 'express');
const CLI = path.join(PLUGIN_ROOT, 'bin', 'sspower-graph.mjs');
const BOOTSTRAP = path.join(PLUGIN_ROOT, 'bin', 'sspower-graph-bootstrap.sh');

// Copy fixture to a temp dir so we can build the index without polluting
// the in-tree fixture (which is checked in clean).
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-p4-routes-mcp-'));
fs.cpSync(FIXTURE_SRC, tmp, { recursive: true });

// Build index.
{
  const { build } = await import('../../scripts/graph/build.mjs');
  await build({
    rootDir: tmp,
    graphDir: path.join(tmp, '.claude', 'graph'),
    log: () => {},
  });
}

const metricState = fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-p4-routes-mcp-metric-'));
const sessionState = fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-p4-routes-mcp-session-'));

const transport = new StdioClientTransport({
  command: BOOTSTRAP,
  args: ['serve', '--mcp'],
  env: {
    ...process.env,
    CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT,
    NODE: process.execPath,
    SSPOWER_GRAPH_STATE_DIR: metricState,
    SSPOWER_SESSION_STATE_DIR: sessionState,
  },
  cwd: tmp,
});
const client = new Client({ name: 'p4-routes-parity', version: '0' }, { capabilities: {} });
await client.connect(transport);

// Sanity: tool is listed.
const tools = await client.listTools();
const names = tools.tools.map(t => t.name).sort();
assert.ok(names.includes('graph_routes'), `graph_routes missing: ${names.join(',')}`);
assert.equal(names.length, 8, `expected 8 tools (P4 bump), got ${names.length}: ${names.join(',')}`);

// Call MCP graph_routes (no args).
const mcpRes = await client.callTool({ name: 'graph_routes', arguments: { cwd: tmp } });
const mcpText = mcpRes.content[0].text;

// CLI routes --json on same cwd.
const cli = spawnSync(process.execPath, [CLI, 'routes', '--cwd', tmp, '--json'], { encoding: 'utf8' });
assert.equal(cli.status, 0, `cli stderr=${cli.stderr}`);
const cliText = cli.stdout;

// F1 gap: MCP wraps the payload as text but does NOT append the trailing
// newline that the CLI's emit() always appends. Compare deep-equal on the
// parsed JSON (canonical equivalence), not byte-identical.
const mcpJson = JSON.parse(mcpText);
const cliJson = JSON.parse(cliText);
assert.deepEqual(mcpJson, cliJson, `MCP/CLI parity mismatch\nMCP=${mcpText}\nCLI=${cliText}`);

// Sanity on payload shape: 5 routes from the express fixture (P4 no mount expansion).
assert.equal(mcpJson.routes.length, 5, `expected 5 routes, got ${mcpJson.routes.length}`);
assert.ok(mcpJson.routes.every(r => r.name && r.qname && r.file && typeof r.line === 'number'),
  `route row shape: ${JSON.stringify(mcpJson.routes[0])}`);

// framework=express filter equivalence.
const mcpFw = await client.callTool({ name: 'graph_routes', arguments: { cwd: tmp, framework: 'express' } });
const mcpFwJson = JSON.parse(mcpFw.content[0].text);
assert.deepEqual(mcpFwJson.routes, mcpJson.routes, 'express filter routes set should match');

// limit cap.
const mcpLim = await client.callTool({ name: 'graph_routes', arguments: { cwd: tmp, limit: 3 } });
const mcpLimJson = JSON.parse(mcpLim.content[0].text);
assert.equal(mcpLimJson.routes.length, 3, `limit=3 returned ${mcpLimJson.routes.length}`);

await client.close();
fs.rmSync(tmp, { recursive: true });
fs.rmSync(metricState, { recursive: true });
fs.rmSync(sessionState, { recursive: true });
console.log('OK p4-routes-mcp');
