if (!process.env.SSPOWER_GRAPH_PERF) {
  console.log('skip: SSPOWER_GRAPH_PERF not set');
  process.exit(0);
}

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import url from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const PLUGIN_ROOT = path.resolve(url.fileURLToPath(import.meta.url), '../../..');
const FIXTURE = path.join(PLUGIN_ROOT, '__tests__', 'graph-fixtures', 'ts-js');

const transport = new StdioClientTransport({
  command: path.join(PLUGIN_ROOT, 'bin', 'sspower-graph-bootstrap.sh'),
  args: ['serve', '--mcp'],
  env: {
    ...process.env,
    CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT,
    NODE: process.execPath,
    SSPOWER_GRAPH_STATE_DIR: fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-perf-metric-')),
    SSPOWER_SESSION_STATE_DIR: fs.mkdtempSync(path.join(os.tmpdir(), 'sssg-perf-session-')),
  },
  cwd: FIXTURE,
});
const client = new Client({ name: 'perf', version: '0' }, { capabilities: {} });
await client.connect(transport);

async function bench(name, args, n = 100) {
  const t = [];
  for (let i = 0; i < n; i++) {
    const t0 = Date.now();
    await client.callTool({ name, arguments: args });
    t.push(Date.now() - t0);
  }
  t.sort((a, b) => a - b);
  return { name, p50: t[Math.floor(n * 0.5)], p95: t[Math.floor(n * 0.95)], max: t[n - 1] };
}

const results = [
  await bench('graph_status', {}),
  await bench('graph_callers', { name: 'helper' }),
  await bench('graph_callees', { name: 'caller' }),
  await bench('graph_node', { name: 'helper' }),
];
console.table(results);
const hardFailures = results.filter(r => r.p95 > 1000);
if (hardFailures.length) {
  console.error(`HARD: ${hardFailures.length} tools exceed p95 >1000ms`);
  await client.close();
  process.exit(1);
}
const advisory = results.filter(r => r.p95 > 300);
if (advisory.length) console.warn(`ADVISORY: ${advisory.length} tools exceed p95 <=300ms`);
await client.close();
