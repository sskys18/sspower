# sspower-graph P0 — Codex review followups

Codex `review` verdict: `approve-with-followups` (2026-05-26, session
019e6244-6e17-7810-8cb6-17314a636c0f).

## Resolved inline (in feat/graph-P0)

### A1. Lockfile reproducibility on npm fallback path
- **Original:** `bun.lock` committed but `bin/sspower-graph-bootstrap.sh`
  npm fallback had no `package-lock.json` → fresh installs via npm could
  resolve different `@modelcontextprotocol/sdk` versions than tested.
- **Fix:** bun-only — npm fallback removed. Bootstrap fails fast if bun
  is absent on first run with a clear message. Matches `packageManager`
  declaration in `package.json` and the committed `bun.lock`.

### A2. Node 22 runtime gate
- **Original:** `engines.node ≥22` documented but not enforced; users on
  older Node could install and fail later when P2 code lands.
- **Fix:** bootstrap reads `process.versions.node`, exits 1 with a clear
  error if major version < 22. Belt-and-suspenders alongside
  `engines.node`.

### A3. Lock concurrency test race
- **Original:** `test_with_lock_blocks_concurrent` used `time.sleep(0.2)`
  to assume first child had the lock; under load, second child could
  start first and assert `["B","A"]`.
- **Fix:** first child writes a `ready` marker file AFTER lock
  acquisition; parent polls (≤5s deadline) until marker appears, THEN
  launches second child. Deterministic ordering.

## Outstanding (none)

No remaining items. P0 ready for tag + merge.
