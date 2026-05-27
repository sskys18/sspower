import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';
import { spawnSync } from 'node:child_process';

const PLUGIN_ROOT = path.resolve(url.fileURLToPath(import.meta.url), '../../..');
const FIXTURES = path.join(PLUGIN_ROOT, '__tests__', 'graph-fixtures');
const GRAPH = path.join(PLUGIN_ROOT, 'bin', 'sspower-graph.mjs');
const VOLATILE_KEYS = new Set(['lastIndexed', 'updated_at', 'indexed_at']);

function normalizeStdout(s) {
  s = s.replace(/"pendingFilesetHash": "[^"]+"/g, '"pendingFilesetHash": "<volatile>"');
  try {
    const v = JSON.parse(s);
    const scrub = x => {
      if (Array.isArray(x)) return x.map(scrub);
      if (x && typeof x === 'object') {
        const out = {};
        for (const [k, v] of Object.entries(x)) out[k] = VOLATILE_KEYS.has(k) ? 0 : scrub(v);
        return out;
      }
      return x;
    };
    return JSON.stringify(scrub(v), null, 2) + '\n';
  } catch {
    return s;
  }
}

const packs = fs.readdirSync(FIXTURES).filter(p =>
  fs.existsSync(path.join(FIXTURES, p, 'expected', 'cli-goldens', 'manifest.json')));

let checked = 0;
for (const pack of packs) {
  const packDir = path.join(FIXTURES, pack);
  const goldenDir = path.join(packDir, 'expected', 'cli-goldens');
  const cases = JSON.parse(fs.readFileSync(path.join(goldenDir, 'manifest.json'), 'utf8'));
  for (const c of cases) {
    const goldenPath = path.join(goldenDir, c.file);
    if (!fs.existsSync(goldenPath)) continue;
    const [verb, ...rest] = c.args;
    const r = spawnSync(process.execPath, [GRAPH, verb, '--cwd', packDir, '--json', ...rest], { encoding: 'utf8' });
    assert.equal(r.status, 0, `${pack}/${c.file}: exit=${r.status} stderr=${r.stderr}`);
    if (verb === 'session-refresh') {
      checked++;
      continue;
    }
    const expected = fs.readFileSync(goldenPath, 'utf8');
    assert.equal(normalizeStdout(r.stdout), normalizeStdout(expected), `${pack}/${c.file}: --json stdout byte-diff`);
    checked++;
  }
}

assert.ok(checked > 0, 'no goldens captured');
console.log(`P2 CLI back-compat: ${packs.length} packs, ${checked} cases OK`);
