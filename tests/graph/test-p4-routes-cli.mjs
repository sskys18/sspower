#!/usr/bin/env node
// P4 Task 6: routes CLI verb assertions.
//   (a) --json output is JSON.stringify(payload, null, 2) + '\n' exact
//   (b) without --framework matches --framework express on the route set
//       (metadata `framework` field differs by design: 'all' vs 'express')
//   (c) --limit 3 returns 3 entries
//   (d) --framework unknown returns empty routes (forward-compat)

import { build } from '../../scripts/graph/build.mjs';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import url from 'node:url';
import { spawnSync } from 'node:child_process';

const ROOT = path.resolve(import.meta.dirname, '..', '..');
const CLI  = path.join(ROOT, 'bin', 'sspower-graph.mjs');

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'sspower-p4-routes-cli-'));
fs.cpSync(path.join(ROOT, '__tests__/graph-fixtures/express'), tmp, { recursive: true });
const graphDir = path.join(tmp, '.claude', 'graph');
await build({ rootDir: tmp, graphDir, log: () => {} });

function runCli(args) {
  const r = spawnSync(process.execPath, [CLI, 'routes', ...args, '--cwd', tmp], {
    encoding: 'utf8',
  });
  if (r.status !== 0) {
    throw new Error(`cli exit ${r.status}: ${r.stderr}`);
  }
  return r.stdout;
}

// (a) byte-exact JSON shape: 2-space indent + trailing '\n'.
const out = runCli(['--json']);
assert.ok(out.endsWith('\n'), 'json output must end with newline');
const parsed = JSON.parse(out);
assert.equal(JSON.stringify(parsed, null, 2) + '\n', out, '--json output must be canonical 2-space + \\n');

// (b) framework filter is no-op for routes set.
const noFlag = JSON.parse(runCli(['--json']));
const expressFlag = JSON.parse(runCli(['--framework', 'express', '--json']));
assert.deepEqual(noFlag.routes, expressFlag.routes, 'routes set must match');
assert.equal(noFlag.framework, 'all');
assert.equal(expressFlag.framework, 'express');

// (c) --limit 3.
const limited = JSON.parse(runCli(['--limit', '3', '--json']));
assert.equal(limited.routes.length, 3, `--limit 3 returned ${limited.routes.length}`);

// (d) unknown framework -> empty.
const fastify = JSON.parse(runCli(['--framework', 'fastify', '--json']));
assert.deepEqual(fastify.routes, [], 'unknown framework must return empty routes');
assert.equal(fastify.framework, 'fastify');

// Sanity: default limit returns ALL 5 fixture routes.
assert.equal(noFlag.routes.length, 5, `expected 5 routes, got ${noFlag.routes.length}`);

fs.rmSync(tmp, { recursive: true });
console.log('OK p4-routes-cli');
