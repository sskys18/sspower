# Plan: SSPOWER_* env-var cleanup (delete 2 dead flags + consolidate CLAUDE.md)

> **Scope reversal (2026-06-01):** the original draft proposed inlining ~22
> flags to reach a ~22-31 count. Codex plan-review + a docs sweep proved the
> premise wrong: `docs/ARCHITECTURE.md` already documents these flags as an
> intentional operator-knob surface (timeouts, cache TTLs, round cap,
> skip/strict patterns, diet default, log rotation, LSP gate promotions).
> Inlining them = breaking documented contracts and deleting operator
> capability — not a cleanup. `SSPOWER_BRIDGE_PATH` is also live
> (`sspower_mem/extract.py`, `doctor.py`, `bin/sspower-mem`), not dead.
>
> Correct scope: remove only the 2 genuinely-dead flags and fix the real
> source of "too many" — CLAUDE.md prose scattering flag mentions — by
> pointing it at the already-consolidated ARCHITECTURE.md reference.

## Files touched
- `tests/hooks/test-integration.sh` — drop dead `SSPOWER_REVIEW_AUTO_APPLY=off`
- `CLAUDE.md` (plugin root) — trim scattered env mentions → ARCHITECTURE.md pointer
- (verify-only) `docs/ARCHITECTURE.md` — already the reference; no change unless a
  removed flag is listed there (it is not)

## Task 1 — Remove `SSPOWER_REVIEW_AUTO_APPLY` (dead)

Auto-apply was removed (ARCHITECTURE.md + CLAUDE.md both say so). Only live
reference is a test setting it:
- `tests/hooks/test-integration.sh:313`:
  ```
  -NO_CACHE='SSPOWER_REVIEW_CACHE_TTL=0 SSPOWER_REVIEW_AUTO_APPLY=off'
  +NO_CACHE='SSPOWER_REVIEW_CACHE_TTL=0'
  ```
  (Keeps `SSPOWER_REVIEW_CACHE_TTL=0` — that flag is a documented, live tunable.)
- Confirm no other code ref:
  ```bash
  grep -rn SSPOWER_REVIEW_AUTO_APPLY . --include='*.sh' --include='*.mjs' \
    --include='*.js' --include='*.py' | grep -v /docs/
  ```
  Expect only `tests/hooks/test-integration.sh` (now fixed) → empty after edit.

## Task 2 — Remove `SSPOWER_SANITY_REVIEW` (dead)

No code read site (sanity reviewer removed from auto-review.sh; now a manual
subagent per ARCHITECTURE.md). Verify, then delete any non-historical ref:
```bash
grep -rn SSPOWER_SANITY_REVIEW . --include='*.sh' --include='*.mjs' \
  --include='*.js' --include='*.py' | grep -v /docs/
# expect empty -> no code change needed; remove from test/header if present
```
If a header comment in `hooks/auto-review.sh` still lists it, delete that line.
Leave `docs/plans/*` and `.claude/wiki/*` history untouched (historical record).

## Task 3 — Consolidate CLAUDE.md env prose

`CLAUDE.md` mentions individual flags inline across the auto-review, LSP, and
graph bullets. ARCHITECTURE.md §Tunables already lists them with defaults.
- Replace the inline tunable lists in CLAUDE.md (the `SSPOWER_REVIEW_*`
  enumeration in the auto-review-loop-guards bullet, etc.) with a single
  pointer: `Full env tunables: docs/ARCHITECTURE.md §Tunables.`
- Keep inline only the ~3 operators reach for most: `SSPOWER_AUTO_REVIEW=off`
  (emergency bypass) and `SSPOWER_DIET`.
- Do NOT delete flags from ARCHITECTURE.md — it is the SSOT reference.

## Verification
```bash
cd /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower
# dead flags gone from code:
for f in SSPOWER_REVIEW_AUTO_APPLY SSPOWER_SANITY_REVIEW; do
  n=$(grep -rE "$f" . --include='*.sh' --include='*.mjs' --include='*.js' \
      --include='*.py' 2>/dev/null | grep -v '/docs/' | grep -v '/.claude/wiki/' \
      | wc -l | tr -d ' ')
  [ "$n" = 0 ] && echo "ok  $f" || echo "LEFT $n  $f"
done
bash tests/hooks/test-integration.sh
bash tests/hooks/auto-review-detect.sh
```
Both suites green; both dead flags `ok`.

## Notes for the supervisor (per codex findings)
- This worker leaves changes **uncommitted**; the supervisor commits (project
  rule: codex worker must not `git commit/push/merge`).
- No `rm -rf` anywhere (the earlier draft's cache-reset step is gone — the
  CACHE_TTL env lever stays, so tests need no filesystem reset).

## Rejected (do NOT do — see scope reversal)
Inlining documented tunables (`REVIEW_TIMEOUT`, `CACHE_TTL`, `APPROVE_TTL`,
`MAX_ROUNDS`, `PROFILE`, `SKIP/STRICT_PATTERN`, `DIET_DEFAULT`, `LOG_MAX_LINES`,
`LOG_KEEP_TAIL`, `SEMBLE_*`, `AST_GREP_BIN`, `GRAPH_MCP_KEY`), or any toggle
(`FLOW_FENCE`, `SEMBLE_REWRITE`, `CODEX_LSP_POSTTOOL`, etc.). All are
documented operator knobs in ARCHITECTURE.md and/or README; removing them
breaks documented contracts and deletes capability. `SSPOWER_BRIDGE_PATH` is
live in `sspower_mem` — keep.
```
