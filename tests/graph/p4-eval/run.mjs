#!/usr/bin/env node
// tests/graph/p4-eval/run.mjs
// Usage: node run.mjs --mode baseline|candidate --out <path.json>
//   baseline:  SSPOWER_GRAPH_ORCHESTRATOR=off  (semble-context.sh runs)
//   candidate: SSPOWER_GRAPH_ORCHESTRATOR=on   (graph-orchestrator.sh runs)
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import url from 'node:url';

const HERE = path.dirname(url.fileURLToPath(import.meta.url));
const PLUGIN_ROOT = path.resolve(HERE, '..', '..', '..');
const PROMPTS = JSON.parse(fs.readFileSync(path.join(HERE, 'prompts.json'), 'utf8'));

const args = parseArgs(process.argv.slice(2));
const mode = args.mode === 'candidate' ? 'candidate' : 'baseline';
const outPath = args.out;
if (!outPath) { console.error('--out required'); process.exit(2); }

const env = {
  ...process.env,
  CLAUDE_PLUGIN_ROOT: PLUGIN_ROOT,
  SSPOWER_GRAPH_ORCHESTRATOR: mode === 'candidate' ? 'on' : 'off',
  SSPOWER_SEMBLE: '1',
};

// In candidate mode, run graph-orchestrator.sh; in baseline, semble-context.sh.
// Both consume the same JSON payload on stdin and emit hookSpecificOutput on stdout.
const HOOK = mode === 'candidate'
  ? path.join(PLUGIN_ROOT, 'hooks', 'graph-orchestrator.sh')
  : path.join(PLUGIN_ROOT, 'hooks', 'semble-context.sh');

const results = [];
for (const p of PROMPTS) {
  const cwd = p.cwd.replace('{{REPO_ROOT}}', PLUGIN_ROOT);
  const payload = JSON.stringify({ prompt: p.prompt, cwd });
  const t0 = Date.now();
  const r = spawnSync(HOOK, [], { input: payload, env, encoding: 'utf8', timeout: 10_000 });
  const wallMs = Date.now() - t0;
  let additionalContext = '';
  try {
    const j = JSON.parse(r.stdout || '{}');
    additionalContext = j?.hookSpecificOutput?.additionalContext ?? '';
  } catch { /* empty emission OK */ }
  const bytes = Buffer.byteLength(additionalContext, 'utf8');
  const hits = p.expected_evidence.filter(ev => additionalContext.includes(ev)).length;
  const answerable = p.expected_evidence.length === 0 ? 1 : hits / p.expected_evidence.length;
  results.push({ id: p.id, intent: p.intent, wallMs, bytes, answerable, exit: r.status });
}

const summary = {
  mode, n: results.length,
  mean_bytes: mean(results.map(r => r.bytes)),
  mean_answerable: mean(results.map(r => r.answerable)),
  p95_wall_ms: p95(results.map(r => r.wallMs)),
  results,
};
fs.writeFileSync(outPath, JSON.stringify(summary, null, 2) + '\n');
console.log(`wrote ${outPath}: bytes=${summary.mean_bytes.toFixed(0)} ans=${summary.mean_answerable.toFixed(2)} p95=${summary.p95_wall_ms}ms`);

function mean(xs) { return xs.reduce((a,b)=>a+b,0) / xs.length; }
function p95(xs) { const s = [...xs].sort((a,b)=>a-b); return s[Math.floor(s.length * 0.95)]; }
function parseArgs(argv) {
  const o = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith('--')) o[argv[i].slice(2)] = argv[i+1];
  }
  return o;
}
