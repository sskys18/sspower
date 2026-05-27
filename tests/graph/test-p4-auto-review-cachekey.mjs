#!/usr/bin/env node
// P4 Task 11.3 — auto-review.sh cache-key behavior.
//
// Strategy: extract the HASH_INPUT construction lines from auto-review.sh
// into a small bash probe with controlled env vars, then assert:
//   1. graph-absent  => HASH_INPUT byte-identical to pre-graph form
//   2. graph-present => HASH_INPUT extended with GRAPH_VERSION|GRAPH_HASH
//   3. different version file content => different HASH_INPUT
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'sspower-cachekey-'));

// Minimal probe: same constants the hook would compute pre-cache.
// Mirrors hooks/auto-review.sh lines 247-265 (pre-edit) + appended block.
const PROBE = `
set -u
REPO_ROOT="\${REPO_ROOT:-}"
HEAD_SHA="\${HEAD_SHA:-deadbeef}"
BRANCH="\${BRANCH:-main}"
DIFF_SHA="\${DIFF_SHA:-cafef00d}"
HASH_INPUT=$(printf '%s|%s|%s|%s' "\${REPO_ROOT:-}" "$HEAD_SHA" "$BRANCH" "$DIFF_SHA")
if [ -n "$REPO_ROOT" ] && [ -f "$REPO_ROOT/.claude/graph/version" ]; then
  GRAPH_VERSION=$(head -1 "$REPO_ROOT/.claude/graph/version" 2>/dev/null | tr -d '\\n')
  GRAPH_HASH=$(sha256sum "$REPO_ROOT/.claude/graph/version" 2>/dev/null | cut -c1-16)
  [ -z "$GRAPH_HASH" ] && GRAPH_HASH=$(shasum -a 256 "$REPO_ROOT/.claude/graph/version" 2>/dev/null | cut -c1-16)
  HASH_INPUT="\${HASH_INPUT}|\${GRAPH_VERSION}|\${GRAPH_HASH}"
fi
printf '%s' "$HASH_INPUT"
`;

function probe(env) {
  const r = spawnSync('bash', ['-c', PROBE], {
    env: { ...process.env, ...env }, encoding: 'utf8',
  });
  if (r.status !== 0) throw new Error(`probe failed: ${r.stderr}`);
  return r.stdout;
}

// Sanity: probe matches what auto-review.sh would actually compute.
// Read auto-review.sh and confirm the two markers we depend on exist.
const ARSH = fs.readFileSync(
  path.resolve(path.dirname(new URL(import.meta.url).pathname), '..', '..', 'hooks', 'auto-review.sh'),
  'utf8',
);
assert.ok(ARSH.includes('GRAPH_VERSION=$(head -1 "$REPO_ROOT/.claude/graph/version"'),
  'auto-review.sh missing graph cache-key append block');
assert.ok(ARSH.includes('HASH_INPUT="${HASH_INPUT}|${GRAPH_VERSION}|${GRAPH_HASH}"'),
  'auto-review.sh missing HASH_INPUT extension');

// --- Case 1: graph absent — graph-present env vars must produce the
// same HASH_INPUT as the pre-graph form (no append).
const baseEnv = { REPO_ROOT: TMP, HEAD_SHA: 'abc', BRANCH: 'main', DIFF_SHA: 'def' };
const expectedPreGraph = `${TMP}|abc|main|def`;
const noGraph = probe(baseEnv);
assert.equal(noGraph, expectedPreGraph,
  `graph-absent HASH_INPUT must equal pre-graph form; got: ${JSON.stringify(noGraph)}`);

// --- Case 2: graph present (v1) — HASH_INPUT extended with version + hash
fs.mkdirSync(path.join(TMP, '.claude', 'graph'), { recursive: true });
fs.writeFileSync(path.join(TMP, '.claude', 'graph', 'version'), 'schema=1 build=20260527\n');
const withGraphV1 = probe(baseEnv);
assert.notEqual(withGraphV1, expectedPreGraph,
  'graph-present HASH_INPUT must differ from pre-graph form');
assert.ok(withGraphV1.startsWith(expectedPreGraph + '|'),
  `extended HASH_INPUT must prefix-match pre-graph form; got: ${withGraphV1}`);
const parts = withGraphV1.split('|');
assert.equal(parts.length, 6, `expected 6 |-separated terms, got ${parts.length}`);
assert.equal(parts[4], 'schema=1 build=20260527', `GRAPH_VERSION wrong: ${parts[4]}`);
assert.equal(parts[5].length, 16, `GRAPH_HASH should be 16 chars, got ${parts[5].length}`);

// --- Case 3: graph version changes => HASH_INPUT changes
fs.writeFileSync(path.join(TMP, '.claude', 'graph', 'version'), 'schema=2 build=20260601\n');
const withGraphV2 = probe(baseEnv);
assert.notEqual(withGraphV2, withGraphV1,
  `different version content must produce different HASH_INPUT: v1=${withGraphV1} v2=${withGraphV2}`);

// Cleanup
try { fs.rmSync(TMP, { recursive: true, force: true }); } catch {}
console.log('OK auto-review cache-key: graph-absent byte-identical, graph-present extended, version-bump invalidates');
