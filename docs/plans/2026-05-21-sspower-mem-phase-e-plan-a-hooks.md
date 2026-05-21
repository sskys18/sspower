# sspower-mem Phase E — Hook + skill rewrites

> **For agentic workers:** REQUIRED SUB-SKILL: use `sspower:subagent-driven-development` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Executor:** a Claude agent via `sspower:subagent-driven-development` — **NOT the Codex worker**. The `git checkout -b` / `git commit` steps ARE in scope for this executor; the Codex-worker "must not commit" rule does not apply here.

**Goal:** Wire the two project-wiki hooks and four skills onto the `sspower-mem` memory backend, exactly as the formal spec mandates. After Phase E:
- `hooks/wiki-archive.py` ingests each session summary into `sspower-mem` as an `episodic` block and **stops** writing `sessions/*.md`; it still writes `sessions/*.json` (legacy belt — removed later in Phase F). `append_index_entry` is removed.
- `hooks/session-start` injects recent project memory into `additionalContext`.
- Every hook caller normalizes `sspower-mem` exit codes through the spec's `sspower_mem_call` wrapper (bash + Python versions).
- `brainstorming`, `systematic-debugging`, `writing-plans`, `using-sspower` SKILL.md files read/write decisions and gotchas via the `sspower-mem` CLI instead of `wiki/*.md` files.

**Single source of truth:** `docs/specs/2026-05-13-index-backend-integration-design.md` — §6.5 (lines 724–743), §9 Phase E (lines 831–926), §6.1 CLI grammar (lines 231–305), §8 failure table (lines 780–794). Where the spec gives code, this plan transcribes it verbatim. No invented error handling, exit codes, env knobs, or invocation forms.

**NOT in Phase E** (spec §9 Phase F — explicitly out of scope here): removing the `write_json` legacy belt; archiving legacy `wiki/sessions/` + `wiki/decisions.md` + `wiki/gotchas.md` under `_legacy_pre_idx/`.

**Tech stack:** Python 3.11+ (`subprocess`, `shutil`), bash 3.2 (macOS — no bash-4 syntax, no `timeout(1)`), `uvx` (the `sspower-mem` runner — invoked `UV_OFFLINE=1 uvx --offline --from "$SSPOWER_MEM_SRC" sspower-mem ...`), repo bash test harness (`tests/hooks/*.sh`, PASS/FAIL idiom from `test-semble-session.sh`), skill evals via subagent dispatch (`skills/writing-skills/testing-skills-with-subagents.md`).

---

## Resolved design decisions (read before executing)

These resolve ambiguities the spec left implicit. Do not re-litigate during execution.

**D1 — `SSPOWER_MEM_SRC` default.** The spec uses `$SSPOWER_MEM_SRC` but §6.1 (lines 237–239) gives the resolution recipe: `PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"`, then `SSPOWER_MEM_SRC="$PLUGIN_ROOT/scripts/sspower_mem"`. The bash hooks compute it inline; the Python wrapper in `wiki-archive.py` uses `os.environ.get("SSPOWER_MEM_SRC", <computed default>)` where the default is `Path(__file__).resolve().parent.parent / "scripts" / "sspower_mem"`.

**D2 — `fan_out_to_central_sidecars` is UNCHANGED in Phase E.** The function (`hooks/wiki-archive.py:710-742`) symlinks `json_path` (the `.json`), NOT the `.md` — verified by reading the function: its parameter is `json_path` and line 738 calls `link.symlink_to(json_path.resolve())`. `write_json` keeps writing `sessions/*.json` through Phase E, so the fan-out target still exists. Its consumer is the user-global `/daily` skill (docstring line 712: "the /daily skill ... reads `~/.claude/sessions/*.json`"). **Decision: no change.** The fan-out and the `/daily` consumer remain correct because the `.json` belt is intact. Phase F (which removes `write_json`) must revisit this — flagged in §Out-of-scope, not fixed here.

**D3 — `<wiki>/index.md` → `index_legacy.md` is a documented operator step, NOT hook-managed.** §6.5 says `index.md` is "renamed to `index_legacy.md` and frozen". A hook cannot rename per-developer user data on every invocation (it would race, and re-create the file the next run). The plan: (a) `append_index_entry` is removed so the hook stops touching `index.md`; (b) any existing `<wiki>/index.md` is left in place — it is now stale but harmless; (c) Task 7 adds a one-line operator note to `CLAUDE.md` documenting that `<wiki>/index.md` is frozen legacy and may be manually renamed to `index_legacy.md`. No hook code renames files.

**D4 — wrapper placement is INLINE.** §9 Phase E presents the `sspower_mem_call` bash function as a verbatim block to transcribe into each hook. Do NOT factor it into a shared `hooks/lib/*.sh` — the spec did not ask for that and a shared file is an unrequested abstraction. `hooks/session-start` and `hooks/wiki-archive.sh` each get their own inline copy. (`wiki-archive.sh` does not itself call `sspower-mem` — see D5 — so only `session-start` carries the bash wrapper; `wiki-archive.py` carries the Python wrapper.)

**D5 — `wiki-archive.sh` is essentially unchanged.** §6.5 line 733: "unchanged in shape; still invokes the .py." The `.py` does the `sspower-mem` call via the Python wrapper. `wiki-archive.sh` gains only an optional pre-flight `command -v uvx` hint to stderr; it does not call `sspower-mem` itself. Keeping the bash wrapper out of `wiki-archive.sh` matches the spec's "unchanged in shape".

**D6 — eval mechanism.** There is no automated skill-eval runner in this repo (confirmed: no `evals/` dir, no runner script). The repo's skill-test mechanism is `skills/writing-skills/testing-skills-with-subagents.md` — subagent-dispatched scenario tests. `systematic-debugging` already ships `test-academic.md` + `test-pressure-1..3.md`. "Eval a skill" here = dispatch a subagent (via the `Task` tool, `subagent_type: general-purpose`) with a scenario prompt that loads the skill, then verify the agent emits the correct `sspower-mem` command. New academic-style test files are added per skill where none exist. The "exact command" for an eval is a `Task` tool call, not a shell command — stated explicitly in each eval step.

**D7 — `seed_wiki_files` is REMOVED.** §6.5 line 729: "`write_markdown` (and decisions/gotchas seeding) → calls `sspower-mem add`". `seed_wiki_files` (`hooks/wiki-archive.py:699-707`) creates empty `decisions.md` + `gotchas.md` templates whose only consumers were the file-reading Pre-flights of `brainstorming` / `systematic-debugging` / `writing-plans`. Task 3–5 rewrite those Pre-flights onto `sspower-mem`, so after Phase E nothing reads those files. Verified: `grep -rn 'decisions.md|gotchas.md' skills/ hooks/` (excluding the three SKILL.md files this plan rewrites and `wiki-archive.py` itself) returns zero readers. **Decision: remove `seed_wiki_files`, `WIKI_DECISIONS_SEED`, `WIKI_GOTCHAS_SEED`, and the `main()` call.** This is the spec-faithful reading of "decisions/gotchas seeding → calls `sspower-mem add`" — the seeding step is retired, not redirected, because an *empty template* has no content to `add`. (Real decisions/gotchas content is now `add`-ed by the skills themselves, per Tasks 3–5.)

**D8 — `using-sspower` has no skill table.** §6.5 line 741 says "add a routing note in the skill table". `skills/using-sspower/SKILL.md` contains no skill table — the routing tables live in `~/.claude/CLAUDE.md`, out of this repo. Closest spec-faithful surface in this file is the `## Skill Types` area. **Decision: add a one-line `## Project memory` note there** (Task 6.1). This is the documented interpretation of "skill table" for a file that has none — not an omission.

---

## File map

**Modify:**
- `hooks/wiki-archive.py` — add `import shutil`, `import subprocess`; add `sspower_mem_call`; rewrite `write_markdown` to emit content for `sspower-mem add` instead of writing `sessions/*.md`; remove `append_index_entry` + `WIKI_INDEX_HEADER`; rewire `main()`.
- `hooks/session-start` — capture stdin payload, extract `cwd`, add inline `sspower_mem_call` bash wrapper, append `sspower-mem search` output to `additionalContext`.
- `hooks/wiki-archive.sh` — add optional `command -v uvx` stderr hint.
- `skills/brainstorming/SKILL.md` — Pre-flight reads/writes decisions via `sspower-mem`.
- `skills/systematic-debugging/SKILL.md` — Pre-flight reads/writes gotchas via `sspower-mem`.
- `skills/writing-plans/SKILL.md` — Pre-flight reads decisions + episodic via `sspower-mem`.
- `skills/using-sspower/SKILL.md` — routing note (no behavior change).
- `CLAUDE.md` — document the Phase E hook behavior + the `index_legacy.md` operator note.

**Create:**
- `tests/hooks/test-session-start-mem.sh` — fake-`uvx` harness for the search-injection path + exit-code normalization.
- `tests/hooks/test-wiki-archive-mem.sh` — fake-`uvx` harness for the ingest path + exit-20 propagation.
- `skills/brainstorming/test-memory-cli.md` — academic-style eval scenario.
- `skills/writing-plans/test-memory-cli.md` — academic-style eval scenario.
- `skills/systematic-debugging/test-memory-cli.md` — academic-style eval scenario (joins existing pressure tests).

**Do NOT touch:** `scripts/sspower_mem/` library code (Plan-B / earlier phases own it); `hooks.json` (both hooks are already registered; editing it triggers the "hooks.json loads at session start" gotcha and is unnecessary).

---

## Task ordering rationale

Each commit is independently revertible and independently testable:
1. Branch.
2. `session-start` rewrite (bash wrapper + search injection) + its test — self-contained; reading-side change.
3. `wiki-archive.py` rewrite (Python wrapper + `write_markdown` + `append_index_entry` removal) + its test + `wiki-archive.sh` hint — self-contained; writing-side change.
4. `brainstorming` SKILL.md + eval.
5. `systematic-debugging` SKILL.md + eval.
6. `writing-plans` SKILL.md + eval.
7. `using-sspower` SKILL.md routing note + `CLAUDE.md` docs.
8. Offline-contract verification.

Skill changes (4–7) are independent of the hook changes (2–3) and of each other. Hook tests are pure (fake-`uvx` stubs, no real backend).

---

## Task 0: Feature branch

- [ ] **Step 0.1: Create the branch**

The repo is on `main`. All Phase E work lands on a feature branch.

```bash
git -C /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower checkout -b phase-e-hooks-skills
```

Expected output: `Switched to a new branch 'phase-e-hooks-skills'`.

---

## Task 1: `session-start` — inject recent project memory into context

**Files:**
- Modify: `hooks/session-start`
- Create: `tests/hooks/test-session-start-mem.sh`

**Behavior (spec §6.5 line 734):** `session-start` reads the SessionStart hook JSON payload from stdin, extracts the `cwd` field, runs `sspower-mem search --cwd <cwd> --scope project,user --mode recent --top-k 8 --json` through the `sspower_mem_call` wrapper, formats the JSON results to a plain-text block, and appends that block to `additionalContext`. On `SSP_RC` 10 or 30 it falls back to current behavior (no extra context). It never blocks; it never exits non-zero on a memory failure. (SessionStart has no data-loss surface — `search` never returns rc 20 — so there is no `exit 20` path here.)

The hook runs under `set -euo pipefail` (verified, `hooks/session-start:4`), so the wrapper MUST always `return 0` and communicate via `SSP_RC`/`SSP_OUT`, exactly as the spec mandates.

- [ ] **Step 1.1: Write the failing test**

Create `tests/hooks/test-session-start-mem.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="${ROOT}/hooks/session-start"
command -v jq      >/dev/null 2>&1 || { echo "SKIP: test-session-start-mem (no jq)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: test-session-start-mem (no python3)"; exit 0; }
FAIL=0; ok(){ echo "PASS: $1"; }; bad(){ echo "FAIL: $1 :: $2"; FAIL=1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PROJ="$WORK/proj"; mkdir -p "$PROJ"
mkdir -p "$WORK/bin"
export UV_LOG="$WORK/uvx.log"

# Fake `uvx`: log full argv to $UV_LOG, behave per $FAKE_MODE.
#   ok   -> print a search-results JSON envelope, exit 0
#   r10  -> exit 10 (degraded)
#   r30  -> exit 30 (dep missing)
#   weird-> exit 7  (unmapped uvx-internal code -> wrapper must normalize to 30)
write_fake_uvx() {
  cat > "$WORK/bin/uvx" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${UV_LOG:?}"
case "${FAKE_MODE:-ok}" in
  ok)    echo '[{"id":"abc1234567890def","source":"digest-recent","score":1.0,"content":"MEM_MARKER recent decision block","scope":"project:deadbeef","layer":"decision","ts":"2026-05-20T09:00:00Z"}]'; exit 0 ;;
  r10)   echo "degraded" >&2; exit 10 ;;
  r30)   echo "dep missing" >&2; exit 30 ;;
  weird) echo "boom" >&2; exit 7 ;;
esac
STUB
  chmod +x "$WORK/bin/uvx"
}
write_fake_uvx
: > "$UV_LOG"

payload() { jq -nc --arg cwd "$PROJ" '{session_id:"s",cwd:$cwd,hook_event_name:"SessionStart",source:"startup"}'; }

# Case A: search succeeds -> additionalContext carries the marker, the
# `sspower-mem search` argv shape is exactly the spec's, hook exits 0.
: > "$UV_LOG"
O="$(payload | FAKE_MODE=ok PATH="$WORK/bin:$PATH" "$HOOK")"; RC=$?
LOG="$(cat "$UV_LOG")"
[ "$RC" -eq 0 ] && ok "case A: hook exits 0" || bad "case A exit" "rc=$RC"
echo "$O" | jq -e '.hookSpecificOutput.hookEventName=="SessionStart"' >/dev/null \
  && ok "case A: emits SessionStart JSON" || bad "case A shape" "$O"
echo "$O" | jq -e '.hookSpecificOutput.additionalContext|test("MEM_MARKER")' >/dev/null \
  && ok "case A: recent memory injected" || bad "case A inject" "$O"
echo "$O" | jq -e '.hookSpecificOutput.additionalContext|test("using-sspower")' >/dev/null \
  && ok "case A: using-sspower block still present" || bad "case A skill block" "$O"
assert_arg() { case "$LOG" in *"$1"*) ok "case A: $2" ;; *) bad "case A: $2" "$LOG" ;; esac ; }
assert_arg '--offline --from'      'invoked via uvx --offline --from'
assert_arg 'scripts/sspower_mem'   '--from points at sspower_mem source'
assert_arg 'sspower-mem search'    'sspower-mem search subcommand'
assert_arg "--cwd $PROJ"           '--cwd is the payload cwd'
assert_arg '--scope project,user'  'scope project,user'
assert_arg '--mode recent'         '--mode recent (no --query at SessionStart)'
assert_arg '--top-k 8'             '--top-k 8'
assert_arg '--json'                '--json'
case "$LOG" in *'--query'*) bad "case A: unexpected --query" "$LOG" ;; *) ok "case A: no --query" ;; esac

# Case B: search degraded (rc=10) -> hook exits 0, no marker, skill block intact.
O="$(payload | FAKE_MODE=r10 PATH="$WORK/bin:$PATH" "$HOOK")"; RC=$?
[ "$RC" -eq 0 ] && ok "case B: rc=10 hook exits 0" || bad "case B exit" "rc=$RC"
echo "$O" | jq -e '.hookSpecificOutput.additionalContext|test("MEM_MARKER")|not' >/dev/null \
  && ok "case B: rc=10 injects no memory" || bad "case B inject" "$O"
echo "$O" | jq -e '.hookSpecificOutput.additionalContext|test("using-sspower")' >/dev/null \
  && ok "case B: rc=10 skill block survives" || bad "case B skill block" "$O"

# Case C: search dep-missing (rc=30) -> hook exits 0, no marker.
O="$(payload | FAKE_MODE=r30 PATH="$WORK/bin:$PATH" "$HOOK")"; RC=$?
[ "$RC" -eq 0 ] && ok "case C: rc=30 hook exits 0" || bad "case C exit" "rc=$RC"
echo "$O" | jq -e '.hookSpecificOutput.additionalContext|test("MEM_MARKER")|not' >/dev/null \
  && ok "case C: rc=30 injects no memory" || bad "case C inject" "$O"

# Case D: uvx-internal exit 7 -> wrapper normalizes to rc=30 -> hook exits 0, no marker.
O="$(payload | FAKE_MODE=weird PATH="$WORK/bin:$PATH" "$HOOK")"; RC=$?
[ "$RC" -eq 0 ] && ok "case D: unmapped rc normalizes, hook exits 0" || bad "case D exit" "rc=$RC"
echo "$O" | jq -e '.hookSpecificOutput.additionalContext|test("MEM_MARKER")|not' >/dev/null \
  && ok "case D: unmapped rc injects no memory" || bad "case D inject" "$O"

# Case E: uvx absent entirely -> pre-flight `command -v uvx` -> rc=30 -> hook exits 0.
O="$(payload | PATH="/usr/bin:/bin" "$HOOK")"; RC=$?
[ "$RC" -eq 0 ] && ok "case E: uvx missing, hook exits 0" || bad "case E exit" "rc=$RC"
echo "$O" | jq -e '.hookSpecificOutput.hookEventName=="SessionStart"' >/dev/null \
  && ok "case E: still emits valid JSON" || bad "case E shape" "$O"

# Case F: payload has no cwd -> search not attempted, hook exits 0 with valid JSON.
: > "$UV_LOG"
O="$(jq -nc '{session_id:"s",hook_event_name:"SessionStart"}' | FAKE_MODE=ok PATH="$WORK/bin:$PATH" "$HOOK")"; RC=$?
[ "$RC" -eq 0 ] && ok "case F: no cwd, hook exits 0" || bad "case F exit" "rc=$RC"
grep -q 'sspower-mem search' "$UV_LOG" \
  && bad "case F: search ran without cwd" "$(cat "$UV_LOG")" \
  || ok "case F: no cwd skips search"

[ "$FAIL" -eq 0 ] && echo "PASS: test-session-start-mem" || { echo "FAIL: test-session-start-mem"; exit 1; }
```

```bash
chmod +x tests/hooks/test-session-start-mem.sh
```

- [ ] **Step 1.2: Run the test — verify it fails**

```bash
bash tests/hooks/test-session-start-mem.sh
```

Expected: `FAIL: test-session-start-mem` — `case A: recent memory injected` fails because `session-start` does not consult `sspower-mem` yet (`$UV_LOG` stays empty, no `MEM_MARKER` in output).

- [ ] **Step 1.3: Rewrite `hooks/session-start`**

The current file is 34 lines (read it fresh before editing). Replace the entire body. The new file: keeps the `set -euo pipefail`, plugin-root resolution, `escape_for_json`, and `using-sspower` skill loading exactly as-is; adds `SSPOWER_MEM_SRC`, the inline `sspower_mem_call` wrapper (transcribed verbatim from spec §9 Phase E lines 843–875), stdin-payload capture, `cwd` extraction, the search call, JSON→text formatting, and the `additionalContext` append.

Overwrite `hooks/session-start` with exactly:

```bash
#!/usr/bin/env bash
# SessionStart hook for sspower plugin

set -euo pipefail

# Determine plugin root directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SSPOWER_MEM_SRC="${CLAUDE_PLUGIN_ROOT:-$PLUGIN_ROOT}/scripts/sspower_mem"

# Capture the SessionStart payload (JSON on stdin) BEFORE any other read.
hook_payload="$(cat 2>/dev/null || true)"

# Read using-sspower content
using_sspower_content=$(cat "${PLUGIN_ROOT}/skills/using-sspower/SKILL.md" 2>&1 || echo "Error reading using-sspower skill")

# Escape string for JSON embedding using bash parameter substitution.
# Each ${s//old/new} is a single C-level pass - orders of magnitude
# faster than the character-by-character loop this replaces.
escape_for_json() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# --- sspower-mem exit-code normalization wrapper (spec §9 Phase E) ---
# ALWAYS returns 0 so the caller (running under set -e) is not killed.
# Communicates the original rc via SSP_RC and output via SSP_OUT.
sspower_mem_call() {
    # Usage: sspower_mem_call <subcommand> [args...]
    # Sets globals: SSP_OUT (stdout+stderr), SSP_RC (normalized exit code).

    # Pre-flight: if uvx is missing OR the uv cache hasn't been bootstrapped, normalize to rc=30.
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

using_sspower_escaped=$(escape_for_json "$using_sspower_content")

# --- Recent project memory from sspower-mem (best-effort, never blocks) ---
mem_block=""
payload_cwd="$(printf '%s' "$hook_payload" | jq -r '.cwd // empty' 2>/dev/null || true)"
if [ -n "$payload_cwd" ]; then
    sspower_mem_call search --cwd "$payload_cwd" --scope project,user --mode recent --top-k 8 --json
    # NOTE: `search` never returns rc 20 (no data-loss surface at SessionStart),
    # so there is intentionally no `20) exit 20` branch here — that branch in the
    # spec's §9 example applies only to the `add` caller in wiki-archive.py.
    case "$SSP_RC" in
      0)
        # Format the JSON result array to a compact text block.
        mem_text="$(printf '%s' "$SSP_OUT" | jq -r '
            if (type=="array" and length>0) then
              (.[] | "- [\(.layer)] \(.content | gsub("\n";" "))")
            else empty end' 2>/dev/null || true)"
        if [ -n "$mem_text" ]; then
            mem_escaped="$(escape_for_json "$mem_text")"
            mem_block="\\n\\n---\\n**Recent project memory (sspower-mem):**\\n${mem_escaped}"
        fi
        ;;
      10|30) : ;;   # degraded / dep-missing -> fall back to no extra context
    esac
fi

session_context="<EXTREMELY_IMPORTANT>\nYou have sspower.\n\n**Below is the full content of your 'sspower:using-sspower' skill - your introduction to using skills. For all other skills, use the 'Skill' tool:**\n\n${using_sspower_escaped}\n</EXTREMELY_IMPORTANT>${mem_block}"

# Output context injection as JSON (Claude Code format).
# Uses printf instead of heredoc to work around bash 5.3+ heredoc hang.
printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "SessionStart",\n    "additionalContext": "%s"\n  }\n}\n' "$session_context"

exit 0
```

Notes for the executor:
- `jq` is already a hard dependency of the hook test suite (`test-semble-session.sh` gates on it). At runtime `jq` is expected present; if `jq` were absent, `payload_cwd` resolves empty via the `|| true` and the hook degrades to no-memory — acceptable.
- The wrapper is transcribed verbatim from spec §9 Phase E (lines 843–875). The only spec-prescribed change for the `search` caller: there is **no** `exit 20` case — `search` never produces rc 20, and SessionStart has no data-loss surface. The `case "$SSP_RC"` after the call therefore handles only `0` and `10|30`.

- [ ] **Step 1.4: Run the test — verify it passes**

```bash
bash tests/hooks/test-session-start-mem.sh
```

Expected: `PASS: test-session-start-mem` — all cases A–F pass.

- [ ] **Step 1.5: Regression-check the hook suite**

```bash
fail=0; for t in tests/hooks/*.sh; do bash "$t" || { echo "SUITE FAILED: $t"; fail=1; }; done; echo "AGGREGATE_RC=$fail"; exit "$fail"
```

Expected: `AGGREGATE_RC=0`, no `SUITE FAILED` line. `test-semble-session.sh` must still pass — `session-start` and `semble-session.sh` are distinct SessionStart hooks; this task touches only `session-start`.

- [ ] **Step 1.6: Commit**

```bash
git -C /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower add hooks/session-start tests/hooks/test-session-start-mem.sh
```

```bash
git -C /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower commit -m "feat(session-start): inject recent sspower-mem project memory"
```

---

## Task 2: `wiki-archive.py` — ingest session summary as episodic memory; drop `sessions/*.md` + index

**Files:**
- Modify: `hooks/wiki-archive.py`
- Modify: `hooks/wiki-archive.sh`
- Create: `tests/hooks/test-wiki-archive-mem.sh`

**Behavior (spec §6.5 lines 728–733, confirmed scope items 1 + 3):**
- `write_markdown` no longer writes `sessions/*.md`. It returns the rendered session-summary string. `main()` passes that string to `sspower-mem add --cwd <cwd> --scope project --layer episodic` (via the Python `sspower_mem_call`). On `rc 20` the hook propagates with `sys.exit(20)` (HARD data-loss). On `rc 10` / `rc 30` it logs and continues.
- `write_json` is UNCHANGED — `sessions/*.json` keeps being written as the legacy belt (Phase F removes it).
- `append_index_entry` is removed; `WIKI_INDEX_HEADER` (its only consumer) is removed; the `main()` call to it is removed.
- `fan_out_to_central_sidecars` is UNCHANGED (D2 — it symlinks the `.json`, still produced).

**Content passing:** the spec CLI grammar (§6.1 lines 257–259) gives `add` exactly `(--content <text> | --content-file <path>)` and notes "explicit `--content-file` avoids @-path LFI risk." The session summary is multi-line markdown; passing it on argv via `--content` is fragile. Use `--content-file`: write the summary to a temp file (`tempfile.NamedTemporaryFile`), pass its path, delete it after the call. This is the spec-blessed form.

- [ ] **Step 2.1: Write the failing test**

Create `tests/hooks/test-wiki-archive-mem.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="${ROOT}/hooks/wiki-archive.py"
command -v jq      >/dev/null 2>&1 || { echo "SKIP: test-wiki-archive-mem (no jq)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: test-wiki-archive-mem (no python3)"; exit 0; }
FAIL=0; ok(){ echo "PASS: $1"; }; bad(){ echo "FAIL: $1 :: $2"; FAIL=1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
export UV_LOG="$WORK/uvx.log"
: > "$UV_LOG"

# Fake `uvx`: log full argv to $UV_LOG, exit with $FAKE_UVX_RC (default 0).
cat > "$WORK/bin/uvx" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${UV_LOG:?}"
exit "${FAKE_UVX_RC:-0}"
STUB
chmod +x "$WORK/bin/uvx"

# Minimal real transcript: one user turn + one assistant turn.
PROJ="$WORK/proj"; mkdir -p "$PROJ"
TRANSCRIPT="$WORK/transcript.jsonl"
cat > "$TRANSCRIPT" <<'JSONL'
{"type":"user","timestamp":"2026-05-21T10:00:00.000Z","message":{"role":"user","content":"hello"}}
{"type":"assistant","timestamp":"2026-05-21T10:00:05.000Z","message":{"role":"assistant","model":"claude-opus-4-7","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":10,"output_tokens":5}}}
JSONL

payload() {
  jq -nc --arg tp "$TRANSCRIPT" --arg cwd "$PROJ" \
     '{session_id:"sess-abc123def456",transcript_path:$tp,cwd:$cwd,hook_event_name:"SessionEnd"}'
}

# Case A: backend reachable (fake uvx rc=0) -> add invoked with the exact spec argv.
: > "$UV_LOG"
payload | FAKE_UVX_RC=0 PATH="$WORK/bin:$PATH" python3 "$HOOK"; RC=$?
LOG="$(cat "$UV_LOG")"
[ "$RC" -eq 0 ] && ok "case A: hook exits 0" || bad "case A exit" "rc=$RC"
assert_arg() { case "$LOG" in *"$1"*) ok "case A: $2" ;; *) bad "case A: $2" "$LOG" ;; esac ; }
assert_arg '--offline --from'      'invoked via uvx --offline --from'
assert_arg 'scripts/sspower_mem'   '--from points at sspower_mem source'
assert_arg 'sspower-mem add'       'sspower-mem add subcommand'
assert_arg "--cwd $PROJ"           '--cwd is the payload cwd'
assert_arg '--scope project'       'scope project'
assert_arg '--layer episodic'      'layer episodic'
assert_arg '--content-file'        '--content-file passed (not --content)'

# Case A2: sessions/*.md is NOT written; sessions/*.json IS still written (legacy belt).
ls "$PROJ"/.claude/wiki/sessions/*.json >/dev/null 2>&1 \
  && ok "case A2: legacy belt sessions/*.json still written" \
  || bad "case A2: json belt missing" "$(ls -la "$PROJ"/.claude/wiki/sessions/ 2>&1)"
ls "$PROJ"/.claude/wiki/sessions/*.md >/dev/null 2>&1 \
  && bad "case A2: sessions/*.md still written (should be dropped)" "$(ls "$PROJ"/.claude/wiki/sessions/)" \
  || ok "case A2: sessions/*.md no longer written"
[ -e "$PROJ/.claude/wiki/index.md" ] \
  && bad "case A2: index.md still written (append_index_entry should be removed)" "exists" \
  || ok "case A2: index.md no longer written"

# Case B: backend degraded (fake uvx rc=10) -> hook still exits 0.
: > "$UV_LOG"
payload | FAKE_UVX_RC=10 PATH="$WORK/bin:$PATH" python3 "$HOOK"; RC=$?
[ "$RC" -eq 0 ] && ok "case B: rc=10 hook exits 0" || bad "case B exit" "rc=$RC"
grep -q 'sspower-mem add' "$UV_LOG" \
  && ok "case B: add was attempted (rc=10 path exercised)" \
  || bad "case B: add not attempted" "$(cat "$UV_LOG")"

# Case C: HARD failure (fake uvx rc=20) -> hook MUST propagate with exit 20.
: > "$UV_LOG"
payload | FAKE_UVX_RC=20 PATH="$WORK/bin:$PATH" python3 "$HOOK"; RC=$?
[ "$RC" -eq 20 ] && ok "case C: rc=20 propagated as exit 20" || bad "case C exit" "rc=$RC (expected 20)"

# Case D: backend dep-missing (fake uvx rc=30) -> hook exits 0.
: > "$UV_LOG"
payload | FAKE_UVX_RC=30 PATH="$WORK/bin:$PATH" python3 "$HOOK"; RC=$?
[ "$RC" -eq 0 ] && ok "case D: rc=30 hook exits 0" || bad "case D exit" "rc=$RC"

# Case E: uvx-internal exit 7 -> Python wrapper normalizes to 30 -> hook exits 0.
: > "$UV_LOG"
payload | FAKE_UVX_RC=7 PATH="$WORK/bin:$PATH" python3 "$HOOK"; RC=$?
[ "$RC" -eq 0 ] && ok "case E: unmapped rc normalizes to 30, hook exits 0" || bad "case E exit" "rc=$RC"

# Case F: uvx absent -> pre-flight shutil.which -> rc=30 -> hook exits 0.
: > "$UV_LOG"
payload | PATH="/usr/bin:/bin" python3 "$HOOK"; RC=$?
[ "$RC" -eq 0 ] && ok "case F: uvx missing, hook exits 0" || bad "case F exit" "rc=$RC"

# Case G: empty payload cwd -> ingest skipped entirely. Spec §9 877-880
# forbids a project-scope `add` without --cwd (would fall back to the hook
# process cwd). The hook must NOT invoke sspower-mem at all here.
: > "$UV_LOG"
jq -nc --arg tp "$TRANSCRIPT" \
   '{session_id:"s",transcript_path:$tp,cwd:"",hook_event_name:"SessionEnd"}' \
  | FAKE_UVX_RC=0 PATH="$WORK/bin:$PATH" python3 "$HOOK"; RC=$?
[ "$RC" -eq 0 ] && ok "case G: empty cwd, hook exits 0" || bad "case G exit" "rc=$RC"
grep -q 'sspower-mem add' "$UV_LOG" \
  && bad "case G: add invoked without payload cwd" "$(cat "$UV_LOG")" \
  || ok "case G: empty cwd skips ingest (no add call)"

[ "$FAIL" -eq 0 ] && echo "PASS: test-wiki-archive-mem" || { echo "FAIL: test-wiki-archive-mem"; exit 1; }
```

```bash
chmod +x tests/hooks/test-wiki-archive-mem.sh
```

- [ ] **Step 2.2: Run the test — verify it fails**

```bash
bash tests/hooks/test-wiki-archive-mem.sh
```

Expected: `FAIL: test-wiki-archive-mem` — `case A: sspower-mem add subcommand` fails (`$UV_LOG` empty: `wiki-archive.py` does not call `uvx` yet) and `case A2: sessions/*.md no longer written` fails (the current `write_markdown` still writes the `.md`).

- [ ] **Step 2.3: Add imports to `wiki-archive.py`**

Re-read `hooks/wiki-archive.py` first. The import block is lines 17–24: `json`, `sys`, `os`, `re`, `hashlib`, then `from datetime ...`, `from collections ...`, `from pathlib ...`. After line 21 (`import hashlib`), insert two lines:

Old (lines 21–22):
```python
import hashlib
from datetime import datetime
```

New:
```python
import hashlib
import shutil
import subprocess
import tempfile
from datetime import datetime
```

(`tempfile` is needed for the `--content-file` temp file; `shutil` for the wrapper's `shutil.which`; `subprocess` for the wrapper.)

- [ ] **Step 2.4: Add the `sspower_mem_call` Python wrapper**

Transcribe the Python wrapper from spec §9 Phase E (lines 897–914) verbatim, adapted only for the `SSPOWER_MEM_SRC` default per D1. Insert it directly after the `_safe_append_text` function (which ends at line 171) and before `def parse_events` (line 174). Insert at line 172:

```python


def sspower_mem_call(*args):
    """Mirror of the shell wrapper (spec §9 Phase E). Returns (rc, out).
    Never raises. rc is always one of {0, 10, 20, 30}; uvx-internal exits
    collapse to 30. Invokes `UV_OFFLINE=1 uvx --offline --from <src>`."""
    src = os.environ.get(
        "SSPOWER_MEM_SRC",
        str(Path(__file__).resolve().parent.parent / "scripts" / "sspower_mem"),
    )
    if not shutil.which("uvx"):
        return 30, "[sspower-mem] uvx not found in PATH"
    env = os.environ.copy()
    env["UV_OFFLINE"] = "1"
    try:
        cp = subprocess.run(
            ["uvx", "--offline", "--from", src, "sspower-mem", *args],
            capture_output=True, text=True, env=env,
        )  # no check=True
    except FileNotFoundError:
        return 30, "[sspower-mem] uvx launch failed"
    raw = cp.returncode
    rc = raw if raw in (0, 10, 20) else 30
    out = (cp.stdout or "") + (cp.stderr or "")
    return rc, out
```

- [ ] **Step 2.5: Rewrite `write_markdown` to return the summary string**

`write_markdown` (lines 600–673) currently ends by writing `path.write_text(...)`. Phase E: it must NOT write `sessions/*.md`; it returns the rendered string instead. The function no longer needs `path` or `trust_root`.

(a) Change the signature + drop the symlink early-return. Old (lines 600–603):
```python
def write_markdown(data: dict, path: Path, trust_root: Path):
    if _has_symlink_component(path, trust_root):
        return
    """Human-readable session summary for wiki browsing."""
```

New:
```python
def render_session_summary(data: dict) -> str:
    """Render the human-readable session summary as a markdown string.

    Phase E: the summary is no longer written to `sessions/*.md`; it is
    handed to `sspower-mem add --layer episodic`. Returns the string."""
```

(b) Change the write tail to a return. Old (lines 670–673):
```python
    try:
        path.write_text("\n".join(lines), encoding="utf-8")
    except OSError:
        pass
```

New:
```python
    return "\n".join(lines)
```

(The function is renamed `write_markdown` → `render_session_summary` because it no longer writes — a `grep -n 'write_markdown' hooks/wiki-archive.py` after this step must show only the `main()` call site, fixed in Step 2.7.)

- [ ] **Step 2.6: Remove `append_index_entry`, `WIKI_INDEX_HEADER`, `seed_wiki_files`, and the seed constants**

Per D7, `seed_wiki_files` and its templates are retired alongside the index. Re-read lines 676–773 first. Delete the following, in this order (the constants are contiguous; deleting bottom-up keeps line numbers stable):

(a) The whole `append_index_entry` function — lines 744–773 (`def append_index_entry(...)` through the final `_safe_append_text(index, row, trust_root)` line).

(b) The `seed_wiki_files` function — lines 699–707 (`def seed_wiki_files(...)` through `_safe_write_text(gotchas, WIKI_GOTCHAS_SEED, trust_root)`).

(c) The three template constants:
- `WIKI_INDEX_HEADER` — lines 690–696 (`WIKI_INDEX_HEADER = """# Session Index` … through the closing `"""`).
- `WIKI_GOTCHAS_SEED` — lines 683–688 (`WIKI_GOTCHAS_SEED = """# Gotchas` … through the closing `"""`).
- `WIKI_DECISIONS_SEED` — lines 676–681 (`WIKI_DECISIONS_SEED = """# Decisions` … through the closing `"""`).

After deletion, the region between `render_session_summary`'s end and `def main()` should contain no constants and no `seed_wiki_files`/`append_index_entry` — just two blank lines before `def main()`.

Verify after deletion (the `main()` call sites are removed in Step 2.7):
```bash
grep -n 'append_index_entry\|WIKI_INDEX_HEADER\|seed_wiki_files\|WIKI_DECISIONS_SEED\|WIKI_GOTCHAS_SEED' hooks/wiki-archive.py
```
Expected after Step 2.7: no output. Until 2.7, this still shows the two `main()` call sites — expected; re-run after 2.7 for zero output.

- [ ] **Step 2.7: Rewire `main()`**

The tail of `main()` (lines 817–823) currently is:
```python
    write_json(data, json_path, trust_root)
    write_markdown(data, md_path, trust_root)

    wiki_root = out_dir.parent
    seed_wiki_files(wiki_root, trust_root)
    append_index_entry(wiki_root, data, md_path, trust_root)
    fan_out_to_central_sidecars(json_path, cwd, session_id)
```

Replace with (the `wiki_root` local is no longer used once `seed_wiki_files` + `append_index_entry` are gone — drop it too):
```python
    write_json(data, json_path, trust_root)
    fan_out_to_central_sidecars(json_path, cwd, session_id)

    # Phase E: ingest the session summary into sspower-mem as an episodic
    # memory block. The summary is no longer written to sessions/*.md.
    #
    # Spec §9 (lines 877-880): hooks MUST pass --cwd explicitly and must
    # NOT rely on os.getcwd(). The hook process cwd is the plugin dir or
    # $HOME — never the user project. So a project-scope `add` without
    # --cwd would ingest the session under the wrong project. If the
    # SessionEnd payload carried no cwd, skip ingest entirely (the legacy
    # .json belt is still written, so nothing is lost).
    if not cwd:
        sys.stderr.write(
            "[wiki-archive] no cwd in hook payload; skipping sspower-mem "
            "ingest (legacy .json belt still written)\n"
        )
    else:
        summary = render_session_summary(data)
        tmp = None
        try:
            with tempfile.NamedTemporaryFile(
                mode="w", suffix=".md", encoding="utf-8", delete=False
            ) as f:
                f.write(summary)
                tmp = f.name
            rc, out = sspower_mem_call(
                "add", "--scope", "project", "--layer", "episodic",
                "--content-file", tmp, "--cwd", cwd,
            )
            if rc == 20:
                # HARD data-loss event (digest unwritable) — propagate loudly.
                sys.stderr.write(f"[wiki-archive] sspower-mem HARD fail (rc=20): {out}\n")
                sys.exit(20)
            elif rc in (10, 30):
                sys.stderr.write(f"[wiki-archive] sspower-mem degraded (rc={rc}): {out}\n")
        finally:
            if tmp:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
```

Notes:
- `write_json` stays — the `.json` belt and the `fan_out_to_central_sidecars` symlink target are preserved (D2).
- `--cwd` is **always** passed when ingest runs; an empty payload `cwd` skips ingest entirely rather than letting the CLI fall back to `os.getcwd()` (spec §9 lines 877-880 — the hook cwd contract). Hooks normally always have `cwd`; the skip path is the defensive case.
- `md_path` is now unused in `main()` since `write_markdown` is gone. Verify with `grep -n 'md_path' hooks/wiki-archive.py` — the `json_path.exists()` dedupe block at lines 812–815 still defines `md_path`; leave that block as-is (harmless dead assignment, removing it is out of scope and risks the dedupe logic). Optionally the executor MAY drop the two `md_path` lines inside the dedupe block — but only if a fresh re-read confirms `md_path` has zero other readers. Default: leave it.

- [ ] **Step 2.8: Add the `uvx` pre-flight hint to `wiki-archive.sh`**

`hooks/wiki-archive.sh` is 11 lines (re-read it). Per spec §6.5 line 733, add an optional `command -v uvx` hint. Insert before the final `exec` line (line 11):

Old (lines 9–11):
```bash
SCRIPT_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

exec python3 "${SCRIPT_DIR}/hooks/wiki-archive.py"
```

New:
```bash
SCRIPT_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Phase E pre-flight: warn once if uvx is absent. The .py still runs the
# legacy JSON belt; only the sspower-mem ingest is lost.
command -v uvx >/dev/null 2>&1 || \
  echo "[wiki-archive] uvx not found; sspower-mem ingest skipped (legacy JSON belt still runs). Install: brew install uv" >&2

exec python3 "${SCRIPT_DIR}/hooks/wiki-archive.py"
```

- [ ] **Step 2.9: Run the test — verify it passes**

```bash
bash tests/hooks/test-wiki-archive-mem.sh
```

Expected: `PASS: test-wiki-archive-mem` — all cases A–F pass, including `case C: rc=20 propagated as exit 20` and `case A2: sessions/*.md no longer written`.

- [ ] **Step 2.10: Regression-check the hook suite**

```bash
fail=0; for t in tests/hooks/*.sh; do bash "$t" || { echo "SUITE FAILED: $t"; fail=1; }; done; echo "AGGREGATE_RC=$fail"; exit "$fail"
```

Expected: `AGGREGATE_RC=0`, no `SUITE FAILED`. Any pre-existing suite that drives `wiki-archive.py` without a fake `uvx` will hit the real `uvx` (or absent `uvx`) — both normalize to a non-blocking rc and the hook exits 0 (rc 20 only fires on a real digest-write failure, which a normal test environment will not trigger).

- [ ] **Step 2.11: Verify no stale references**

```bash
grep -rn 'write_markdown\|append_index_entry\|WIKI_INDEX_HEADER\|seed_wiki_files\|WIKI_DECISIONS_SEED\|WIKI_GOTCHAS_SEED' hooks/ tests/
```

Expected: no output. (`render_session_summary` is the new name; all old identifiers — the index helper, the seeding helper, and all three template constants — must be fully gone.)

- [ ] **Step 2.12: Commit**

```bash
git -C /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower add hooks/wiki-archive.py hooks/wiki-archive.sh tests/hooks/test-wiki-archive-mem.sh
```

```bash
git -C /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower commit -m "feat(wiki-archive): ingest session summary into sspower-mem; drop sessions/*.md + index"
```

---

## Task 3: `brainstorming` SKILL.md — decisions via `sspower-mem`

**Files:**
- Modify: `skills/brainstorming/SKILL.md`
- Create: `skills/brainstorming/test-memory-cli.md`

**Spec §6.5 line 735:** brainstorming "write decisions" → `sspower-mem add --layer decision`; reads via `sspower-mem search`.

- [ ] **Step 3.1: Rewrite the Pre-flight section**

`skills/brainstorming/SKILL.md` lines 10–17 currently read:

```markdown
## Pre-flight: read project wiki

Before proposing any approach, read these if they exist:

- `<cwd>/.claude/wiki/decisions.md` — prior architectural calls, ground new design in them
- `<cwd>/.claude/wiki/sessions/` — last 3 session `.md` files (sort by name, newest = highest YYMMDD prefix) for recent context

Skip silently if the directory doesn't exist (project hasn't archived yet). Surface any contradiction between the user's request and prior decisions before proposing.
```

Replace those 8 lines with:

```markdown
## Pre-flight: read prior decisions

Before proposing any approach, query the project's memory backend for prior
architectural decisions and recent session context:

```bash
sspower-mem search --scope project --layer decision --mode recent --top-k 5 --json
sspower-mem search --scope project --layer episodic --mode recent --top-k 3 --json
```

When you have a concrete task description, swap `--mode recent` for
`--query "<task description>"` on the `decision` search to align by relevance.

If the command is unavailable or returns no results, skip silently (the
project may not have a memory backend yet). Surface any contradiction between
the user's request and a prior decision before proposing.

## Recording decisions

When the design is approved, record each load-bearing architectural call:

```bash
sspower-mem add --scope project --layer decision --content "<one-line call + reasoning>"
```
```

- [ ] **Step 3.2: Create the eval scenario**

Create `skills/brainstorming/test-memory-cli.md`:

```markdown
# Academic Test: brainstorming — memory-backend integration

You have access to the brainstorming skill at skills/brainstorming/SKILL.md

Read the skill and answer based SOLELY on what the skill says:

1. In the Pre-flight, what exact command(s) does the skill tell you to run to
   retrieve prior architectural decisions? Quote them verbatim.
2. What `--scope` and `--layer` does the decision search use?
3. When should you use `--query` instead of `--mode recent`?
4. After a design is approved, what exact command records a decision?
5. What should you do if the `sspower-mem` command is unavailable?

Return direct quotes from the skill where applicable.

**PASS criteria:** answers cite `sspower-mem search --scope project --layer
decision --mode recent --top-k 5`, `sspower-mem add --scope project --layer
decision`, mention swapping `--mode recent` for `--query`, and "skip silently".
No mention of reading `wiki/decisions.md` as a file.
```

- [ ] **Step 3.3: Run the eval**

This is a subagent dispatch, not a shell command (D6). Dispatch a subagent via the `Task` tool:
- `subagent_type`: `general-purpose`
- `description`: `eval brainstorming memory-cli`
- `prompt`: the full contents of `skills/brainstorming/test-memory-cli.md`.

Expected: the subagent's answers satisfy the PASS criteria in the test file — it quotes the `sspower-mem search`/`add` commands and never tells the user to open `wiki/decisions.md` as a file. If the subagent still references the old file path, the SKILL.md edit is incomplete — re-read and fix.

- [ ] **Step 3.4: Commit**

```bash
git -C /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower add skills/brainstorming/SKILL.md skills/brainstorming/test-memory-cli.md
```

```bash
git -C /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower commit -m "feat(brainstorming): read/write decisions via sspower-mem"
```

---

## Task 4: `systematic-debugging` SKILL.md — gotchas via `sspower-mem`

**Files:**
- Modify: `skills/systematic-debugging/SKILL.md`
- Create: `skills/systematic-debugging/test-memory-cli.md`

**Spec §6.5 line 736:** systematic-debugging "same for gotchas (`--layer gotcha`)" — read via `sspower-mem search`, write via `sspower-mem add --layer gotcha`.

- [ ] **Step 4.1: Rewrite the Pre-flight section**

`skills/systematic-debugging/SKILL.md` lines 10–14 currently read:

```markdown
## Pre-flight: check known gotchas

Before Phase 1, read `<cwd>/.claude/wiki/gotchas.md` if it exists. Match the current symptom against known gotchas FIRST — if the bug is already documented, apply the recorded fix and skip a fresh investigation. Skip silently if the file doesn't exist.

After fixing a new (un-documented) gotcha, append it to that file so the next session benefits.
```

Replace those 5 lines with:

```markdown
## Pre-flight: check known gotchas

Before Phase 1, query the project's memory backend for known gotchas:

```bash
sspower-mem search --scope project --layer gotcha --query "<current symptom>" --top-k 5 --json
```

Match the current symptom against known gotchas FIRST — if the bug is already
documented, apply the recorded fix and skip a fresh investigation. If the
command is unavailable or returns no results, skip silently.

After fixing a new (un-documented) gotcha, record it so the next session
benefits:

```bash
sspower-mem add --scope project --layer gotcha --content "<symptom + root cause + fix>"
```
```

- [ ] **Step 4.2: Create the eval scenario**

Create `skills/systematic-debugging/test-memory-cli.md`:

```markdown
# Academic Test: systematic-debugging — memory-backend integration

You have access to the systematic-debugging skill at skills/systematic-debugging/SKILL.md

Read the skill and answer based SOLELY on what the skill says:

1. In the Pre-flight, what exact command retrieves known gotchas? Quote it.
2. What `--layer` does the gotcha search use, and does it use `--query` or
   `--mode recent`?
3. After fixing a new gotcha, what exact command records it?
4. What should you do if the `sspower-mem` command is unavailable?

Return direct quotes from the skill where applicable.

**PASS criteria:** answers cite `sspower-mem search --scope project --layer
gotcha --query`, `sspower-mem add --scope project --layer gotcha`, and "skip
silently". No mention of reading or appending `wiki/gotchas.md` as a file.
```

- [ ] **Step 4.3: Run the eval**

Subagent dispatch (D6) via the `Task` tool:
- `subagent_type`: `general-purpose`
- `description`: `eval systematic-debugging memory-cli`
- `prompt`: the full contents of `skills/systematic-debugging/test-memory-cli.md`.

Expected: answers satisfy the PASS criteria — the subagent quotes the `sspower-mem search`/`add` gotcha commands and never references `wiki/gotchas.md` as a file. If it still references the file, re-read and fix the SKILL.md.

- [ ] **Step 4.4: Commit**

```bash
git -C /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower add skills/systematic-debugging/SKILL.md skills/systematic-debugging/test-memory-cli.md
```

```bash
git -C /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower commit -m "feat(systematic-debugging): read/write gotchas via sspower-mem"
```

---

## Task 5: `writing-plans` SKILL.md — Pre-flight via `sspower-mem`

**Files:**
- Modify: `skills/writing-plans/SKILL.md`
- Create: `skills/writing-plans/test-memory-cli.md`

**Spec §6.5 lines 737–740 / §9 line 924:** the Pre-flight reads `wiki/decisions.md` + `sessions/`. Rewrite to `sspower-mem search --scope project --layer decision --mode recent --top-k 5` and `--layer episodic --mode recent --top-k 3` (or `--query <task>` when a task description is available).

- [ ] **Step 5.1: Rewrite the Pre-flight section**

`skills/writing-plans/SKILL.md` lines 14–21 currently read:

```markdown
## Pre-flight: read project wiki

Before drafting the plan, read these if they exist:

- `<cwd>/.claude/wiki/decisions.md` — prior architectural calls; align plan with them or flag conflicts
- `<cwd>/.claude/wiki/sessions/` — last 3 session `.md` files for recent project state

Skip silently if the directory doesn't exist.
```

Replace those 8 lines with:

```markdown
## Pre-flight: read prior decisions

Before drafting the plan, query the project's memory backend:

```bash
sspower-mem search --scope project --layer decision --mode recent --top-k 5 --json
sspower-mem search --scope project --layer episodic --mode recent --top-k 3 --json
```

The first call surfaces prior architectural decisions to align the plan with
(or flag conflicts against); the second surfaces recent session state. When
the plan has a concrete task description, swap `--mode recent` for
`--query "<task description>"` to align results by relevance instead of
recency.

If the command is unavailable or returns no results, skip silently.
```

- [ ] **Step 5.2: Create the eval scenario**

Create `skills/writing-plans/test-memory-cli.md`:

```markdown
# Academic Test: writing-plans — memory-backend integration

You have access to the writing-plans skill at skills/writing-plans/SKILL.md

Read the skill and answer based SOLELY on what the skill says:

1. In the Pre-flight, what exact two commands does the skill tell you to run?
   Quote them verbatim.
2. What `--layer` and `--top-k` does each call use?
3. When should you use `--query` instead of `--mode recent`?
4. What should you do if the `sspower-mem` command is unavailable?

Return direct quotes from the skill where applicable.

**PASS criteria:** answers cite `sspower-mem search --scope project --layer
decision --mode recent --top-k 5` AND `--layer episodic --mode recent --top-k
3`, mention swapping for `--query`, and "skip silently". No mention of reading
`wiki/decisions.md` or `sessions/` as files.
```

- [ ] **Step 5.3: Run the eval**

Subagent dispatch (D6) via the `Task` tool:
- `subagent_type`: `general-purpose`
- `description`: `eval writing-plans memory-cli`
- `prompt`: the full contents of `skills/writing-plans/test-memory-cli.md`.

Expected: answers satisfy the PASS criteria — both `sspower-mem search` commands quoted, no file-path references. If the subagent still references `wiki/decisions.md`/`sessions/`, re-read and fix.

- [ ] **Step 5.4: Commit**

```bash
git -C /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower add skills/writing-plans/SKILL.md skills/writing-plans/test-memory-cli.md
```

```bash
git -C /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower commit -m "feat(writing-plans): read prior decisions via sspower-mem"
```

---

## Task 6: `using-sspower` SKILL.md routing note + `CLAUDE.md` docs

**Files:**
- Modify: `skills/using-sspower/SKILL.md`
- Modify: `CLAUDE.md`

**Spec §6.5 line 741:** using-sspower gets "a routing note in the skill table; no behavior change." This skill's SKILL.md has no skill table (it has a `Skill Priority` / `Skill Types` section — the routing tables live in `~/.claude/CLAUDE.md`, not here). The minimal spec-faithful change: add a one-line note under `## Skill Types` pointing at the memory backend.

- [ ] **Step 6.1: Add the routing note to `using-sspower/SKILL.md`**

`skills/using-sspower/SKILL.md` lines 46–50 currently read:

```markdown
## Skill Types

**Rigid** (TDD, debugging): Follow exactly. **Flexible** (patterns): Adapt to context.

See `references/red-flags-table.md` for the full rationalization table, instruction priority, and platform adaptation details.
```

Replace with:

```markdown
## Skill Types

**Rigid** (TDD, debugging): Follow exactly. **Flexible** (patterns): Adapt to context.

## Project memory

`brainstorming`, `writing-plans`, and `systematic-debugging` read and write
project memory (decisions, gotchas, session history) through the `sspower-mem`
CLI rather than `<cwd>/.claude/wiki/*.md` files. When a skill's Pre-flight
calls `sspower-mem search`, that is the project's memory backend — not a stray
shell command. If `sspower-mem` is unavailable the skills degrade silently.

See `references/red-flags-table.md` for the full rationalization table, instruction priority, and platform adaptation details.
```

- [ ] **Step 6.2: Update `CLAUDE.md` — hooks line in the Structure fence**

`CLAUDE.md` `## Structure` section has a fenced block whose `hooks/` line ends with `PreCompact + SessionEnd (wiki-archive)`. Re-read the exact line first:

```bash
grep -n 'wiki-archive' CLAUDE.md
```

In-fence edit: replace the trailing `PreCompact + SessionEnd (wiki-archive)` with:

```
PreCompact + SessionEnd (wiki-archive — ingests the session summary into sspower-mem)
```

- [ ] **Step 6.3: Add a `Key Rules` bullet to `CLAUDE.md`**

Under `## Key Rules` in `CLAUDE.md`, add one bullet:

```
- sspower-mem hook + skill integration (Phase E): `wiki-archive.py` ingests each archived session into `sspower-mem` as an `episodic` block and no longer writes `wiki/sessions/*.md` (it still writes `*.json` as a legacy belt — removed in Phase F). `append_index_entry` is removed; any existing `<wiki>/index.md` is now frozen legacy — operators may manually rename it to `index_legacy.md`. `session-start` injects recent project memory into `additionalContext` via `sspower-mem search --mode recent`. The `brainstorming` / `writing-plans` / `systematic-debugging` skills read/write decisions + gotchas via the `sspower-mem` CLI. All `sspower-mem` calls go through the spec's exit-code-normalizing wrapper (`UV_OFFLINE=1 uvx --offline --from "$SSPOWER_MEM_SRC"`): rc 0 ok, 10 degraded (continue), 20 HARD data-loss (hook propagates `exit 20`), 30 dep-missing (continue empty); any other rc normalizes to 30.
```

- [ ] **Step 6.4: Run the using-sspower eval**

Subagent dispatch (D6) via the `Task` tool — there is no academic test file for `using-sspower` (it is largely a routing reference); the eval is a retrieval probe:
- `subagent_type`: `general-purpose`
- `description`: `eval using-sspower memory note`
- `prompt`:
  ```
  Read skills/using-sspower/SKILL.md. Answer based solely on the skill:
  When a skill's Pre-flight runs `sspower-mem search`, what is that command,
  and what should you assume if `sspower-mem` is unavailable?
  ```

Expected: the subagent answers that `sspower-mem search` is the project's memory backend (not a stray shell command) and that skills degrade silently when it is unavailable.

- [ ] **Step 6.5: Commit**

```bash
git -C /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower add skills/using-sspower/SKILL.md CLAUDE.md
```

```bash
git -C /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower commit -m "docs(using-sspower,CLAUDE): document Phase E sspower-mem integration"
```

---

## Task 7: Offline-contract verification

**Spec §9 Phase E line 926 + §6.5 offline contract (lines 886, 890):** after `sspower-mem doctor --bootstrap` warms the `uvx` cache, `UV_OFFLINE=1 uvx --offline` works; with the cache removed a hook invocation exits 30 (not 0 — wait: the *wrapper* normalizes the cache-miss to rc 30, the *hook* then continues and exits 0). The precise contract: a hook invocation with the cache cleared must NOT crash and must NOT silently succeed as if memory were written — `SSP_RC`/`rc` must be 30, and the hook continues with empty memory output.

This task only **verifies**; no code changes. If a prior phase (A/C) has not yet shipped a runnable `sspower-mem` + `doctor --bootstrap`, mark this task as deferred and record that in the branch handoff — do not block the skill/hook commits on it.

- [ ] **Step 7.1: Confirm `sspower-mem` is runnable**

```bash
UV_OFFLINE=1 uvx --offline --from scripts/sspower_mem sspower-mem --help > /tmp/sspower-mem-help.log 2>&1; echo "rc=$?"; head -5 /tmp/sspower-mem-help.log
```

If `rc` is non-zero because `doctor --bootstrap` has not run yet, run the bootstrap (online, one-time):

```bash
uvx --from scripts/sspower_mem sspower-mem doctor --bootstrap > /tmp/sspower-mem-bootstrap.log 2>&1; echo "rc=$?"; tail -10 /tmp/sspower-mem-bootstrap.log
```

Expected: bootstrap exits 0; it warms the `uvx` cache and creates `~/.claude/sspower/idx/`.

- [ ] **Step 7.2: Verify the warmed offline path succeeds**

```bash
UV_OFFLINE=1 uvx --offline --from scripts/sspower_mem sspower-mem --help > /tmp/sspower-mem-offline.log 2>&1; echo "rc=$?"
```

Expected: `rc=0` — `uvx --offline` resolves entirely from the warmed cache, no network.

- [ ] **Step 7.3: Verify a cold cache forces rc 30 (sandboxed HOME — does NOT touch the real `~/.cache/uv/`)**

Run a hook with `HOME` + `XDG_CACHE_HOME` redirected to a throwaway dir so the `uvx` cache is unwarmed there. The wrapper's `uvx --offline` then cannot resolve the env and exits non-zero; the wrapper normalizes that to rc 30; the hook continues and exits 0.

```bash
T="$(mktemp -d)"
jq -nc --arg cwd "$PWD" '{session_id:"smoke",cwd:$cwd,hook_event_name:"SessionStart",source:"startup"}' \
  | env HOME="$T" XDG_CACHE_HOME="$T/cache" bash hooks/session-start > /tmp/cold-session-start.log 2>&1
echo "hook exit=$?"
grep -c 'Recent project memory' /tmp/cold-session-start.log || true
```

Expected: `hook exit=0` (the hook never crashes on a cold cache), and `Recent project memory` count is `0` — with the cache cold the `search` normalizes to rc 30 and no memory block is injected. A non-zero hook exit, or an injected memory block, is a failure of the offline contract.

> Why sandboxed `HOME`: removing the real `~/.cache/uv/` is destructive and would force a re-download of every `uvx` tool the developer uses. Redirecting `HOME`/`XDG_CACHE_HOME` to a temp dir gives `uvx` a guaranteed-empty cache without touching the real one — the `test-semble-session.sh` harness uses the same sandboxing idiom.
>
> Which wrapper branch this exercises: `uvx` lives on `PATH`, not under `$HOME`, so the wrapper's `command -v uvx` / `shutil.which("uvx")` pre-flight still succeeds. The cold-cache path therefore exercises the "`uvx --offline` cannot resolve the env → exits non-zero → wrapper normalizes to rc 30" branch — not the "uvx missing" pre-flight branch (that branch is covered by Task 1.1 case E / Task 2.1 case F, which empty `PATH`).

- [ ] **Step 7.4: Verify the wiki-archive ingest path against a cold cache**

```bash
T="$(mktemp -d)"
printf '%s\n' '{"type":"user","timestamp":"2026-05-21T10:00:00.000Z","message":{"role":"user","content":"hi"}}' > "$T/t.jsonl"
jq -nc --arg tp "$T/t.jsonl" --arg cwd "$T" \
  '{session_id:"smoke",transcript_path:$tp,cwd:$cwd,hook_event_name:"SessionEnd"}' \
  | env HOME="$T" XDG_CACHE_HOME="$T/cache" python3 hooks/wiki-archive.py > /tmp/cold-wiki-archive.log 2>&1
echo "hook exit=$?"
ls "$T"/.claude/wiki/sessions/*.json >/dev/null 2>&1 && echo "json belt: OK" || echo "json belt: MISSING"
```

Expected: `hook exit=0` (cold cache → `sspower-mem add` normalizes to rc 30 → hook continues; rc 20 is a disk-level event and will not fire here), and `json belt: OK` (the legacy `.json` is still written).

---

## Task 8: Finish the branch

- [ ] **Step 8.1: Full hook suite green**

```bash
fail=0; for t in tests/hooks/*.sh; do bash "$t" || { echo "SUITE FAILED: $t"; fail=1; }; done; echo "AGGREGATE_RC=$fail"; exit "$fail"
```

Expected: `AGGREGATE_RC=0`, no `SUITE FAILED`; `test-session-start-mem` and `test-wiki-archive-mem` both end `PASS:`.

- [ ] **Step 8.2: Confirm all four skill evals passed**

Confirm Tasks 3.3, 4.3, 5.3, 6.4 each ran and the subagent satisfied the PASS criteria. If any eval was skipped, run it now before finishing — CLAUDE.md rule: "All skill changes must be eval-tested before committing."

- [ ] **Step 8.3: Finish the branch**

Invoke `sspower:finishing-a-development-branch` to choose merge / PR / cleanup. The auto-review gate fires on `git push` / `gh pr create`.

---

## Self-Review

**Spec coverage — every §6.5 + §9-Phase-E requirement maps to a task:**

| Spec requirement | Task |
|---|---|
| §6.5 — `wiki-archive.py` `write_markdown` → `sspower-mem add --layer episodic`, stop `sessions/*.md` | Task 2.5, 2.7 |
| §6.5 — `write_json` keeps writing `sessions/*.json` (legacy belt, Phase E) | Task 2.7 (kept), Step 2.1 case A2 |
| §6.5 line 729 — decisions/gotchas seeding retired (`seed_wiki_files` + seed constants removed) | Task 2.6, 2.7 (D7) |
| §6.5 — `append_index_entry` removed; `index.md` frozen as `index_legacy.md` | Task 2.6 (removal), D3 + Task 6.3 (operator note) |
| §6.5 — `fan_out_to_central_sidecars` resolution | D2 (no change — symlinks the `.json`, still produced; rationale documented) |
| §6.5 line 734 — `session-start` injects `sspower-mem search --cwd ... --scope project,user --mode recent --top-k 8 --json` | Task 1.3 |
| §6.5 line 733 — `wiki-archive.sh` unchanged in shape + `command -v uvx` hint | Task 2.8 |
| §9 — bash `sspower_mem_call` transcribed verbatim | Task 1.3 |
| §9 — Python `sspower_mem_call` transcribed verbatim | Task 2.4 |
| §9 — exit contract: 0 ok / 10 degraded / 20 HARD `exit 20` / 30 dep-missing / other→30; `rc=$?` on its own line | Task 1.3 (search: no rc20 path), Task 2.7 (`sys.exit(20)`) |
| §6.5 line 735 — `brainstorming` decisions via `sspower-mem add/search` | Task 3 |
| §6.5 line 736 — `systematic-debugging` gotchas via `sspower-mem` | Task 4 |
| §6.5 lines 737-740 — `writing-plans` Pre-flight via `sspower-mem search` | Task 5 |
| §6.5 line 741 — `using-sspower` routing note | Task 6.1 |
| §9 line 925 — eval each touched skill | Tasks 3.3, 4.3, 5.3, 6.4 (D6 — subagent dispatch) |
| §9 line 926 — offline contract verification | Task 7 |

All 7 user-confirmed scope items covered: (1) Task 2; (2) Task 1; (3) Tasks 1.3 + 2.4 + 2.7; (4) Tasks 3–6; (5) Task 5; (6) Tasks 3.3/4.3/5.3/6.4; (7) Task 7.

**Placeholder scan:** no `TBD`/`TODO`/"add error handling"/"similar to Task N". Every code block is complete and verbatim. Every command has an expected result. The two wrapper blocks are transcribed verbatim from spec §9 Phase E.

**Type/name consistency:** `sspower_mem_call` — bash form (Task 1.3, sets `SSP_RC`/`SSP_OUT`), Python form (Task 2.4, returns `(rc, out)`). `SSPOWER_MEM_SRC` — bash inline (Task 1.3), Python `os.environ.get` default (Task 2.4), both = `<plugin-root>/scripts/sspower_mem` (D1). `render_session_summary` — defined Task 2.5, called Task 2.7; old `write_markdown` fully removed (verified Task 2.11). `append_index_entry` + `WIKI_INDEX_HEADER` + `seed_wiki_files` + `WIKI_DECISIONS_SEED` + `WIKI_GOTCHAS_SEED` — all removed Task 2.6, call sites removed Task 2.7, zero references verified Task 2.11. Test files `test-session-start-mem.sh` / `test-wiki-archive-mem.sh` shadow `uvx` (not `uv` — the spec invocation is `uvx`). `test-memory-cli.md` eval files — created + dispatched per skill (Tasks 3.2/3.3, 4.2/4.3, 5.2/5.3).

**File:line citations re-verified** against `hooks/wiki-archive.py` (827 lines): imports 17–24; `_safe_append_text` ends 171; `parse_events` starts 174; `write_json` 563; `write_markdown` 600–673; `WIKI_DECISIONS_SEED` 676–681; `WIKI_GOTCHAS_SEED` 683–688; `WIKI_INDEX_HEADER` 690–696; `seed_wiki_files` 699–707; `fan_out_to_central_sidecars` 710–742; `append_index_entry` 744–773; `main` 776; `main` tail 817–823; `json_path.exists()` dedupe 812–815. `hooks/session-start` (34 lines): `set -euo pipefail` line 4, `PLUGIN_ROOT` line 8, `escape_for_json` 16–24, `session_context` line 27. `hooks/wiki-archive.sh` (11 lines): `SCRIPT_DIR` line 9, `exec` line 11. `skills/brainstorming/SKILL.md` Pre-flight lines 10–17. `skills/systematic-debugging/SKILL.md` Pre-flight lines 10–14. `skills/writing-plans/SKILL.md` Pre-flight lines 14–21. `skills/using-sspower/SKILL.md` Skill Types lines 46–50.

**Out of scope (Phase F — deliberately NOT in this plan):** removing the `write_json` legacy belt; archiving `wiki/sessions/` + `wiki/decisions.md` + `wiki/gotchas.md` under `_legacy_pre_idx/`; revisiting `fan_out_to_central_sidecars` once the `.json` belt is gone; editing `hooks.json` (both hooks already registered); `scripts/sspower_mem/` library code.

---

## Plan-review residual findings (Codex, 2026-05-21)

One Codex plan-review pass was run. Verdict: `needs-attention`, 4 medium + 1 low, **no high**. The one correctness item was fixed inline; the rest are tracked here for the executor (an `approve-with-followups`-equivalent disposition).

- **FIXED INLINE — `--cwd` hook contract (medium).** Spec §9 lines 877-880: hooks MUST pass `--cwd`, never fall back to `os.getcwd()`. Task 2.7 now skips ingest entirely when the payload `cwd` is empty (was: omit `--cwd` and let the CLI guess). Test Case G added.
- **FOLLOWUP — `index.md` → `index_legacy.md` migration (medium).** Spec §6.5 line 731 says the existing `<wiki>/index.md` is *renamed* to `index_legacy.md` and frozen. The plan (D3) treats this as an operator step (Task 6.3 documents it) rather than hook code, because `index.md` lives in every consuming repo's `.claude/wiki/` and the hook cannot safely rename per-repo files. Disposition: **tracked deviation** — acceptable, since `append_index_entry` is removed so no new rows are written; the stale `index.md` is inert. Executor: confirm Task 6.3's operator note is explicit; do not add per-repo rename code to the hook.
- **FOLLOWUP — `test-wiki-archive-mem.sh` content-file assertion (medium).** The fake `uvx` only logs argv; it does not open `--content-file` to confirm the rendered summary was actually written and non-empty. Executor: extend the fake `uvx` to read the `--content-file` path, assert it exists and contains expected markers (session title, project, a user prompt), before relying on Case A.
- **FOLLOWUP — stale module docstring (low).** `hooks/wiki-archive.py` lines 9-14 still say it produces `YYMMDD_HH-MM_Event.md`. Executor: in Task 2, update the docstring — `.json` legacy belt remains, the markdown summary is rendered and ingested into `sspower-mem` as episodic memory, `sessions/*.md` is no longer written.
- **FOLLOWUP — offline-contract rc=30 assertion (medium).** Task 7.3/7.4 check only hook `exit=0` and absence of an injected block — a legitimate empty result is indistinguishable from a cold-cache rc=30. Executor: add an assertion on the wrapper's stderr `dep missing (rc=30…)` message (or a fake cold-cache `uvx` that records the normalized rc) so the rc=30 path is positively proven.
