# Codex-Worker LSP Quality Gate + Codex Tier/Review Consolidation — Design Spec

> Status: **v6** (2026-05-18). P0+P1 IMPLEMENTED & committed (`b548683` P0, `d538bd6` P1). **v6 = post-implementation correction:** the locked `service_tier=flex` decision (D-A1/§4.1) was empirically **falsified at execution** — Codex's config schema accepts only `fast|flex`, but the **API rejects `flex` at runtime (`400 Unsupported service_tier: flex`) on this account**. Shipped as **all-`fast`** (proven working end-to-end). The bridge profile-routing machinery is correct and unaffected; only the config tier *value* changed vs the original decision. G1's rate-limit mitigation now rests solely on the call-count cuts (D-A4 fan-out 3→1, cache 600→3600, single auto-gate), not the `flex` lever. (v5 history below retained.)
> Author: Claude (Opus 4.7), 2026-05-17.
> Supersedes: the "**Semble is out of scope** (user decision 2026-05-13)" note in `docs/specs/2026-05-13-index-backend-integration-design.md`. That decision is **reversed**: `johunsang/semble_rs` was validated on a real repo this session (see §2) and is now in scope as Track B.
> HARD-GATE: no implementation until this spec is user-approved. Phased delivery; each phase ships independently.
> **First implementation plan scope: P0 + P1 only** (Cleanup C1–C3/C10 + Track A). P2–P6 (Track B, remaining cleanup) are design intent here but **PROVISIONAL** — re-planned after P1 ships and the spike tools prove out in real use. Mirrors the decomposition precedent in `2026-05-13-index-backend-integration-design.md`.

## 0. Change log

### v5 → v6 (post-implementation: `flex` empirically impossible — corrected to all-`fast`)

Discovered during P1 execution (real `plan-review` dogfood, not catchable by `--print-args` dry-runs):

1. **D-A1/§4.1 `flex` decision falsified.** Codex `config.toml` schema accepts only `fast|flex` (spec was right about the *schema*; `""`/omit → parse error or root-inherit). But the **API returns `400 invalid_request_error: Unsupported service_tier: flex`** for this account/model at request time. `fast` works (verified end-to-end). Therefore the only viable value is **`fast`** — a hard constraint, not a preference.
2. **Resolution:** `~/.codex/config.toml` root + all profiles = `service_tier="fast"` (out-of-repo, plan R1 — not committed; lives in user-global state, must be re-seeded `fast` if regenerated). `deep`/`quick` were already `fast`; only `normal`+root reverted from the planned `flex`.
3. **D-A1, §4.1 rationale, R5, §12 r5 corrected** below (strikethrough-in-spirit: `normal=flex/root=flex` → all `fast`).
4. **G1 impact:** the heavy-volume rate-limit relief now comes **only** from call-count reduction (D-A4 fan-out 3→1, cache TTL 600→3600, single automatic gate). The `flex` tier lever is unavailable on this account. Whether call-count cuts alone fully meet G1 is empirically unverified — monitor.

### v4 → v5 (Codex review iter 4, user-requested: 4 findings, all `[High]`, all P1-blocking — addressed; CONVERGED)

> Methodology note: iter4-attempt-1 mistakenly used `codex-bridge.mjs spec-review` (schema `compliant|non-compliant`, implementation-vs-spec) — it bounced on the HARD-GATE/read-only sandbox, produced no design critique. Re-run with `rescue` (the iter1–3 tool) yielded the 4 findings below. **That misfire empirically confirms Finding 1.**

1. **D-A5 migration target was wrong (Finding 1, self-validated).** v4 migrated plan/design review `rescue → spec-review`. `spec-review`'s schema is `compliant|non-compliant`, implementation-vs-spec oriented — structurally wrong for open-ended design/gap critique (proven: `spec-review` on this very doc produced garbage; `rescue` produced these findings). `review` is diff/code-oriented (same mismatch class). **Resolution: add a dedicated `plan-review` command + `schemas/plan-review-output.json` to the bridge; migrate plan/design callers there.** This **adds P1 scope: 1 bridge command + 1 schema** (§12 rows 6c, 8a, 8b). Alternative (reuse `review`, accept schema mismatch) rejected — recreates Finding 1. D-A3, D-A5, §4.4, §6, §12 updated.
2. **D-A6 precedence contradicted §4.2 (Finding 2).** D-A6 said `--profile > --effort/-c > COMMAND_PROFILE`; §4.2 says explicit `--model`/`--effort` patch individual fields of the profile. D-A6 replaced with the §4.2 rule verbatim.
3. **Wrong effort key still in §4.2 prose + resume path (Finding 3).** §4.2 "Critical bridge-semantics" para and the `resume` para still wrote `-c reasoning.effort=`. Must be `-c model_reasoning_effort="..."` **everywhere** — bridge sites confirmed at `codex-bridge.mjs:370` AND `:907` (v4 named only :370), plus `runCodexExec`/`_runCodexComplete`/resume-repair. §4.2 + §12 r6 corrected.
4. **P1 omitted `cmdResume` (Finding 4).** `cmdResume` (bridge `:1402`) default-emits `-m gpt-5.5` via `resolveModel(opts.model)` (`:1410`) — so no-flag resume kills root config just like the other 4 commands. v4's default-`-m` removal list (cmdImplement/Review/SpecReview/Complete) must include `cmdResume`. §4.2 + §12 r6 amended. (Line refs: bridge drifted since v3's 1033/1235/1288/1302; v5 cites current `:1402/:1410` + names functions — verify at P1.)

### v3 → v4 (Codex spec-review iter 3, user-requested: needs-attention, 5 blocking + 3 advisory — addressed; PLATEAU [RETRACTED v5])

1. **Precedence rule fixed** — was self-contradictory ("profile > effort" vs "emit `-c` when effort explicit"). Final rule: **`--profile` supplies field defaults; explicit `--model`/`--effort` override individual fields within that profile** (Codex CLI: explicit `-c` overrides profile). §4.2.
2. **`--effort` key** — must emit `-c model_reasoning_effort="..."` (NOT `reasoning.effort=` which bridge.mjs:370 currently uses against the wrong key). P1 changes the emitted key. §4.2 + §12 row 6.
3. **NEW live caller (Codex iter3 #3, missed by iter1/2):** `hooks/prompt-submit:126` calls `enrich`; if disabled-enrich exits 0 with a notice, prompt-submit:140 injects that notice **as the enriched prompt**. §12: disable the enrich call in `hooks/prompt-submit`; disabled `enrich` must echo the **raw prompt verbatim** to stdout, notice to stderr only. D-A2 amended.
4. **Security allowlist concrete** — no `~`, no `<placeholder>`. Exact expanded absolute paths in §4.4.
5. **codex-lsp discovery (P3)** — codex-lsp NOT on PATH (cloned to /tmp during spike). P3 must define a vendored/install path + discovery contract. §5.7a.
6. **P3 wording** — "converges or emits `would-block`; `BLOCKED` only when blocking env enabled". §9.
7. **Per-command MCP required/optional** — via **bridge-generated `.codex/config.toml`** (resume has no `--profile`; can't be profile-scoped). §5 B1.
8. (advisory) Track A model confirmed coherent by Codex; only the bridge default-`-m`/`-c` removal (#1/§12 r6) is load-bearing.

### v2 → v3 (Codex spec-review iter 2: needs-attention, 6 blocking + 1 advisory — all addressed; Codex cap reached)

1. **Bridge default routing** — bridge must pass `--profile` by default and pass `-m`/`-c` **only when user explicitly supplied** `--model`/`--effort` (else `resolveModel()` default `gpt-5.5` + effort `-c` override the profile). §4.2 + §12 row 6 amended.
2. **D-A4 self-contradiction removed** — exact behavior: **MAIN always; SECURITY additionally on strict/high-risk; otherwise off**. Success criterion: 1 call normally, 2 on strict/high-risk.
3. **Security config surface defined** — `SSPOWER_SECURITY_REPOS` env (colon-sep path-prefix list), default source, match rule, install location. §4.4 + §12.
4. **D-B3 needs a real MCP client** — `_spawnAndCapture` is Codex-JSONL-specific; P3 must build a small JSON-RPC/MCP stdio client (initialize, tools/call, id correlation, framing, timeout, shutdown). §5.7a amended.
5. **Advisory vs BLOCKED split** — command `status` stays `DONE` in advisory mode; `_lsp.decision="would-block"|"block"|"clean"`; only blocking-mode returns non-acceptance. §5.7/§5.7b amended.
6. **resume repair contract** — repair resumes pass `-c model_reasoning_effort="high"` (no `--profile`); pre-resume concurrency check rejects if registry says session running/killed/stale. §5.7b amended.
7. **(advisory) P0 C10 verification reworded** — repo has 22 `SKILL.md`; the bug is README *listing* `codex-enrich-workspace` (no SKILL.md). Verify = README table matches actual SKILL.md set, not a count change.

### v1 → v2 (Codex spec-review iter 1: needs-attention, 9 blocking + 2 advisory — all addressed)

1. **D-A3 caller migration** — `rescue` is called by live skills (`brainstorming/SKILL.md:38`, `brainstorming/references/after-design.md:25`, `writing-plans/SKILL.md:86`, second-opinion, codex-enrich). D-A3 amended: rescue stays functional until all callers migrate; migration matrix is §12; disable is the **last** P1 step. (Note: this very brainstorming run used `rescue` for spec-review.)
2. **D-A5 contract made explicit** — §4.4 now defines the exact hooks.json/skill change, not just intent.
3. **Config reality** — §4.1/§12 now state the actual current values (root + `[profiles.normal]` = `fast`, lines 1-3/61-64) that P1 must edit to `flex`.
4. **Key name** — `reasoning_effort` → **`model_reasoning_effort`** (actual Codex profile key; wrong key = silent no-op).
5. **`--effort` preserved** — not removed; kept as compat/override flag (auto-review.sh:377/385/402 passes it). `--profile` added alongside.
6. **`resume` profile** — verified `codex exec resume` has no `--profile`; `resume` uses root config (∴ root must be `flex`) + optional `-m`/`-c` only.
7. **D-B3 MCP lifecycle** — §5.7a added (server-per-run, init, root, file-open, timeout, shutdown, unavailable).
8. **D-B6 vs P3** — P3 success criterion reworded to "reports would-block advisory" (no blocking unless mode flipped).
9. **Repair-loop termination** — §5.7b added (no-diff, same-diagnostics, missing/stale session, nonzero resume, registry-running, HEAD drift).
10. **Security hybrid** — D-A4 amended: security auto-ON for configured high-risk repo paths + strict branches, manual elsewhere (user decision; Codex + Claude independently converged on this regression risk).
11. **P0/P1 change matrix** — §12 added (per-file + caller migration) so P0+P1 is single-pass implementable.

### v1 (initial)

Captures two tracks designed in the 2026-05-17 session:

- **Track A** — Codex tier + review-architecture consolidation. Decisions fully settled this session; ~3 file edits; ships first; no unknowns.
- **Track B** — Codex-as-worker + semble_rs context + codex-lsp quality gate. Validated by spike (§2). Phased advisory→block. Larger surface.

Plus a **Cleanup track** folding the 12 tech-debt items from the full-plugin audit.

The session reversed several decisions mid-flight (rescue keep→disable; security manual→strict→manual; spec-gate off→plan-driven). §6 reconciles the final state explicitly so the spec is unambiguous.

## 1. Context & goals

### 1.1 Problem

1. Codex is invoked through `sspower/scripts/codex-bridge.mjs` for `implement`/`review`/`spec-review`/`enrich`/`complete`/etc. Tiers (`service_tier`), per-command reasoning effort, and the auto-review fan-out (3 parallel codex calls × up to 3 rounds × cross-checkpoint) are mistuned — caused a transient rate-limit failure burst (11 failures in a ~50min window, 2026-05-16).
2. Codex worker output is trusted on self-report. No independent post-run verification (LSP/tests) by the bridge.
3. Agent context is wasted on `grep -R` / `ls -R` / full-file reads when token-cheap semantic search exists.
4. 12 tech-debt items in the plugin (version skew, orphaned skill, marketplace↔cache bridge divergence, etc.).

### 1.2 Goals

- **G1** Consolidate all codex tier/effort control into `~/.codex/config.toml` profiles (single source of truth). One automatic review path.
- **G2** Make Claude the supervisor/final-gate, Codex the worker, codex-lsp the worker's inner + bridge-side quality gate. Bridge independently verifies Codex output (LSP) before accepting it.
- **G3** Inject token-cheap repo context via semble_rs; rewrite token-explosive commands.
- **G4** Clean the plugin to a consistent, documented, single-source state.

### 1.3 Non-goals

- Forking/maintaining `code-yeongyu/codex-lsp` (decision **D-B3**: reuse its MCP surface, do not fork).
- semble_rs `digest` (spike inconclusive on clean log — deferred to a follow-up, not in this spec's delivery).
- Replacing Claude-side native LSP.

## 2. Validated facts (spike, 2026-05-17)

Independently measured on `~/Mine/kimp` (193 git-tracked files) and a synthetic TS repo:

| Tool | Result | Source |
|---|---|---|
| `semble_rs search` (warm) | 3,639 B vs grep+read baseline ~110,447 B (~30×) | Claude byte count |
| `semble_rs tree` | 4,081 B vs `ls -R` 12,066,847 B (~3000×) | Claude byte count |
| `semble_rs` self-stat | 86% token savings | tool, corroborated |
| `semble_rs` latency | first 5s (incl ~60 MB model dl), warm 1s | measured |
| `semble_rs digest` | clean cargo log no-op (123B→123B) — **inconclusive** | measured |
| codex-lsp `hook post-tool-use` | 2s, accurate TS diagnostics, correct `{decision:"block",hookSpecificOutput.additionalContext}` | measured |

- `semble_rs` = real Rust binary, `git clone … && cargo install --path .` → `~/.cargo/bin/semble_rs` (26.1 MB). Commands: `search/find-related/deps/impact/find-pattern/plan/savings/tree/encode/digest`. v0.9.1, ~2 days old.
- `codex-lsp` = real TS/Node, prebuilt `dist/cli.js`, `bun install` builds. `hook post-tool-use` + `mcp` (7 LSP tools). v0.1.0, ~2 days old. `typescript-language-server` already on PATH.
- Both **brand-new and pre-1.0** — real but unproven at scale. Mitigated by advisory-first rollout (**D-B6**).

**Loaded-copy fact:** `~/.claude/settings.json` registers the marketplace path (`source_type=local`). Claude Code loads the **1770-line marketplace** `codex-bridge.mjs`, NOT the 1479-line cache copy. All edits target the marketplace tree. Cache copy is stale dead weight (Cleanup C3).

## 3. Architecture

```
Claude (supervisor / final gate)
   │ 1. task envelope
   ▼
codex-bridge.mjs
   │ 2. record baseHead (git rev-parse HEAD)
   │ 3. codex exec --json --output-schema --sandbox workspace-write  (profile: normal|deep)
   ▼
Codex worker  ── 4. PostToolUse: codex-lsp diagnostics (self-repair)
   │           ── 5. Stop: codex-lsp final LSP gate (self-repair)
   ▼
codex-bridge.mjs
   │ 6. git diff --name-only baseHead → changed files
   │ 7. query codex-lsp MCP (lsp.diagnostics) per changed file  [D-B3: MCP, not CLI fork]
   │ 8. errors? → codex exec resume <session_id> (≤2 repair rounds) → re-verify
   │ 9. write bridge-COMPUTED _lsp / _verification (overrides Codex self-report)
   ▼
Claude  → 10. final judgement / review / merge gate
```

Two-layer LSP verification: Codex-internal hooks (medium trust, fast self-repair) + bridge post-run via MCP (high trust, authoritative). **Codex self-report is advisory; bridge-computed `_lsp` is truth.**

## 4. Track A — Codex tier & review consolidation

### 4.1 Profiles (`~/.codex/config.toml`) — single source of truth

`service_tier` config-schema values are only `flex` and `fast`. **v6 correction: `flex` is API-rejected at runtime on this account (`400 Unsupported service_tier: flex`); the only working value is `fast`. All profiles + root use `fast`.**

Profile key is **`model_reasoning_effort`** (the actual Codex config key — NOT `reasoning_effort`; wrong key silently no-ops).

| Profile | model | model_reasoning_effort | service_tier | Consumers |
|---|---|---|---|---|
| `quick` | gpt-5.4 | low | `fast` | complete (+ enrich if it existed; disabled per D-A2) |
| `normal` | gpt-5.5 | high | `fast` (was `flex` — v6: flex API-dead) | review r0/r1, implement, resume, spec-review |
| `deep` | gpt-5.5 | xhigh | `fast` | review r2 (stuck), strict-branch review |
| root default | gpt-5.5 | — | `flex` | safety fallback; `resume` (no `--profile`) inherits this |

**Current actual config (P1 must change):** `~/.codex/config.toml:3` root `service_tier = "fast"`; `[profiles.normal]` (lines 61-64) `service_tier = "fast"`. P1 edits root + `profiles.normal` → `flex`; `quick`/`deep` keep `fast`.

~~Rationale: `fast` reserved for rare-but-critical (`deep`)... heavy path (`normal`) on `flex`...~~ **v6: VOID — `flex` is API-rejected on this account; all tiers forced to `fast`.** The intended "heavy path off the priority pool" benefit is unavailable; rate-limit sustainability now rests entirely on the call-count cuts (D-A4 fan-out 3→1, cache 600→3600, single auto-gate). `unset`/`""` is not an option (config schema rejects it). Monitor whether call-count reduction alone holds G1.

### 4.2 Bridge profile routing (`codex-bridge.mjs`)

Add a `--profile` passthrough + default `COMMAND_PROFILE` map: `implement/review/spec-review → normal`; `complete → quick`. **`--effort` parser support is PRESERVED** (not removed) as a compat/override flag — `auto-review.sh:377/385/402` and docs/skills still pass `--effort`; removing it breaks live callers.

**Precedence (single rule, Codex iter3 #1):** `--profile` (explicit or `COMMAND_PROFILE` default) supplies the field defaults via `-p`. Explicit `--model`/`--effort` then **override individual fields within that profile** by additionally emitting `-m`/`-c`. They do not "beat" the profile — they patch fields of it (Codex CLI: an explicit `-c` overrides the profile's value for that key only). No `--model`/`--effort` ⇒ profile fields used as-is, nothing emitted.

**`--effort` emits the correct key (Codex iter3 #2):** when `--effort X` is explicit, emit `-c model_reasoning_effort="X"` — NOT `-c reasoning.effort=` (the key bridge.mjs:370 currently uses, which does not match the profile/config key `model_reasoning_effort` and silently no-ops at profile level).

**Critical bridge-semantics change (Codex iter2 #1, iter4 Finding 4):** today `cmdImplement/cmdReview/cmdSpecReview/cmdComplete` **and `cmdResume`** unconditionally pass `resolveModel(opts.model)` (returns default `gpt-5.5`) and a resolved-effort `-c` (bridge sites: cmdComplete `:1032`, cmdImplement `:1245`, cmdSpecReview `:1287`, cmdReview `:1301`, **cmdResume `:1410`** — lines drifted from v3's 1033/1235/1288/1302; verify at P1). That **overrides any profile/root config**. P1 must change **all five** to: pass `-p <COMMAND_PROFILE|--profile>` by default (resume excepted — no `--profile`, see below), and emit `-m`/`-c model_reasoning_effort="..."` **only when the user explicitly supplied** `--model`/`--effort` (track "user-supplied" vs "defaulted" in arg parsing). Otherwise the profile/root config is dead on arrival.

**Effort key (Codex iter3 #2, iter4 Finding 3):** every `-c` effort emission — in `runCodexExec`, `_runCodexComplete`, and the resume-repair path — must use `-c model_reasoning_effort="X"`, NOT `-c reasoning.effort="X"`. The wrong key is currently emitted at `codex-bridge.mjs:370` **and `:907`** (v4 named only :370). P1 fixes both.

`resume`: **verified** `codex exec resume` has NO `--profile` flag. `resume` therefore uses root config.toml (∴ root `service_tier=flex` is load-bearing) plus optional `-m`/`-c model_reasoning_effort=` only. **`cmdResume` must also track user-supplied vs defaulted (Finding 4): no-flag resume must emit NO `-m`/`-c`** so root config governs — today `:1410` default-emits `-m gpt-5.5`. No profile assumption in the repair loop may depend on `--profile` for resume.

`complete`: keeps its existing custom path; profile applied via the same `-c`/profile mechanism as today, `quick` default.

### 4.3 Review ladder (`auto-review.sh`)

Replace the effort `case` with a profile `case`:

- round 0 → `normal`
- round 1 → `normal` (stuck retry, no escalation)
- round 2 → `deep`
- strict branch (`main|master|prod|release/*`) → `deep` always
- cap stays 3 (rounds 0,1,2 = normal,normal,deep)

### 4.4 Only the universal MAIN review runs automatically

- **Exact behavior (Codex iter2 #2):** MAIN review runs **always**. SECURITY runs **additionally** iff branch is strict (`main|master|prod|release/*`) OR repo path matches `SSPOWER_SECURITY_REPOS`. SANITY default on → **off** (manual only). Otherwise: MAIN only.
- Codex calls per clean push: **1 normally, 2 on strict/high-risk** (MAIN + SECURITY). Down from 3.
- `SSPOWER_SECURITY_REPOS` (Codex iter2 #3 / iter3 #4): colon-separated **fully-expanded absolute** path-prefix list (NO `~`, NO placeholders — string-prefix-matched against `git rev-parse --show-toplevel`). P1-seeded default in `auto-review.sh`:
  `/Users/sskys/blockwavelabs/custody-dashboard-solution:/Users/sskys/blockwavelabs/danal/pay-chain:/Users/sskys/blockwavelabs/danal/danalstable-frontend:/Users/sskys/blockwavelabs/danal/danalstablecoin-backend:/Users/sskys/blockwavelabs/infinite-block/security`
  Overridable by exporting the env. `SSPOWER_SECURITY_REVIEW=on/off` still forces per-invocation.
- `auto-spec-gate.sh` (D-A5 explicit contract): **remove its entry from `hooks/hooks.json` `PreToolUse:Bash`** (it currently sits at hooks.json:54, commit-driven). Its review logic is repackaged as a callable: `brainstorming/SKILL.md` (after-design step) and `writing-plans/SKILL.md` invoke `codex-bridge.mjs plan-review --cd . --prompt @<plan>` directly at their HARD-GATE (**`plan-review`, NOT `spec-review`** — Codex iter4 Finding 1: `spec-review`'s impl-vs-spec schema is wrong for design/plan critique). Net: plan/spec review fires **once, inside the planning workflow**, not on every `docs/plans/*` commit. `writing-plans/SKILL.md:56-79` updated to call `plan-review` explicitly. The standalone `auto-spec-gate.sh` script is retained (for manual `SSPOWER_SPEC_GATE=on` use) but unwired by default.

### 4.5 Cache

Verdict cache TTL `600s → 3600s`. Cross-checkpoint diff-hash unification **dropped** — moot once only one automatic gate exists (the multi-gate duplication is removed by D-A4/D-A5, not cached around).

## 5. Track B — Codex-worker LSP quality gate (phased)

### Phase B1 — Codex sees the same LSP

- Create `~/.codex/lsp-client.json` (typescript/python/rust/go/c_cpp → existing servers on PATH).
- Register `lsp` MCP in `.codex/config.toml` for the bridge's project root with explicit `env.PATH`/`HOME` (Codex subprocess PATH ≠ Claude PATH).
- **MCP required/optional is bridge-generated, not profile-scoped (Codex iter3 #7):** `resume` has no `--profile`, so required/optional cannot ride profiles. The bridge writes a per-run `.codex/config.toml` fragment setting `mcp_servers.lsp.required = true` for `implement`/`resume` runs and `false`/absent for `review`. One generated config per run, torn down after.
- **codex-lsp discovery (Codex iter3 #5):** codex-lsp is NOT on PATH (spike cloned to `/tmp`). P3 vendors it at `sspower/tools/codex-lsp/` (committed `dist/cli.js`) or resolves `SSPOWER_CODEX_LSP_CLI` env → explicit path. Bridge/hook fail-open (skip, log) if unresolved. No reliance on PATH.
- Smoke: `codex exec --sandbox read-only --json "Call lsp.status…"`.

### Phase B2 — Codex internal self-repair

- Repo-local `.codex/hooks.json` (NOT plugin_hooks) → `PostToolUse: ^(apply_patch|Edit|Write)$` → codex-lsp `hook post-tool-use`.
- Rollout advisory → block (D-B6).

### Phase B3 — Bridge-side gate via codex-lsp MCP (D-B3)

- Bridge computes changed files from `git diff --name-only baseHead`.
- Bridge spawns/queries codex-lsp `mcp` over stdio, calls `lsp.diagnostics` per changed source file. **No CLI fork.**
- Result normalized into `_lsp` (see §5.7).

### Phase B4 — Bridge final gate + repair loop (`codex-bridge.mjs`)

`runCodexExec`/`runCodexResume`: record baseHead → run (ephemeral=false so session is resumable) → changed files → MCP diagnostics → if errors and sessionId: `codex exec resume <id>` with a scoped repair prompt → re-verify → ≤2 repair rounds → still errors ⇒ structured `status:"BLOCKED"` + `_lsp`; clean ⇒ auto-commit/review.

### Phase B5 — Codex Stop gate

- `.codex/hooks.json` `Stop` → bridge-style check (changed source files + remaining LSP errors → `decision:"block"` with reason → Codex continues fixing). Implemented after B3 (depends on MCP query path).

### Phase B6 — Codex rules / sandbox / approval profiles

- `.codex/rules/sspower.rules`: `git commit`/`git push` **forbidden** (sspower owns commits/push); `rm -rf` forbidden; `pnpm|npm install` **prompt**.
- Bridge profile: `approval_policy="never"`, `sandbox_mode="workspace-write"`, `network_access=false`.
- Interactive (human Codex TUI): `approval_policy="on-request"` + `auto_review` (auto_review is meaningless under `never`).

### Phase B7 — semble_rs context + command rewrite (Claude side)

- `UserPromptSubmit`: coding-intent-gated `semble_rs plan`/`search --compact` context inject (advisory, `additionalContext`, length-capped). Sits in front of the existing prompt-submit flow.
- `PreToolUse:Bash`: rewrite `ls -R`→`semble_rs tree`, bare `grep -R`→`semble_rs search --compact` (allow/ask, **never deny**).
- `SessionStart`: availability check (`semble_rs`, codex-lsp `dist/cli.js`, node/jq, model warm) → short status; warmup with short timeout (avoid 60 MB first-run stall on UserPromptSubmit).
- `PostToolUse:Write|Edit|MultiEdit`: codex-lsp diagnostics on **Claude's own** edits, advisory first (D-B6).
- Deferred from the pasted plan: `semble_rs digest` (spike inconclusive), `PreToolUse:Read` deny-guard, `PostToolBatch`, Stop block-gate on the Claude side — revisit after B1–B6 prove out.

### 5.7 Schema additions

`implementation-output` schema gains bridge-computed fields, distinct from Codex-reported `tests`:

```json
"_lsp": { "status": "clean|errors|unavailable|skipped", "checked_files": [...], "total_errors": 0, "errors": [{file,line,character,message,source,severity}] },
"_verification": { "tests_run": [...], "passed": true, "notes": "..." }
```

`tests` = Codex self-report. `_lsp`/`_verification` = bridge-observed. Claude judges on the latter.

### 5.7a MCP lifecycle (D-B3, resolves Codex#7 / Q1)

- **One codex-lsp `mcp` server per bridge run** (not shared with the Codex worker's own MCP — separate process, separate LSP state; that isolation is intentional and acceptable).
- **Needs a real MCP client (Codex iter2 #4):** `_spawnAndCapture` is Codex-JSONL/result-file specific and CANNOT be reused for MCP. P3 builds a minimal JSON-RPC-over-stdio client: `initialize` handshake → `tools/call` `lsp.diagnostics` per file → request-id correlation → newline/Content-Length framing per MCP → per-call timeout → `shutdown`/exit. ~150 LOC, isolated module (`scripts/mcp-lsp-client.mjs`).
- Bridge spawns the stdio child *after* the Codex run completes (post-run gate only; not during the worker turn).
- Init: MCP `initialize` handshake; project root = `--cd` (the worktree/repo root the bridge used); for each changed source file, send file URI; call `lsp.diagnostics`.
- Diagnostics timeout: per-file 30s, whole-gate cap 120s. Timeout → `_lsp.status="unavailable"` (fail-OPEN: do not block on infra failure; log to `sspower-codex.log`).
- Shutdown: explicit MCP `shutdown` + process kill on gate completion (no leaked stdio child). Registered in the bridge cleanup path alongside `cleanupTmpDir()`.
- Unavailable semantics: codex-lsp/`dist/cli.js` missing or non-zero → `_lsp.status="skipped"`, gate passes (advisory), logged.

### 5.7b Repair-loop termination + advisory/block split (resolves Codex iter1#9 / iter2 #5,#6 / R5)

**Status fields (advisory ≠ BLOCKED, Codex iter2 #5):** command `status` stays `DONE` (or its original value) in advisory mode — the bridge does NOT fail the run. The verdict lives in `_lsp.decision ∈ {clean, would-block, block}`:
- advisory mode (default, D-B6): errors ⇒ `_lsp.decision="would-block"`, `status` unchanged. Claude sees it, decides.
- blocking mode (user-flipped env): errors ⇒ `_lsp.decision="block"` and command returns non-acceptance (`status:"BLOCKED"`).

**Repair resume contract (Codex iter2 #6):** repair uses `codex exec resume <session_id>` with `-c model_reasoning_effort="high"` (no `--profile` on resume) — root `flex` tier applies. Before each repair resume: query session registry; if it reports the session `running`/`killed`/stale, **abort the loop** (no concurrent `steer`/resume collision) and emit `would-block`/`block` with reason.

Loop stops on ANY of:

1. ≤2 repair rounds exhausted.
2. **No-progress**: post-resume `git diff` unchanged vs pre-resume (Codex made no edit).
3. **Same-diagnostics**: identical error set (file+line+code hash) two rounds running.
4. Missing/empty `session_id`.
5. `codex exec resume` non-zero exit.
6. Registry says session `running`/`killed`/stale (pre-resume concurrency check).
7. **HEAD drift**: repo HEAD changed unexpectedly between baseHead snapshot and gate → abort, no auto-commit.

Clean (0 errors) ⇒ `_lsp.decision="clean"` ⇒ proceed to auto-commit/review.

### 5.8 Run artifacts

`~/.claude/sspower-codex/runs/<run-id>/`: `prompt.txt`, `events.jsonl`, `result.json`, `diff.patch`, `changed-files.txt`, `lsp-before.json`, `lsp-after.json`, `bridge.json` (run_id, session_id, mode, base/final head, model, profile, tool/edit counts, tokens, lsp status, tests).

## 6. Reconciliation of session decision churn

| Topic | Final state | Note |
|---|---|---|
| `enrich` | **Disabled** (D-A2) | Bridge `enrich` exits with notice; `codex-enrich` skill goes dead (also Cleanup). Worker prompt-envelope is for implement/resume, unrelated to enrich. |
| `rescue` (subcommand) | **Disabled — but migration-gated** (D-A3) | Live callers exist (brainstorming, writing-plans, after-design, second-opinion, codex-enrich). rescue stays functional until §12 migration completes; disable is the LAST P1 step. Plan/design callers migrate to new **`plan-review`** (iter4 Finding 1), code callers to `review`. |
| Track B repair loop | **Uses `resume`, not `rescue`** | The LSP-error repair is `codex exec resume <same session>`, bridge-internal, automatic. `resume` plumbing stays (also needed by `steer`). Distinct mechanism; no contradiction with D-A3. |
| `security`/`sanity` | **Hybrid** (D-A4) | sanity off-auto. security auto-ON for configured high-risk repo paths + strict branches, manual elsewhere (user decision; Codex+Claude converged). |
| `auto-spec-gate` | **Plan-driven, not commit-driven** (D-A5) | Fires from brainstorming/writing-plans HARD-GATE, not raw `docs/plans/*` commits. |
| Semble scope | **In scope** | Reverses 2026-05-13 "out of scope" (validated this session). |

## 7. Cleanup track (folds the 12 audit items)

Ship alongside Track A (low-risk, high-leverage):

- **C1** `package.json` version `1.0.0`→`1.1.0` (skew vs plugin.json).
- **C2** Delete orphaned `skills/codex-enrich-workspace/` (no SKILL.md; falsely advertised). Aligns with D-A2.
- **C3** Resolve marketplace↔cache `codex-bridge.mjs` divergence (1770 vs 1479) — cache is stale/unused; document marketplace as canonical, remove/ignore cache reliance.
- **C4** Hook integration tests (chain policy, verdict assembly, round cap).
- **C5** Document real env knobs; remove unread `SSPOWER_LOG_*` or wire them.
- **C6** Stale `.git/sspower-review-rounds-*` auto-cleanup.
- **C7** Auto-apply patch audit trail / opt-out visibility.
- **C8** `SSPOWER_DIET=off` permanent disable.
- **C9** Schema validation for `resume`/`complete`.
- **C10** Doc fixes: README "22 skills" count, ARCHITECTURE `--profile` tunability, effort-uniformity claims.
- (C11/C12 minor: rounds clutter, dead skill refs — covered by C2/C6.)

## 8. Locked decisions

- **D-A1** All codex tier/effort via `~/.codex/config.toml` profiles. ~~`deep=fast, normal=flex, quick=fast, root=flex`~~ **v6: all `fast` (`deep=fast, normal=fast, quick=fast, root=fast`) — `flex` API-rejected on this account; profile-routing machinery (model/effort per profile) unaffected.**
- **D-A2** `enrich` disabled. Disabled `enrich` echoes the **raw prompt verbatim to stdout** (notice → stderr only) so the live `hooks/prompt-submit:126` caller injects the unmodified prompt, not a notice (Codex iter3 #3). `hooks/prompt-submit` enrich call removed in P1.
- **D-A3** `rescue` subcommand disabled **only after §12 caller migration completes** (last P1 step). `resume` retained (Track B + steer). Migration targets (Codex iter4 Finding 1 — corrected): plan/design-review callers → **new `plan-review` command** (NOT `spec-review`: its `compliant|non-compliant` impl-vs-spec schema is structurally wrong for open-ended design critique; NOT `review`: diff/code-oriented, same mismatch); code-review callers → `review` (exists). `plan-review` + `schemas/plan-review-output.json` is new P1 scope (§12 r6c).
- **D-A4** Auto push gate = MAIN review only; sanity off-auto. **Security: hybrid** — auto-ON when repo path matches `SSPOWER_SECURITY_REPOS` (configured high-risk: custody/stablecoin/pay-chain/security paths) OR branch is strict (`main|master|prod|release/*`); manual elsewhere. Review ladder normal→normal→deep, strict→deep. Cache TTL 3600s. Cross-checkpoint dedupe dropped.
- **D-A6** `--effort` parser support preserved as compat/override; `--profile` added alongside. **Precedence (Codex iter4 Finding 2 — §4.2 rule verbatim, supersedes the prior contradictory ordering):** `--profile` (explicit or `COMMAND_PROFILE` default) supplies field defaults via `-p`; explicit `--model`/`--effort` then **patch individual fields within that profile** by additionally emitting `-m`/`-c model_reasoning_effort` (Codex CLI: explicit `-c` overrides the profile's value for that key only) — they do not "beat" the profile, they override per-field. No `--model`/`--effort` ⇒ profile fields used as-is, nothing emitted. `resume` has no `--profile` (verified) → root config governs it (plus optional explicit `-m`/`-c` per Finding 4).
- **D-A5** `auto-spec-gate` driven by brainstorming/writing-plans HARD-GATE, not raw plan commits.
- **D-B1** Claude=supervisor, Codex=worker, codex-lsp=quality gate. Bridge-computed `_lsp` overrides Codex self-report.
- **D-B2** Codex sees existing language servers via `~/.codex/lsp-client.json` + explicit MCP `env.PATH`.
- **D-B3** Bridge-side gate reuses codex-lsp **MCP `lsp.diagnostics` over stdio**. NO fork, NO CLI extension of the third-party repo. Lifecycle per §5.7a (one server per run, fail-open on unavailable, explicit shutdown).
- **D-B7** Repair loop terminates per §5.7b (7 stop conditions). LSP/MCP infra failure fails OPEN (advisory), never blocks on infra.
- **D-B4** Codex never commits/pushes (rules: forbidden). sspower owns git surface.
- **D-B5** Bridge profile `never`+`workspace-write`+`network off`; interactive `on-request`+`auto_review`.
- **D-B6** Every gate ships **advisory first**. Promotion to block is a **user-gated decision** (not time-based): user reviews N clean advisory runs in `sspower-codex.log` and explicitly flips the mode env var. Default stays advisory until that decision.
- **D-C1** Marketplace tree is canonical; cache copy is not a source of truth.

## 9. Phased delivery & success criteria

| Phase | Scope | Success criterion | Ships with |
|---|---|---|---|
| **P0** | Cleanup C1–C3, C10 | version consistent; orphan gone; canonical bridge documented | first commit |
| **P1** | Track A (§4) + §12 caller migration | no-flag run spawns `-p <profile>` + no default `-m`/`-c`; `--effort` still parses; clean push = **1 call (2 on strict/high-risk)**; ladder in `sspower-codex.log`; rescue callers migrated then rescue disabled (last) | Track A |
| **P2** | B1+B2 | `lsp.status` smoke passes; Codex self-repairs a seeded TS error (advisory) | Track B start |
| **P3** | B3+B4 | bridge `_lsp.decision` reports `would-block` (advisory) for a Codex run leaving a TS error; repair loop converges (≤2 rounds, `decision=clean`) **or emits `would-block`**; emits `BLOCKED` **only when blocking env enabled** (D-B6) | core gate |
| **P4** | B5+B6 | Stop gate blocks on remaining errors; rules forbid `git commit` inside Codex | hardening |
| **P5** | B7 | semble_rs context injected on coding prompts; `ls -R`/`grep -R` rewritten; advisory LSP on Claude edits | context layer |
| **P6** | C4–C9 | hook integration tests green; remaining debt closed | cleanup tail |

Advisory→block promotion (D-B6) is a gated step within P2/P3/P4, not automatic.

## 10. Risks & open questions

- **R1** semble_rs/codex-lsp are pre-1.0, 2 days old. Mitigation: advisory-first, availability guards (`command -v … || exit 0`), no hard dependency in critical path until proven.
- **R2** ~~Security off-auto~~ **RESOLVED v2** — hybrid (D-A4): security auto-ON for `SSPOWER_SECURITY_REPOS` paths + strict branches, manual elsewhere. Codex (iter1 #10) and Claude independently flagged the full-manual regression; user accepted hybrid. Residual: the high-risk repo allowlist must be configured correctly (P1 sets the initial list: custody-dashboard, pay-chain, infinite-block/security, stablecoin repos).
- **R3** `codex exec resume` `-p` support unverified — fallback to root flex documented.
- **R4** Codex subprocess PATH/env divergence could make MCP `lsp` server fail to find language servers. Mitigated by explicit `mcp_servers.lsp.env`. `required=true` makes failure loud (good).
- **R5** Repair-loop cost: each LSP-fail round = another resume turn. Cap at 2; BLOCKED beats infinite. ~~Tier `normal=flex` keeps cost bounded~~ **(v6: `normal=fast`; cost bound now from round cap + call-count cuts, not tier).**
- **Q1** Does the bridge spawn one persistent codex-lsp MCP per run or one per project session? (Perf vs isolation — resolve in P3.)
- **Q2** Run-artifact retention/rotation policy (disk growth) — resolve in P3.

## 11. Out of scope (this spec)

semble_rs `digest`; PreToolUse Read deny-guard; PostToolBatch; Claude-side Stop block-gate; OTel export; forking codex-lsp; Claude-side native LSP replacement. All revisitable post-P5.

## 12. P0 + P1 change matrix (single-pass implementable)

Ordered. Each row = one file, one change, one verification. P1 step 9 (rescue disable) is **last** and gated on steps 6-8.

| # | File | Change | Verify |
|---|---|---|---|
| **P0** | | | |
| 1 | `package.json` | version `1.0.0`→`1.1.0` (C1) | matches `.claude-plugin/plugin.json` |
| 2 | `skills/codex-enrich-workspace/` | delete dir (C2; no SKILL.md, orphaned) | not in skill router; README count fixed |
| 3 | `README.md`, `docs/ARCHITECTURE.md` | remove orphan `codex-enrich-workspace` from README skill table; add `--profile` tunability; fix effort-uniformity claim (C10). NOT a count edit — repo has 22 real SKILL.md | README skill table == actual `find skills -name SKILL.md` set |
| 4 | `docs/` note | document marketplace tree canonical, cache stale (C3, D-C1) | one-liner in ARCHITECTURE |
| **P1 — config** | | | |
| 5 | `~/.codex/config.toml` | **v6: NO-OP for tier — keep root + all profiles `service_tier="fast"`** (planned `fast`→`flex` reverted: `flex` API-rejected, `400`). Profile key `model_reasoning_effort` per matrix still applies. | real `--profile normal` call exits 0 (NOT a 400); `grep -c flex ~/.codex/config.toml` = 0 |
| **P1 — bridge** | | | |
| 6 | `scripts/codex-bridge.mjs` | add `--profile`+`-p` passthrough; `COMMAND_PROFILE` map; **default `-p`, emit `-m`/`-c` ONLY if user explicitly supplied `--model`/`--effort`** (track user-supplied in parser; else `resolveModel()` default kills profile/root config). Apply to **all five**: cmdComplete `:1032`, cmdImplement `:1245`, cmdSpecReview `:1287`, cmdReview `:1301`, **cmdResume `:1410`** (Finding 4 — resume excepted from `-p`, no `--profile`; still must suppress default `-m`). Fix wrong effort key at **both `:370` and `:907`**: `reasoning.effort=` → `model_reasoning_effort=` (Finding 3); explicit `--effort X` emits `-c model_reasoning_effort="X"`; keep `--effort` parser; `enrich`→**echo raw prompt to stdout**, notice to stderr (iter3 #3); `complete`→`quick`. (Lines drifted from v3; verify before edit.) | no-flag `review` spawns `-p normal`, no `-m`/`-c`; **no-flag `resume` emits no `-m`/`-c`** (root governs); `--effort high`→`-c model_reasoning_effort="high"`; `grep -n 'reasoning\.effort=' bridge` = 0; `enrich foo`→stdout==`foo` |
| 6c | `scripts/codex-bridge.mjs` + `schemas/plan-review-output.json` | **NEW (Finding 1):** add `plan-review` command + its output schema (open-ended design/gap critique: findings[]+severity, NOT `compliant\|non-compliant`). This is the migration target for plan/design `rescue` callers. Distinct from `spec-review` (impl-vs-spec) and `review` (code/diff). | `codex-bridge.mjs plan-review --prompt @<spec>` returns findings-shaped JSON; schema validates |
| 6b | `hooks/prompt-submit` | remove the `node "$BRIDGE" enrich` call (line ~126) + its injection (line ~140); prompt passes through unmodified (iter3 #3) | coding prompt submitted → no enrich call in `sspower-codex.log` |
| **P1 — hooks** | | | |
| 7 | `hooks/auto-review.sh` | effort `case`→profile `case` (r0/r1 `normal`, r2 `deep`, strict `deep`); pass `--profile`; cache TTL 600→3600; security gate = path-match `SSPOWER_SECURITY_REPOS` OR strict-branch (else off); sanity off-auto | seed each round; check `sspower-codex.log` `kind=tier_chosen`; security fires only on configured repo/strict |
| 8 | `hooks/hooks.json` | remove `auto-spec-gate.sh` from `PreToolUse:Bash` (D-A5) | plan commit no longer auto-reviewed |
| **P1 — skill caller migration (gates step 9)** | | | |
| 8a | `skills/brainstorming/SKILL.md:38`, `references/after-design.md:25` | `rescue` → **`plan-review`** for design/spec review (Finding 1; gated on r6c) | brainstorming design review works via `plan-review` |
| 8b | `skills/writing-plans/SKILL.md:56-79,86` | `rescue` → **`plan-review`**; add explicit `plan-review` call (D-A5 repackage; gated on r6c) | writing-plans gate calls `plan-review` |
| 8c | `skills/second-opinion`, `codex-enrich` refs | `rescue` → `review`/remove (codex-enrich dead per D-A2) | grep: no live `rescue` caller remains |
| **P1 — final** | | | |
| 9 | `scripts/codex-bridge.mjs` | `rescue` subcommand → disabled (exit-with-notice). **ONLY after 8a-8c verified zero live callers** (D-A3) | `grep -rn 'rescue' skills/ hooks/` = no invocation |

P2–P6 get their own plan after P1 ships (PROVISIONAL per status header).
