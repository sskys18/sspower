# Design: sspower config/state consolidation

> Date: 2026-05-18
> Branch: `refactor/sspower-config-consolidation` (off `main`)
> Status: DRAFT — awaiting Codex review + user approval

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
- `log_rotate_lines`: integer, default 1000 (replaces the hardcoded literal in `codex-bridge.mjs`).
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
- `updateConfig(patch)` → atomic read-modify-write: read current, shallow-merge `patch`, write to `config.json.<pid>.<ts>` then `rename()` over `config.json`. Reuses the temp+rename pattern already in `_diet-config.js:76`.

**Concurrency contract:** all writers (diet toggle, rotation-lines change) go through `updateConfig`. `rename()` is atomic on the same filesystem, so a diet write and a rotation-config write cannot interleave-corrupt. Readers tolerate a transient missing file (mid-rename) by falling back to defaults for that read; next read succeeds. Rotation of `codex.log` / appends to `failures.jsonl` do NOT touch `config.json` (separate files) — no cross-contention.

### Code changes — plugin repo (this repo)

| File:line | Change |
|---|---|
| `scripts/codex-bridge.mjs:53` | `FAILURE_LOG` → `path.join(os.homedir(),'.claude','sspower','failures.jsonl')` |
| `scripts/codex-bridge.mjs:61` | `LOG_FILE` → `…/sspower/codex.log` |
| `scripts/codex-bridge.mjs` (rotation) | rotation threshold reads `readConfig().log_rotate_lines` (fallback 1000) instead of literal |
| `hooks/prompt-submit:21` | `DIAG_LOG="${HOME}/.claude/sspower/codex.log"` |
| `hooks/_log.sh:10` | default → `$HOME/.claude/sspower/codex.log` (keep env override) |
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
| Concurrent config writes (diet vs rotation-lines) corrupt JSON | All writes via `updateConfig` atomic temp+rename; reads tolerate transient absence |
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

None outstanding. Single-consumer scope locked; log-folding ruled out for correctness; branch chosen.
