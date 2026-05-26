#!/usr/bin/env node
// sspower-graph MCP stub server (P0).
//
// Spec: docs/specs/2026-05-26-codegraph-style-graph-design.md D31.

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';

const argv = process.argv.slice(2);
const cmd = argv[0];

if (cmd !== 'serve' || argv[1] !== '--mcp') {
  console.error('usage: sspower-graph serve --mcp');
  process.exit(2);
}

const server = new Server(
  { name: 'sspower-graph', version: '0.0.1' },
  { capabilities: { tools: {} } },
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [{
    name: 'graph_status',
    description: 'Graph index freshness (P0 stub: always returns {ok:true,stub:true})',
    inputSchema: { type: 'object', properties: {}, required: [] },
  }],
}));

server.setRequestHandler(CallToolRequestSchema, async ({ params }) => {
  if (params.name === 'graph_status') {
    return {
      content: [{
        type: 'text',
        text: JSON.stringify({ ok: true, stub: true, phase: 'P0' }),
      }],
    };
  }
  throw new Error(`unknown tool: ${params.name}`);
});

await server.connect(new StdioServerTransport());
