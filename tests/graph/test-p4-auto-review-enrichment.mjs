#!/usr/bin/env node
// P4 Task 11.3 — auto-review.sh enrichment block behavior.
//
// Strategy: replay the enrichment block via a small bash probe with a
// stubbed sspower-graph binary on PATH. We can't drive the full
// auto-review.sh (codex bridge dep), so the probe wraps just the block
// between the MAIN_PROMPT_FILE `EOF` and `MAIN_BRIDGE_ARGS=` lines.
//
// Stubs:
//   $PLUGIN_ROOT/bin/sspower-graph.mjs  → emits canned JSON; honors $SLEEP
//   timeout 3 from the real block
// Inputs controlled per case:
//   DIFF_FILE     — synthesized diff
//   REPO_ROOT     — tmp dir with optional .claude/graph + dirty file
//   PLUGIN_ROOT   — tmp with stub bin/sspower-graph.mjs
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const TMP_ROOT = fs.mkdtempSync(path.join(os.tmpdir(), 'sspower-enrich-'));

// Probe wraps the enrichment block + an additional line to print the
// resulting MAIN_PROMPT_FILE content + an `IMPACT_INVOCATIONS` count for
// the parallel-cap assertion. The bin stub appends to $IMPACT_LOG every
// time it runs.
const PROBE = `
set -u
log_event() { :; }   # stub away the logger
PLUGIN_ROOT="\${PLUGIN_ROOT}"
REPO_ROOT="\${REPO_ROOT}"
DIFF_FILE="\${DIFF_FILE}"
MAIN_PROMPT_FILE="\${MAIN_PROMPT_FILE}"

# --- begin verbatim enrichment block (mirrors hooks/auto-review.sh) ---
GRAPH_ENRICH=""
GRAPH_DIR_AR="$REPO_ROOT/.claude/graph"
if [ -n "$REPO_ROOT" ] && [ -d "$GRAPH_DIR_AR" ] && [ ! -s "$GRAPH_DIR_AR/dirty" ]; then
  CHANGED=$(awk '/^diff --git / { gsub(/^a\\//,"",$3); print $3 }' "$DIFF_FILE" \\
              | sort -u | head -8)
  if [ -n "$CHANGED" ]; then
    ENRICH_TMP=$(mktemp -t sspower-autoreview-enrich-XXXXXX)
    : > "$ENRICH_TMP"
    PIDS=()
    PER_FILE_TMP=()
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      tf=$(mktemp -t sspower-autoreview-impact-XXXXXX)
      PER_FILE_TMP+=("$tf")
      (
        if command -v timeout >/dev/null 2>&1; then
          timeout 3 node "$PLUGIN_ROOT/bin/sspower-graph.mjs" impact "$f" \\
            --json --cwd "$REPO_ROOT" >"$tf" 2>/dev/null || true
        else
          node "$PLUGIN_ROOT/bin/sspower-graph.mjs" impact "$f" \\
            --json --cwd "$REPO_ROOT" >"$tf" 2>/dev/null || true
        fi
      ) &
      PIDS+=($!)
    done <<< "$CHANGED"
    for pid in "\${PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
    for tf in "\${PER_FILE_TMP[@]}"; do
      if [ -s "$tf" ]; then
        SUMMARY_LINE=$(jq -r '
          if .reason == "no-index" then empty
          else "- " + (.target_file // "?") + ": direct=" + ((.direct_count // 0)|tostring) +
               " transitive=" + ((.transitive_count // 0)|tostring)
          end
        ' "$tf" 2>/dev/null)
        [ -n "$SUMMARY_LINE" ] && printf '%s\\n' "$SUMMARY_LINE" >> "$ENRICH_TMP"
      fi
      rm -f "$tf"
    done
    if [ -s "$ENRICH_TMP" ]; then
      GRAPH_ENRICH=$(printf '\\n# Graph impact (sspower-graph; cap 8 files, 3s each)\\n%s\\n' "$(cat "$ENRICH_TMP")")
    fi
    rm -f "$ENRICH_TMP"
    printf 'ENRICH_BYTES=%d\\n' "\${#GRAPH_ENRICH}" >&2
  fi
elif [ -n "$REPO_ROOT" ] && [ -s "$GRAPH_DIR_AR/dirty" ]; then
  printf 'SKIP_REASON=dirty\\n' >&2
fi
if [ -n "$GRAPH_ENRICH" ]; then printf '%s' "$GRAPH_ENRICH" >> "$MAIN_PROMPT_FILE"; fi
# --- end verbatim enrichment block ---
exit 0
`;

function makeStubGraph(plugin, { sleep = 0, perFileSleep = {} } = {}) {
  fs.mkdirSync(path.join(plugin, 'bin'), { recursive: true });
  // The stub mimics: node sspower-graph.mjs impact <FILE> --json --cwd <REPO>
  // process.argv:  [0]=node [1]=script [2]=impact [3]=FILE ...
  const stub = `#!/usr/bin/env node
import fs from 'node:fs';
const file = process.argv[3] || 'unknown';
const sleepMap = ${JSON.stringify(perFileSleep)};
const defaultSleep = ${sleep};
const ms = sleepMap[file] ?? defaultSleep;
fs.appendFileSync(process.env.IMPACT_LOG, file + '\\n');
const sync = (ms_) => new Promise(r => setTimeout(r, ms_));
(async () => {
  if (ms > 0) await sync(ms);
  process.stdout.write(JSON.stringify({
    target_file: file,
    direct_count: 3,
    transitive_count: 7,
  }) + '\\n');
})();
`;
  const p = path.join(plugin, 'bin', 'sspower-graph.mjs');
  fs.writeFileSync(p, stub);
  fs.chmodSync(p, 0o755);
}

function makeDiff(files) {
  return files.map(f => `diff --git a/${f} b/${f}\nindex 1..2 100644\n--- a/${f}\n+++ b/${f}\n@@ -1 +1 @@\n-x\n+y\n`).join('');
}

// Stub `timeout` binary so the enrichment block's `command -v timeout`
// branch fires uniformly on macOS (no coreutils-timeout) AND linux.
// Implements the minimal subset auto-review.sh uses:
//   timeout <SECONDS> <CMD> <ARGS...>
function makeTimeoutStub(pathDir) {
  fs.mkdirSync(pathDir, { recursive: true });
  const stub = `#!/usr/bin/env node
import { spawn } from 'node:child_process';
const [, , secStr, cmd, ...args] = process.argv;
const sec = Number(secStr);
const child = spawn(cmd, args, { stdio: 'inherit' });
const killer = setTimeout(() => { try { child.kill('SIGKILL'); } catch {} }, sec * 1000);
child.on('exit', (code, sig) => {
  clearTimeout(killer);
  process.exit(sig === 'SIGKILL' ? 124 : (code ?? 0));
});
`;
  const p = path.join(pathDir, 'timeout');
  fs.writeFileSync(p, stub);
  fs.chmodSync(p, 0o755);
}

function runCase({ plugin, repo, diff, sleep = 0, perFileSleep = {} } = {}) {
  const diffFile = path.join(TMP_ROOT, `diff-${Math.random().toString(36).slice(2)}.diff`);
  const promptFile = path.join(TMP_ROOT, `prompt-${Math.random().toString(36).slice(2)}.txt`);
  const impactLog = path.join(TMP_ROOT, `impact-${Math.random().toString(36).slice(2)}.log`);
  fs.writeFileSync(diffFile, diff);
  fs.writeFileSync(promptFile, 'PROMPT_HEADER\n');
  fs.writeFileSync(impactLog, '');
  makeStubGraph(plugin, { sleep, perFileSleep });
  const pathShim = path.join(TMP_ROOT, 'pathshim-' + Math.random().toString(36).slice(2));
  makeTimeoutStub(pathShim);
  const r = spawnSync('bash', ['-c', PROBE], {
    env: {
      ...process.env,
      PATH: `${pathShim}:${process.env.PATH}`,
      PLUGIN_ROOT: plugin,
      REPO_ROOT: repo,
      DIFF_FILE: diffFile,
      MAIN_PROMPT_FILE: promptFile,
      IMPACT_LOG: impactLog,
    },
    encoding: 'utf8',
    timeout: 30_000,
  });
  return {
    status: r.status,
    stderr: r.stderr,
    promptOut: fs.readFileSync(promptFile, 'utf8'),
    invocations: fs.readFileSync(impactLog, 'utf8').split('\n').filter(Boolean),
  };
}

let nFail = 0;
function check(label, fn) {
  try { fn(); console.log(`OK  ${label}`); }
  catch (e) { console.log(`FAIL ${label}\n     ${e.message}`); nFail++; }
}

// ----- Case 1: dirty empty + 3 changed files → 3 invocations, output appended -----
check('1: clean graph + 3 files → 3 parallel invocations, enrichment appended', () => {
  const plugin = fs.mkdtempSync(path.join(TMP_ROOT, 'plugin-'));
  const repo = fs.mkdtempSync(path.join(TMP_ROOT, 'repo-'));
  fs.mkdirSync(path.join(repo, '.claude', 'graph'), { recursive: true });
  const r = runCase({
    plugin, repo,
    diff: makeDiff(['src/a.ts', 'src/b.ts', 'src/c.ts']),
  });
  assert.equal(r.status, 0, `bash exit ${r.status}; stderr=${r.stderr}`);
  assert.equal(r.invocations.length, 3, `expected 3 invocations, got ${r.invocations.length}: ${r.invocations}`);
  assert.ok(r.promptOut.includes('# Graph impact'), `enrichment header missing; prompt=${r.promptOut}`);
  for (const f of ['src/a.ts', 'src/b.ts', 'src/c.ts']) {
    assert.ok(r.promptOut.includes(f), `prompt missing ${f}`);
    assert.ok(r.promptOut.includes('direct=3 transitive=7'), 'summary line missing counts');
  }
});

// ----- Case 2: dirty non-empty → enrichment skipped, no impact runs -----
check('2: dirty non-empty → enrichment skipped, no invocations', () => {
  const plugin = fs.mkdtempSync(path.join(TMP_ROOT, 'plugin-'));
  const repo = fs.mkdtempSync(path.join(TMP_ROOT, 'repo-'));
  fs.mkdirSync(path.join(repo, '.claude', 'graph'), { recursive: true });
  fs.writeFileSync(path.join(repo, '.claude', 'graph', 'dirty'), '{"op":"upsert","path":"x"}\n');
  const r = runCase({
    plugin, repo,
    diff: makeDiff(['src/a.ts']),
  });
  assert.equal(r.status, 0, `bash exit ${r.status}; stderr=${r.stderr}`);
  assert.equal(r.invocations.length, 0, `expected 0 invocations on dirty skip, got ${r.invocations.length}`);
  assert.ok(!r.promptOut.includes('# Graph impact'), 'enrichment must be absent on dirty skip');
  assert.ok(r.stderr.includes('SKIP_REASON=dirty'), 'expected dirty skip log on stderr');
});

// ----- Case 3: 12 changed files → exactly 8 invocations (cap enforced) -----
check('3: 12 changed files → exactly 8 invocations (cap 8)', () => {
  const plugin = fs.mkdtempSync(path.join(TMP_ROOT, 'plugin-'));
  const repo = fs.mkdtempSync(path.join(TMP_ROOT, 'repo-'));
  fs.mkdirSync(path.join(repo, '.claude', 'graph'), { recursive: true });
  const files = Array.from({ length: 12 }, (_, i) => `src/f${String(i).padStart(2, '0')}.ts`);
  const r = runCase({ plugin, repo, diff: makeDiff(files) });
  assert.equal(r.status, 0, `bash exit ${r.status}; stderr=${r.stderr}`);
  assert.equal(r.invocations.length, 8,
    `expected exactly 8 invocations, got ${r.invocations.length}: ${r.invocations}`);
});

// ----- Case 4: per-file 3s timeout — one file sleeps 5s, others succeed -----
check('4: per-file 3s timeout — slow file empty, others succeed', () => {
  const plugin = fs.mkdtempSync(path.join(TMP_ROOT, 'plugin-'));
  const repo = fs.mkdtempSync(path.join(TMP_ROOT, 'repo-'));
  fs.mkdirSync(path.join(repo, '.claude', 'graph'), { recursive: true });
  // a.ts sleeps 5s (timeout kills it at 3s); b.ts + c.ts run normally
  const r = runCase({
    plugin, repo,
    diff: makeDiff(['src/a.ts', 'src/b.ts', 'src/c.ts']),
    perFileSleep: { 'src/a.ts': 5000 },
  });
  assert.equal(r.status, 0, `bash exit ${r.status}; stderr=${r.stderr}`);
  // All 3 stubs are launched (parallel); cap is fine. Stub appends to
  // IMPACT_LOG on entry, before sleep — so invocation count reflects
  // process starts, not completions.
  assert.equal(r.invocations.length, 3, `expected 3 starts, got ${r.invocations.length}`);
  // Slow file must be ABSENT from the prompt (timeout killed it before
  // it wrote stdout); fast files must appear.
  assert.ok(!r.promptOut.includes('src/a.ts'),
    `slow file should be missing from prompt; got: ${r.promptOut}`);
  assert.ok(r.promptOut.includes('src/b.ts'), 'fast file b.ts missing from prompt');
  assert.ok(r.promptOut.includes('src/c.ts'), 'fast file c.ts missing from prompt');
});

// Cleanup
try { fs.rmSync(TMP_ROOT, { recursive: true, force: true }); } catch {}

if (nFail > 0) {
  console.log(`\n${nFail} case(s) failed`);
  process.exit(1);
}
console.log('\nAll 4 enrichment cases pass');
