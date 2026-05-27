import assert from 'node:assert/strict';
import path from 'node:path';
import url from 'node:url';

const PLUGIN_ROOT = path.resolve(url.fileURLToPath(import.meta.url), '../../..');
const FIXTURE = path.join(PLUGIN_ROOT, '__tests__', 'graph-fixtures', 'ts-js');

import { handler as statusHandler } from '../../scripts/graph/mcp-tools/status.mjs';
const r = await statusHandler({ cwd: FIXTURE });
assert.equal(typeof r.fileCount, 'number');
assert.ok(r.fileCount > 0, `expected fixture files in ${FIXTURE}`);
console.log('graph_status OK');

import { handler as callersHandler } from '../../scripts/graph/mcp-tools/callers.mjs';
const c = await callersHandler({ cwd: FIXTURE, name: 'helper', limit: 10 });
assert.ok(Array.isArray(c.matches), 'matches array (P2 shape)');
assert.ok(c.matches.some(m => /caller/.test(m.src_qname ?? m.qname ?? m.name ?? '')), 'caller should appear in helper callers');
console.log('graph_callers OK');

import { handler as calleesHandler } from '../../scripts/graph/mcp-tools/callees.mjs';
const cc = await calleesHandler({ cwd: FIXTURE, name: 'caller' });
assert.ok(Array.isArray(cc.matches));
assert.ok(cc.matches.some(m => /helper/.test(m.tgt_qname ?? m.qname ?? m.name ?? '')), 'caller should call helper');
console.log('graph_callees OK');

import { handler as traceHandler } from '../../scripts/graph/mcp-tools/trace.mjs';
const t = await traceHandler({ cwd: FIXTURE, from: 'caller', to: 'helper', maxHops: 4 });
assert.ok('paths' in t, 'trace returns paths field');
console.log('graph_trace OK');

import { handler as impactHandler } from '../../scripts/graph/mcp-tools/impact.mjs';
const i = await impactHandler({ cwd: FIXTURE, file: 'sample-input.ts' });
assert.ok('files' in i || 'direct_count' in i, 'impact returns files/direct_count');
console.log('graph_impact OK');

import { handler as nodeHandler } from '../../scripts/graph/mcp-tools/node.mjs';
const n = await nodeHandler({ cwd: FIXTURE, name: 'helper' });
const rows = Array.isArray(n) ? n : (n.matches ?? []);
assert.ok(rows.length > 0, 'helper should have at least one node row');
console.log('graph_node OK');

import { handler as ctxHandler } from '../../scripts/graph/mcp-tools/context.mjs';
const ctx = await ctxHandler({ cwd: FIXTURE, task: 'add caching to helper' });
assert.ok('hits' in ctx, 'graph_context returns hits[]');
console.log('graph_context OK');

let threw = false;
try { await ctxHandler({ cwd: FIXTURE, task: 'x'.repeat(501) }); } catch { threw = true; }
assert.ok(threw, 'graph_context did not clamp task length');
console.log('graph_context clamp OK');
