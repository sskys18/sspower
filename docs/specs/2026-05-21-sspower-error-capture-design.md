# sspower Unified Error Capture + Investigation — Design

Date: 2026-05-21
Status: design — pending review
Topic: capture errors across all sspower/Claude Code surfaces into one log; broaden the codex-only investigator skill to cover all errors.

## 1. Problem

Running Claude Code with the sspower plugin produces errors from several
unrelated surfaces. Today only **one** surface is captured and triaged:

| Surface | Captured today? | Where |
| --- | --- | --- |
| Codex bridge run errors | yes | `~/.claude/sspower/failures.jsonl` + `codex-failures` CLI + `codex-health` skill |
| Codex bridge spawn errors (`spawn_error`) | no | only `~/.claude/sspower/codex.log` as `[error]` — not in `failures.jsonl`, not triaged |
| sspower hook crashes | partial | hooks log *some* events to `codex.log`; an uncaught crash is not trapped |
| Plugin load errors (bad skill/agent frontmatter) | no | Claude Code's own `~/.claude/debug/` stream only |
| Claude Code core errors | no | `~/.claude/debug/` + MCP logs only |

There is no single place an operator (or the `/daily` routine) can look to
answer "what errors happened in the last 24h, and which are sspower's fault".

## 2. Hard constraint — what is and isn't interceptable

A Claude Code plugin **cannot** intercept "an error occurred". There is no
error-hook event. Hook events are limited to SessionStart, UserPromptSubmit,
PreToolUse, PostToolUse, PreCompact, SessionEnd, Stop. None fire on error.

Consequence — capture splits into two tiers:

- **Tier 1 — Capture (real-time).** Only *sspower's own shell hooks* can be
  made to report their own crashes. This is the sole genuine real-time
  capture available.
- **Tier 2 — Scrape (on-demand).** Everything else — plugin-load errors,
  Claude Code core errors, MCP errors, codex `spawn_error` — is only
  observable by reading logs Claude Code already writes. This is read at
  `/daily` time, not captured live.

Designs that promise live capture of plugin-load / CC-core errors are not
implementable; this spec does not attempt it.

## 3. Decision summary (approved 2026-05-21)

1. **Combined log.** One unified file, `~/.claude/sspower/errors.jsonl`,
   covering *all* categories including codex.
2. **One-source-of-truth preserved.** `errors.jsonl` is a *derived
   aggregate* (a materialized view), not a second authoritative write
   target. `failures.jsonl`, `codex.log`, CC `debug/`, MCP logs remain the
   authoritative sources. The scraper rebuilds/extends `errors.jsonl` from
   them with dedup.
3. **Investigator skill broadened + renamed.** `codex-health` →
   `error-health`. It investigates *all* error categories, with codex as one
   section. Triggered standalone and by `/daily`.
4. **No codex-bridge edit.** The `spawn_error` gap is closed by the scraper
   (greps `codex.log`), not by editing `codex-bridge.mjs`. A source-level
   bridge fix (`appendFailure` in the spawn catch block) is noted as
   optional future work, out of scope here.

## 4. Data contract — `~/.claude/sspower/errors.jsonl`

One JSON object per line. Mode `0600`. Ring-buffer rotation (see §7).

```json
{
  "ts": "2026-05-21T04:57:18Z",
  "category": "hook|plugin-load|codex|cc-core|mcp",
  "origin": "plugin|external",
  "source": "hook.auto-review",
  "level": "error|warn",
  "message": "exit 1",
  "raw": "<original log line, truncated 500 chars>",
  "session": "<session id or null>"
}
```

Field semantics:

- `category` — which surface the error came from.
- `origin` — `plugin` = caused by sspower (hooks, bridge, sspower skills);
  `external` = Claude Code core, other plugins, MCP servers. This is the
  field that answers "is it our fault or not".
- `source` — finer label, e.g. `hook.auto-review`, `bridge.complete`,
  `plugin.<name>`, `mcp.<server>`, `cc.core`.
- `raw` — the original log line, redacted (see §8) and truncated.

Origin classification rules:

| category | origin |
| --- | --- |
| `hook` (any `hook.*` source) | `plugin` |
| `codex` (`bridge.*`, `failures.jsonl`) | `plugin` |
| `plugin-load` for an sspower skill/agent | `plugin` |
| `plugin-load` for a non-sspower plugin | `external` |
| `cc-core` | `external` |
| `mcp` | `external` |

## 5. Tier 1 — Capture (plugin repo)

### 5.1 `hooks/_log.sh` — two new helpers

```sh
# Append one structured row to errors.jsonl. Best-effort, never errors out.
_sspower_err_jsonl() {  # category origin source level message
  local f="${SSPOWER_ERRORS_FILE:-$HOME/.claude/sspower/errors.jsonl}"
  local ts cat="$1" org="$2" src="$3" lvl="$4" msg="$5"
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || return 0
  # JSON-escape message
  local esc="${msg//\\/\\\\}"; esc="${esc//\"/\\\"}"; esc="${esc//$'\n'/\\n}"
  (
    umask 077
    mkdir -p "$(dirname "$f")" 2>/dev/null || exit 0
    printf '{"ts":"%s","category":"%s","origin":"%s","source":"%s","level":"%s","message":"%s","raw":"","session":null}\n' \
      "$ts" "$cat" "$org" "$src" "$lvl" "$esc" >> "$f"
  ) 2>/dev/null || true
}

# EXIT trap: log a crash only when the exit code is NOT an expected one.
# Usage: trap '_sspower_exit_guard $? "0" hook.NAME' EXIT
_sspower_exit_guard() {
  local rc="$1" ok="$2" src="$3"
  case " $ok " in *" $rc "*) return 0 ;; esac
  log_event error "$src" kind=crash exit="$rc"
  _sspower_err_jsonl hook plugin "$src" error "exit $rc"
}
```

The expected-codes argument is the crux. sspower hooks do **not** deny via
`exit 2` — PreToolUse hooks (`auto-review.sh`, `semble-rewrite.sh`,
`cmd-rewrite.sh`) emit a JSON `permissionDecision:"deny"`/`"ask"` on stdout
and `exit 0` (verified: `auto-review.sh:84-88`). So the only legitimate
non-zero exit in the whole set is `session-start`'s `exit 20` (sspower-mem
HARD data-loss propagation). Expected set is therefore `"0"` for every hook
except `session-start` (`"0 20"`). A blanket "non-zero = error" trap would
still be wrong — `set -e` mid-script aborts must be caught, intentional
`exit 20` must not.

### 5.2 Per-hook source + trap lines

Only 3 files currently source `_log.sh` (`auto-review.sh`,
`auto-spec-gate.sh`, and `_log.sh` itself). Hooks that do **not** already
source it need two lines added near the top; hooks that already source it
need only the `trap` line:

```sh
source "$(dirname "${BASH_SOURCE[0]}")/_log.sh"          # only if not already sourced
trap '_sspower_exit_guard $? "0" hook.NAME' EXIT         # NAME = hook basename
```

`session-start` uses `"0 20"` instead of `"0"`.

Shell hooks in scope (**9**): `session-start` (`0 20`), `prompt-submit`,
`semble-session.sh`, `semble-context.sh`, `semble-rewrite.sh`,
`cmd-rewrite.sh`, `auto-review.sh` (already sources `_log.sh`),
`auto-spec-gate.sh` (already sources `_log.sh`), `codex-lsp-posttool.sh`.

`wiki-archive.sh` is **excluded** — it ends with `exec python3 …`, which
replaces the bash process; an `EXIT` trap set beforehand never fires. The
Python child's failures are covered by Tier 2 scrape.

Expected-code set per hook is re-verified against each hook's own `exit`
statements during implementation (`grep -oE 'exit [0-9]+'`).

### 5.3 Out of capture scope

JS hooks (`diet-activate.js`, `diet-track.js`) and the Python child of
`wiki-archive.sh` (`wiki-archive.py`) do **not** get a bash trap.
`codex-track-prompt.sh` is shell but is a low-risk read-only injector and is
left to scrape too (it is not in the 9). Their failures are covered by
Tier 2 scrape (stderr lands in `~/.claude/debug/`). Adding language-specific
traps is deferred — YAGNI until scrape proves insufficient.

## 6. Tier 2 — Scraper (`~/.claude` repo)

New file `~/.claude/skills/daily/scripts/scan_errors.py` — mirrors the
existing `extract_github.py` in the same directory (stdlib only, JSON to
stdout, non-zero exit on hard failure).

Sources read:

| Source | Yields category | Notes |
| --- | --- | --- |
| `~/.claude/sspower/codex.log` `[error]`/`[warn]` lines | `hook` or `codex` | `hook.*` source → `hook`; `bridge.*` → `codex`. `kind=spawn_error` → `codex` (closes the gap) |
| `~/.claude/sspower/failures.jsonl` | `codex` | structured codex run failures |
| `~/.claude/sspower/errors.jsonl` (hook-trap rows) | `hook` | already in final schema — read for dedup, not re-ingested |
| `~/.claude/debug/*` | `plugin-load` or `cc-core` | CC's own debug stream; pattern-match load errors vs core errors |
| `~/Library/Caches/claude-cli-nodejs/<proj>/mcp-logs-*` | `mcp` | per-MCP-server logs |

Behaviour:
- Accepts `--since 1h|24h|7d|<ISO>` (default 24h) and `--json`.
- Classifies `category`/`origin` per §4.
- Dedup key: `sha1(category + source + message + day-bucket)`. A row already
  present in `errors.jsonl` is not appended again.
- Appends new rows to `errors.jsonl`.
- Emits summary JSON: `{counts: {category: {plugin: N, external: M}},
  recurring: [...], window: "24h", total: N}`.

## 7. Rotation

`errors.jsonl` follows the same ring-buffer pattern as `failures.jsonl`
(`appendFailure` in `codex-bridge.mjs`) and `codex.log` (`_log.sh`):
- Cap: 2000 lines (`SSPOWER_ERRORS_MAX`, env-overridable).
- On overflow keep last 1000 (`SSPOWER_ERRORS_KEEP`).
- The scraper performs rotation after its append pass (single writer for
  rotation — avoids two processes truncating concurrently). The hook-trap
  writer only appends, never rotates.

## 8. Secret redaction

The scraper redacts before writing `raw`/`message`, reusing the same
patterns as `codex-bridge.mjs` `redactSecrets()`: `sk-…`, `gh[ps]_…`,
`password|secret|api_key|token = …`. The hook-trap writer only ever writes a
fixed `"exit N"` message, so it carries no secret risk.

## 9. Investigator skill — `codex-health` → `error-health`

Rename the skill directory `~/.claude/skills/codex-health/` →
`~/.claude/skills/error-health/` and rewrite `SKILL.md`.

New scope — investigates **all** categories:

1. **Error inventory (last 24h)** — run `scan_errors.py --since 24h`. Report
   table: `category | origin | count | last_ts | sample_source`.
2. **Plugin vs external split** — headline count, so the operator
   immediately sees how much is sspower's fault.
3. **Recurring errors** — same `source+message` seen 3+ times.
4. **Codex section** (existing logic, retained) — stuck review branches,
   stale verdict cache, codex error-kind table + recommendations.
5. **Hook crashes** — any `category:hook` rows, with the offending hook.
6. **Recommendations** — per category.
7. **Auto-actions (with confirmation)** — unchanged codex cleanup actions.

Trigger words updated: `error health`, `errors`, `investigate errors`,
`codex health` (kept as alias), `why is Claude erroring`.

`SKILL.md` also fixes the stale line claiming `failures.jsonl` is "absent
for now" — it exists.

## 10. `/daily` integration

`~/.claude/skills/daily/SKILL.md`:
- **Step 1, subagent 3** — currently "Codex health", reads
  `codex-health/SKILL.md`. Change to read `error-health/SKILL.md` and
  execute the broadened steps. Report error counts by category × origin.
- **Step 2c** — new `## Errors` section writer, idempotent like `## GitHub`:
  - clean → `## Errors — clean`
  - else → `## Errors — N plugin, M external` + per-category breakdown +
    recurring list.
  - error state uses the `⚠️` idempotency marker like other sections.

## 11. Files touched

Plugin repo (`.../plugins/sspower`):

| File | Change |
| --- | --- |
| `hooks/_log.sh` | +`_sspower_exit_guard`, +`_sspower_err_jsonl` |
| 9 shell hooks | +`trap` line (7 also +`source _log.sh`) |
| `CLAUDE.md` | update `codex-health` references → `error-health`; note `errors.jsonl` |

`~/.claude` repo:

| File | Change |
| --- | --- |
| `skills/codex-health/` → `skills/error-health/` | rename dir |
| `skills/error-health/SKILL.md` | rewrite — broadened scope |
| `skills/daily/scripts/scan_errors.py` | new |
| `skills/daily/SKILL.md` | subagent 3 ref + `## Errors` section |

## 12. Not doing (explicit scope cuts)

- Live capture of plugin-load / CC-core / MCP errors — not interceptable
  (§2). Scrape only.
- Language-specific crash traps for JS/Python hooks — deferred (§5.3).
- Editing `codex-bridge.mjs` to route `spawn_error` into `failures.jsonl` —
  optional future work; the scraper covers it (§3.4).
- A standalone `sspower-errors` viewer CLI mirroring `codex-failures` —
  deferred; the `error-health` skill + `/daily` already provide
  investigation. Add later if direct CLI querying is wanted.
- Telegram/notification on error — `/daily` already aggregates and sends.

## 13. Test plan

- `_sspower_exit_guard` unit: exit 0 → no row; expected `exit 2` → no row;
  `exit 1` → one `errors.jsonl` row + one `codex.log` `[error]`.
- Each modified hook: run with a forced failure, confirm one row, confirm
  normal `exit 2` denies produce **no** row.
- `scan_errors.py`: fixture logs for each source; assert classification,
  dedup (re-run yields zero new rows), `--since` window filtering,
  redaction.
- `error-health` skill: eval-test per the plugin rule "all skill changes
  must be eval-tested before committing".
- `/daily` `## Errors` section: idempotency (re-run skips clean section,
  replaces `⚠️` section).
