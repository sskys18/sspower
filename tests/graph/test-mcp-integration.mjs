import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import url from 'node:url';
import { ensureFixtureGraph } from './fixture-graph.mjs';

const PLUGIN_ROOT = path.resolve(url.fileURLToPath(import.meta.url), '../../..');
const FIXTURE = path.join(PLUGIN_ROOT, '__tests__', 'graph-fixtures', 'ts-js');

await ensureFixtureGraph(FIXTURE);

const transport = new StdioClientTransport({
  command: path.join(PLUGIN_ROOT, 'bin', 'sspower-graph-bootstrap.sh'),
  args: ['serve', '--mcp'],
  env: {
    ...process.env,
    CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT,
    NODE: process.execPath,
    SSPOWER_GRAPH_STATE_DIR: fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-int-metric-')),
    SSPOWER_SESSION_STATE_DIR: fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-int-session-')),
  },
  cwd: FIXTURE,
});
const client = new Client({ name: 'smoke', version: '0' }, { capabilities: {} });
await client.connect(transport);

const tools = (await client.listTools()).tools;
assert.equal(tools.length, 7, `expected 7 tools; got ${tools.length}: ${tools.map(t => t.name).join(',')}`);
const expected = ['graph_status', 'graph_callers', 'graph_callees', 'graph_trace', 'graph_impact', 'graph_node', 'graph_context'];
const names = tools.map(t => t.name).sort();
assert.deepEqual(names, [...expected].sort(), 'tool name set mismatch');

for (const name of expected) {
  const args = {
    graph_status: {},
    graph_callers: { name: 'helper' },
    graph_callees: { name: 'caller' },
    graph_trace: { from: 'caller', to: 'helper' },
    graph_impact: { file: 'sample-input.ts' },
    graph_node: { name: 'helper' },
    graph_context: { task: 'add cache to helper' },
  }[name];
  const r = await client.callTool({ name, arguments: args });
  assert.ok(r.content?.[0]?.text, `${name}: no text content`);
  JSON.parse(r.content[0].text);
}

await client.close();
console.log('MCP integration 7-tool smoke OK');
