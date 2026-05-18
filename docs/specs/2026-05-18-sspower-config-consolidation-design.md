# Design: sspower config/state consolidation

> Date: 2026-05-18
> Branch: `refactor/sspower-config-consolidation` (off `main`)
> Status: REV2 — Codex spec-review applied (verdict v1: non-compliant; 5 gaps addressed below). Awaiting user approval.

## Codex review resolution (v1 → REV2)

| # | Codex finding | Resolution |
|---|---|---|
| 1 | Missed runtime consumer `skills/codex-diagnostics/SKILL.md` (hardcodes `~/.claude/sspower-codex.log` at lines 10, 32, + description) | Added to plugin change table. |
| 2 | `_log.sh` rotation knobs left as env, contradicting "all knobs in config" | **Explicit carve-out** (rationale below) — narrowed `log_rotate_lines` claim to codex-bridge only. |
| 3 | "Atomic read-modify-write" is a false guarantee (lost-update) | **Collapsed, not locked**: verified nothing writes `log_rotate_lines` programmatically (it's a const/env default). Only `diet` is code-written. Single writer key → temp+rename is sufficient. Lock explicitly deferred (YAGNI, single human operator). |
| 4 | Stale docs (`README.md:256`, `ARCHITECTURE.md:76,325`, `CLAUDE.md`) | Added to change table as doc-cleanup step. |
| 5 | `_diet-config.js` default-resolution chain (`SSPOWER_DIET_DEFAULT`, XDG `diet.json`, `defaultMode`) fate undefined | **Explicit non-goal**: that chain computes the *default* mode and is unchanged. This refactor relocates only the *active* flag. |

## Problem

sspower scatters 4 files directly in `~/.claude/` root:

| File | Nature | Writer |
|---|---|---|
| `sspower-codex-failures.jsonl` | append-only structured event log | `scripts/codex-bridge.mjs:53` |
| `sspower-codex.log` | rotated text log (1000 lines) | `codex-bridge.mjs:61`, `hooks/prompt-submit:21`, `hooks/_log.sh:10` |
| `.sspower-diet` | 4-byte diet-level state flag | `hooks/diet-activate.js:16`, `diet-track.js:14`, `_diet-config.js:76` |
| `sspower-codex-patches.md` | hand-written upstream-resync recovery doc | human only |

This pollutes `~/.claude/` root and there is no single place to configure sspower. Two cross-repo consumers in the user's `~/.claude` config repo (NOT this plugin) also hardcode these paths: `bin/codex-failures:7`, `skills/codex-health/SKILL.md:9,10,19`.

## Goals

- Single root entry: `~/.claude/sspower/` directory replaces 4 scattered files.
- Single configuration file: `~/.claude/sspower/config.json` holds **all** configurable knobs + state flags (diet level, log rotation).
- No data loss (9 days of `failures.jsonl`, the `patches.md` recovery doc, the live diet state).
- Single consumer (one user, one machine) → no relocatable base_dir, no env-var SSOT, no jq dependency. YAGNI.

## Non-Goals

- Relocatable `base_dir` / `SSPOWER_HOME` override. Single consumer never needs it.
- Folding append-only logs into JSON. `failures.jsonl` / `codex.log` are data streams written on every event by processes that run concurrently with diet hooks; embedding them in a config JSON forces whole-file rewrite+reparse per append and creates a write race that corrupts config. Logs are output, not configuration — they remain separate files in the dir.
- Migrating the cross-repo consumers' resolution to be dynamic. They hardcode the new fixed path (see below).
- **Changing `_diet-config.js` default-resolution** (Codex v1 #5). Its chain — `SSPOWER_DIET_DEFAULT` env → `$XDG_CONFIG_HOME/sspower/diet.json` → `~/.config/sspower/diet.json` → `%APPDATA%` → `defaultMode` — computes the *default* diet mode when no active flag is set. That is orthogonal to *active* state and stays **unchanged**. This refactor relocates only the active flag (`.sspower-diet` → `config.json.diet`). The resolution order becomes: active `config.json.diet` if present, else the existing default chain.
- **Other already-namespaced sspower state.** `~/.claude/state/sspower/codex/` (session tracking), `~/.cache/sspower/verdicts/` (review cache), `<repo>/.claude/sspower/` (per-repo followups/patches) are already namespaced, not root clutter — explicitly out of scope. This change touches only the 4 `~/.claude/sspower-*` / `.sspower-diet` root files.

## Scope carve-out: `_log.sh` rotation knobs (Codex v1 #2)

`hooks/_log.sh` is the shell logger for hook events (auto-review denials etc.), separate from `codex-bridge.mjs`. Its rotation tuning `SSPOWER_LOG_MAX_LINES` / `SSPOWER_LOG_KEEP_TAIL` **stays env-with-default and does NOT move into `config.json`**, deliberately:

- Reading JSON from this hot bash hook needs a `jq` dependency on a path that runs on hook events — unjustified for a single consumer.
- These are static tuning the user effectively never changes.
- `config.json.log_rotate_lines` governs **only `codex-bridge.mjs`'s `codex.log` rotation** (its `LOG_MAX_LINES` literal). `_log.sh`'s env default is kept numerically equal (1000) so the shared `codex.log` cap stays consistent, exactly as the existing `_log.sh:14` comment already promises.

Net: the "single config file" holds sspower's code-managed state (`diet`) + the one rotation knob a user might tune (`log_rotate_lines`, bridge-side). The shell hook logger's env tuning is an intentional, documented exception — not an oversight.

## Design

### Layout

```
~/.claude/sspower/
  config.json        ← THE config file: all knobs + state
  failures.jsonl     (was ~/.claude/sspower-codex-failures.jsonl)
  codex.log          (was ~/.claude/sspower-codex.log)
  patches.md         (was ~/.claude/sspower-codex-patches.md; human doc)
```

`config.json` schema (v1):

```json
{
  "diet": "full",
  "log_rotate_lines": 1000
}
```

- `diet`: one of `off | lite | full | ultra` (replaces `.sspower-diet` content).
- `log_rotate_lines`: integer, default 1000. **User-edited, read-only to code** — governs `scripts/codex-bridge.mjs` `codex.log` rotation only (replaces its `LOG_MAX_LINES` literal). NO code path writes this key. See "Concurrency" + "Scope carve-out: `_log.sh`".
- Unknown/missing keys → defaults. Missing file → all defaults, file lazily created on first write.

### Path constants

Fixed, hardcoded in all consumers (no resolution logic):

- `SSPOWER_DIR = ~/.claude/sspower`
- `CONFIG = $SSPOWER_DIR/config.json`
- `FAILURES = $SSPOWER_DIR/failures.jsonl`
- `CODEX_LOG = $SSPOWER_DIR/codex.log`

`hooks/_log.sh` keeps its existing `SSPOWER_LOG_FILE` env override (backward-compat, harmless) but its default becomes `$SSPOWER_DIR/codex.log`.

### Config access module (plugin)

New `hooks/_config.js` (or extend existing `hooks/_diet-config.js`) exposing:

- `readConfig()` → parsed object merged over defaults; tolerant of absent/corrupt file (returns defaults, never throws).
- `updateConfig(patch)` → read current (or defaults), shallow-merge `patch`, write to `config.json.<pid>.<ts>` then `rename()` over `config.json`. Reuses the O_EXCL temp + rename pattern already in `_diet-config.js:76`.

**Concurrency contract (corrected per Codex v1 #3):** The earlier draft claimed "atomic read-modify-write" — that is false in general (two read-merge-rename writers can lose each other's updates). It is **not needed here**, because there is exactly **one code-writable key**:

- `diet` — written only by the diet hooks (`diet-activate`/`_diet-config`). A single human toggling diet serializes these by nature; the existing O_EXCL temp already prevents torn writes.
- `log_rotate_lines` — **never written by code** (verified: `codex-bridge.mjs` uses a `const LOG_MAX_LINES`; `_log.sh` uses an env default). It is user-edited, read-only to code.

With one writer key, temp+rename is sufficient: no lost-update scenario exists. The only residual race — a human hand-editing `config.json` in the exact sub-second a diet toggle fires — is a non-scenario for a single sequential operator and is explicitly accepted. A `flock` is **deferred (YAGNI)**; revisit only if a second programmatic writer is ever added. Readers tolerate a transient missing file (mid-rename) via default fallback. `codex.log` rotation / `failures.jsonl` appends never touch `config.json` (separate files).

### Code changes — plugin repo (this repo)

| File:line | Change |
|---|---|
| `scripts/codex-bridge.mjs:53` | `FAILURE_LOG` → `path.join(os.homedir(),'.claude','sspower','failures.jsonl')` |
| `scripts/codex-bridge.mjs:61` | `LOG_FILE` → `…/sspower/codex.log` |
| `scripts/codex-bridge.mjs` (rotation) | rotation threshold reads `readConfig().log_rotate_lines` (fallback 1000) instead of literal |
| `hooks/prompt-submit:21` | `DIAG_LOG="${HOME}/.claude/sspower/codex.log"` |
| `hooks/_log.sh:10` | default path → `$HOME/.claude/sspower/codex.log` (keep `SSPOWER_LOG_FILE` env override). Rotation knobs `SSPOWER_LOG_MAX_LINES`/`SSPOWER_LOG_KEEP_TAIL` stay env — see carve-out |
| `skills/codex-diagnostics/SKILL.md:10,32` + description | replace `~/.claude/sspower-codex.log` → `~/.claude/sspower/codex.log` (Codex v1 #1 — missed runtime consumer) |
| `README.md:256`, `docs/ARCHITECTURE.md:76,325` | doc-cleanup: old paths → new (Codex v1 #4) |
| `CLAUDE.md` (plugin) | update any `~/.claude/sspower-*` path mentions (Codex v1 #4) |
| `hooks/diet-activate.js:16` | write diet via `updateConfig({diet: level})` instead of `.sspower-diet` |
| `hooks/diet-track.js:14` | read diet via `readConfig().diet` instead of `.sspower-diet` |
| `hooks/_diet-config.js:76` | generalize temp+rename into `updateConfig`; drop `.sspower-diet` path |
| `hooks/diet-activate.js:5` | stale comment "(for tracker/statusline)" — update text; **no statusline code actually reads the flag** (verified: `bin/statusline.js` has zero diet refs) |

> Verified exhaustively (`grep -rn` plugin + config repo, 2026-05-18): the ONLY `.sspower-diet` accessors are the 3 hooks above. No statusline/tracker consumer exists — the `diet-activate.js:5` comment is aspirational and stale. No phantom consumer to chase during implementation.

### Code changes — config repo (`~/.claude`, separate git repo)

These are NOT in this plugin; listed for the implementation plan's cross-repo step:

| File:line | Change |
|---|---|
| `bin/codex-failures:7` | `LOG="$HOME/.claude/sspower/failures.jsonl"` |
| `bin/codex-failures:3` | comment path update |
| `skills/codex-health/SKILL.md:9,10,19` | `sspower/codex.log`, `sspower/failures.jsonl` |

### Migration — `scripts/sspower-migrate.sh` (manual, one-shot)

User-run after upgrade. Idempotent:

```
mkdir -p ~/.claude/sspower
[ -f ~/.claude/sspower-codex-failures.jsonl ] && mv ~/.claude/sspower-codex-failures.jsonl ~/.claude/sspower/failures.jsonl
[ -f ~/.claude/sspower-codex.log ]            && mv ~/.claude/sspower-codex.log            ~/.claude/sspower/codex.log
[ -f ~/.claude/sspower-codex-patches.md ]     && mv ~/.claude/sspower-codex-patches.md     ~/.claude/sspower/patches.md
# diet: migrate old flag content into config.json, then remove flag
if [ -f ~/.claude/.sspower-diet ]; then
  level=$(tr -d '[:space:]' < ~/.claude/.sspower-diet)
  # write {"diet":"<level>","log_rotate_lines":1000} if config absent, else patch .diet
  rm ~/.claude/.sspower-diet
fi
# ensure config.json exists with defaults if still absent
```

`mv` on same filesystem is atomic → no partial state. Skips absent files (safe to re-run).

**Sequencing constraint:** the diet flag is live this session. Running migration mid-session moves the flag into `config.json`; until the upgraded hooks load, an old hook reading `.sspower-diet` would miss it → one diet re-init blip. Mitigation documented in plan: run migration only when ready to accept at most one diet-state reset, ideally at session boundary.

## Risks

| Risk | Mitigation |
|---|---|
| Concurrent config writes lose updates | Collapsed (Codex v1 #3): only `diet` is code-written; `log_rotate_lines` is read-only to code. One writer key → temp+rename sufficient, no lock. See Concurrency contract |
| `codex.log` cap inconsistent between bridge (config) and `_log.sh` (env) | `_log.sh` env default kept numerically = `config.json.log_rotate_lines` default (1000); documented carve-out, matches existing `_log.sh:14` invariant |
| Missed runtime consumer beyond the 6 found | `codex-diagnostics` SKILL was the miss (now in table). Impl step 1 = exhaustive `grep -rn 'sspower-codex\|\.sspower-diet'` across plugin + config repo, fail-closed if any unlisted hit |
| Hot-path cost: diet read every prompt now parses JSON | File ~40 bytes; parse is sub-ms; acceptable |
| Cross-repo consumers break if only plugin updated | Implementation plan has explicit cross-repo step (`bin/codex-failures`, `codex-health`); migration + both edits land together |
| Migration run mid-session blips diet | Documented sequencing constraint; run at session boundary |
| `patches.md` (recovery doc) lost in migration | `mv` preserves it into `sspower/patches.md`; it documents this very kind of resync |
| Other undiscovered `.sspower-diet` / path readers | Implementation step 1 = exhaustive `grep -rn` across plugin + config repo before edits (per edit-safety "No Semantic Search") |

## Rollout

1. Plugin branch `refactor/sspower-config-consolidation` (off `main`) — code + `_config.js` + migrate script + tests.
2. Cross-repo edits in `~/.claude` config repo (`bin/codex-failures`, `codex-health` skill), committed there separately.
3. User runs `scripts/sspower-migrate.sh` at a session boundary.
4. Verify: `~/.claude` root has only `sspower/`; diet still active; codex-health reads new paths; a forced codex failure appends to `sspower/failures.jsonl`.

## Open questions

None outstanding. Codex v1 review applied (5/5 addressed in REV2). Single-consumer scope locked; log-folding ruled out for correctness; `_log.sh` carve-out + `_diet-config` default-chain non-goal explicit; concurrency claim corrected (one writer key, no lock). Branch chosen. Ready for user approval → writing-plans.
