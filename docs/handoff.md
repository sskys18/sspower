# Session Handoff
> Generated: 2026-05-14 21:00 KST

## Task
Ship `sspower-mem` Phase C: wire Mem0 as semantic-index backend with client-side LLM extraction. Phase 0 + A + B already merged; v11 spec amendment landed on `phase-c` branch (no code yet).

## Status

### Completed (on `origin/main` @ `c8f2d53`)
- **Phase 0**: `docs/specs/2026-05-13-index-provider-registration.md` — upstream Mem0 OSS API verification @ SHA `70bc9e51`. Pinned 9 decisions.
- **Phase A v0.1.0**: `scripts/sspower_mem/` — digest-only stdlib backend, 21 plan tasks, 67/67 tests. 8 Codex review rounds. CLI: `add`, `search`, `digest`, `doctor` with `--scope`, `--cwd`, `--content`, `--content-file`. Exit codes 0/10/20/30.
- **Phase A v0.1.1**: 4 post-merge fixes — trailing-newline preservation, strict-anchored lock open, bounded reads (64MB digest, 8MB content-file), trust-root confinement re-enforced. 75/75 tests.
- **Phase B**: `scripts/codex-bridge.mjs complete --json` subcommand. 14 bridge tests. OpenAI-shape envelope; `--sandbox read-only`, hard system directive, `reasoning.effort=minimal`, 60s timeout.

### In Progress (on `origin/phase-c` @ `fe35a25`, plus handoff commit `8aee8db` on phase-c not yet on main)
- `docs/specs/2026-05-13-index-backend-integration-design.md` v11 amendment: client-side extraction supersedes infer=True. Body sections (§3 D11/D13/D14, §6.1 Step 3a/3b, §6.1.5 prompt contract, §6.3 factory, §8 failure rows) rewritten + changelog aligned. Codex re-review confirmed 5 prior issues closed (3 in initial re-review + 2 stragglers in last commit).

## Resume Here
1. `git checkout phase-c` (v11 spec lives there, plus this handoff's twin).
2. Invoke `sspower:writing-plans` skill: "Write Phase C plan from v11 spec at `docs/specs/2026-05-13-index-backend-integration-design.md` §6.1/6.1.5/6.3/8 + Phase 0 deliverable. Output: `docs/plans/2026-05-13-sspower-mem-phase-c.md`."
3. Commit plan on `phase-c` (auto-spec-gate fires on plan files — may iterate).
4. Switch to `sspower:subagent-driven-development` for implementation. Pattern from Phase A: Codex implement per task (sandbox blocks `.git` — main thread commits); tight prompts via `--prompt @/tmp/sdd-task-N.md`; per-task TaskCreate tracking.
5. Push `phase-c` periodically; expect Codex auto-review iterations (target: converge in 1-3 rounds, not the 8 Phase A took).
6. Merge `phase-c → main` via PR when 3 consecutive clean reviews. Then Phase D (migration).

## Decisions (do NOT revisit)
- **Sync in-lock extraction (v8 D11 amended)** — `lock → digest → Mem0 raw infer=False → codex-bridge complete → Mem0 extracted × N infer=False → release`. Async queue (option B) and detached subprocess (option C) rejected: too many moving parts for v0; hook latency 5-30s acceptable since hooks run between user actions.
- **Client-side extraction, never `Memory.add(infer=True)`** — Phase 0 Q6 found infer=True activates Chroma entity-store collections that can't be disabled. Q7 found it swallows LLM exceptions and only emits ADD (no UPDATE/NONE). We control extraction via Phase B's `codex-bridge complete` so failures are observable and entity-store stays dormant.
- **Mem0 as backend (not DIY chromadb wrapper)** — user choice 2026-05-14. Despite using ~5% of Mem0's API after Phase 0 constraints, sticking with the library trades upfront simplicity for ongoing maintenance against upstream changes.
- **Factory registration via class-path STRINGS** — `LlmFactory.register_provider("sspower-noop", "sspower_mem.mem.noop.NoOpLLM", BaseLlmConfig)` + `EmbedderFactory.provider_to_class["sspower-model2vec"] = "sspower_mem.mem.embedder.Model2VecEmbedder"`. Phase 0 Q1+Q2 verified. NO class objects, NO other monkey-patches.
- **Extraction wire contract pinned** — Codex `--json` envelope; `choices[0].message.content` parses as JSON object `{"facts": ["..."]}`. Empty success = `{"facts": []}`. Invalid JSON → `extracted="skipped-failed"`, rc=10. Hard caps: 32 facts × 512 chars per fact.
- **Fact identity** — every extracted Mem0 record has `metadata = {kind: "extracted", raw_id, fact_index, fact_hash=sha1(raw_id+":"+fact)[:16], layer, scope, ts}`. `--rebuild-chroma --reextract <raw_id>` deletes all matching `raw_id+kind=extracted` records then replays Step 3a+3b deterministically.

## Gotchas
- **Codex sandbox blocks `.git` writes**. Codex implement creates files; main thread commits. Do NOT instruct Codex to `git add`/`git commit`.
- **Auto-review converges slowly on security-sensitive code** — Phase A took 8 rounds. Don't be surprised if Phase C takes 3-5. File bypass `.sspower-skip-auto-review` is the unambiguous switch; remove after push. Env-var `SSPOWER_AUTO_REVIEW=off` as a command prefix does NOT work (parsed as wrapper).
- **Working tree is shared between parallel agents.** When dispatching a background Codex implement, expect HEAD movement. Phase B + v0.1.1 collided during this session — recovered via stash/checkout dance. Prefer `git worktree add` for true parallelism. Or run sequentially.
- **`uv` cache permission issues in sandbox** — Codex usually needs `UV_CACHE_DIR=/private/tmp/sspower-uv-cache` for tests. Inline in test commands.
- **Spec-gate filters to `docs/plans/*.md` only** — spec edits don't trigger Codex review at commit; auto-review fires on push.
- **v0.1.2 followups queued (defer until Phase C green)**: (a) collision dedup still ignores trailing newlines in id comparison, (b) search text output emits unsanitized digest metadata to terminal, (c) plan §Task 19 has been synced once but more drift may accrue, (d) CLAUDE.md still lists `scripts/` as only bridge + registry (now also `sspower_mem/`).
- **Auto-review iteration cap = 3 rounds per branch** at `.git/sspower-review-rounds-<branch>`. `rm` the file to reset. Track cumulatively via review verdict cache at `~/.cache/sspower/verdicts/`.
- **Background agents finishing while main thread is mid-edit**: Codex implement's last action sometimes re-checks out a different branch. Always `git rev-parse HEAD && git branch --show-current` before staging.

## Context
- **Branch**: `phase-c` @ `8aee8db` (origin in sync up to `fe35a25`; the 8aee8db handoff commit is local-only on phase-c, also being committed to main as this same file). `main` @ `c8f2d53`.
- **Tests**: 75/75 `scripts/sspower_mem/` (Phase A) + 14 `tests/codex-bridge/test-complete.sh` (Phase B). Run via `cd scripts/sspower_mem && UV_CACHE_DIR=/private/tmp/sspower-uv-cache uv run --with pytest pytest -v` and `bash tests/codex-bridge/test-complete.sh`.
- **Bridge model**: `gpt-5.5` + `xhigh` reasoning default; Phase B `complete` overrides to `minimal` effort, 60s wall cap.
- **Unknowns** (verify before acting):
  - Mem0 import-time side effects in pytest environment — never run real Mem0 init in tests yet.
  - Chroma persistence-dir cleanup semantics in test isolation — use `tmp_path` with explicit teardown.
  - Whether `Memory.add(infer=False)` returns the auto-generated record id or our supplied metadata.id — Phase 0 Q3 said "returned ids: see source" — read `mem0/memory/main.py:add` once before wiring.
  - Real Codex extraction prompt latency on full session-summary text — Phase B integration smoke deferred (Phase B test uses a stub).
- **Plugins repo path**: `/Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower/` (working tree is also the marketplace cache; install consumers pull from `~/.claude/plugins/cache/sskys18/sspower/<version>/`).
