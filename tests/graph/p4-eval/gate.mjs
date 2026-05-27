#!/usr/bin/env node
// tests/graph/p4-eval/gate.mjs
// Usage: node gate.mjs --baseline <a.json> --candidate <b.json> --criteria <c.json>
import fs from 'node:fs';
const args = parseArgs(process.argv.slice(2));
const base = JSON.parse(fs.readFileSync(args.baseline, 'utf8'));
const cand = JSON.parse(fs.readFileSync(args.candidate, 'utf8'));
const crit = JSON.parse(fs.readFileSync(args.criteria, 'utf8'));

const ansDelta = cand.mean_answerable - base.mean_answerable;
const bytesRatio = cand.mean_bytes / Math.max(base.mean_bytes, 1);

const modes = {};
for (const m of crit.modes) {
  if (m.name === 'balanced') {
    modes.balanced =
      ansDelta >= m.answerable_mean_delta_min &&
      bytesRatio <= m.bytes_mean_ratio_max &&
      cand.p95_wall_ms <= m.wall_p95_ms_max;
  } else if (m.name === 'answerable-first') {
    modes['answerable-first'] =
      ansDelta >= m.answerable_mean_delta_min &&
      cand.mean_bytes <= m.bytes_mean_cap &&
      cand.p95_wall_ms <= m.wall_p95_ms_max;
  }
}
const pass = modes.balanced || modes['answerable-first'];

const report = {
  baseline: { bytes: base.mean_bytes, answerable: base.mean_answerable, p95_wall_ms: base.p95_wall_ms },
  candidate: { bytes: cand.mean_bytes, answerable: cand.mean_answerable, p95_wall_ms: cand.p95_wall_ms },
  delta: { answerable: ansDelta, bytes_ratio: bytesRatio },
  modes, pass,
};
console.log(JSON.stringify(report, null, 2));
process.exit(pass ? 0 : 1);

function parseArgs(argv) {
  const o = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith('--')) o[argv[i].slice(2)] = argv[i+1];
  }
  return o;
}
