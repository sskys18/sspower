// tests/graph/perf-10k.mjs
// Synthesize a 10k-file TypeScript tree, build the graph, then time
// `callers` 100x against a known hot symbol; assert spec §4 P2 gates.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { build } from '../../scripts/graph/build.mjs';
import { callers } from '../../scripts/graph/query.mjs';
import { openDb, initSchema } from '../../scripts/graph/db.mjs';

const TOTAL_FILES   = parseInt(process.env.PERF_FILES   ?? '10000', 10);
const QUERY_REPEATS = parseInt(process.env.PERF_QUERIES ?? '100', 10);
const BUILD_BUDGET_MS = parseInt(process.env.PERF_BUILD_MS ?? '60000', 10);
const QUERY_P95_MS    = parseInt(process.env.PERF_P95_MS  ?? '1000', 10);

const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'sspower-perf-'));
const graphDir = path.join(tmp, '.claude', 'graph');
await fs.mkdir(graphDir, { recursive: true });

console.error(`generating ${TOTAL_FILES} files in ${tmp}`);
for (let i = 0; i < TOTAL_FILES; i++) {
  const dirN  = path.join(tmp, `d${Math.floor(i / 100)}`);
  await fs.mkdir(dirN, { recursive: true });
  const filePath = path.join(dirN, `m${i}.ts`);
  const target = i === 0 ? 0 : i - 1;
  const targetFile = path.relative(dirN, path.join(tmp, `d${Math.floor(target / 100)}`, `m${target}.ts`)).replace(/\\/g, '/').replace(/\.ts$/, '');
  await fs.writeFile(filePath,
    `import { fn${target} } from '${targetFile.startsWith('.') ? targetFile : './' + targetFile}';\n` +
    `export function fn${i}() { return fn${target}() + ${i}; }\n`
  );
  if ((i + 1) % 1000 === 0) console.error(`  ${i + 1}/${TOTAL_FILES}`);
}

console.error('building...');
const tBuild0 = Date.now();
await build({ rootDir: tmp, graphDir, log: () => {} });
const buildMs = Date.now() - tBuild0;
console.error(`build: ${buildMs}ms`);

assert.ok(buildMs < BUILD_BUDGET_MS, `build budget: ${buildMs} >= ${BUILD_BUDGET_MS}`);

console.error(`running ${QUERY_REPEATS} warm callers queries...`);
const db = openDb(path.join(graphDir, 'index.sqlite'));
initSchema(db);
const timings = [];
for (let i = 0; i < QUERY_REPEATS; i++) {
  const target = `fn${Math.floor(TOTAL_FILES / 2)}`;
  const t0 = process.hrtime.bigint();
  callers(db, target, { limit: 50, disambiguate: true });
  const dt = Number(process.hrtime.bigint() - t0) / 1e6;
  timings.push(dt);
}
db.close();
timings.sort((a, b) => a - b);
const p50 = timings[Math.floor(timings.length * 0.5)];
const p95 = timings[Math.floor(timings.length * 0.95)];
const p99 = timings[Math.floor(timings.length * 0.99)];
console.error(`callers p50=${p50.toFixed(2)}ms p95=${p95.toFixed(2)}ms p99=${p99.toFixed(2)}ms`);

assert.ok(p95 < QUERY_P95_MS, `p95 budget: ${p95} >= ${QUERY_P95_MS}`);

await fs.rm(tmp, { recursive: true, force: true });
console.log(`perf-10k.mjs OK   build=${buildMs}ms  callers p50=${p50.toFixed(2)} p95=${p95.toFixed(2)}`);
