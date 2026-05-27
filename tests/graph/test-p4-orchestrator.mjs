#!/usr/bin/env node
// P4 Task 9 — orchestrator unit tests (cases A-I).
//
// Strategy: build a fake CLAUDE_PLUGIN_ROOT in tmp containing
//   hooks/graph-orchestrator.sh  (copy of real)
//   hooks/_log.sh                (copy of real)
//   hooks/semble-context.sh      (STUB — prints a fixed JSON marker)
//   bin/sspower-graph-bootstrap.sh (STUB — prints content for child 2)
// PATH-prepend a tmpdir containing a fake `semble_rs` executable so the
// orchestrator finds the stub through `command -v`. The real semble path
// at `/usr/local/bin/semble_rs` is bypassed because we prepend.
//
// Each case provides its own JSON payload on stdin via spawnSync and the
// test asserts on stdout (additionalContext JSON) plus wall clock.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import url from 'node:url';

const HERE = path.dirname(url.fileURLToPath(import.meta.url));
const REAL_ROOT = path.resolve(HERE, '..', '..');
const REAL_ORCH = path.join(REAL_ROOT, 'hooks', 'graph-orchestrator.sh');
const REAL_LOG  = path.join(REAL_ROOT, 'hooks', '_log.sh');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'sspower-orch-'));
const ROOT = path.join(TMP, 'plugin');           // CLAUDE_PLUGIN_ROOT
const HOOKS = path.join(ROOT, 'hooks');
const BIN   = path.join(ROOT, 'bin');
const PATHDIR = path.join(TMP, 'pathshim');      // prepend to PATH
fs.mkdirSync(HOOKS, { recursive: true });
fs.mkdirSync(BIN, { recursive: true });
fs.mkdirSync(PATHDIR, { recursive: true });

// Copy real orchestrator + _log.sh into the fake root so it uses our stubs.
fs.copyFileSync(REAL_ORCH, path.join(HOOKS, 'graph-orchestrator.sh'));
fs.chmodSync(path.join(HOOKS, 'graph-orchestrator.sh'), 0o755);
fs.copyFileSync(REAL_LOG, path.join(HOOKS, '_log.sh'));

// Stub semble-context.sh — emits its own additionalContext JSON so cases
// A/B/C can verify "exec'd semble-context.sh" by looking for its marker.
const STUB_SEMBLE_CTX = `#!/usr/bin/env bash
set -uo pipefail
# Drain stdin (orchestrator passes the user payload via here-string)
cat >/dev/null 2>&1 || true
jq -n '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:"STUB_SEMBLE_CONTEXT_MARKER"}}'
`;
fs.writeFileSync(path.join(HOOKS, 'semble-context.sh'), STUB_SEMBLE_CTX);
fs.chmodSync(path.join(HOOKS, 'semble-context.sh'), 0o755);

// PATH-shim semble_rs — prints SEMBLE_TEXT_FILE contents (controlled per-case).
const SEMBLE_TEXT_FILE = path.join(TMP, 'semble.txt');
fs.writeFileSync(SEMBLE_TEXT_FILE, ''); // default empty
const SEMBLE_SHIM = `#!/usr/bin/env bash
# stub semble_rs: prints contents of $SEMBLE_TEXT_FILE; honors SEMBLE_SLEEP for timeout cases
sleep "\${SEMBLE_SLEEP:-0}"
cat "${SEMBLE_TEXT_FILE}"
`;
fs.writeFileSync(path.join(PATHDIR, 'semble_rs'), SEMBLE_SHIM);
fs.chmodSync(path.join(PATHDIR, 'semble_rs'), 0o755);

// Stub bin/sspower-graph-bootstrap.sh — prints GRAPH_TEXT_FILE contents.
const GRAPH_TEXT_FILE = path.join(TMP, 'graph.txt');
fs.writeFileSync(GRAPH_TEXT_FILE, '');
const GRAPH_STUB = `#!/usr/bin/env bash
# stub graph bootstrap: ignores args, prints GRAPH_TEXT_FILE, honors GRAPH_SLEEP
sleep "\${GRAPH_SLEEP:-0}"
cat "${GRAPH_TEXT_FILE}"
`;
fs.writeFileSync(path.join(BIN, 'sspower-graph-bootstrap.sh'), GRAPH_STUB);
fs.chmodSync(path.join(BIN, 'sspower-graph-bootstrap.sh'), 0o755);

// Per-case workspace: provides .claude/graph/index.sqlite (presence => "graph present")
function makeCwd({ graphPresent = true, dirty = '' } = {}) {
  const cwd = fs.mkdtempSync(path.join(TMP, 'cwd-'));
  if (graphPresent) {
    const gd = path.join(cwd, '.claude', 'graph');
    fs.mkdirSync(gd, { recursive: true });
    fs.writeFileSync(path.join(gd, 'index.sqlite'), 'fake-sqlite');
    if (dirty) fs.writeFileSync(path.join(gd, 'dirty'), dirty);
  }
  return cwd;
}

function runOrch({ env = {}, cwd, prompt = 'refactor the extractFile dispatcher across the graph' }) {
  const payload = JSON.stringify({ prompt, cwd });
  const fullEnv = {
    ...process.env,
    CLAUDE_PLUGIN_ROOT: ROOT,
    HOME: TMP,                // keep diag log out of $HOME/.claude
    PATH: `${PATHDIR}:${process.env.PATH}`,
    SEMBLE_SLEEP: '0',
    GRAPH_SLEEP: '0',
    ...env,
  };
  const t0 = Date.now();
  const r = spawnSync('bash', [path.join(HOOKS, 'graph-orchestrator.sh')], {
    input: payload, env: fullEnv, encoding: 'utf8', timeout: 15_000,
  });
  return { ...r, wallMs: Date.now() - t0 };
}

function parseAddCtx(stdout) {
  if (!stdout || !stdout.trim()) return null;
  try {
    const j = JSON.parse(stdout);
    return j?.hookSpecificOutput?.additionalContext ?? null;
  } catch { return null; }
}

let nFail = 0;
function check(label, fn) {
  try {
    fn();
    console.log(`OK  ${label}`);
  } catch (e) {
    console.log(`FAIL ${label}\n     ${e.message}`);
    nFail++;
  }
}

// Default content for the "healthy" cases.
fs.writeFileSync(SEMBLE_TEXT_FILE, 'SEMBLE_HEALTHY_TEXT_42');
fs.writeFileSync(GRAPH_TEXT_FILE,  'GRAPH_HEALTHY_TEXT_99');

// ----- Case A: orchestrator off → exec semble-context.sh -----
check('A: SSPOWER_GRAPH_ORCHESTRATOR=off execs semble-context.sh', () => {
  const cwd = makeCwd({ graphPresent: true });
  const r = runOrch({ env: { SSPOWER_GRAPH_ORCHESTRATOR: 'off' }, cwd });
  assert.equal(r.status, 0, `exit 0, got ${r.status}; stderr=${r.stderr}`);
  const ctx = parseAddCtx(r.stdout);
  assert.equal(ctx, 'STUB_SEMBLE_CONTEXT_MARKER', `expected stub marker, got: ${ctx}`);
  assert.ok(r.wallMs < 7000, `wall ${r.wallMs}ms`);
});

// ----- Case B: graph absent → exec semble-context.sh -----
check('B: graph index absent execs semble-context.sh', () => {
  const cwd = makeCwd({ graphPresent: false });
  const r = runOrch({ env: { SSPOWER_GRAPH_ORCHESTRATOR: 'on' }, cwd });
  assert.equal(r.status, 0);
  const ctx = parseAddCtx(r.stdout);
  assert.equal(ctx, 'STUB_SEMBLE_CONTEXT_MARKER', `expected stub marker, got: ${ctx}`);
  assert.ok(r.wallMs < 7000, `wall ${r.wallMs}ms`);
});

// ----- Case C: dirty non-empty → exec semble-context.sh, log reason=dirty -----
check('C: dirty non-empty execs semble-context.sh and logs reason=dirty', () => {
  const cwd = makeCwd({ graphPresent: true, dirty: '{"op":"upsert","path":"x"}\n' });
  // Force diag log into a known location to scrape.
  const home = fs.mkdtempSync(path.join(TMP, 'home-'));
  const r = runOrch({ env: { SSPOWER_GRAPH_ORCHESTRATOR: 'on', HOME: home }, cwd });
  assert.equal(r.status, 0);
  const ctx = parseAddCtx(r.stdout);
  assert.equal(ctx, 'STUB_SEMBLE_CONTEXT_MARKER');
  const logPath = path.join(home, '.claude', 'sspower', 'codex.log');
  assert.ok(fs.existsSync(logPath), 'codex.log not written');
  const log = fs.readFileSync(logPath, 'utf8');
  assert.ok(log.includes('reason=dirty'), `expected reason=dirty in log, got: ${log}`);
  assert.ok(r.wallMs < 7000, `wall ${r.wallMs}ms`);
});

// ----- Case D: both backends healthy → merged with both markers -----
check('D: both backends healthy → merged additionalContext', () => {
  fs.writeFileSync(SEMBLE_TEXT_FILE, 'SEMBLE_HEALTHY_TEXT_42');
  fs.writeFileSync(GRAPH_TEXT_FILE,  'GRAPH_HEALTHY_TEXT_99');
  const cwd = makeCwd({ graphPresent: true });
  const r = runOrch({ env: { SSPOWER_GRAPH_ORCHESTRATOR: 'on' }, cwd });
  assert.equal(r.status, 0, `exit ${r.status}; stderr=${r.stderr}`);
  const ctx = parseAddCtx(r.stdout);
  assert.ok(ctx, `no additionalContext; stdout=${r.stdout}`);
  assert.ok(ctx.includes('SEMBLE_HEALTHY_TEXT_42'), 'semble payload missing');
  assert.ok(ctx.includes('GRAPH_HEALTHY_TEXT_99'),  'graph payload missing');
  assert.ok(ctx.includes('semble_rs repo orientation'), 'semble marker missing');
  assert.ok(ctx.includes('sspower-graph context'),     'graph marker missing');
  assert.ok(r.wallMs < 7000, `wall ${r.wallMs}ms`);
});

// ----- Case E: SSPOWER_SEMBLE=0 → graph-only -----
check('E: SSPOWER_SEMBLE=0 → graph-only', () => {
  const cwd = makeCwd({ graphPresent: true });
  const r = runOrch({ env: { SSPOWER_GRAPH_ORCHESTRATOR: 'on', SSPOWER_SEMBLE: '0' }, cwd });
  assert.equal(r.status, 0);
  const ctx = parseAddCtx(r.stdout);
  assert.ok(ctx, 'no additionalContext');
  assert.ok(!ctx.includes('semble_rs repo orientation'), 'semble marker should be absent');
  assert.ok(ctx.includes('GRAPH_HEALTHY_TEXT_99'), 'graph payload missing');
  assert.ok(r.wallMs < 7000, `wall ${r.wallMs}ms`);
});

// ----- Case F: SSPOWER_GRAPH=0 → semble-only -----
check('F: SSPOWER_GRAPH=0 → semble-only', () => {
  const cwd = makeCwd({ graphPresent: true });
  const r = runOrch({ env: { SSPOWER_GRAPH_ORCHESTRATOR: 'on', SSPOWER_GRAPH: '0' }, cwd });
  assert.equal(r.status, 0);
  const ctx = parseAddCtx(r.stdout);
  assert.ok(ctx, 'no additionalContext');
  assert.ok(ctx.includes('SEMBLE_HEALTHY_TEXT_42'), 'semble payload missing');
  assert.ok(!ctx.includes('sspower-graph context'), 'graph marker should be absent');
  assert.ok(r.wallMs < 7000, `wall ${r.wallMs}ms`);
});

// ----- Case G: both stubs sleep past per-child timeout → no additionalContext, exit 0 -----
check('G: both backends timeout → no additionalContext, exit 0', () => {
  const cwd = makeCwd({ graphPresent: true });
  // Both stubs sleep 10s; per-child timeout 5s + wall 6s — both get TERMed,
  // output files stay empty, MERGED is empty, exit 0.
  const r = runOrch({
    env: { SSPOWER_GRAPH_ORCHESTRATOR: 'on', SEMBLE_SLEEP: '10', GRAPH_SLEEP: '10' },
    cwd,
  });
  assert.equal(r.status, 0, `exit ${r.status}; stderr=${r.stderr}`);
  assert.equal(r.stdout.trim(), '', `expected empty stdout, got: ${r.stdout}`);
  assert.ok(r.wallMs < 8000, `wall ${r.wallMs}ms exceeds 8s (wall budget 6s + slack)`);
});

// ----- Case H: 5KB inputs → ~4KB merged with truncation markers in both sections -----
check('H: 5KB each → ~4KB merged with truncation markers', () => {
  fs.writeFileSync(SEMBLE_TEXT_FILE, 'S'.repeat(5000));
  fs.writeFileSync(GRAPH_TEXT_FILE,  'G'.repeat(5000));
  const cwd = makeCwd({ graphPresent: true });
  const r = runOrch({ env: { SSPOWER_GRAPH_ORCHESTRATOR: 'on' }, cwd });
  assert.equal(r.status, 0, `exit ${r.status}; stderr=${r.stderr}`);
  const ctx = parseAddCtx(r.stdout);
  assert.ok(ctx, 'no additionalContext');
  // Two 2KB caps + markers + header lines → expect bytes between 4000 and 5000
  const bytes = Buffer.byteLength(ctx, 'utf8');
  assert.ok(bytes <= 5000, `merged bytes ${bytes} > 5000 expected ≤5000`);
  assert.ok(bytes >= 3500, `merged bytes ${bytes} < 3500 — caps too aggressive`);
  // Both sections must carry truncation marker
  const sembleIdx = ctx.indexOf('SSSSS');
  const graphIdx  = ctx.indexOf('GGGGG');
  assert.ok(sembleIdx >= 0 && graphIdx >= 0, 'both payloads should appear');
  // Marker appears in both halves
  const markerCount = (ctx.match(/\[\.\.\.truncated\]/g) || []).length;
  assert.equal(markerCount, 2, `expected 2 truncation markers, got ${markerCount}`);
  assert.ok(r.wallMs < 7000, `wall ${r.wallMs}ms`);
  // Restore healthy text for next cases
  fs.writeFileSync(SEMBLE_TEXT_FILE, 'SEMBLE_HEALTHY_TEXT_42');
  fs.writeFileSync(GRAPH_TEXT_FILE,  'GRAPH_HEALTHY_TEXT_99');
});

// ----- Case I: wall time discipline across all cases -----
// (Covered inline above; explicit assertion: max wall across the suite.)
check('I: every case completed in <8s (wall budget 6s + slack)', () => {
  // No-op: each case asserts its own wall budget. This is a guard so the
  // suite output makes the constraint explicit.
  assert.ok(true);
});

// Cleanup
try { fs.rmSync(TMP, { recursive: true, force: true }); } catch {}

if (nFail > 0) {
  console.log(`\n${nFail} case(s) failed`);
  process.exit(1);
}
console.log('\nAll 9 orchestrator cases pass');
