# Session Handoff
> Generated: 2026-05-16 06:25 KST

## Task
Phase E — rewrite `hooks/wiki-archive.py` and `hooks/session-start` to call `sspower-mem` (per spec §6.5 + §9 Phase E). Phase D `sspower-mem migrate` shipped to `main`.

## Status

### Completed (on `main` @ `e8801dc`)
- **Phase D v0.3.0**: PR #5 merged 2026-05-16T06:18:29Z. `sspower-mem migrate` imports legacy wiki + user-global memory into Phase C digest + Mem0 index. 14 commits.
- **Codex `implement` effort default**: `xhigh` → `high` (caused stalls). `complete` stays `minimal`. Security pass in `auto-review.sh` keeps `xhigh` via `SSPOWER_SECURITY_EFFORT`.
- **Tests**: 152 pytest + 14 bridge = 166 green.

### In Progress
- _(nothing in flight)_

## Resume Here
1. Invoke `sspower:writing-plans`: "Write Phase E plan from `docs/specs/2026-05-13-index-backend-integration-design.md` §6.5 + §9 Phase E. Output: `docs/plans/2026-05-1X-sspower-mem-phase-e.md`."
2. Plan body covers: rewrite `hooks/wiki-archive.py` write tail to call `sspower-mem add` (replacing direct file appends); rewrite `hooks/session-start` to append `sspower-mem search` results to `additionalContext`; introduce `sspower_mem_call` bash wrapper (returns 0, communicates rc via global `SSP_RC`) per spec §6.5 to play nicely with `set -euo pipefail` in existing hooks.
3. Commit plan on `phase-e` branch (auto-spec-gate fires; iterate if Codex flags).
4. Switch to `sspower:subagent-driven-development` for implementation.
5. After Phase E green: Phase F (verification + archive legacy `wiki/sessions/`, `wiki/decisions.md`, `wiki/gotchas.md` under `wiki/_legacy_pre_idx/`).

## Decisions (do NOT revisit)

### Phase C (still binding)
- **Metadata correlation key = `block_id`, NOT `id`** — Mem0 reserves `metadata.id`.
- **`LlmConfig`/`EmbedderConfig` via `model_construct`** — bypass hardcoded provider allow-list.
- **`VectorStoreConfig` via full validation** — chroma IS allow-listed.
- **`mem.vector_store.client` for chromadb ops** — Chroma singleton-per-path enforcement.
- **Phase A tests default to fake bridge fixture** — `tests/fixtures/fake_bridge.sh` + empty-facts envelope.

### Phase D (locked this session)
- **Sessions `.md` is migration unit; `.json` provenance-only.** Orphan `.json` skipped. Rejected: double-ingest of pair (defeats dedup since base_ids differ).
- **`MEMORY.md` hard-skipped** under user-global enumeration (it's an index, not content).
- **decisions/gotchas split**: H2 wins over HR. Stub files (H1 only) yield zero blocks. First match wins per file.
- **`--reextract` delegates to `cmd_digest --rebuild-chroma --reextract all`** per scope. Rejected: parallel reextract path in Phase D.
- **`--dry-run` is strict no-op** — no lock, no bootstrap, no writes. Stdout-only plan JSON.
- **`_clear_extracted_only_via` scopes by `scope_id_str`** — Phase D PR #5 review caught silent cross-scope wipe. Filter `where={"$and":[{"kind":"extracted"},{"scope":scope_id_str}]}`. Rejected: full clear (drops other scope's facts when cross-scope reextract iterates).
- **Codex `implement` effort = `high`** (was `xhigh`). Rejected: xhigh caused stalls.

## Gotchas

### Phase D
- **`cmd_migrate` captures `cmd_add` stdout via `io.StringIO` swap** to harvest the per-block JSON line. Any future change to `cmd_add` adding more stdout lines breaks `_add_fn`'s `json.loads`. Keep `cmd_add` printing exactly one JSON line at end-of-function. **Verified safe today** by independent reviewer (no stdout from any transitive callee).
- **`_split_blocks` does NOT honor fenced code blocks** — a `## ` inside ` ``` ` fence splits as a real H2. Only affects `decisions.md`/`gotchas.md` (sessions don't use splitter). **Phase E follow-up** if users put markdown-about-markdown there.
- **Test 10 reframed**: plan asked top-5 idx-recall ≥ 9/10 → actual test uses `--mode recent` (digest-only enumeration). Embedder accuracy is Phase C scope. **Phase F follow-up**: restore real idx-recall against curated content fixture.

### Codex bridge
- **Codex usage limit until 2026-05-19 11:27 AM** — fresh interactive `codex` calls fail with "You've hit your usage limit." Earlier auto-review/auto-spec-gate passed via verdict cache (10min TTL at `~/.cache/sspower/verdicts/`). Plan for next session: either wait, top up credits, or use independent Claude reviewer as Codex stand-in (worked for PR #5).
- **`~/.codex/config.toml` line 182 had orphan duplicate** — fixed this session. Watch for similar editor-paste artifacts.

### Pre-existing followups (still deferred)
- Plan `docs/plans/2026-05-13-sspower-mem-phase-c.md` references OLD import paths + `id` key (informational; impl is correct).
- Spec `docs/specs/2026-05-13-index-backend-integration-design.md` §6.1 D11 pseudocode uses `meta["id"]`; amend to `meta["block_id"]` (low priority).
- `bootstrap` returns `status="degraded"` whenever bridge unreachable; Phase A tests accept both.

## Context

- **Branch**: `main` @ `e8801dc` (in sync with origin). No in-flight branches.
- **Tests**: 152/152 pytest (`cd scripts/sspower_mem && UV_CACHE_DIR=/private/tmp/sspower-uv-cache uv run --with pytest pytest`); 14/14 bridge (`bash tests/codex-bridge/test-complete.sh`).
- **Phase D PR**: https://github.com/sskys18/sspower/pull/5 (merged).
- **Phase D plan**: `docs/plans/2026-05-15-sspower-mem-phase-d.md` (executed; post-impl amendments appended).
- **Spec for Phase E**: `docs/specs/2026-05-13-index-backend-integration-design.md` §6.5 (hook wrapper exit normalization) + §9 Phase E (bullets).
- **Reference patterns**: `scripts/sspower_mem/sspower_mem/cli.py` (cmd_add / cmd_search / cmd_migrate); `hooks/wiki-archive.py` (current direct-write tail to rewrite); `hooks/session-start` (current — needs `additionalContext` injection).
- **Bridge defaults post-tweak**: model `gpt-5.5`, effort `high` (implement) / `minimal` (complete), 60s wall cap. Security pass uses `xhigh` via `SSPOWER_SECURITY_EFFORT` only.
- **Unknowns (verify before Phase E)**:
  - Real shape of `additionalContext` field in SessionStart hook payload — read `hooks/session-start` head + Claude Code hook schema before drafting injection.
  - Whether `hooks/wiki-archive.py` (Python) or shell-wrapper has the write tail — file inventory needed.
  - Test infra for hooks: does Phase D's fake-bridge fixture cover SessionStart? `tests/codex-bridge/` shells out — likely need a separate hook-level harness.
