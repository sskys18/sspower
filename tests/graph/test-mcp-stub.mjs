#!/usr/bin/env node
// MCP stub smoke test. Spawns the bootstrap wrapper and performs the full
// handshake: initialize, tools/list, tools/call.
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import assert from 'node:assert/strict';
import path from 'node:path';

const pluginRoot = process.env.CLAUDE_PLUGIN_ROOT
  ?? path.resolve(import.meta.dirname, '..', '..');

const transport = new StdioClientTransport({
  command: path.join(pluginRoot, 'bin', 'sspower-graph-bootstrap.sh'),
  args: ['serve', '--mcp'],
  env: { ...process.env, CLAUDE_PLUGIN_ROOT: pluginRoot },
});

const client = new Client(
  { name: 'sspower-graph-smoke', version: '0.0.1' },
  { capabilities: {} },
);

await client.connect(transport);

const tools = await client.listTools();
assert.equal(tools.tools.length, 1, `expected 1 tool, got ${tools.tools.length}`);
assert.equal(tools.tools[0].name, 'graph_status');

const result = await client.callTool({ name: 'graph_status', arguments: {} });
assert.equal(result.content.length, 1);
assert.equal(result.content[0].type, 'text');
const payload = JSON.parse(result.content[0].text);
assert.equal(payload.ok, true);
assert.equal(payload.stub, true);
assert.equal(payload.phase, 'P0');

let threw = false;
try {
  await client.callTool({ name: 'nonexistent', arguments: {} });
} catch {
  threw = true;
}
assert.ok(threw, 'unknown tool should throw');

await client.close();
console.log('OK MCP stub smoke passed');
