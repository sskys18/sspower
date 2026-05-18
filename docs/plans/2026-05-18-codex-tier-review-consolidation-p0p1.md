# Codex Tier/Review Consolidation — P0+P1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use sspower:subagent-driven-development (recommended) or sspower:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the cleanup track (C1–C3, C10) and Track A (Codex tier/effort consolidation into `~/.codex/config.toml` profiles + one automatic review path + new `plan-review` command) from spec v5, leaving Track B (P2–P6) provisional.

**Architecture:** Centralized bridge refactor — `parseOpts` gains `--profile`, a new `COMMAND_PROFILE` map supplies per-command profile defaults, and `runCodexExec`/`_runCodexComplete` emit `-p`/`-m`/`-c` *conditionally* (only what was explicitly supplied or profile-defaulted) instead of force-defaulting model+effort and killing any profile. `~/.codex/config.toml` profiles become the single source of truth for tier/effort. `auto-review.sh` switches from an effort `case` to a profile `case`. `auto-spec-gate.sh` is unwired from hooks and repackaged as an explicit in-skill `plan-review` call.

**Tech Stack:** Node ESM (`scripts/codex-bridge.mjs`), bash hooks, TOML config, JSON Schema (draft 2020-12), Markdown skills.

---

## Source & scope

- **Spec:** `docs/specs/2026-05-17-codex-worker-lsp-gate-design.md` **v5** (`f052f6b`), user-approved 2026-05-18.
- **In scope:** P0 (Cleanup C1–C3, C10) + P1 (Track A §4 + §12 caller migration + new `plan-review` cmd/schema §12 r6c).
- **Out of scope (PROVISIONAL — do NOT implement):** P2–P6 (Track B: codex-lsp gate, semble_rs, B1–B7, C4–C9). Re-planned after P1 ships.
- **Branch:** `design/codex-worker-lsp-gate`, rebased onto `main` (0 behind / 3 spec-doc commits ahead). All line numbers below verified against the post-rebase tree (`scripts/codex-bridge.mjs` = 1780 lines).

## Spec §12 reconciliations (deltas found during grounding — authoritative over spec §12)

The spec §12 matrix was written against a pre-rebase tree and approximated several facts. This plan corrects them; **these reconciliations override spec §12 where they conflict:**

| Spec §12 said | Reality (verified post-rebase) | Plan resolution |
|---|---|---|
| C1: `package.json` `1.0.0`→`1.1.0` | `package.json`=`1.0.0`; `plugin.json`+`marketplace.json`=`1.1.1` | Target **`1.1.1`** (match the other two) |
| r6: per-cmd line edits at `1033/1235/1288/1302` | Default-emit is centralized: `resolveModel`/`resolveEffort` force defaults; every `cmd*` passes them into `runCodexExec` which always pushes `-m`/`-c` | Fix is **centralized** in `parseOpts` + `runCodexExec` + `_runCodexComplete` + per-cmd option-passing — NOT line-poking 4 cmds |
| Finding 3: wrong key at `:370` | `reasoning.effort=` emitted at **`:380` and `:917`** (`:867` is a comment) | Fix **both** `:380` and `:917` |
| Finding 4: cmdResume `:1410` | `cmdResume` at `:1412`, `resolveModel(opts.model)` at `:1420` | Use current refs; same conditional-emit fix |
| §12 r8a/8b/8c callers: brainstorming, writing-plans, second-opinion, codex-enrich | Live `rescue` callers also include `executing-plans/SKILL.md:60`, `codex-enrich/SKILL.md:17`; live `spec-review` callers in `subagent-driven-development` are **correct impl-vs-spec usage — NOT a migration target** | Migration scope widened (Task 14); subagent-driven-development `spec-review` left intact |
| §4.3 ladder normal/normal/deep | `auto-review.sh` currently effort `low`(r0)/`high`(r1)/`xhigh`(r2), strict→`xhigh`; SANITY default **on** | Replace with profile case + flip SANITY default **off** (D-A4) |

## Pre-flight (already done)

- [x] Wiki read: `decisions.md`/`gotchas.md` empty templates; recent sessions = config-consolidation (landed main 1.1.1) + sspower-mem — no binding conflicts.
- [x] Branch rebased onto main (was 18 behind; 3 docs-only commits replayed clean).

---

# PHASE P-COMMIT — commit this plan (Task 0)

> Why first: `auto-spec-gate.sh` is still wired in `hooks/hooks.json` until Task 13 removes it. It fires on `git commit` whenever staged files include `docs/plans/*.md`, runs Codex `review`, and **blocks the commit unless verdict is `approve`**. That is the `writing-plans` skill's mandated plan gate — satisfy it here, before any implementation. (If P1 Task 13 runs before this commit for any reason, the gate is already gone and this is a plain commit.)

### Task 0: commit the plan (triggers Codex plan gate)

**Files:**
- Add: `docs/plans/2026-05-18-codex-tier-review-consolidation-p0p1.md`

- [ ] **Step 1: Stage the plan only**

Run: `git add docs/plans/2026-05-18-codex-tier-review-consolidation-p0p1.md && git status --porcelain`
Expected: only the plan file staged

- [ ] **Step 2: Commit (standalone — auto-spec-gate + auto-review chokepoint)**

```bash
git commit -m "docs(plan): P0+P1 Codex tier/review consolidation (spec v5)"
```
Expected: `auto-spec-gate.sh` runs Codex `review` on the staged plan. Commit succeeds only on verdict `approve`. On deny: read the issues from the deny payload, fix each inline in the plan, restage, recommit (hook re-runs).

- [ ] **Step 3: Verify commit landed**

Run: `git log --oneline -1 -- docs/plans/2026-05-18-codex-tier-review-consolidation-p0p1.md`
Expected: the plan commit at HEAD

---

# PHASE P0 — Cleanup (C1–C3, C10)

### Task 1: C1 — version skew fix

**Files:**
- Modify: `package.json:3`

- [ ] **Step 1: Verify current skew**

Run: `grep -H '"version"' package.json .claude-plugin/plugin.json .claude-plugin/marketplace.json`
Expected: `package.json` = `1.0.0`; other two = `1.1.1`

- [ ] **Step 2: Bump package.json to 1.1.1**

In `package.json` change line 3 from:
```json
  "version": "1.0.0",
```
to:
```json
  "version": "1.1.1",
```

- [ ] **Step 3: Verify all three agree**

Run: `grep -hE '"version"' package.json .claude-plugin/plugin.json .claude-plugin/marketplace.json | sort -u`
Expected: single line `  "version": "1.1.1",`

### Task 2: C2 — delete orphaned skill

**Files:**
- Delete: `skills/codex-enrich-workspace/` (contains only `iteration-1/`, no `SKILL.md`)

- [ ] **Step 1: Confirm orphan (no SKILL.md, not in router)**

Run: `find skills/codex-enrich-workspace -name SKILL.md; grep -rl 'codex-enrich-workspace' skills/using-sspower/ 2>/dev/null || echo "not in router"`
Expected: no SKILL.md found; "not in router"

- [ ] **Step 2: Delete the directory**

Run: `git rm -r skills/codex-enrich-workspace`
Expected: removes `skills/codex-enrich-workspace/iteration-1/...`

- [ ] **Step 3: Verify skill count unchanged at 22 (orphan was never a real skill)**

Run: `find skills -name SKILL.md | wc -l | tr -d ' '`
Expected: `22`

### Task 3: C3 — document marketplace bridge as canonical

**Files:**
- Modify: `docs/ARCHITECTURE.md` (Codex bridge section, ~line 152–156)

- [ ] **Step 1: Locate the bridge section anchor**

Run: `grep -n 'Codex bridge (.scripts/codex-bridge.mjs.)' docs/ARCHITECTURE.md`
Expected: one match (~line 152)

- [ ] **Step 2: Add canonical-source note**

Immediately after the `## Codex bridge (\`scripts/codex-bridge.mjs\`)` heading line, insert a new paragraph:

```markdown
> **Canonical source:** Claude Code loads the **marketplace** tree
> (`~/.claude/plugins/marketplaces/sskys18/plugins/sspower/scripts/codex-bridge.mjs`),
> registered via `~/.claude/settings.json` (`source_type=local`). The
> `~/.codex/plugins/cache/sskys18/sspower/<version>/scripts/codex-bridge.mjs`
> copy is stale dead weight — never edit it, never rely on it. All bridge
> edits target the marketplace tree (decision D-C1).
```

- [ ] **Step 3: Verify the note rendered**

Run: `grep -n 'Canonical source' docs/ARCHITECTURE.md`
Expected: one match inside the Codex bridge section

### Task 4: C10 — doc fixes (skill count, --profile tunability, effort claim)

**Files:**
- Modify: `README.md:12` (Codex defaults claim), `README.md:247` (orphan skill row), `README.md:222` + `README.md:325` (skill count consistency)
- Modify: `docs/ARCHITECTURE.md:156` (effort-uniformity claim), `docs/ARCHITECTURE.md:322` (per-call options)

- [ ] **Step 1: Remove orphan skill row from README skill table**

Delete `README.md:247`:
```markdown
| `codex-enrich-workspace` | Codex | Codex-assisted workspace enrichment |
```

- [ ] **Step 2: Reconcile skill count (header says "22", structure line says "16")**

Run: `grep -nE 'All 22 Skills|16 skill directories' README.md`

`README.md:222` "## All 22 Skills" is correct (`find skills -name SKILL.md` = 22). Fix `README.md:325` from:
```
  skills/                      -- 16 skill directories
```
to:
```
  skills/                      -- 22 skill directories
```

- [ ] **Step 3: Add --profile to README Codex-defaults claim**

`README.md:12` currently:
```markdown
- **Codex defaults** — `codex-bridge.mjs` defaults to `gpt-5.5` model with `high` reasoning effort (subcommands all pinned `high` — `xhigh` caused stalls). Override per-call with `--model` / `--effort`.
```
Replace with:
```markdown
- **Codex defaults** — tier/model/effort are governed by `~/.codex/config.toml` profiles (`quick`/`normal`/`deep`, single source of truth). `codex-bridge.mjs` selects a per-command profile (`COMMAND_PROFILE`) and passes `-p`; override per-call with `--profile` / `--model` / `--effort` (explicit flags patch individual profile fields).
```

- [ ] **Step 4: Fix ARCHITECTURE effort-uniformity claim**

`docs/ARCHITECTURE.md:156` currently asserts subcommands are "all pinned `high`". Replace that sentence with:
```markdown
Defaults: governed by `~/.codex/config.toml` profiles. The bridge maps each subcommand to a profile via `COMMAND_PROFILE` (`complete`→`quick`; `implement`/`review`/`spec-review`/`plan-review`→`normal`) and passes `-p <profile>`. **`resume` is excluded — `codex exec resume` has no `--profile`; it inherits root `config.toml` (root `service_tier=flex` is load-bearing) and only emits explicit `--model`/`--effort` overrides.** Explicit `--profile`/`--model`/`--effort` patch individual fields of the selected profile (see `scripts/codex-bridge.mjs` `parseOpts`/`runCodexExec`). `auto-review.sh` security pass keeps `xhigh` via `SSPOWER_SECURITY_EFFORT`.
```

- [ ] **Step 5: Add --profile to ARCHITECTURE per-call options table**

`docs/ARCHITECTURE.md:322` row — change:
```
| Per-call codex options | `--model`, `--effort`, `--cd`, `--write`, `--worktree`, `--auto-commit` |
```
to:
```
| Per-call codex options | `--profile`, `--model`, `--effort`, `--cd`, `--write`, `--worktree`, `--auto-commit` |
```

- [ ] **Step 6: Verify no dangling orphan/count refs**

Run: `grep -rnE 'codex-enrich-workspace|16 skill directories' README.md docs/ARCHITECTURE.md`
Expected: no matches

### Task 4b: P0 commit

- [ ] **Step 1: Stage P0 changes**

Run: `git add package.json README.md docs/ARCHITECTURE.md && git status --porcelain`
(Note: `skills/codex-enrich-workspace` already staged via `git rm` in Task 2.)
Expected: `package.json`, `README.md`, `docs/ARCHITECTURE.md` modified; `skills/codex-enrich-workspace/*` deleted

- [ ] **Step 2: Commit (standalone — auto-review chokepoint)**

```bash
git commit -m "chore(p0): cleanup C1-C3/C10 — version skew, orphan skill, bridge-canonical doc, doc fixes"
```
Expected: commit succeeds (P0 touches no `docs/plans/*` so auto-spec-gate does not fire; `git commit` is not push, no Codex gate)

---

# PHASE P1 — Track A (config + bridge + hooks + skills + plan-review)

> Ordering rule (spec §12): Task 15 (`rescue` subcommand disable) is **LAST** and gated on Task 14 verifying zero live `rescue` callers. Task 10 (`plan-review`) must land before Task 14 (callers migrate *to* it).

### Task 5: P1 config — `~/.codex/config.toml` profiles

**Files:**
- Modify: `~/.codex/config.toml` (root `service_tier`; `[profiles.normal]`; ensure `[profiles.quick]`/`[profiles.deep]`)

- [ ] **Step 1: Snapshot current config**

Run: `grep -nE '^\s*service_tier|^\[profiles\.|model_reasoning_effort|^model ' ~/.codex/config.toml`
Expected: shows root `service_tier = "fast"`, `[profiles.normal] service_tier = "fast"`

- [ ] **Step 2: Set root + normal to `flex`, define profile matrix**

Edit `~/.codex/config.toml` so the effective values are (spec §4.1):

```toml
# root defaults (resume — which has no --profile — inherits these)
model = "gpt-5.5"
service_tier = "flex"

[profiles.quick]
model = "gpt-5.4"
model_reasoning_effort = "low"
service_tier = "fast"

[profiles.normal]
model = "gpt-5.5"
model_reasoning_effort = "high"
service_tier = "flex"

[profiles.deep]
model = "gpt-5.5"
model_reasoning_effort = "xhigh"
service_tier = "fast"
```

Preserve any unrelated existing keys. The profile effort key MUST be `model_reasoning_effort` (NOT `reasoning_effort` — wrong key silently no-ops).

- [ ] **Step 3: Verify effective config per profile**

Run: `codex --profile normal --help >/dev/null 2>&1; grep -A4 '\[profiles.normal\]' ~/.codex/config.toml`
Expected: `[profiles.normal]` block shows `service_tier = "flex"`, `model_reasoning_effort = "high"`; root `service_tier = "flex"`; `quick`/`deep` keep `fast`

### Task 6: P1 bridge — `parseOpts` `--profile` + `COMMAND_PROFILE` map

**Files:**
- Modify: `scripts/codex-bridge.mjs` (consts block ~line 44; `parseOpts` ~line 200+)

- [ ] **Step 1: Add `COMMAND_PROFILE` const after `COMMAND_EFFORT`**

After the `COMMAND_EFFORT` object (ends ~line 52) add:
```javascript
// Per-command default profile (single source of truth = ~/.codex/config.toml).
// Bridge passes `-p <profile>` unless the user gave an explicit --profile.
// `resume` is intentionally absent: `codex exec resume` has NO --profile;
// it inherits root config.toml (root service_tier=flex is load-bearing).
const COMMAND_PROFILE = {
  complete: "quick",
  enrich: "quick",
  implement: "normal",
  review: "normal",
  "spec-review": "normal",
  "plan-review": "normal",
  rescue: "normal",
};
```

- [ ] **Step 2: Add `profile` to the `opts` object in `parseOpts`**

In `parseOpts`, add to the `opts` initializer (alongside `model: null,`):
```javascript
    profile: null,
```

- [ ] **Step 3: Add `--profile` + `--print-args` cases to the `parseOpts` switch**

After the `case "--model":` block add:
```javascript
      case "--profile":
        opts.profile = argv[++i];
        break;
      case "--print-args":
        opts.printArgs = true;
        break;
```
And add `printArgs: false,` to the `opts` initializer (alongside `profile: null,`).

`--print-args` is a **dry-run/test affordance** (consumed by `runCodexExec`/`runCodexResume`/`_runCodexComplete` in Task 7): assemble the full codex `args` array, print it as JSON to stdout, and `process.exit(0)` **before spawning codex**. This makes Tasks 6/8/9 deterministically verifiable without a network codex call (bridge does NOT otherwise echo its invocation args — without this flag the verification greps would false-pass).

- [ ] **Step 4: Verify parser accepts the new flags (syntax only here; emit asserted in Task 7/8)**

Run: `node --check scripts/codex-bridge.mjs && echo "syntax OK"`
Expected: `syntax OK` (full `--print-args` behavior is verified in Task 8 Step 3 after Task 7 wires it)

### Task 7: P1 bridge — conditional emit in `runCodexExec` + `_runCodexComplete` + effort-key fix

**Files:**
- Modify: `scripts/codex-bridge.mjs:359-388` (`runCodexExec`), `:380` (effort key), `:904-917` (`_runCodexComplete`), `:917` (effort key), `:405-437` (`runCodexResume`)

- [ ] **Step 1: Add `profile` to `runCodexExec` options + conditional `-p`/`-m`/`-c`**

In `runCodexExec` (signature `function runCodexExec(prompt, options = {})`), destructure `profile` from options alongside `model`/`effort`. The existing block at lines ~379-380 sits **before** the final `args.push("-")` (stdin marker, ~line 388) — replace it in place so order is preserved (flags stay before `"-"`):
```javascript
  if (model) args.push("-m", model);
  if (effort) args.push("-c", `reasoning.effort="${effort}"`);
```
becomes:
```javascript
  if (profile) args.push("-p", profile);
  if (model) args.push("-m", model);
  if (effort) args.push("-c", `model_reasoning_effort="${effort}"`);
```
(Order: `-p` first so explicit `-m`/`-c` patch individual fields of the profile — spec §4.2 precedence. Confirm these pushes remain ABOVE `args.push("-")`.)

- [ ] **Step 2: Fix `_runCodexComplete` effort key + make model/effort conditional**

In `_runCodexComplete` (~line 904) the args array is an **array literal** ending with the stdin marker `"-"`. It hardcodes `"-m", model,` and `"-c", \`reasoning.effort="${effort}"\`,`. Re-read `:904-917` before editing (edit-safety). Steps:
1. Remove the two hardcoded literal entries `"-m", model,` and `"-c", \`reasoning.effort="${effort}"\`,` from the array literal.
2. After the array (with its trailing `"-"`) is constructed, **splice the conditional flags in BEFORE the final `"-"`** — do NOT `push` them (push appends after `"-"`, placing flags after the stdin marker → Codex misparses). Use:
```javascript
  const _stdinIdx = args.lastIndexOf("-");
  const _flags = [];
  if (profile) _flags.push("-p", profile);
  if (model) _flags.push("-m", model);
  if (effort) _flags.push("-c", `model_reasoning_effort="${effort}"`);
  args.splice(_stdinIdx, 0, ..._flags);
```
3. Thread `profile` (and `printArgs`) through `_runCodexComplete`'s `options`.
(If `_runCodexComplete` builds args incrementally without a trailing `"-"`, fall back to plain conditional `args.push` before any stdin marker — verify the actual structure at edit time.)

- [ ] **Step 3: Make `runCodexResume` model/effort conditional (no `-p`); ADD missing `effort` support**

In `runCodexResume` (~line 405): its options destructure is `{ sessionId, model, schemaName, cd }` — **`effort` is absent and no `-c` is ever pushed**, so explicit `--effort` on resume is currently silently ignored (contradicts the resume-inheritance contract). Fix:
1. Add `effort = null,` to the destructure.
2. `-m` is pushed conditionally at ~line 426 (`if (model) args.push("-m", model);`) — keep as-is, verify it's BEFORE the `args.push("-")` (~line ~437).
3. Immediately after the `-m` push (still before `args.push("-")`) add:
```javascript
  if (effort) args.push("-c", `model_reasoning_effort="${effort}"`);
```
4. Ensure NO `-p`/`--profile` is ever pushed in `runCodexResume` (resume has no `--profile`; root `config.toml` governs). Confirm `codex exec resume` accepts `-c key=value` (local `codex exec resume --help` shows `-c, --config <key=value>` — supported).

- [ ] **Step 3b: Honor `--print-args` dry-run in all three arg builders**

In `runCodexExec`, `runCodexResume`, and `_runCodexComplete`, immediately **after the full `args` array is assembled and before the codex child is spawned** (after the last `args.push(...)`, before `execFileSync`/`spawn`), insert:
```javascript
  if (options.printArgs) {
    process.stdout.write(JSON.stringify({ bin: codexBin(), args }) + "\n");
    process.exit(0);
  }
```
Thread `printArgs` through: each `cmd*` must pass `printArgs: opts.printArgs` in the options object it hands to the runner (add it alongside the `profile`/`model`/`effort` keys edited in Task 8). For `_runCodexComplete`, place the guard after its array is fully built.

- [ ] **Step 3c: Verify dry-run prints args and does NOT spawn codex**

Run: `node scripts/codex-bridge.mjs review --print-args --prompt "noop" --cd . 2>/dev/null`
Expected: a single JSON line `{"bin":"...","args":[...,"-p","normal",...]}`; process exits 0 immediately; no codex network call / no session record created

- [ ] **Step 4: Verify the wrong key is gone everywhere**

Run: `grep -nE 'reasoning\.effort=' scripts/codex-bridge.mjs`
Expected: **0 matches** (line 867 is a comment — if it still reads `reasoning.effort=minimal` in a comment, reword it to `model_reasoning_effort=minimal`)

Run: `grep -nE 'model_reasoning_effort=' scripts/codex-bridge.mjs`
Expected: matches in `runCodexExec`, `_runCodexComplete`, (and resume path if it emits effort)

### Task 8: P1 bridge — cmd bodies pass profile/model/effort conditionally

**Files:**
- Modify: `scripts/codex-bridge.mjs` — `cmdComplete:1042`, `cmdImplement:1255`, `cmdSpecReview:1297`, `cmdReview:1311`, `cmdRescue:1325`

- [ ] **Step 1: Replace force-default option passing in each review-class cmd**

For `cmdSpecReview`, `cmdReview`, `cmdRescue`, `cmdImplement` the current pattern is:
```javascript
    model: resolveModel(opts.model),
    effort: resolveEffort(opts.effort, "<cmd>"),
```
Replace with (profile-default + explicit-override, spec §4.2):
```javascript
    profile: opts.profile || COMMAND_PROFILE["<cmd>"],
    model: opts.model || null,
    effort: opts.effort || null,
```
Concretely per call site (use the exact command key already passed to `resolveEffort`):
- `cmdImplement` (~1255): `profile: opts.profile || COMMAND_PROFILE.implement`
- `cmdReview` (~1311): `profile: opts.profile || COMMAND_PROFILE.review`
- `cmdSpecReview` (~1297): `profile: opts.profile || COMMAND_PROFILE["spec-review"]`
- `cmdRescue` (~1325): `profile: opts.profile || COMMAND_PROFILE.rescue` (rescue still functional until Task 15)

- [ ] **Step 2: `cmdComplete` profile passing**

`cmdComplete` (~1042) uses `_runCodexComplete`. Change its `const model = resolveModel(opts.model);` and effort resolution so it passes `profile: opts.profile || COMMAND_PROFILE.complete`, `model: opts.model || null`, `effort: opts.effort || null` into `_runCodexComplete`'s options. Do NOT force `DEFAULT_MODEL`.

- [ ] **Step 3: Verify no-flag run emits `-p`, no `-m`/`-c` (via `--print-args`)**

Run:
```bash
node scripts/codex-bridge.mjs review --print-args --prompt "noop" --cd . 2>/dev/null | python3 -c 'import json,sys; a=json.load(sys.stdin)["args"]; print("p="+(a[a.index("-p")+1] if "-p" in a else "NONE"), "m="+("PRESENT" if "-m" in a else "ABSENT"), "effort="+("PRESENT" if any("model_reasoning_effort" in x for x in a) else "ABSENT"))'
```
Expected: `p=normal m=ABSENT effort=ABSENT`

Run:
```bash
node scripts/codex-bridge.mjs review --print-args --effort high --prompt "noop" --cd . 2>/dev/null | python3 -c 'import json,sys; a=json.load(sys.stdin)["args"]; print([x for x in a if "model_reasoning_effort" in x])'
```
Expected: `['model_reasoning_effort="high"']` (explicit `--effort` patches the field; `-p normal` still present)

Run (explicit profile override):
```bash
node scripts/codex-bridge.mjs review --print-args --profile deep --prompt "noop" --cd . 2>/dev/null | python3 -c 'import json,sys; a=json.load(sys.stdin)["args"]; print(a[a.index("-p")+1])'
```
Expected: `deep`

- [ ] **Step 4: Verify `complete` path (array-literal + stdin-marker ordering)**

Run:
```bash
node scripts/codex-bridge.mjs complete --print-args --prompt "noop" --cd . 2>/dev/null | python3 -c 'import json,sys; a=json.load(sys.stdin)["args"]; i=a.index("-p"); j=a.index("-"); print("p="+a[i+1], "p_before_stdin="+str(i<j), "m="+("PRESENT" if "-m" in a else "ABSENT"))'
```
Expected: `p=quick p_before_stdin=True m=ABSENT` (profile `quick` for `complete`; flags inserted before the `"-"` stdin marker; no forced default `-m`)

### Task 9: P1 bridge — `cmdResume` AND `cmdSteer` suppress default `-m`, thread `effort`

**Files:**
- Modify: `scripts/codex-bridge.mjs` — `cmdResume` (~1412, `resolveModel(opts.model)` ~1420), `cmdSteer` (~1538, `runCodexResume(...)` call with `model: resolveModel(opts.model)` ~1578-1580)

> Both `cmdResume` AND `cmdSteer` call `runCodexResume`. `cmdSteer` (kill+resume) is a second live resume caller — fixing only `cmdResume` leaves steer force-defaulting `-m`, breaking the resume-inheritance contract for steer.

- [ ] **Step 1: `cmdResume` — stop default `-m`, thread explicit `effort`**

In `cmdResume` (~1412), change the options passed into `runCodexResume`:
```javascript
    model: resolveModel(opts.model),
```
to:
```javascript
    model: opts.model || null,
    effort: opts.effort || null,
```
(Resume inherits root config.toml — root `service_tier=flex`. NO `--profile`/`-p`. `model`/`effort` emitted only when explicitly supplied. `effort` now actually reaches `runCodexResume` per Task 7 Step 3.)

- [ ] **Step 1b: `cmdSteer` — same conditional resume options**

In `cmdSteer` (~1538), its `runCodexResume(prompt, { ... })` call (~1578-1580) passes `model: resolveModel(opts.model)`. Change to:
```javascript
    model: opts.model || null,
    effort: opts.effort || null,
```
(Steer obeys the same resume-inheritance rule. Also thread `printArgs: opts.printArgs` for the dry-run verification below.)

- [ ] **Step 2: Verify no-flag resume emits no `-m`/`-c`/`-p` (via `--print-args`)**

Run:
```bash
node scripts/codex-bridge.mjs resume --print-args --session-id deadbeef --prompt "noop" --cd . 2>/dev/null | python3 -c 'import json,sys; a=json.load(sys.stdin)["args"]; print("p="+("PRESENT" if "-p" in a else "ABSENT"), "m="+("PRESENT" if "-m" in a else "ABSENT"), "effort="+("PRESENT" if any("model_reasoning_effort" in x for x in a) else "ABSENT"))'
```
Expected: `p=ABSENT m=ABSENT effort=ABSENT` (resume inherits root config.toml; no forced flags)

Run (explicit model honored): `node scripts/codex-bridge.mjs resume --print-args --session-id x --model gpt-5.5 --prompt noop --cd . 2>/dev/null | grep -o '"-m"'`
Expected: `"-m"` present

Run (explicit effort now honored — was silently ignored before Task 7 Step 3):
```bash
node scripts/codex-bridge.mjs resume --print-args --session-id x --effort high --prompt noop --cd . 2>/dev/null | python3 -c 'import json,sys; a=json.load(sys.stdin)["args"]; print([x for x in a if "model_reasoning_effort" in x])'
```
Expected: `['model_reasoning_effort="high"']`

Run (steer no longer force-defaults `-m`):
```bash
node scripts/codex-bridge.mjs steer --print-args --session-id x --prompt noop --cd . 2>/dev/null | python3 -c 'import json,sys; a=json.load(sys.stdin)["args"]; print("m="+("PRESENT" if "-m" in a else "ABSENT"), "p="+("PRESENT" if "-p" in a else "ABSENT"))'
```
Expected: `m=ABSENT p=ABSENT` (steer obeys resume-inheritance; no forced model/profile)

### Task 10: P1 bridge — new `plan-review` command + schema (§12 r6c)

**Files:**
- Create: `schemas/plan-review-output.json`
- Modify: `scripts/codex-bridge.mjs` (add `cmdPlanReview` near `cmdSpecReview` ~1303; register in the subcommand dispatcher)

- [ ] **Step 1: Create the plan-review output schema**

Create `schemas/plan-review-output.json` (findings-shaped, NOT `compliant|non-compliant` — design/gap critique):
```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "additionalProperties": false,
  "required": ["verdict", "findings", "summary"],
  "properties": {
    "verdict": {
      "type": "string",
      "enum": ["approve", "approve-with-followups", "needs-attention"],
      "description": "Overall plan/design judgement"
    },
    "findings": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["severity", "issue", "evidence", "suggested_fix"],
        "properties": {
          "severity": { "type": "string", "enum": ["high", "medium", "low"] },
          "issue": { "type": "string", "description": "The design/plan gap, ambiguity, contradiction, or risk" },
          "evidence": { "type": "string", "description": "What in the plan/spec triggers this (quote or section ref)" },
          "suggested_fix": { "type": "string", "description": "Concrete correction" }
        }
      },
      "description": "Open-ended design/gap findings (empty array if none)"
    },
    "summary": {
      "type": "string",
      "description": "Overall assessment and recommendation"
    }
  }
}
```

- [ ] **Step 2: Add `cmdPlanReview` to the bridge**

Immediately after `cmdSpecReview` (ends ~line 1303) add:
```javascript
async function cmdPlanReview(argv) {
  const opts = parseOpts(argv);
  const prompt = resolvePrompt(opts.prompt);
  const result = await runCodexExec(prompt, {
    schema: schemaPath("plan-review-output"),
    sandbox: "read-only",
    profile: opts.profile || COMMAND_PROFILE["plan-review"],
    model: opts.model || null,
    effort: opts.effort || null,
    printArgs: opts.printArgs,
    cd: opts.cd,
    ephemeral: true, // reviews don't need resume
  });
  output(result, { expectStructured: true });
}
```

- [ ] **Step 3: Register `plan-review` in the subcommand dispatcher**

Find the main dispatch (search `case "spec-review":` or the `switch`/map routing `process.argv[2]` to `cmd*`). Add a `plan-review` → `cmdPlanReview` branch mirroring the `spec-review` registration exactly.

Run: `grep -nE 'spec-review|cmdSpecReview' scripts/codex-bridge.mjs | grep -vE '^\s*//' `
Expected: locate the dispatch line; add the parallel `plan-review` entry

- [ ] **Step 4: Add `plan-review` to the usage/help text**

In the top-of-file usage comment block (lines ~16-20) add a line:
```
 *   node codex-bridge.mjs plan-review --prompt <text|@file> [--profile <p>] [--model <m>] [--cd <dir>]
```

- [ ] **Step 5: Smoke-test plan-review against this very plan**

Run:
```bash
node scripts/codex-bridge.mjs plan-review --cd . --prompt @docs/plans/2026-05-18-codex-tier-review-consolidation-p0p1.md 2>&1 | tail -20
```
Expected: JSON conforming to `plan-review-output.json` (has `verdict`/`findings`/`summary`); schema validation passes (no `schema not found` / validation error)

### Task 11: P1 bridge — disable `enrich`; unwire `prompt-submit` enrich call

**Files:**
- Modify: `scripts/codex-bridge.mjs` (`cmdEnrich` ~1333)
- Modify: `hooks/prompt-submit` (~line 110-128 enrich invocation)

- [ ] **Step 1: Replace `cmdEnrich` body with disabled-passthrough**

Replace the entire `cmdEnrich` function body (1333–1410) so it echoes the **raw prompt verbatim to stdout** and the disabled notice to **stderr only** (spec D-A2 / iter3 #3 — `hooks/prompt-submit` injects stdout as the enriched prompt; a notice on stdout would poison the prompt):
```javascript
async function cmdEnrich(argv) {
  const opts = parseOpts(argv);
  const rawPrompt = resolvePrompt(opts.prompt);
  process.stderr.write("[codex:enrich] disabled (spec D-A2) — passing raw prompt through\n");
  logEvent("info", "bridge.enrich", { kind: "disabled_passthrough" });
  process.stdout.write(rawPrompt);
  cleanupTmpDir();
  process.exit(0);
}
```

- [ ] **Step 2: Remove the enrich invocation from `hooks/prompt-submit`**

In `hooks/prompt-submit`, the `if should_enrich; then ... fi` block (~line 111+) calls `node "$BRIDGE" enrich`. Remove the bridge call so the prompt passes through unmodified. Minimal change: make `should_enrich()` always return non-zero, OR delete the enrich block. Preferred: in `should_enrich()` add as the first line:
```bash
  return 1   # enrich disabled (spec D-A2) — never enrich
```
(Leaves the block dead but intact for audit; no behavior, no bridge spawn.)

- [ ] **Step 3: Verify no enrich spawn on coding prompt**

Run: `printf 'fix the auth bug' | CLAUDE_PROJECT_DIR="$PWD" bash hooks/prompt-submit 2>&1 | grep -c 'enrich' || true`
Expected: `0` enrich bridge invocation (a passthrough/reminder context is fine; assert no `codex-bridge.mjs enrich` process)

Run (defense-in-depth, the disabled bridge path itself): `echo 'hello world' > /tmp/pe.txt; node scripts/codex-bridge.mjs enrich --prompt @/tmp/pe.txt --cd . 2>/dev/null`
Expected: stdout is exactly `hello world` (no markers, no notice)

### Task 12: P1 hooks — `auto-review.sh` profile case + cache TTL + security/sanity

**Files:**
- Modify: `hooks/auto-review.sh` (effort tier ~254-266; cache TTL ~227; MAIN/SEC/SANITY args ~377-402)

- [ ] **Step 1: Replace round-aware effort tier with profile tier (KEEP a derived `ROUND_EFFORT` compat shim)**

⚠️ `hooks/auto-review.sh` runs `set -u` (line 39). `ROUND_EFFORT` is consumed downstream at **`:409`** (timeout `case "$ROUND_EFFORT"`), **`:440`** (`parallel_review_start` log `main_effort=`), **`:645`** (`deny_verdict` log `effort=`). Removing `ROUND_EFFORT` without a shim aborts the hook → breaks the P1 one-call criterion. So: introduce `ROUND_PROFILE` AND keep a derived `ROUND_EFFORT` for those three sites.

The block at ~254-266 sets `ROUND_EFFORT`. Replace it with:
```bash
  # ---------- Round-aware profile tier (main review) ----------
  if [ -n "${SSPOWER_REVIEW_PROFILE:-}" ]; then
    ROUND_PROFILE="$SSPOWER_REVIEW_PROFILE"
  elif [ "$BRANCH_TIER" = "strict" ]; then
    ROUND_PROFILE="deep"
  else
    case "$ROUNDS" in
      0) ROUND_PROFILE="normal" ;;
      1) ROUND_PROFILE="normal" ;;
      *) ROUND_PROFILE="deep" ;;
    esac
  fi
  # Back-compat shim: downstream timeout (:409) + logs (:440,:645) still read
  # ROUND_EFFORT. Derive it from the chosen profile so `set -u` stays happy
  # and the timeout case keeps working. (MAIN review itself uses --profile.)
  case "$ROUND_PROFILE" in
    deep)   ROUND_EFFORT="xhigh" ;;
    quick)  ROUND_EFFORT="low" ;;
    *)      ROUND_EFFORT="high" ;;   # normal
  esac
  log_event info hook.auto-review kind=tier_chosen branch="$BRANCH" tier="$BRANCH_TIER" round="$((ROUNDS+1))/$ROUNDS_CAP" profile="$ROUND_PROFILE" effort="$ROUND_EFFORT"
```

- [ ] **Step 1b: Verify no unguarded `ROUND_EFFORT` use remains**

Run: `grep -n 'ROUND_EFFORT' hooks/auto-review.sh`
Expected: definition in the shim above + reads at `:409`/`:440`/`:645` only (all now defined before use); NO read before the shim. `bash -n hooks/auto-review.sh` → syntax OK.

- [ ] **Step 2: Switch MAIN review from `--effort` to `--profile`**

`~line 377`: change
```bash
  MAIN_BRIDGE_ARGS=(review --prompt "@$MAIN_PROMPT_FILE" --effort "$ROUND_EFFORT")
```
to:
```bash
  MAIN_BRIDGE_ARGS=(review --prompt "@$MAIN_PROMPT_FILE" --profile "$ROUND_PROFILE")
```

- [ ] **Step 2b: Make the `parallel_review_start` log reflect actual SECURITY/SANITY gate state**

`hooks/auto-review.sh:440` currently logs `sec_effort="$SEC_EFFORT"` unconditionally — so it prints `xhigh` even when `SECURITY_ENABLED=0`, making the Step 5 call-count assertion meaningless. Change the `:440` `log_event ... kind=parallel_review_start ...` line so the effort fields reflect the gate decision:
```bash
  log_event info hook.auto-review kind=parallel_review_start branch="$BRANCH" \
    main_effort="$ROUND_PROFILE" \
    sec_effort="$([ "$SECURITY_ENABLED" = "1" ] && echo "$SEC_EFFORT" || echo "off")" \
    sanity_effort="$([ "$SANITY_ENABLED" = "1" ] && echo "$SANITY_EFFORT" || echo "off")" \
    timeout="${REVIEW_TIMEOUT}s"
```
Now `sec_effort=off` ⟺ SECURITY skipped (1 call); `sec_effort=xhigh` ⟺ SECURITY ran (2 calls); `sanity_effort=off` always under D-A4 default.

- [ ] **Step 3: Cache TTL 600→3600**

`~line 227`: change `CACHE_TTL="${SSPOWER_REVIEW_CACHE_TTL:-600}"` to `CACHE_TTL="${SSPOWER_REVIEW_CACHE_TTL:-3600}"`. Update the header comment at line 27 (`default 600s = 10min`) to `default 3600s = 60min`.

- [ ] **Step 4: Security gate = hybrid (path-allowlist OR strict), SANITY off-auto**

Implement spec §4.4 / D-A4. Replace the `SEC_EFFORT`/`SECURITY_ENABLED` logic (~380-385) so SECURITY runs iff branch is strict OR `git rev-parse --show-toplevel` string-prefix-matches one of `SSPOWER_SECURITY_REPOS` (colon-sep, fully-expanded absolute, default seeded):
```bash
  SSPOWER_SECURITY_REPOS="${SSPOWER_SECURITY_REPOS:-/Users/sskys/blockwavelabs/custody-dashboard-solution:/Users/sskys/blockwavelabs/danal/pay-chain:/Users/sskys/blockwavelabs/danal/danalstable-frontend:/Users/sskys/blockwavelabs/danal/danalstablecoin-backend:/Users/sskys/blockwavelabs/infinite-block/security}"
  SEC_EFFORT="${SSPOWER_SECURITY_EFFORT:-xhigh}"
  SECURITY_ENABLED=0
  _repo_root="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
  if [ "$BRANCH_TIER" = "strict" ]; then
    SECURITY_ENABLED=1
  elif [ -n "$_repo_root" ]; then
    _OLDIFS="$IFS"; IFS=':'
    for _p in $SSPOWER_SECURITY_REPOS; do
      case "$_repo_root" in "$_p"*) SECURITY_ENABLED=1 ;; esac
    done
    IFS="$_OLDIFS"
  fi
  # Explicit env override still wins
  if [ "$SEC_EFFORT" = "off" ] || [ "${SSPOWER_SECURITY_REVIEW:-}" = "off" ]; then SECURITY_ENABLED=0; fi
  if [ "${SSPOWER_SECURITY_REVIEW:-}" = "on" ]; then SECURITY_ENABLED=1; fi
```
Then change `SEC_BRIDGE_ARGS` (~385) to keep `--effort "$SEC_EFFORT"` (security pass intentionally stays effort-pinned `xhigh` per CLAUDE.md / ARCHITECTURE — do NOT profile-ize the security pass).

For SANITY (~394-400): flip default OFF (D-A4 "sanity off-auto"). Change the default in `SANITY_ENABLED` logic so SANITY only runs when `SSPOWER_SANITY_REVIEW=on` is explicitly set:
```bash
  SANITY_ENABLED=0
  if [ "${SSPOWER_SANITY_REVIEW:-off}" = "on" ] && [ "$BRANCH_TIER" != "strict" ] && [ "$SANITY_EFFORT" != "off" ]; then
    SANITY_ENABLED=1
  fi
```
Update header comment line 32 (`SSPOWER_SANITY_REVIEW (default on...)`) → `(default off; set on to enable sanity pass)`.

- [ ] **Step 5: Verify gate behavior deterministically (fresh log, asserted record fields — NOT stale `tail`)**

Grepping the last `tier_chosen` can match a stale pre-edit entry and never proves call count. Instead: snapshot the log line count, invoke the hook once with a controlled diff, then assert on the **newly appended** `parallel_review_start` record (it carries `main_effort`, `sec_effort`, `sanity_effort` — the call-count is derivable: SECURITY on ⇒ 2 calls, SANITY on ⇒ +1).

Use a throwaway git repo so branch/path are controlled and no real review spawns (point the bridge at `--print-args` is not wired into the hook, so instead assert via the log record the hook writes *before* spawning — `parallel_review_start` is logged at `:440` after gate decisions, before the codex calls):

```bash
LOG=$(ls -t ~/.claude/sspower/*.log 2>/dev/null | head -1); LOG="${LOG:-/dev/null}"
BEFORE=$(wc -l < "$LOG" 2>/dev/null || echo 0)
# Case A — non-strict, non-allowlisted (this repo, branch design/...): expect 1 call
#   Invoke the hook's gate path on a seeded trivial staged diff (see hook's own
#   self-test harness if present, else a fixture repo on a feature branch).
# After invocation:
NEWREC=$(tail -n +"$((BEFORE+1))" "$LOG" | grep 'kind=parallel_review_start' | tail -1)
echo "$NEWREC"
```
Expected (Case A, non-strict + not in `SSPOWER_SECURITY_REPOS`): the **new** record shows `sec_effort=off`-equivalent gating (SECURITY_ENABLED=0) and `sanity_effort=off` ⇒ **1 MAIN call only**, and a `kind=tier_chosen` new record with `profile=normal effort=high`.

Case B (strict branch, e.g. fixture repo on `main`): new `parallel_review_start` shows SECURITY enabled (`sec_effort=xhigh`), `sanity_effort=off` (strict suppresses sanity) ⇒ **2 calls**.

Case C (non-strict but repo path in `SSPOWER_SECURITY_REPOS`): SECURITY enabled ⇒ **2 calls**; `sanity_effort=off`.

Assert SANITY never auto-enables: in all three, the new record's `sanity_effort=off` (D-A4 default flip). If the hook has no isolated entrypoint, add a guarded self-test shim (`SSPOWER_AUTOREVIEW_SELFTEST=1` short-circuit that logs the gate decision and exits before spawning) as part of this step and verify via that.

### Task 13: P1 hooks — remove `auto-spec-gate.sh` from `hooks.json`

**Files:**
- Modify: `hooks/hooks.json:54-58` (the `auto-spec-gate.sh` PreToolUse:Bash entry)

- [ ] **Step 1: Remove the auto-spec-gate hook object**

In `hooks/hooks.json`, delete the object (currently lines ~54-58):
```json
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/auto-spec-gate.sh\"",
            "timeout": 600
          },
```
(Leave `cmd-rewrite.sh` and `auto-review.sh` entries intact. The `auto-spec-gate.sh` *script* is retained on disk for manual `SSPOWER_SPEC_GATE=on` use — only the hooks.json wiring is removed, spec §4.4/D-A5.)

- [ ] **Step 2: Validate hooks.json still parses**

Run: `node -e 'JSON.parse(require("fs").readFileSync("hooks/hooks.json","utf8")); console.log("valid")'`
Expected: `valid`

- [ ] **Step 3: Verify the gate no longer fires on plan commits**

Run: `grep -c 'auto-spec-gate' hooks/hooks.json`
Expected: `0`

### Task 14: P1 skills — migrate `rescue`/plan callers (gates Task 15)

**Files:**
- Modify: `skills/brainstorming/SKILL.md:38`, `skills/brainstorming/references/after-design.md:25` (design review: `rescue` → `plan-review`)
- Modify: `skills/writing-plans/SKILL.md` ("Codex Plan Review" section + line 86 execution-option)
- Modify: `skills/executing-plans/SKILL.md:60` (`rescue --write` worker → `implement --write`)
- Modify: `skills/second-opinion/SKILL.md:60` (`rescue --write` stuck-worker → `implement --write`) + graphviz nodes (lines ~26-35: relabel `codex-bridge rescue` node/edges to the new stuck flow)
- Modify: `skills/subagent-driven-development/references/codex-integration.md:62,85` (prose documents `rescue --write` worker behavior — reword to `implement --write`; rescue is removed Task 15 so these become wrong)
- Modify: `skills/codex-enrich/SKILL.md` (uses `rescue` as enrich-worker; enrich is dead per D-A2 — make skill inert per Step 4)
- **Leave intact:** all `subagent-driven-development` `spec-review` **command** usages (correct impl-vs-spec usage, NOT a rescue/plan migration — verify Step 6)

- [ ] **Step 1: brainstorming design-review → plan-review**

`skills/brainstorming/SKILL.md:38`: change `independent review via codex-bridge.mjs rescue` → `independent review via codex-bridge.mjs plan-review`.
`skills/brainstorming/references/after-design.md:25`: change `codex-bridge.mjs rescue --cd . --prompt @spec-review-prompt.md` → `codex-bridge.mjs plan-review --cd . --prompt @spec-review-prompt.md`.

- [ ] **Step 2: writing-plans plan-gate → plan-review (D-A5 repackage)**

In `skills/writing-plans/SKILL.md` "Codex Plan Review (auto-enforced at commit)" section: it documents the now-removed `auto-spec-gate.sh` hook. Rewrite it to an explicit in-skill call at the HARD-GATE:
```markdown
## Codex Plan Review (explicit gate — run before declaring the plan done)

Run plan review explicitly (the `auto-spec-gate.sh` hook was removed, D-A5):

\`\`\`bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/codex-bridge.mjs" plan-review \
  --cd . --prompt @docs/plans/YYYY-MM-DD-<feature-name>.md
\`\`\`

Fix every `high`/`medium` finding inline, re-run until `verdict` is
`approve` or `approve-with-followups`. `plan-review` (findings-shaped),
NOT `spec-review` (impl-vs-spec) — see spec v5 Finding 1.
```
Also `skills/writing-plans/SKILL.md:86` execution-option mentions `codex-bridge.mjs rescue --write` — change to `codex-bridge.mjs implement --write` (rescue being disabled Task 15).

- [ ] **Step 3: executing-plans rescue-worker → implement**

`skills/executing-plans/SKILL.md:60`: change `delegate to Codex via codex-bridge.mjs implement --write or codex-bridge.mjs rescue --write` → `delegate to Codex via codex-bridge.mjs implement --write` (drop the `rescue --write` alternative; rescue disabled Task 15).

- [ ] **Step 3b: second-opinion stuck-worker rescue → implement**

`skills/second-opinion/SKILL.md:60` has a quoted-path executable: `node "${SSPOWER_PLUGIN_ROOT}/scripts/codex-bridge.mjs" rescue --write --cd . --prompt @/tmp/rescue-prompt.md`. Change `rescue --write` → `implement --write`. Also update the graphviz block (~lines 26-35): relabel node `"codex-bridge rescue"` → `"codex-bridge implement (--write)"` and its edge from `"Stuck after 2+ fix attempts"` accordingly so the diagram matches the new command.

- [ ] **Step 3c: subagent-driven-development codex-integration doc — purge ALL `rescue` refs (5 sites)**

`skills/subagent-driven-development/references/codex-integration.md` documents the removed `rescue` command at **5 sites** — `grep -nE '\brescue\b' <file>` must return zero after this step. Apply all:
- **Line 18** (subcommand table row `| \`rescue\` | none (free-form) | configurable | Open-ended investigation |`): **delete the row** (rescue no longer exists). If "open-ended investigation" capability is referenced elsewhere, point it at `implement`.
- **Line 62** (`[codex:session]` capture during `implement` and `rescue --write`): drop `and \`rescue --write\`` → just `implement`.
- **Line 85** (`implement` and `rescue --write` run without `--ephemeral`): drop `and \`rescue --write\`` → just `implement`.
- **Line 86** (`spec-review`, `review`, and read-only `rescue` run with `--ephemeral`): remove `, and read-only \`rescue\`` → `\`spec-review\` and \`review\` run with \`--ephemeral\``.
- **Line 113** (free-form commands `(rescue, resume)`): remove `rescue` → `For free-form commands (\`resume\`), unparsed text is returned as-is.`

Verify: `grep -cE '\brescue\b' skills/subagent-driven-development/references/codex-integration.md` → `0`.

- [ ] **Step 4: codex-enrich skill — neutralize trigger + frontmatter (enrich dead, D-A2)**

A body banner alone does NOT stop skill auto-selection — the loader keys off frontmatter `description` (which contains "Trigger whenever … enrich …", line 3) and `user_invocable: true` (line 4). Make the skill genuinely inert:

Replace the frontmatter block (`skills/codex-enrich/SKILL.md` lines 1-6) with:
```yaml
---
name: codex-enrich
description: "DEPRECATED and inert (spec D-A2, 2026-05-18). The codex enrich path is disabled and the rescue subcommand is removed. This skill performs no action. Not for invocation."
user_invocable: false
allowed-tools: Read
---
```
(No trigger language in `description`; `user_invocable: false`; no executable tools.)

Add immediately after the frontmatter:
```markdown
> **DEPRECATED (spec D-A2, 2026-05-18):** `enrich` is disabled and the
> `rescue` subcommand is removed (P1). This skill is inert. Do not invoke.
```

Neutralize the two executable `codex-bridge.mjs rescue` references (line ~17 prose, line ~41 fenced command): replace the fenced command block body with `# DEPRECATED — enrich/rescue removed (spec D-A2); this skill is inert` and reword line ~17 to past-tense/deprecated.

(Do NOT delete the skill dir — deletion/registry cleanup is C-track tail, out of P0+P1 scope. Inert frontmatter + neutralized commands is sufficient to clear it as a live `rescue` caller AND stop auto-trigger.)

- [ ] **Step 4b: Verify codex-enrich is fully inert**

Run:
```bash
grep -nE 'Trigger whenever|user_invocable:\s*true|codex-bridge\.mjs +rescue' skills/codex-enrich/SKILL.md
```
Expected: **0 matches** (no trigger language, not user-invocable, no executable rescue call)

- [ ] **Step 5: Verify ZERO live `rescue` invocations remain (gates Task 15)**

The regex MUST catch quoted bridge paths (`codex-bridge.mjs" rescue`), `$BRIDGE`/`$SSPOWER_PLUGIN_ROOT` forms, and `rescue --write`/`--cd`. Scope to `skills/` and `hooks/` only — `scripts/codex-bridge.mjs` self-references (usage comment, dispatcher, `cmdRescue` itself) are handled in Task 15, not here:
```bash
grep -rnE 'codex-bridge\.mjs"?[[:space:]]+rescue|BRIDGE\}?"?[[:space:]]+rescue|\brescue[[:space:]]+--(write|cd|prompt)' skills/ hooks/ \
  | grep -viE 'DEPRECATED|disabled \(spec D-A2|spec D-A3|spec D-A2\)|# DEPRECATED'
```
Expected: **0 matches**. Any match = an unmigrated live caller; fix it before Task 15. (Cross-check the human-readable list: brainstorming ×2, writing-plans ×2, executing-plans, second-opinion, codex-enrich ×2 — all must be migrated/inert by now.)

- [ ] **Step 6: Verify `spec-review` correct-usage callers untouched**

Run: `grep -rn 'codex-bridge.mjs spec-review' skills/subagent-driven-development/`
Expected: still present (these are correct impl-vs-spec usage — must NOT be migrated)

### Task 15: P1 bridge — disable `rescue` subcommand (LAST, gated on Task 14)

**Files:**
- Modify: `scripts/codex-bridge.mjs` (`cmdRescue` ~1319; usage comment line 19)

- [ ] **Step 1: Re-confirm zero live callers (hard gate)**

Run the Task 14 Step 5 grep again.
Expected: **0 matches**. DO NOT PROCEED if any live `rescue` invocation exists.

- [ ] **Step 2: Replace `cmdRescue` body with disabled-notice**

Replace the `cmdRescue` body (1319–1331) with:
```javascript
async function cmdRescue(argv) {
  parseOpts(argv); // tolerate args for back-compat
  process.stderr.write(
    "[codex:rescue] disabled (spec D-A3). Use `plan-review` for design/plan review, " +
    "`review` for code review, or `implement --write` for worker delegation.\n"
  );
  logEvent("info", "bridge.rescue", { kind: "disabled" });
  process.exit(2);
}
```

- [ ] **Step 3: Update usage comment**

`scripts/codex-bridge.mjs:19` — change the `rescue` usage line to:
```
 *   node codex-bridge.mjs rescue     [DISABLED — see spec D-A3; use plan-review/review/implement]
```

- [ ] **Step 4: Verify rescue is disabled and exits non-zero**

Run: `node scripts/codex-bridge.mjs rescue --prompt "x" --cd . 2>&1; echo "exit=$?"`
Expected: stderr disabled notice; `exit=2`; no Codex spawn

- [ ] **Step 5: Full bridge sanity (no syntax break)**

Run: `node --check scripts/codex-bridge.mjs && echo "syntax OK"`
Expected: `syntax OK`

Run: `node scripts/codex-bridge.mjs ps 2>&1 | head -1`
Expected: runs without crash (registry listing)

### Task 16: P1 commit + plan-review gate

- [ ] **Step 1: Stage all P1 changes**

Run: `git add scripts/codex-bridge.mjs schemas/plan-review-output.json hooks/auto-review.sh hooks/hooks.json hooks/prompt-submit skills/ && git status --porcelain`
(Note: `~/.codex/config.toml` Task 5 is outside the repo — verify separately, not committed here.)
Expected: bridge, new schema, hooks, skills staged

- [ ] **Step 2: Pre-flight plan-review on THIS plan (dogfood the new command)**

Run:
```bash
node scripts/codex-bridge.mjs plan-review --cd . --prompt @docs/plans/2026-05-18-codex-tier-review-consolidation-p0p1.md > /tmp/p1-planreview.json 2>&1
tail -30 /tmp/p1-planreview.json
```
Expected: valid plan-review JSON; address any `high` findings before commit

- [ ] **Step 3: Commit P1 (standalone — auto-review chokepoint)**

```bash
git commit -m "feat(p1): Track A — config.toml profiles, bridge --profile routing, plan-review cmd, enrich/rescue disabled, auto-review profile case"
```
Expected: commit succeeds. (auto-spec-gate removed in Task 13 so no plan-gate fires on this commit; `git commit` is not a push so no auto-review Codex gate.)

---

## Verification matrix (acceptance — spec §9 P0/P1 criteria)

| Spec criterion | Command | Expected |
|---|---|---|
| P0: version consistent | `grep -hE '"version"' package.json .claude-plugin/plugin.json` | both `1.1.1` |
| P0: orphan gone | `ls skills/codex-enrich-workspace 2>&1` | not found |
| P0: 22 skills doc-consistent | `grep -E '22 skill' README.md` | header + structure both 22 |
| P0: bridge canonical documented | `grep -c 'Canonical source' docs/ARCHITECTURE.md` | `1` |
| P1: no-flag run spawns `-p`, no default `-m`/`-c` | `... review --print-args --prompt noop --cd .` → parse args JSON (Task 8 Step 3) | `p=normal m=ABSENT effort=ABSENT` |
| P1: `--effort` still patches field | `... review --print-args --effort high ...` → args JSON | `model_reasoning_effort="high"` present |
| P1: wrong key eradicated | `grep -cE 'reasoning\.effort=' scripts/codex-bridge.mjs` | `0` |
| P1: no-flag resume emits nothing | `... resume --print-args --session-id x ...` → args JSON (Task 9 Step 2) | `p=ABSENT m=ABSENT effort=ABSENT` |
| P1: plan-review works | `... plan-review --prompt @<plan> ...` | valid findings JSON |
| P1: enrich passthrough | `echo hi >/tmp/h; ... enrich --prompt @/tmp/h` | stdout == `hi` |
| P1: clean push = 1 call (2 strict/allowlist) | `grep tier_chosen ~/.claude/sspower/*.log` | `profile=normal`; SECURITY only strict/allowlist |
| P1: auto-spec-gate unwired | `grep -c auto-spec-gate hooks/hooks.json` | `0` |
| P1: zero live rescue callers | Task 14 Step 5 grep | `0` |
| P1: rescue disabled | `node scripts/codex-bridge.mjs rescue --prompt x; echo $?` | notice + exit 2 |
| Bridge integrity | `node --check scripts/codex-bridge.mjs` | OK |

## Risks & assumptions

- **R1 — `~/.codex/config.toml` is user-global, outside the repo.** Task 5 edits it in place; not version-controlled here. Snapshot before edit (Step 1). Other tools sharing this config (interactive Codex TUI) inherit `flex` root — acceptable per spec §4.1 (flex is sustainable; fast reserved for `quick`/`deep`).
- **R2 — Spec §12 caller list was incomplete.** Grounding found `executing-plans` + `codex-enrich` as additional `rescue` callers and confirmed `subagent-driven-development` `spec-review` is *correct* usage (impl-vs-spec), NOT a migration target. Task 14 reconciles; the rescue-as-worker path migrates to `implement --write` (spec under-specified this — documented here as the resolution).
- **R3 — `_runCodexComplete` uses an array-literal arg style** (not incremental `args.push`). Task 7 Step 2 requires converting two hardcoded entries to post-construction conditional pushes; verify the surrounding array construction when editing (re-read `:904-917` before the edit per edit-safety).
- **R4 — Bridge line numbers will drift as edits land.** All refs verified at plan time (post-rebase, 1780 lines). Re-grep the anchor (function name / unique string) before each edit rather than trusting the line number (edit-safety rule).
- **R5 — Codex `-p`/`--profile` flag support assumed.** Spec verified `codex exec resume` has NO `--profile`; `codex exec` (non-resume) `-p` support is assumed from Codex CLI. Task 6 Step 4 + Task 8 Step 3 fail-fast if `-p` is rejected — if so, fall back to emitting `-m`+`-c model_reasoning_effort` from profile values read out of `~/.codex/config.toml` (documented fallback, spec R3).
- **R6 — `auto-review.sh` security pass stays effort-pinned (`xhigh`), not profile-ized.** Intentional per CLAUDE.md/ARCHITECTURE; only the MAIN review switches to `--profile`. SANITY default flips on→off (D-A4).
- **Assumption:** Task 15 strictly gated on Task 14 Step 5 returning zero — enforced as a hard STOP in Task 15 Step 1.
- **R7 — Parked stash (housekeeping, not a plan dependency).** `git stash@{0}` "main resume handoff 2026-05-17 (post-iter4 restore)" holds main's session-resume `docs/handoff.md` rewrite (it differs between `main` and this branch; stashed during the iter4 branch switch). It is NOT needed for this plan. Restore when next on `main`: `git checkout main` then `git stash pop` (verify with `git stash list` first). If lost, it is only a regenerated handoff doc — no code.

## Execution Handoff

**Plan complete. Three execution options:**
1. **Subagent-Driven (recommended)** → sspower:subagent-driven-development
2. **Inline Execution** → sspower:executing-plans
3. **Codex execute** → delegate via `codex-bridge.mjs implement --write`

**Which approach?**
