import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import url from 'node:url';
import { spawnSync } from 'node:child_process';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const PLUGIN_ROOT = path.resolve(url.fileURLToPath(import.meta.url), '../../..');
const FIXTURE = path.join(PLUGIN_ROOT, '__tests__', 'graph-fixtures', 'ts-js');
const GRAPH = path.join(PLUGIN_ROOT, 'bin', 'sspower-graph.mjs');
const metricState = fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-parity-metric-'));
const sessionState = fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-parity-session-'));

function cliJson(verb, ...args) {
  const r = spawnSync(process.execPath, [GRAPH, verb, '--cwd', FIXTURE, '--json', ...args], { encoding: 'utf8' });
  assert.equal(r.status, 0, `cli ${verb} stderr=${r.stderr}`);
  return r.stdout.trimEnd();
}

const transport = new StdioClientTransport({
  command: path.join(PLUGIN_ROOT, 'bin', 'sspower-graph-bootstrap.sh'),
  args: ['serve', '--mcp'],
  env: {
    ...process.env,
    CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT,
    NODE: process.execPath,
    SSPOWER_GRAPH_STATE_DIR: metricState,
    SSPOWER_SESSION_STATE_DIR: sessionState,
  },
  cwd: FIXTURE,
});
const client = new Client({ name: 'parity', version: '0' }, { capabilities: {} });
await client.connect(transport);

const cases = [
  ['graph_status', {}, []],
  ['graph_callers', { name: 'helper' }, ['helper']],
  ['graph_callees', { name: 'caller' }, ['caller']],
  ['graph_node', { name: 'helper' }, ['helper']],
  ['graph_trace', { from: 'caller', to: 'helper' }, ['caller', 'helper']],
  ['graph_impact', { file: 'sample-input.ts' }, ['sample-input.ts']],
  ['graph_context', { task: 'add cache to helper' }, ['add cache to helper']],
];

for (const [mcpName, mcpArgs, cliArgs] of cases) {
  const r = await client.callTool({ name: mcpName, arguments: mcpArgs });
  const mcpText = r.content[0].text;
  const cliRaw = cliJson(mcpName.replace(/^graph_/, ''), ...cliArgs);
  assert.equal(mcpText, cliRaw, `${mcpName}: MCP/CLI raw byte mismatch\nMCP=${mcpText}\nCLI=${cliRaw}`);
}

await client.close();
console.log('MCP/CLI byte-identical parity OK (7 tools)');
