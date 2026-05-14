# Native Index Backend for sspower Memory — Design Spec

> Status: **ACCEPTED v8 — Phase A only** (2026-05-13). User decision after 8 Codex spec-reviews plateaued at 10–14 issues/pass (12→9→10→12→7→11→14→14, ~3.85M cumulative input tokens). The Phase A slice (digest-only plaintext backend, §9 Phase A) is well-specified and Codex-praised across all 8 passes. Phases B–F (index-backend wiring + migration + hooks/skills rewrites) are **PROVISIONAL** — they remain in this spec as design intent, but their open contracts will be re-specified after (a) Phase 0 reads the index-backend source, and (b) Phase A implementation surfaces real runtime edges. The 14 v8 issues are scoped almost entirely to Phases B–F; do NOT block Phase A on them.
>
> Next step: `writing-plans` for Phase A. HARD-GATE D10 lifted for Phase A only; remains in effect for everything else until a revised spec passes a fresh review.
> Author: Claude (Opus 4.7), 2026-05-13.
> Supersedes: v1–v4 (same file) and the Semble + index-backend dual-track proposal in `docs/handoff.md` (2026-05-12 21:30). Semble is **out of scope** (user decision 2026-05-13).

## 0. Change log

### v7 → v8 (after Codex review of v7)
- **`--idx-only` rename propagated** to all read-path references (Codex flagged 2 stale `--no-grep-fallback` mentions) (v7 missing #1 + misunderstanding #1).
- **Phase E `--cwd` propagation** — shell wrapper example + session-start rewrite now both pass `--cwd "$CLAUDE_HOOK_CWD"` / `--cwd "$payload_cwd"` explicitly (v7 missing #2 + misunderstanding #3).
- **`add --no-llm` step 2 fail = rc=10** (clarified): --no-llm only affects step 3 classification; step 2 fail still degrades (v7 missing #3 + misunderstanding #2).
- **rc=30 vs rc=10 boundary table** — startup deps (uvx, Python, doctor) = rc=30; in-add index-backend imports (lazy-loaded) = rc=10. Unambiguous (v7 missing #4).
- **`--idx-only` zero-result behavior** — empty index result = `[]` + rc=0; index-backend exception = nonzero exit (v7 missing #5).
- **`--cwd` canonicalization** — realpath() before openat anchor + hash; missing cwd = rc=20; symlink resolves cleanly (v7 missing #6).
- **fd ownership idiom** documented for both strict helpers — no double-close (v7 missing #7).
- **Migration uses `effective_id` logic** — `_dup<N>` collision handling inherited via the standard `add` call path (v7 missing #8 + misunderstanding #4).
- **Phase 0 Q#8** added — the index's metadata-filter API surface verification + fallback options (dedup-db, client-side filter, fork) (v7 missing #9).
- **`digest --rebuild-chroma` extraction behavior** specified — default = full add path with per-block `no_llm` flag respected; `--no-llm` force-skips step 3 (v7 missing #10).

### v6 → v7 (after Codex review of v6)
- **Lazy index-backend imports** in `add` step 2/3 — the upstream index library + chromadb + model2vec are NOT imported at startup; only inside step 2/3 AFTER step 1's digest append. Import failures degrade to rc=10 (not rc=30), preserving D2/D11 against dep regression (v6 missing #1).
- **Python wrapper full contract** — `wiki-archive.py` now has a Python equivalent of the shell wrapper: pre-flight `shutil.which("uvx")`, `UV_OFFLINE=1` env, `--offline` flag, exit-code normalization (non-{0,10,20} → 30). No leakage of uvx-internal exits (v6 missing #2).
- **`--cwd <path>` shared option** added to all subcommands. Hooks pass it from the hook JSON payload `cwd` field; CLI does not infer from `os.getcwd()` when called via hook (v6 missing #3).
- **`resolve_out_dir` NOT reused** for project trust-root creation — that function returns `sessions/` with central-fallback behavior. v7 introduces `safe_makedirs_strict` (openat-style mkdirat walk) and on unwritable project cwd returns rc=20 instead of falling back to a different location (v6 missing #4 + misunderstandings #1/#2).
- **writing-plans rewrite** now grammar-compliant: includes `--mode recent` (or `--query <task>`) as required by the search CLI contract (v6 missing #5).
- **`_dup<N>` propagation**: pseudocode in §6.1 now passes `effective_id` (not `base_id`) through to the index's metadata (`id`, `raw_id`). Two distinct blocks with the same 64-bit prefix get distinct records in the index (v6 missing #6).
- **`migrate --reextract` standalone mode**: synopsis updated — `--from-wiki`/`--from-memory` are OPTIONAL when `--reextract` is set; REQUIRED otherwise (v6 missing #7).
- **`--idx-only` renamed to `--idx-only`** and tightened to disable BOTH exception-fallback AND zero-result fallback. Old name only gated one path (v6 missing #8).
- **Degenerate-case rules** for all score normalizations: single hit / all-tied / empty scope / max-zero grep / shared-ts all explicitly resolved. No division-by-zero, no NaN (v6 missing #9).

### v5 → v6 (after Codex review of v5)
- **D12 row rewritten** — now correctly states digest path uses `safe_append_strict` (was still saying "no new write primitives") (v5 misunderstanding #1).
- **Wrapper rc=30 normalization** — pre-flight `command -v uvx` check + post-call exit-code collapse (anything not in {0,10,20} → 30). uvx-internal exits never leak past the wrapper (v5 missing #1).
- **`source="digest-recent"`** added to the result schema; `--mode recent` cross-scope merge defined (sort by ts desc, scope priority project>user, lex on id; score = linear ts-position normalized) (v5 missing #2).
- **the index's multi-scope score merge algorithm** — min-max normalize per scope, then concat + sort by normalized score desc + tie-break ts desc + lex on id. Result entries carry the normalized score, not the index's raw score (v5 missing #3).
- **`safe_append_strict` rejects path-traversal** components (`..`, `.`, empty) before walking. `relative_to` does not normalize these and openat would happily traverse out (v5 missing #4).
- **`append_index_entry` removed in Phase E**; `index.md` frozen to `index_legacy.md`; `digest.md` itself serves as the new grep-able index (v5 missing #5).
- **Project trust-root creation assigned**: lazy creation on first `add --scope project` via existing `resolve_out_dir(cwd)`. `doctor --bootstrap` covers user-scope only (v5 missing #6).

### v4 → v5 (after Codex review of v4)
- **Wrapper function rewritten** — under `set -euo pipefail` (the existing hooks' shell flags), a wrapper returning non-zero kills the script before the caller's case statement runs. v5 wrapper ALWAYS returns 0 and communicates rc via the global `SSP_RC`; caller dispatches on `$SSP_RC` (v4 missing #1).
- **SessionStart read mode** — added `sspower-mem search --mode recent` (no query, return top-k newest blocks; bypasses the index backend, source="digest-recent"). `hooks/session-start` uses `--mode recent`, not `--query` (v4 missing #2).
- **Phase E checklist** explicitly adds `skills/writing-plans/SKILL.md` (v4 missing #3).
- **`add --no-llm` semantics fully specified** — exits 0, JSON `extracted="skipped-intentional"`, metadata `no_llm=true`, `--reextract all` skips these (v4 missing #4).
- **Phase 0 question #7** added — verify `Memory.add(infer=True)` metadata preservation across ADD/UPDATE/NONE + LLM-adapter failure visibility. Step 3 in §6.1 relies on both (v4 missing #5).
- **Hook offline contract enforced** — wrapper invokes `UV_OFFLINE=1 uvx --offline`. Cache misses on the critical path → rc=30, never network (v4 missing #6).
- **Multi-scope search corrected** — the index's `user_id` filter is scalar (verified). v5 mapping table + read path both issue **per-scope sequential searches** and merge client-side; the v4 `user_id IN (...)` shape was wrong (v4 missing #7).
- **Mixed id width fixed** — `[:8]` → `[:16]` everywhere (§5 mapping table, §6.1 pseudocode, §7.2 migration). v4 left 3 stale `[:8]` references (v4 misunderstanding #1).
- **Primitive references consistent** — §4 preconditions row + §6.1 step-1 comment + Phase A bullet all now name `safe_append_strict`. Legacy `_safe_append_text` is explicitly limited to the legacy belt only (v4 misunderstanding #2).
- **`safe_append_strict` parent-dir model** — rewritten as `openat`-style walk: open trust_root with `O_DIRECTORY|O_NOFOLLOW`, then walk each rel component via `os.open(part, ..., dir_fd=cur_fd)`. Full chain integrity below trust_root. Trust-root model explicit: components at/above trust_root are user-owned, not atomically protected (v4 misunderstanding #3).
- **Open question #6 phrasing fixed** — "Chroma persistent (sqlite3 + HNSW)" (v4 left "DuckDB+Parquet" stale) (v4 misunderstanding #4).
- **wiki-archive.py rewrite targets** named explicitly — `write_markdown` (and decisions/gotchas seeding) rewrites to `sspower-mem add`; `write_json` stays writing `sessions/*.json` for the legacy belt (v4 misunderstanding #5).

### v3 → v4 (after Codex review of v3)
- §2 + §6.5 add **`skills/writing-plans/SKILL.md`** to the in-scope rewrites — Codex found its Pre-flight section reads `wiki/decisions.md` + `sessions/` (v3 missing #1). Verified in repo.
- §6.1 subcommand contract declares the previously-undeclared flags: `add --no-llm`, `migrate --reextract [<id>|all]` (v3 missing #2).
- §6.1 read path adds a **fully deterministic grep-fallback scoring algorithm** (tokenize → per-block hit count → size-normalized raw score → max-normalized → top-k with newest-wins, then lex tiebreak) (v3 missing #3).
- §7.1 Phase 0 question #6 added: **verify the index's v3 entity-linking / entity-store behavior** — current OSS algorithm may lazily create extra Chroma collections (v3 missing #4).
- §8 row 1 rewritten + Phase E wrapper aligned: **rc=20 always propagates** as `exit 20`. v3 had §8 "hook returns success" vs Phase E "propagates" — picked propagate, fixed §8.
- §6.1 stable id widened to `sha1[:16]` (64 bits) with explicit full-content compare + `_dup<N>` suffix on collision (v3 misunderstanding #2).
- §5 Chroma storage layout corrected: `chroma.sqlite3` + HNSW dirs, not "DuckDB+Parquet" (v3 misunderstanding #3, sourced).
- §9 Phase E wrapper rewritten as a shell **function** (`sspower_mem_call`) returning `$SSP_RC`, with caller doing `exit 20` in script context. v3 used bare `return 20` which is invalid at script top-level (v3 misunderstanding #4).
- §6.2 specifies the achievable Codex CLI tool-disable contract: `--sandbox read-only` + hard system directive + `reasoning.effort=minimal` + 60s wall cap. Full tool-off requires upstream Codex changes (out of scope) (v3 misunderstanding #5).
- §6.4 introduces **`safe_append_strict`** with `O_NOFOLLOW` on the final `os.open` — closes the TOCTOU window in the existing `_safe_append_text` for the new source-of-truth digest path. D12 amended. The legacy `_safe_append_text` is retained for legacy `sessions/*.md` writes during Phase E's one-release belt only (v3 misunderstanding #6).

### v2 → v3 (after Codex review of v2)
- §6.1 write critical section rewritten with **stable `block_id` correlation key** and explicit per-step idempotency / upsert rules. Resolves v2 missing #3 (exit code ambiguity) + #4 (de-dup/rebuild) + misunderstanding #2 (raw/extract correlation). Exit code rule is now single: step1 fail → 20; step1 ok + step2 + step3 all ok → 0; step1 ok + (step2 OR step3) failed → 10.
- §6.1 read path replaced `degraded: true` flag with explicit per-result `source: "index" | "digest-grep"` field + deterministic 4-rule order. New `--idx-only` flag. Resolves v2 missing #5 + the "non-deterministic fallback" misunderstanding.
- §9 Phase E hook wrapper bash rewritten — capture `rc=$?` BEFORE any negation/chained command (the `if ! out=$(...)` pattern in v2 hides the original exit code because `!` sets `$?` to the negated status). Resolves v2 missing #2 + misunderstanding #1.
- §6.1 exact `uvx --from <path>` launch form specified — points at `<plugin-root>/scripts/sspower_mem/` source tree. Resolves v2 missing #6.
- §9 Phase C entire block now labeled "CONTRACTS PENDING Phase 0". Every bullet keyed to the Phase 0 question it depends on. Resolves v2 missing #1 + misunderstanding #3.

### v1 → v2 (after Codex review of v1)

- **D1 inverted** to resolve Codex misunderstanding #1 — digest.md is now the **source of truth**, the index is an **indexed semantic cache** built from digest.md. Justification: user constraint "dont make it fail" + the no-rollback argument both require a plaintext durable surface. "Single backend" still holds: the legacy wiki/{sessions,decisions,gotchas}.md + auto-memory/*.md surfaces are replaced by **one** plaintext substrate (digest.md per scope) + the index as its index. No third store.
- New **§7.1 Phase 0** — read the index-backend source + write a provider-registration mini-plan **before** committing to the LLM/embedder adapter strategy. Codex source check (factory.py) found no public `provider: custom` key. Phase 0 must produce a verified mechanism (subclass / monkey-patch / fork / wrapper façade) before Phase C is unblocked.
- §6.3 rewrites the LLM/embedder strategy: every `add` now does **(a) digest write → (b) the index's `infer=False` raw add → (c) the index's `infer=True` extraction**, in that order. (b) guarantees Chroma always has the raw embedding even when Codex bridge LLM is unavailable. Resolves Codex misunderstanding #3.
- §5 pins the index's SQLite history under `~/.claude/sspower/idx/history.db` and disables upstream telemetry before any index-library import (exact env-var/module-patch identifier verified by Phase 0; D8 locks the privacy invariant, not a guessed name). Resolves Codex missing #4.
- §6.1 adds a **file lock** (`fcntl.flock` on `~/.claude/sspower/idx/.lock`) around the full add path, as a Phase A requirement. Resolves Codex missing #5.
- §6.5 (digest format) cites and reuses the existing `wiki-archive.py` symlink-safe helpers (`_has_symlink_component`, `_safe_writability_probe`, `resolve_out_dir`, `_safe_write_text`, `_safe_append_text`). Resolves Codex missing #6.
- §6.1 defines the exact scope syntax → index filter mapping. Resolves Codex missing #1.
- §9 Phase A adds an explicit **bootstrap/prefetch** step that downloads Model2Vec + warms the index before any hook starts depending on `sspower-mem`. Documents the offline contract: "After bootstrap, no network calls on any hook path." Resolves Codex missing #7.
- §9 Phase E adds a hook-wrapper exit-code normalization contract (exits 10/30 → hook exit 0 with a logged hint; exit 20 propagates). Resolves Codex missing #8.
- §6.6 corrected against real repo: hooks are `hooks/session-start` (bash, no `.sh`) and `hooks/prompt-submit`, not `session-start.sh`. There is **no** `skills/session-start/SKILL.md`; the SessionStart context-injection is hook-only. Resolves Codex misunderstanding #2.
- §12 dropped the contradictory "auto-memory md as source-of-truth" line. The user-global auto-memory is replaced by digest.md scope `user:global`. Resolves Codex misunderstanding #4.

## 1. Goal

> **Glossary.** Throughout this spec, `<index>` and "the index" / "the indexer" / "the index library" refer to the upstream OSS project at **https://github.com/mem0ai/mem0**. The library identifier is intentionally omitted from prose for branding reasons; the URL is the canonical reference for Phase 0 source verification. Concrete API surface (Python import root, factory class names, env var names, source-file paths under `<index>/...`) MUST be resolved against that upstream repo before being treated as load-bearing — see §7.1 Phase 0.

Replace sspower's two current memory surfaces — project wiki (`<cwd>/.claude/wiki/`) and global auto-memory (`~/.claude/projects/<slug>/memory/`) — with **a single plaintext substrate** (per-scope `digest.md`, written through symlink-safe helpers) plus **the index** (self-hosted, the upstream OSS index project) as a semantic cache over that substrate.

One write path (`sspower-mem add`) appends to digest.md first, then writes to the index (raw + extracted). One read path (`sspower-mem search`) queries the index and falls back to digest.md grep when the index is unavailable. Every hook + skill that currently reads/writes the wiki or auto-memory routes through this CLI.

## 2. Scope

### In scope
- New CLI `sspower-mem` (Python, `uvx`-launched) with `add` / `search` / `migrate` / `digest` / `doctor` subcommands.
- New `codex-bridge.mjs complete --json` subcommand (OpenAI-shape chat-completion).
- Codex-bridge-based index LLM adapter + Model2Vec index embedder adapter (registration mechanism TBD in Phase 0).
- Vector store: **Chroma** local-embedded, file-backed at `~/.claude/sspower/idx/chroma/`.
- Graph store: disabled.
- Plaintext substrate: per-scope `digest.md` (project-scope at `<cwd>/.claude/wiki/digest.md`, user-scope at `~/.claude/sspower/digest.md`). Append-only, block-structured, symlink-safe.
- File lock (`fcntl.flock`) around every `add` (digest + the index's raw + the index's extract = one critical section).
- Migration from existing wiki/sessions+decisions+gotchas + `~/.claude/projects/*/memory/*.md`.
- Hook rewrites: `hooks/wiki-archive.{sh,py}`, `hooks/session-start` (existing bash file).
- Skill updates: `using-sspower`, `brainstorming`, `systematic-debugging`, **`writing-plans`** (currently reads `<cwd>/.claude/wiki/decisions.md` + `sessions/` in its Pre-flight section — rewrite to call `sspower-mem search --layer decision,episodic`).

### Out of scope (this spec)
- Semble (user decision 2026-05-13).
- the cloud-hosted index service, the index's graph store, OpenMemory daemon, Qdrant.
- Multi-machine sync (each machine has its own local digest.md + Chroma).
- New skill `skills/session-start/SKILL.md` (does not currently exist; this spec does not introduce one).

## 3. Locked decisions

| # | Decision | Source / status |
|---|----------|-----------------|
| D1 | **digest.md is the source of truth. the index is an indexed semantic cache rebuildable from digest.md.** | v2 (resolves Codex misunderstanding #1). |
| D2 | Mirror-first write order + degrade-to-md fallback on every read/write. | User 2026-05-13. |
| D3 | LLM for index fact extraction = **Codex via codex-bridge.mjs OAuth**, not OpenAI API, not local LLM. | User. |
| D4 | Embedder = **Model2Vec** (`potion-base-8M`), local. | This spec. |
| D5 | Vector store = **Chroma local-embedded** at `~/.claude/sspower/idx/chroma/`. | This spec. |
| D6 | Graph store = off. | This spec. |
| D7 | Memory layers (metadata-only, not separate index collections): `episodic`, `decision`, `gotcha`, `user-global`. | Handoff. |
| D8 | Self-hosted only; **never the cloud-hosted index service**; **upstream telemetry MUST be disabled before any index-library import**. Exact opt-out mechanism (env var name, module patch, or both) verified in Phase 0 (§7.1 Q5) — D8 locks the privacy invariant, NOT a specific identifier. | Privacy. |
| D9 | No Semble. | User 2026-05-13. |
| D10 | brainstorming HARD-GATE: no implementation code until this spec passes self-review + Codex spec-review + user approval. | Handoff. |
| D11 | One write critical section: file lock → (digest append) → (the index's `infer=False` raw add) → (the index's `infer=True` extract) → release. Failures in steps 2/3 do not roll back step 1; the digest line is authoritative. | v2 (resolves Codex missing #5 + misunderstanding #3). |
| D12 | digest.md (new source-of-truth path) uses **`safe_append_strict`** (new primitive, §6.4 — `openat`-walk + `O_NOFOLLOW`, closes TOCTOU). Legacy `wiki-archive.py` helpers (`_safe_write_text`, `_safe_append_text`) are retained ONLY for the legacy `sessions/*.md` belt during Phase E. | v2 origin; v5 rewritten to reflect §6.4 amendment (v4 misunderstanding #2 + v5 misunderstanding #1). |

## 4. Verified preconditions (2026-05-13)

| Check | Result |
|-------|--------|
| `uv` / `uvx` installed | ✓ 0.9.24 at `/opt/homebrew/bin/uv{,x}`. |
| `docs/specs/` exists | ✓ created by v1. |
| `codex-bridge.mjs` subcommands today | ✓ `setup implement spec-review review rescue resume enrich ps status kill steer tail`. No `complete`. |
| Real hook surfaces | ✓ `hooks/session-start` (bash), `hooks/prompt-submit` (bash), `hooks/wiki-archive.{sh,py}` (bash + python). No `.sh` suffix on session-start. |
| Real skill surfaces | ✓ `skills/{brainstorming,systematic-debugging,using-sspower,compress-memory}/SKILL.md`. No `skills/session-start/`. |
| Symlink-safe helpers in wiki-archive.py | ✓ `_has_symlink_component` (L73), `_safe_writability_probe` (L92), `resolve_out_dir` (L122), `_safe_write_text` (L150), `_safe_append_text` (L162). The new source-of-truth digest path uses `safe_append_strict` (§6.4 — `O_NOFOLLOW`-based, closes TOCTOU). Legacy helpers retained for the legacy `sessions/*.md` belt only. |
| Codex bridge 24h reliability | ⚠️ 4 transient bridge events today, all self-recovered. Justifies D2 + D11. |

Unknowns deferred to **Phase 0** (must resolve before Phase C; see §7.1):
- the index's custom-provider registration mechanism (Codex source check found no `provider: custom` key in `<index>/utils/factory.py`).
- the index's custom-embedder factory registration.
- the index's `Memory.add(infer=False)` exact semantics (storage path, returned ids, metadata schema).
- the index's SQLite `history.db` path override mechanism.
- Whether upstream telemetry honors an env-var opt-out (exact name TBD by reading upstream source) or requires a runtime module patch.

## 5. Architecture & storage layout

```
~/.claude/sspower/
  idx/
    chroma/           # vector store (Chroma persistent layout: `chroma.sqlite3` + per-collection
                      # HNSW index dirs; the "DuckDB+Parquet" name in v3 was a stale Chroma fact —
                      # current Chroma stores SQLite + HNSW files. Source verified against
                      # https://cookbook.chromadb.dev/core/storage-layout/ during v4 review.)
    history.db        # the index backend's SQLite history (pinned here, D8)
    config.json       # the index backend's config snapshot
    .lock             # fcntl lock file for write critical section
    errors.jsonl      # degraded-write log (exit 10 path)
  digest.md           # user-global scope plaintext substrate

<cwd>/.claude/wiki/
  digest.md           # project-scope plaintext substrate (NEW: source of truth)
  _legacy_pre_idx/   # archive of pre-migration sessions/decisions/gotchas (after Phase F)
```

### Scope syntax → index filter mapping (resolves Codex missing #1)

| sspower-mem scope arg | digest.md location | index filter |
|-----------------------|---------------------|-------------|
| `--scope project` (implicit current cwd) | `<cwd>/.claude/wiki/digest.md` | `user_id = "project:<sha1(cwd)[:16]>"` |
| `--scope user` | `~/.claude/sspower/digest.md` | `user_id = "user:global"` |
| `--scope project,user` (search only) | both files concatenated for grep fallback | **Two sequential index searches** (current the index's `Memory.search` validates `filters.user_id` as a scalar entity id, not a list; verified against `<index>/memory/main.py` during v4 review). One call with `user_id="project:<hash>"`, one with `user_id="user:global"`; results merged client-side, scored against the union, top-k by score. |

`--layer <episodic|decision|gotcha|user-global>` maps to the index's `metadata.layer` (filterable but not partitioning). The `user-global` layer is only valid in the `user` scope.

Rationale for `user_id` (not `agent_id`/`run_id`): the index's main entity filter is `user_id`. We overload it as the scope key; `run_id` is per-session and would fragment retrieval. `metadata.layer` provides intra-scope filtering.

## 6. Components

### 6.1 `sspower-mem` CLI

Python package shipped as a `uvx`-runnable tool. Source at `<plugin-root>/scripts/sspower_mem/`, declared in `<plugin-root>/scripts/sspower_mem/pyproject.toml` with entry point `sspower-mem`.

**Hook launch path (exact):**
```bash
# In every hook, resolve plugin root from $CLAUDE_PLUGIN_ROOT or compute from $0:
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SSPOWER_MEM_SRC="$PLUGIN_ROOT/scripts/sspower_mem"
# Dev (this repo): --from points to the local source tree.
uvx --from "$SSPOWER_MEM_SRC" sspower-mem "$@"
```
- The `--from <path>` form points `uvx` at the local source tree (no PyPI publish required). `uv` caches the resolved env at `~/.cache/uv/`.
- If we ever publish to PyPI, this changes to `uvx --from "sspower-mem==<pinned>" sspower-mem ...`. **Not in this spec's scope** — dev path only.
- Python equivalent (for `wiki-archive.py`): `subprocess.run(["uvx", "--from", SSPOWER_MEM_SRC, "sspower-mem", ...])`.
- Bootstrap (`sspower-mem doctor --bootstrap`) warms the `uvx` cache so subsequent hook invocations don't pay cold-start.

Subcommands:

```
# All subcommands accept a shared option:
#   --cwd <path>   For --scope project, the user project directory (not the hook process cwd).
#                  Required when --scope is project (or project,user) AND the caller is a hook —
#                  hooks pass it from the hook JSON payload's `cwd` field. If omitted, the CLI
#                  falls back to os.getcwd(), which is correct for interactive shell use only.

sspower-mem add    --scope <project|user> --layer <episodic|decision|gotcha|user-global>
                   --content @<file>|<text> [--cwd <path>] [--meta k=v ...] [--no-llm]
                   # --no-llm: skip step 3 (the index's `infer=True` / Codex extraction).
sspower-mem search --scope <project|user|project,user> [--cwd <path>] [--layer <l1,l2,...>]
                   (--query <text> | --mode recent) [--top-k 8] [--json] [--idx-only]
                   # --query <text>:  semantic/grep search (default behavior).
                   # --mode recent:   no query; return top-k most-recent blocks. Bypasses the index;
                   #                  source="digest-recent". Used by hooks/session-start.
                   # Exactly one of --query and --mode is required.
                   # --idx-only: disables ALL digest fallback (both exception fallback AND zero-result
                   #              fallback). Renamed from v5's `--no-grep-fallback` (which only gated
                   #              the 0-result fallback — Codex v6 flagged the ambiguity).
                   #              Behavior with --idx-only set:
                   #                - the index raises  → CLI exits NONZERO (caller debugs the dep/Chroma).
                   #                - the index returns [] → CLI prints [] and exits 0 (legitimate no-match).
                   #              Default (flag NOT set): both fallbacks active, digest grep covers
                   #              both exceptions and zero-result.
sspower-mem migrate [--from-wiki <dir>] [--from-memory <dir>] [--dry-run]
                    [--reextract [<id>|all]] [--cwd <path>]
                    # Either ingest-from-source mode (--from-wiki and/or --from-memory) OR
                    # reextract-existing mode (--reextract, no source dirs needed).
                    # Constraints:
                    #   - If --reextract is set: --from-* are OPTIONAL. The command operates on
                    #     existing digest.md + the index's records only.
                    #   - If --reextract is NOT set: at least one of --from-wiki / --from-memory
                    #     is REQUIRED (otherwise migrate has no input).
                    #   - --reextract takes optional value: <id> for single block, `all` for every
                    #     raw-only block (default = `all`). `no_llm=true` blocks are SKIPPED on
                    #     `all` but processed on explicit <id>.
sspower-mem digest --scope <project|user> [--cwd <path>] [--rebuild-chroma [--no-llm]]
                   # --rebuild-chroma: re-ingest every digest.md block into the index from scratch.
                   #                   Default: full re-add via the standard `add` path = step 2
                   #                   (raw) + step 3 (extract) per block. Blocks with `no_llm=true`
                   #                   in digest metadata SKIP step 3 (preserves original intent).
                   #                   Idempotent via effective_id+kind dedup (§6.1 D11).
                   # --rebuild-chroma --no-llm: force-skip step 3 for ALL blocks (used when the
                   #                   bridge is down and you just want raw indexing restored fast).
sspower-mem doctor [--bootstrap]
                   # health: lock writable, chroma reachable, bridge reachable, m2v loads, digest writable
                   # --bootstrap: download Model2Vec model, init chroma+history.db, write config.json,
                   # verify codex-bridge `complete` round-trip, warm uvx cache. Idempotent.
```

#### Exit codes

| Code | Meaning | When |
|------|---------|------|
| `0`  | OK | All requested steps succeeded; or `--no-llm` and steps 1+2 succeeded. |
| `10` | Degraded: digest written, the index-backend step failed | Step 1 ok + step 2 or 3 failed (incl. the upstream index library + chromadb + model2vec **import** failure inside `add` — lazy-load policy, see §6.1). |
| `20` | HARD: digest write failed | Disk full / readonly / symlink-refused / path-traversal / project cwd unwritable (no fallback location for source-of-truth writes). |
| `30` | Startup dependency missing | uvx not on PATH, Python interpreter missing, or `doctor --bootstrap` never run (lock file absent at expected path). NOT used for in-add index-backend import failures — those are rc=10 per the lazy-import policy. Caller logs hint, no-ops. |

#### Write critical section (D11)

Every block has a **stable id** = `sha1(scope|layer|content)[:16]` (64 bits — collision probability < 1e-12 at 10⁴ blocks via birthday bound; v3 used `[:8]` = 32 bits which Codex flagged as collision-material at 10K scale). On any apparent id collision in `digest_append_or_skip`, the implementation **must** compare full content before skipping; if the content differs, append anyway with a `_dup<N>` suffix in the id field (`<base_id>_dup1`, `<base_id>_dup2`, …, picking the next free N) and log a warning.

**Effective id propagation** (v6 missing #6 fix): once `_dup<N>` is appended, the **effective id** (full string including suffix) is used as `block_id` everywhere downstream — `meta["id"]` for the index's raw-add path, and `meta["raw_id"]` on the index's extract-add path. Pseudocode below uses `effective_id` to make this explicit. Two genuinely distinct content blocks with the same 64-bit prefix will therefore have distinct records in the index and distinct digest entries.

The id is the correlation key across all three writes (digest header line, the index's raw record metadata `id`, the index's extract record metadata `raw_id`).

```python
# Lazy-import policy (v6 missing #1): the upstream index library + chromadb + model2vec are NOT imported at module load.
# They are imported INSIDE step 2/3 below, AFTER step 1's digest append has succeeded.
# A missing/broken Python dep therefore cannot bypass the digest write — it surfaces as rc=10
# (degraded), not rc=30 (which would skip the digest entirely).

with fcntl.flock(LOCK_FD, fcntl.LOCK_EX):
    base_id = sha1(f"{scope}|{layer}|{content}".encode()).hexdigest()[:16]

    # Step 1 (DURABLE): digest append via safe_append_strict(trust_root=<scope_root>) — §6.4.
    #   Idempotency: if digest already has a block with `base_id` AND content matches → SKIP append,
    #   return effective_id = base_id (already-recorded).
    #   If `base_id` exists but content differs → effective_id = "<base_id>_dup<N>", append new block.
    #   On exception (disk full / symlink / traversal) → exit 20. No further steps.
    effective_id, step1_ok = digest_append_or_skip(base_id, content, ...)

    # All downstream metadata uses effective_id, NOT base_id (v6 missing #6).
    meta = {"id": effective_id, "layer": layer, "scope": scope, "ts": iso_now(), ...}

    # Step 2 (RAW INDEX): lazy-import here so import-time failures degrade to rc=10.
    try:
        from idx_lib import Memory  # alias for the upstream index lib  # noqa: lazy
        # idx_raw_upsert(content, user_id=<scope>, metadata={**meta, "kind": "raw"})
        #   Idempotency: pre-search the index by metadata.id+kind=raw; if hit → skip.
        step2_ok = idx_raw_upsert(content, meta)
    except ImportError as e:
        log_errors_jsonl({"stage": "step2_import", "err": str(e)}); step2_ok = False
    except Exception as e:
        log_errors_jsonl({"stage": "step2_index", "err": str(e)}); step2_ok = False

    # Step 3 (EXTRACT): metadata uses raw_id=effective_id.
    if no_llm_flag:
        step3_ok = True  # intentional skip; exit 0
        extracted_status = "skipped-intentional"
    else:
        try:
            # idx_extract_upsert(content, user_id=<scope>,
            #   metadata={**meta, "kind": "extracted", "raw_id": effective_id})
            #   Idempotency: pre-search by metadata.raw_id+kind=extracted; if hit → skip.
            step3_ok = idx_extract_upsert(content, {**meta, "kind": "extracted", "raw_id": effective_id})
            extracted_status = "ok" if step3_ok else "skipped-failed"
        except ImportError as e:
            log_errors_jsonl({"stage": "step3_import", "err": str(e)}); step3_ok = False
            extracted_status = "skipped-failed"
        except Exception as e:
            log_errors_jsonl({"stage": "step3_index", "err": str(e)}); step3_ok = False
            extracted_status = "skipped-failed"

# Lock released.
# Exit code (single rule):
#   step1 fail            → 20
#   step1 ok, step2+step3 ok → 0
#   step1 ok, (step2 or step3) failed → 10
```

Step 2 (`infer=False`) gives raw indexing even when Codex is down — the index stores content + Model2Vec vector without LLM extraction. Step 3 (`infer=True`) adds LLM-extracted facts. The `raw_id` metadata field correlates extract records back to the raw record so `--rebuild-chroma` can dedup and `search` can deduplicate hits.

Codex misunderstanding #2 (correlation) + #3 (raw fallback) fix.

#### `add --no-llm` semantics (resolves v4 missing #4)

`add --no-llm`: intentional skip of **step 3 only**. Step 2 (raw indexing) still runs normally.

- **Exit code rule** (clarifies v7 missing #3): `--no-llm` reclassifies step 3 from "fail = rc=10" to "intentional skip = no rc effect". The overall add rule still applies to step 2:
  - step1 fail → 20
  - step1 ok + step2 ok + (--no-llm) → **0** (intentional skip; clean success)
  - step1 ok + **step2 fail** + (--no-llm) → **10** (step 2 failure is not masked by --no-llm)
  - step1 ok + step2 ok + step3 ok (no flag) → 0
  - step1 ok + (step2 or step3) fail (no flag) → 10
- **Output representation**: when `--json`, the result object has `"extracted": "skipped-intentional"` (vs `"skipped-failed"` for the rc=10 case where step 3 raised, and `"ok"` when step 3 succeeded).
- **Persistence**: the digest block header includes `[meta] no_llm=true`. The index's raw record's metadata also has `no_llm=true`.
- **`migrate --reextract` interaction**: blocks tagged `no_llm=true` are **SKIPPED** by `--reextract all` (they're intentional, not victims of bridge outage). `--reextract <id>` (explicit single id) re-runs extraction regardless of the flag — used when the user changes their mind about a specific block.
- **`--no-llm` does NOT save the bridge call cost twice**: the bridge is not invoked at all in step 3. The index client just isn't called with `infer=True`.

#### Read path

```
search (deterministic order):
  1. Try the index's search — **one call per scope** (the index's user_id filter is scalar; see §5 mapping).
     For `--scope project,user`: issue search(query, user_id="project:<hash>") AND
     search(query, user_id="user:global"), concatenate hits, then de-dup by metadata.raw_id
     (or metadata.id when raw_id absent): prefer kind=extracted when both kinds match;
     fall back to kind=raw. Re-score against the union per the merged-scope rule in step 5 below.
  2. the index raised an exception          → fall through to grep fallback. source="digest-grep".
  3. the index returned 0 results AND `--idx-only` NOT set (default: fallback enabled)
                                    → grep fallback. source="digest-grep".
  4. the index returned ≥1 result        → return the index hits. source="index".

Every result entry:
  { "id": "<block_id>",
    "source": "index" | "digest-grep" | "digest-recent",
    "score": <float in [0,1]>,         // for "digest-recent": newest = 1.0, oldest in set = 0.0 (linear)
    "content": "...", "scope": "...", "layer": "...", "ts": "..." }

Grep fallback scoring (deterministic, no external lib):
  1. Tokenize the query: lowercase, split on whitespace + punctuation, drop tokens shorter than 3 chars.
     If zero tokens remain (very short query) → use the original query as a single token.
  2. For each block B in the in-scope digest.md file(s), parsed by `## <ts> · ...` header boundaries:
     - hits(B) = sum over tokens t of: count of case-insensitive substring occurrences of t in B.content.
     - if hits(B) == 0 → skip.
     - raw_score(B) = hits(B) / max(1, len(B.content) / 1000)
       (normalize by content size in KB so short, dense matches outrank long sprawls).
     - For tie-breaking on identical raw_score: prefer larger B.ts (newer wins). Final tie: lexicographic
       order of block_id (deterministic).
  3. Compute score(B) = raw_score(B) / max_raw_score across the candidate set → values in [0, 1].
  4. Return top-k by score, lex-stable on ties (per step 2).
  5. For merged `--scope project,user` fallback: concatenate per-scope candidate lists, run step 3 over
     the union (single normalization across both scopes), then top-k. Each result keeps its native scope.

  Cross-scope merge rules (apply to both the index and digest-recent paths, NOT only grep fallback):

  (A) index multi-scope: scores returned by separate index searches are NOT directly comparable across
      collections (the index/Chroma cosine similarity is bounded in [0,1] but normalization differs by query
      and collection). Algorithm:
        - For each scope, run search, take its top-k hits.
        - Min-max normalize each scope's hit scores to [0,1] within that scope.
        - Concatenate, sort by normalized score desc, tie-break by ts desc, then lex on id.
        - Return top-k from the merged sorted list.
      Result entries carry their NORMALIZED score, not the index's raw score.

  (B) digest-recent multi-scope: collect newest --top-k blocks from each scope's digest.md.
      Sort the union by ts desc; tie-break by scope priority (project > user); then lex on id.
      Score field = normalized (newest in union = 1.0, oldest in union = 0.0, linear by ts position).
      Return top-k from the merged sorted list.

  Degenerate-case rules (resolves v6 missing #9):
    - **Empty scope**: zero hits contribute nothing to the merged list. If both scopes empty → return [].
    - **Single hit in a scope** (the index): min == max → normalized score = 1.0 for that hit (no division by zero).
    - **All hits tied at the same raw score** (the index): min == max → all normalized to 1.0; tie-breaks proceed
      by ts desc then lex on id.
    - **Single block in digest-recent merged set**: score = 1.0.
    - **All blocks in digest-recent share the same ts**: score = 1.0 for all; tie-breaks by scope priority
      then lex on id.
    - **Grep fallback `max_raw_score == 0`** (no hits at all): return []. Never produces NaN.
    - Implementation: a tiny helper `min_max_norm(values)` that returns `[1.0]*len(values)` when `min==max`.

CLI flags:
  --idx-only   disable step 3 (index-only mode for debugging)
  --json               machine-readable output (the above object array)
```

`degraded: true` from v2 is replaced by the explicit `source` field. There is no out-of-band degraded-mode state; behavior is per-call deterministic from the above rules.

### 6.2 `codex-bridge.mjs complete --json`

New subcommand, added to existing dispatch (§4 verified: existing subcommands listed; `complete` not present).

```
codex-bridge.mjs complete --json --prompt <text|@file>
                          [--system <text>] [--model <m>] [--effort <e>] [--timeout <ms>]
```

- Input: prompt + optional system message. **No tool use**, no schema validation, no agentic loop.
- **Tool-use disable mechanism**: Codex CLI's `exec` path always loads its default tool surface; full disable from the wire is not exposed. Practical enforcement:
  1. Pass `--sandbox read-only` (no file writes, no spawns beyond read-only shell).
  2. Prepend a hard system directive: `You are a single-turn extractor. Do NOT call any tool. Respond with the answer directly. If you start to call a tool, stop and answer in text.`
  3. Set `reasoning.effort=minimal` (lowers the chance of tool-use during reasoning).
  4. Cap wall time at 60s; on timeout return exit nonzero so the index's extract step degrades cleanly.
- This is the achievable contract. Full tool-off requires upstream Codex CLI changes; out of scope.
- Output (stdout): OpenAI-shape `chat.completion`:
  ```json
  {"id":"...","object":"chat.completion","model":"<m>",
   "choices":[{"index":0,"message":{"role":"assistant","content":"..."},"finish_reason":"stop"}],
   "usage":{"prompt_tokens":N,"completion_tokens":N,"total_tokens":N}}
  ```
- Errors → exit nonzero + stderr JSON `{"error":{"type":"...","message":"..."}}`.
- Defaults: model `gpt-5.5`, effort `minimal`, timeout 60s.
- Implementation note: thin wrapper over the existing Codex CLI single-shot path. Reuse `secureTmpFile` + `cleanupTmpDir` from existing bridge for the prompt file. Reuse `classifyError` for failure logging.

### 6.3 Index custom-LLM + custom-embedder adapters

**Exact registration mechanism: TBD in Phase 0.** Codex source check (factory.py) found built-in provider maps only, no documented `provider: custom` key. Three candidate mechanisms to evaluate in Phase 0:

1. **Subclass + factory monkey-patch**: add our class to `<index>.utils.factory.LlmFactory.provider_to_class` at import time. Lowest invasiveness, fragile across index-library versions.
2. **Wrapper façade**: instantiate the index with a stock provider, then replace `memory_instance.llm` / `memory_instance.embedding_model` post-init with our objects. Bypasses factory entirely. Depends on whether the index re-reads these from config later.
3. **Fork**: maintain a thin sspower fork of the index with the providers added. Most resilient, highest maintenance cost.

Phase 0 produces a 1-page mini-spec choosing one mechanism with evidence (index-backend source citations) and recording the chosen mechanism's stability assumptions.

Adapter interfaces (sketch, exact signatures TBD in Phase 0 once the index-backend source is read):

```python
class CodexBridgeLLM:
    """Implements index LLM interface. Calls codex-bridge.mjs complete --json."""
    def generate_response(self, messages, response_format=None, tools=None, tool_choice="auto"):
        # subprocess.run([BRIDGE, "complete", "--json", "--prompt", flatten(messages)], timeout=60)
        # On non-zero exit → raise CodexBridgeUnavailable (the index catches in infer=True path)

class Model2VecEmbedder:
    """Implements index embedder interface."""
    def __init__(self, model_name="minishlab/potion-base-8M"):
        from model2vec import StaticModel
        self.model = StaticModel.from_pretrained(model_name)
    def embed(self, text, memory_action=None):
        return self.model.encode(text).tolist()
```

### 6.4 digest.md format

Append-only, block-structured, written via a **strict** symlink-safe append primitive. The existing `_safe_append_text(path, content, trust_root)` in `hooks/wiki-archive.py:162` does a symlink check then a normal `open(path, 'a')` — there is a TOCTOU window between check and open (Codex v3 finding). For the new source-of-truth digest path, we tighten this:

**Trust-root model** (resolves v4 misunderstanding #3): "strict" here closes the TOCTOU on the **final path component** and on **directory components below `trust_root`** via `openat`-style relative opens. Components **at or above** `trust_root` (e.g., `$HOME`, `$HOME/.claude/`) are NOT atomically protected — those are paths owned by the user; an attacker capable of swapping symlinks at that level can already do worse than redirect a memory write.

**Trust root creation** (resolves v5 missing #6 + v6 misunderstandings #1/#2):
- **User-scope** `~/.claude/sspower/` → created by `sspower-mem doctor --bootstrap` (Phase A), via a new `safe_makedirs_strict(path, parents, mode=0o700)` (see below) — NOT plain `os.makedirs`.
- **Project-scope** `<cwd>/.claude/wiki/` → created **lazily by the first `sspower-mem add --scope project` invocation** in that project, via the same `safe_makedirs_strict` helper. `--cwd <path>` (passed by hooks from the hook JSON payload) is the source-of-truth for project cwd; CLI does not infer from `os.getcwd()` when called via hook.
- **Important**: this spec does NOT reuse `hooks/wiki-archive.py:resolve_out_dir`. That function (a) returns a `sessions/` subdir, not `<wiki>/`; (b) has a fallback to `~/.claude/wiki/<basename>-<hash>/sessions/` when the project dir is unwritable, which would silently redirect source-of-truth writes for digest. Both behaviors are wrong for our use. Instead:
  - `safe_makedirs_strict` creates each intermediate component via `os.mkdir(part, dir_fd=cur_fd)` (POSIX `mkdirat`) — no path-component races.
  - On unwritable project dir (e.g., user opened a session in a read-only cwd), `add --scope project` returns **rc=20** (HARD failure) rather than falling back to a different filesystem location. The user is told their cwd doesn't support project memory; they can fix it or use `--scope user` only.

```python
# sspower_mem/io.py (sibling to safe_append_strict)

def safe_makedirs_strict(path: pathlib.Path, parent_anchor: pathlib.Path, mode: int = 0o700) -> None:
    """Create `path` and any missing intermediate dirs UNDER `parent_anchor`, using openat-style
    component creation. Rejects symlink components below `parent_anchor`. `parent_anchor` itself
    must already exist and not be a symlink."""
    rel = path.relative_to(parent_anchor)
    for part in rel.parts:
        if part in ("", ".", ".."):
            raise OSError(f"traversal component {part!r} in {path}")
    flags_dir = os.O_RDONLY | os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags_dir |= os.O_NOFOLLOW
    cur_fd = os.open(parent_anchor, flags_dir)
    try:
        for part in rel.parts:
            try:
                os.mkdir(part, mode=mode, dir_fd=cur_fd)
            except FileExistsError:
                pass  # already exists; open below verifies it is not a symlink
            next_fd = os.open(part, flags_dir, dir_fd=cur_fd)
            os.close(cur_fd)
            cur_fd = next_fd
    finally:
        os.close(cur_fd)
```

Parent anchors (the only paths assumed pre-existing and trusted): `$HOME` and the **user-supplied `--cwd` value**.

**`--cwd` canonicalization** (resolves v7 missing #6):
- CLI calls `os.path.realpath(cwd_arg)` to resolve symlinks BEFORE both (a) using the path as the openat parent anchor and (b) computing `sha1(cwd)[:16]` for the scope id.
- If the realpath does not exist → exit 20 (project cwd missing; no fallback for source-of-truth writes).
- If the realpath differs from the lexical input (i.e., the user passed a symlinked cwd) → log an info line; proceed with the realpath. Hash uses the realpath, so two symlinks pointing at the same project share the same digest. This is the desired behavior.
- Trust root is anchored at the realpath, not the lexical input — closes a class of symlink-redirect attacks on the scope hash.

**fd ownership** (resolves v7 missing #7): both `safe_append_strict` and `safe_makedirs_strict` must guard against double-close on intermediate-open failure. Idiom:

```python
cur_fd = os.open(trust_root, flags_dir)
try:
    for part in rel.parts:
        next_fd = os.open(part, flags_dir, dir_fd=cur_fd)  # may raise; cur_fd still valid
        os.close(cur_fd)   # only reached if next_fd succeeded
        cur_fd = next_fd
    # ... final file open uses cur_fd as dir_fd ...
finally:
    os.close(cur_fd)       # always closes the last surviving fd; no double-close
```

If `os.open(part, ...)` raises, control jumps to `finally` with `cur_fd` still pointing at the last successful open — no leak, no double-close.

```python
# sspower_mem/io.py (new shared module)

import os, pathlib

def safe_append_strict(path: pathlib.Path, content: str, trust_root: pathlib.Path) -> None:
    """Append `content` to `path`, refusing if any path component AT OR BELOW `trust_root`
    is a symlink. TOCTOU-closed via openat-style relative opens with O_NOFOLLOW."""
    # Resolve path components relative to trust_root.
    try:
        rel = path.relative_to(trust_root)
    except ValueError:
        raise OSError(f"path {path} not under trust_root {trust_root}")

    # Reject path-traversal components. `relative_to` does not normalize `..`,
    # so a lexical "<trust_root>/sub/../../escape" could yield `("sub","..","..","escape")`
    # and the openat walk would happily traverse out of trust_root via the dir-fd of the
    # parent. Explicit rejection closes the escape.
    for part in rel.parts:
        if part in ("", ".", ".."):
            raise OSError(f"path {path} contains traversal component {part!r}")

    # 1. Open trust_root with O_DIRECTORY|O_NOFOLLOW. If trust_root itself is a symlink, refuse.
    flags_dir = os.O_RDONLY | os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags_dir |= os.O_NOFOLLOW
    cur_fd = os.open(trust_root, flags_dir)
    try:
        # 2. Walk intermediate dirs via openat (dir_fd=cur_fd), each with O_NOFOLLOW.
        #    Any swapped-in symlink mid-walk → OSError(ELOOP). No window between check and open.
        for part in rel.parts[:-1]:
            next_fd = os.open(part, flags_dir, dir_fd=cur_fd)
            os.close(cur_fd)
            cur_fd = next_fd
        # 3. Open the final file relative to the last dir fd, O_NOFOLLOW.
        file_flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT
        if hasattr(os, "O_NOFOLLOW"):
            file_flags |= os.O_NOFOLLOW
        file_fd = os.open(rel.parts[-1], file_flags, mode=0o644, dir_fd=cur_fd)
        try:
            os.write(file_fd, content.encode("utf-8"))
        finally:
            os.close(file_fd)
    finally:
        os.close(cur_fd)
```

Platform note: `O_NOFOLLOW` + `dir_fd=` are POSIX (macOS + Linux, both targets). Windows is out of scope.

D12 amended: the digest path uses **`safe_append_strict`** (new), not the existing `_safe_append_text`. The legacy helper is retained for legacy `sessions/*.md` belt writes only.

Block format (v2 with v4 id-width tightening; v9 metadata encoding fix below):

```
## <ISO-8601-timestamp> · <scope> · <layer> · <id>
[meta] {"key": "value", "key": "value"}
<content>

---

```

**Metadata encoding (v9 amendment, resolves Phase A round-2 auto-review docs-drift finding):** the `[meta] ` line is followed by a **compact JSON object** — NOT `key=value, key=value`. The earlier `key=value` format was lossy for values containing commas or equals signs (e.g., path strings). Phase A implementation uses JSON; the spec is amended to match. `[meta] {}` is the empty case.

- `id` = first 16 chars of SHA-1 over `(scope|layer|content)` (v4 bump from 8 chars; see §6.1 for collision-handling).
- `<scope>` = `project:<hash>` or `user:global`.
- Trailing `---\n\n` separator on every block.
- Grep-friendly: layer/scope/id all on the header line.

### 6.5 Hook + skill rewrites

Surfaces verified in §4 — corrected from v1:

- **`hooks/wiki-archive.py`** — keep extracting structured session summary (existing logic preserved). The actual write functions today are `write_json(data, path, trust_root)` (L563), `write_markdown(data, path, trust_root)` (L600), and `append_index_entry(...)` (which appends a row to `<wiki>/index.md` linking to the per-session `.md` file). `_safe_write_text`/`_safe_append_text` are their primitives. After the rewrite:
  - `write_markdown` (and decisions/gotchas seeding) → calls `sspower-mem add --scope project --layer <episodic|decision|gotcha>` via subprocess.
  - `write_json` (raw archive JSON) → stays writing `sessions/*.json` for one release as the legacy belt (Phase E), giving us a third recovery surface.
  - **`append_index_entry`** → **removed in Phase E** (no longer meaningful, since the linked `.md` file no longer exists). The `<wiki>/index.md` file is renamed to `index_legacy.md` and frozen (read-only). The `sspower-mem digest` command + the digest.md file itself serve as the new "index" — `digest.md` is grep-friendly with one header line per block.
  Both legacy and new paths kept symlink-safe: legacy belt via existing helpers, new `sspower-mem add` path via `safe_append_strict` (§6.4).
- **`hooks/wiki-archive.sh`** — unchanged in shape; still invokes the .py. May add a pre-flight `command -v uvx` check; if absent, emit a one-line hint to stderr and continue the legacy path only.
- **`hooks/session-start`** — read the hook JSON payload's `cwd` field, then append to its current `additionalContext` output a section sourced from `sspower-mem search --cwd "$payload_cwd" --scope project,user --mode recent --top-k 8 --json` (NOT `--query`; no user prompt available at SessionStart). `--cwd` is REQUIRED for project-scope reads. Formatted to text per the result schema in §6.1. On exit 10 or 30, fall back to current behavior (no extra context); never block.
- **`skills/brainstorming/SKILL.md`** — change "write decisions" instructions to call `sspower-mem add --layer decision`. Reads via `sspower-mem search`.
- **`skills/systematic-debugging/SKILL.md`** — same for gotchas (`--layer gotcha`).
- **`skills/writing-plans/SKILL.md`** — Pre-flight section reads `<cwd>/.claude/wiki/decisions.md` + `sessions/`. Rewrite per the search CLI grammar (must supply `--query` or `--mode`):
  - For prior decisions: `sspower-mem search --scope project --layer decision --mode recent --top-k 5` (no semantic query; just the most-recent N decisions).
  - For recent sessions: `sspower-mem search --scope project --layer episodic --mode recent --top-k 3`.
  - Optionally, when the skill has a concrete user prompt to align with, `--query "<user's task description>"` instead of `--mode recent`.
- **`skills/using-sspower/SKILL.md`** — add a routing note in the skill table; no behavior change.

There is no `skills/session-start/SKILL.md` and this spec does not introduce one.

## 7. Migration

### 7.1 Phase 0 — index-backend source verification (NEW, blocks Phase C)

**Deliverable:** a 1-page mini-spec `docs/specs/2026-05-13-index-provider-registration.md` answering:

1. Which of the 3 registration mechanisms in §6.3 we choose, with index-backend source citations.
2. Exact `LlmFactory` / `EmbedderFactory` API surface in current index-library main.
3. `Memory.add(infer=False)` storage path: does it write to the same collection as `infer=True`? What metadata does it return? Does it embed via the configured embedder?
4. How to override the index's history-DB path (env var? config key? subclass?).
5. Upstream telemetry opt-out: exact env-var name (read upstream source — does NOT assume any particular identifier) and/or runtime module patch (`<index>.memory.telemetry` or equivalent). Phase 0 picks one and freezes the variable name into the implementation.
6. **the index's v3 entity-linking / entity-store behavior** (resolves v3 missing #4): does the current OSS index algorithm lazily create extra Chroma collections (entity store) even when graph is off? If yes, what is the collection name, where is it persisted, and can it be disabled? Sources to check: `<index>/memory/main.py` (entity-store init), (upstream index migration docs). Spec assumption ("Chroma stores exactly the configured `memories` collection + nothing else") must be verified or revised.
7. **`Memory.add(infer=True)` metadata + failure semantics** (resolves v4 missing #5): does the index preserve caller-supplied metadata (`raw_id`, `kind=extracted`, `id`, `layer`, `scope`, `ts`) when extraction yields multiple facts (1-to-N)? What is the resolution under ADD/UPDATE/NONE actions — does UPDATE replace metadata? Does the LLM adapter raising an exception surface to the caller, or does the index swallow it and return `[]`? Step 3 (§6.1) relies on (a) `raw_id` correlation surviving extraction, (b) failures being observable (so the wrapper sets `extracted="skipped-failed"`, not `"ok"`). If the index swallows the failure, we must wrap `Memory.add(infer=True)` with our own pre-check (e.g., timing the call + comparing the post-add count) or fork the relevant method. Source to check: `<index>/memory/main.py:add` + `_add_to_vector_store`.
8. **the index's metadata-filter API surface** (resolves v7 missing #9): does the index's `Memory.search` (or a sibling like `Memory.get`/`Memory.list`) accept arbitrary `metadata.<key>` filters (e.g., `metadata.id == "<block_id>" AND metadata.kind == "raw"`)? §6.1 dedup pre-search requires this. If the index only filters by the top-level `user_id` + a fixed `run_id`/`agent_id` set, we must implement dedup by: (a) maintaining our own SQLite dedup table at `~/.claude/sspower/idx/dedup.db` (block_id+kind → idx_record_id), or (b) issuing a broad search + filtering metadata client-side, or (c) forking. Output of Phase 0 must pick one. Source to check: `<index>/memory/main.py:search` and `<index>/vector_stores/chroma.py` (or equivalent) for the filter pass-through.

Phase 0 reads the index-backend source only — no implementation. Output is a doc. Re-run Codex spec-review on the mini-spec before unblocking Phase C.

### 7.2 One-shot migration

`sspower-mem migrate` (single command, idempotent):

Inputs scanned:
- `<cwd>/.claude/wiki/sessions/*.{json,md}` → scope `project:<hash>`, layer `episodic`.
- `<cwd>/.claude/wiki/{decisions,gotchas}.md` → split by `##` or `---`, scope `project:<hash>`, layer `decision` / `gotcha`.
- `~/.claude/projects/*/memory/*.md` → scope `user:global`, layer `user-global`.

For each block:
1. Compute `base_id = sha1(scope|layer|content)[:16]` (same formula as §6.1).
2. Call `sspower-mem add` (which applies the same `effective_id` collision logic from §6.1 — full-content compare on apparent id collision, `_dup<N>` suffix if content differs). Migration does NOT bypass the standard add path or its dedup rules (resolves v7 missing #8).
3. Tag metadata: `migrated_from=<path>`, `original_mtime=<ts>` (merged into the standard meta dict before `add` is called).

`--dry-run` prints plan, writes nothing. `--reextract` re-runs LLM extraction (the index's `infer=True` re-add) for entries currently lacking extracted facts (e.g. when Codex was down at migrate time).

After Phase F green-checkpoint, archive legacy `wiki/sessions/`, `wiki/decisions.md`, `wiki/gotchas.md` under `wiki/_legacy_pre_idx/`. The digest.md is now the substrate.

## 8. Failure modes (D2 / D11 compliance)

| Failure | Detection | Degradation | Recovery |
|---------|-----------|-------------|----------|
| `digest.md` unwritable | step 1 of write critical section | exit 20 HARD. **Hook propagates the failure** (logs hint to stderr and exits 20 itself, per Phase E wrapper). Loud failure beats silent data loss — data-loss event must surface to the user, not get swallowed by `set +e`. | free disk; rerun hook manually. |
| the index's `infer=False` raw add fails (Chroma corrupt/locked, embedder load error) | step 2 raises | digest line is already durable. errors.jsonl logged. `add_result.raw="skipped"`. exit 10. | `sspower-mem digest --rebuild-chroma` re-ingests all digest blocks. |
| Codex bridge `complete` timeout/error | step 3 raises CodexBridgeUnavailable | digest + raw embedding stored. Only LLM-extracted facts are skipped. `add_result.extracted="skipped"`. exit 10. | `sspower-mem migrate --reextract` once bridge healthy. |
| Model2Vec / chromadb / index-library import fails inside `add` | lazy import raises after digest append | exit **10** (NOT 30). Digest line is already durable; only the index's raw+extract are skipped. `errors.jsonl` logged. Lazy-import policy: the upstream index library + chromadb + model2vec are imported INSIDE `add` AFTER step 1 (digest append), so a missing or broken Python dep cannot bypass the digest write. This preserves D2/D11 against dep regression. | `sspower-mem doctor --bootstrap`; if model fetch fails, smaller pinned model in config.json. |
| Model2Vec model load fails at CLI startup (before `add` begins) | `doctor --bootstrap` only — `add` never imports m2v at startup | exit 30 from doctor; `add` is unaffected because it doesn't import m2v until after digest append. | re-bootstrap with smaller model. |
| `uv` / `uvx` missing | hook wrapper `command -v uvx` check | exit 30 (from wrapper, before invoking sspower-mem). Hook no-ops with hint. Legacy belt still runs. | `brew install uv`. |
| Lock file unwritable | `fcntl.flock` raises | exit 30. Same as uv-missing path. No alternate-location fallback — D5/D11 pin storage to `~/.claude/sspower/idx/` and a split lock would silently fragment the substrate. | fix permissions on `~/.claude/sspower/idx/` (or its parent); rerun `sspower-mem doctor --bootstrap`. |
| index returns wrong/garbage facts on search | not auto-detected | digest grep fallback never sees garbage facts. Manual inspection of `search --json` shows source ids. | `sspower-mem migrate --reextract <id>` re-runs extraction on a known-good block; or set `--no-llm` per-add to skip extraction for that block. |
| Chroma history-db growth | `doctor` reports size | not blocking; informational only. | manual `vacuum`/`reset` via `chromadb` CLI. |

**The contract**: if `sspower-mem add` returns 0 or 10, the content is recoverable from digest.md by `--rebuild-chroma`. Exit 20 is the only data-loss exit and it's disk-level.

## 9. Phases (ordered for independent verifiability)

### Phase 0 — index-backend source verification (NEW, blocks C)
Deliverable: `docs/specs/2026-05-13-index-provider-registration.md` per §7.1. Re-run Codex spec-review on it. No code in Phase 0.

### Phase A — sspower-mem skeleton, **digest-only** (no the index yet)
- [ ] `scripts/sspower_mem/` package + `pyproject.toml`.
- [ ] `sspower-mem add/search/digest/doctor` operating ONLY on digest.md (no index-backend dep).
- [ ] File lock (`fcntl.flock`) around add. Symlink-safe writes via the new `safe_append_strict` (§6.4) — NOT the legacy `_safe_append_text` (TOCTOU gap; retained only for the legacy belt).
- [ ] `doctor --bootstrap` creates `~/.claude/sspower/idx/` + writes empty `config.json` + `.lock`.
- [ ] Tests: append correctness under lock contention, header parse, grep search, exit-20 on unwritable, exit-30 on missing dependency, symlink refusal.
- [ ] **Checkpoint**: working plain-md backend with no index-backend dep. Ship-able as v0.

### Phase B — codex-bridge `complete --json`
- [ ] Add `complete` subcommand to `scripts/codex-bridge.mjs`.
- [ ] Tests against fixture Codex responses (mock spawn).
- [ ] Manual smoke against real Codex.

### Phase C — index-backend wiring (blocked by Phase 0 + Phase A + Phase B)

**All bullets below are CONTRACTS PENDING Phase 0** — they describe the intended end-state, but the exact index-backend API surface (registration mechanism, `infer=False` semantics, history.db override, telemetry opt-out) is verified and frozen only by the Phase 0 mini-spec. If Phase 0 finds a different shape, this section is rewritten before Phase C starts.

- [ ] Add the index + chromadb + model2vec to `sspower_mem` deps; pin versions (pins selected during Phase 0 + Phase A bootstrap testing).
- [ ] Implement `CodexBridgeLLM` and `Model2VecEmbedder` per the mechanism chosen in Phase 0 (§6.3 candidates 1/2/3).
- [ ] Wire `infer=False` (raw) → `infer=True` (extract) two-step add inside the lock, using stable `block_id` + `raw_id` metadata correlation (§6.1 D11). Idempotent upsert per §6.1.
- [ ] `doctor --bootstrap` extended: download M2V model (`potion-base-8M`), init chromadb at `~/.claude/sspower/idx/chroma/`, run round-trip add+search, run `complete --json` round-trip against Codex bridge. Warm `uvx` cache.
- [ ] Disable upstream telemetry in CLI entry before any index-library import. The exact mechanism (env var name + value, and/or runtime module patch) is the Phase 0 Q5 deliverable — wire whatever Phase 0 selects, do NOT hard-code a guessed identifier.
- [ ] Pin the index's history.db to `~/.claude/sspower/idx/history.db` (mechanism from Phase 0 question 4 — env var vs config key vs subclass).
- [ ] Tests: round-trip add → search; idempotency (same content added twice = single record per kind); error injections per §8 (chroma corrupt, bridge timeout, m2v load fail).

### Phase D — Migration
- [ ] `sspower-mem migrate` against a copy of real wiki+memory. Verify idempotence (twice = same row count).
- [ ] `--reextract` works on a block whose initial add ran with bridge mocked-failed.
- [ ] Sample-compare: random 10 legacy md blocks vs the index's search results.

### Phase E — Hooks + skills
- [ ] Rewrite `hooks/wiki-archive.py` write tail to call `sspower-mem add`.
- [ ] Rewrite `hooks/session-start` to append `sspower-mem search` results to `additionalContext`.
- [ ] **Hook-wrapper exit normalization** (resolves Codex v1 missing #8 + v2 missing #2): every hook caller wraps `sspower-mem` invocation so the original exit code is captured (`$?` after `if !` is the negated value, not the original — must NOT use that pattern):
  ```bash
  # Existing hooks (`hooks/session-start`, `hooks/wiki-archive.sh`) run with
  # `set -euo pipefail` (verified). A function that returns non-zero would
  # therefore terminate the script via `set -e` BEFORE the caller's `case`
  # statement runs. Solution: the wrapper function ALWAYS returns 0 and
  # communicates the original rc via the global `SSP_RC`. Caller dispatches
  # on `$SSP_RC` after the call.

  sspower_mem_call() {
    # Usage: sspower_mem_call <subcommand> [args...]
    # Sets globals: SSP_OUT (stdout+stderr), SSP_RC (normalized exit code).
    # ALWAYS returns 0 so the caller (running under set -e) is not killed.

    # Pre-flight: if uvx is missing OR the uv cache hasn't been bootstrapped, normalize to rc=30.
    # Otherwise the caller could see uvx-internal exit codes (1, 2, ...) instead of our contract.
    if ! command -v uvx >/dev/null 2>&1; then
      SSP_OUT="[sspower-mem] uvx not found in PATH; run 'brew install uv' and 'sspower-mem doctor --bootstrap'"
      SSP_RC=30
      echo "$SSP_OUT" >&2
      return 0
    fi

    set +e
    SSP_OUT=$(UV_OFFLINE=1 uvx --offline --from "$SSPOWER_MEM_SRC" sspower-mem "$@" 2>&1)
    raw_rc=$?
    set -e
    # Normalize: any non-{0,10,20} exit becomes 30 (dep/launch failure).
    # uvx cache-miss in offline mode exits with uvx-specific codes — collapse to 30.
    case "$raw_rc" in
      0|10|20) SSP_RC=$raw_rc ;;
      *)       SSP_RC=30 ;;
    esac
    case "$SSP_RC" in
      0)  : ;;  # success; $SSP_OUT is the result
      10) echo "[sspower-mem] degraded (rc=10, the index-backend step failed): $SSP_OUT" >&2 ;;
      20) echo "[sspower-mem] HARD fail (rc=20, digest unwritable): $SSP_OUT" >&2 ;;
      30) echo "[sspower-mem] dep missing (rc=30, uv cache not warmed?): $SSP_OUT" >&2; SSP_OUT="" ;;
      *)  echo "[sspower-mem] unexpected rc=$SSP_RC: $SSP_OUT" >&2; SSP_OUT="" ;;
    esac
    return 0  # CRITICAL: never propagate via return value under set -e.
  }

  # In hook script body — `$CLAUDE_HOOK_CWD` is the user project cwd from the hook JSON payload.
  # Hooks MUST pass --cwd explicitly; do NOT rely on $PWD or os.getcwd() (the hook process cwd
  # is often the plugin dir or $HOME, not the user project).
  sspower_mem_call add --cwd "$CLAUDE_HOOK_CWD" --scope project --layer episodic --content @"$summary_file"
  case "$SSP_RC" in
    0|10|30) : ;;       # continue, treat as success at hook level
    20)      exit 20 ;; # propagate HARD failure (digest unwritable = data-loss event)
  esac
  ```
  **Offline contract** (resolves v4 missing #6): the wrapper invokes `uvx` with `UV_OFFLINE=1 uvx --offline`. After `sspower-mem doctor --bootstrap` warms the cache, all subsequent hook-path invocations refuse to hit the network. Any dependency resolution attempt on the critical path → uvx exits non-zero → wrapper observes rc=30 → hook continues with empty output (legacy belt still runs during Phase E). `doctor --bootstrap` itself runs without `--offline` (one-time download path).
  Rules:
  - `rc=10` → hook continues, `$SSP_OUT` may have partial info (content is on disk via digest).
  - `rc=20` → hook **`exit 20`** (script context) or **`return 20`** (function context). Data-loss event; must propagate.
  - `rc=30` → hook continues with empty `$SSP_OUT` (legacy belt still runs during Phase E).
  - `rc=$?` ALWAYS captured immediately after the command on its own line — never after `if !`, `||`, or any compound.
  - Python equivalent for `wiki-archive.py` — must mirror the shell wrapper's full contract (pre-flight uvx check + `UV_OFFLINE=1` + `--offline` + exit-code normalization):
    ```python
    import os, shutil, subprocess
    SSPOWER_MEM_SRC = os.environ.get("SSPOWER_MEM_SRC", default_src_path)

    def sspower_mem_call(*args):
        """Mirror of the shell wrapper. Returns (rc, out). Never raises.
        rc is always one of {0, 10, 20, 30}; uvx-internal exits collapse to 30."""
        if not shutil.which("uvx"):
            return 30, "[sspower-mem] uvx not found in PATH"
        env = os.environ.copy()
        env["UV_OFFLINE"] = "1"
        try:
            cp = subprocess.run(
                ["uvx", "--offline", "--from", SSPOWER_MEM_SRC, "sspower-mem", *args],
                capture_output=True, text=True, env=env,
            )  # no check=True
        except FileNotFoundError:
            return 30, "[sspower-mem] uvx launch failed"
        raw = cp.returncode
        rc = raw if raw in (0, 10, 20) else 30
        out = (cp.stdout or "") + (cp.stderr or "")
        return rc, out

    rc, out = sspower_mem_call("add", "--cwd", project_cwd, "--scope", "project", ...)
    if rc == 20:
        sys.exit(20)  # propagate HARD failure
    elif rc in (10, 30):
        log_degraded(rc, out)  # continue
    ```
  - Same offline / cache-warm semantics as the shell version. A hook script in `wiki-archive.sh` AND the Python in `wiki-archive.py` both go through this contract — no path-dependent leakage.
- [ ] Update `skills/{brainstorming,systematic-debugging,using-sspower}/SKILL.md`.
- [ ] **Update `skills/writing-plans/SKILL.md`** — Pre-flight reads `wiki/decisions.md` + `sessions/`. Rewrite per §6.5: `sspower-mem search --scope project --layer decision --mode recent --top-k 5` and `sspower-mem search --scope project --layer episodic --mode recent --top-k 3` (or `--query <task>` when a task description is available).
- [ ] Eval each touched skill (CLAUDE.md "All skill changes must be eval-tested before committing").
- [ ] Verify hook wrapper offline contract: `UV_OFFLINE=1 uvx --offline` works after `doctor --bootstrap` warmed the cache; a hook invocation with cache cleared exits 30 (not 0). Test by removing `~/.cache/uv/` and running a hook.

### Phase F — Verification & deprecation
- [ ] Run for 1 week on real sessions.
- [ ] Weekly compare: digest.md block count vs index raw-collection count (must match modulo migration).
- [ ] Remove legacy belt write in `wiki-archive.py`.
- [ ] Archive existing legacy files under `_legacy_pre_idx/`.

## 10. Self-review checklist (pre Codex re-review)

- [ ] No load-bearing placeholders. (Phase 0 unknowns are scoped to a dedicated phase + deliverable.)
- [ ] All locked decisions in §3 trace to user input, this spec's reasoning, or Codex review evidence.
- [ ] Scope §2 in/out exhaustive.
- [ ] Every §8 failure mode has detect + degrade + recover.
- [ ] No implementation code (HARD-GATE D10).
- [ ] §9 phases independently verifiable. Phase A ships without the index at all.
- [ ] Source-of-truth contract consistent across §1, D1, D11, §6.1, §8 (digest is durable; the index is index).
- [ ] All Codex v1 findings answered in §0 with file/section pointer.
- [ ] Repo surfaces (§4) verified against actual filesystem, not assumed.

## 11. Open questions (Phase 0 must close)

1. the index's custom-LLM registration mechanism — choose subclass-monkey-patch / wrapper façade / fork.
2. the index's custom-embedder factory API.
3. `Memory.add(infer=False)` exact semantics: storage path, returned ids, embedder use, metadata schema.
4. the index's SQLite history-DB path override mechanism.
5. Upstream telemetry opt-out: exact env-var name (verified by reading upstream source, NOT guessed) and whether import-time honor is sufficient or runtime module patch (`<index>.memory.telemetry` or equivalent) is required.
6. Chroma persistent (sqlite3 + HNSW) locking semantics under concurrent PreCompact + SessionEnd (the §6.1 file lock is the belt; need to know if Chroma has its own to skip the suspenders).
7. `sspower-mem search` latency budget on `hooks/session-start` (target <1s for UX). M2V encode ~10ms warm + Chroma top-k 8 ~5ms = OK in theory; verify on real machine in Phase A.

## 12. Non-goals / explicit rejections

- No Semble (D9).
- No graph store (the index neo4j unused).
- No the cloud-hosted index service / hosted (D8).
- No daemon (OpenMemory MCP server).
- No third memory store. digest.md replaces wiki + auto-memory; the index backend IS our index, not a separate store.
- No multi-machine sync of Chroma. Each machine has its own digest.md + Chroma; sharing across machines uses git-tracked digest.md (out of scope for this spec).
- **No `skills/session-start/SKILL.md`** introduced. SessionStart context-injection stays hook-only.
