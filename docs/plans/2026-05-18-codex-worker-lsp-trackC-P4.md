# Codex-Worker LSP Gate — Track C (P4: Codex Stop gate + rules/sandbox profiles) Implementation Plan

> **REVIEWERS — READ FIRST:** This is a PLAN to be *critiqued*, not executed now. Plan-review must assess the plan's correctness/completeness on a READ-ONLY filesystem and MUST NOT attempt to create files, chmod, or commit. "Cannot write in this session / sandbox is read-only / approval disabled" is the EXPECTED review condition and is NOT a plan finding — implementation happens later in a separate `workspace-write` SDD session (Execution Handoff). Do not raise read-only-ness as a defect.
>
> **For agentic workers:** REQUIRED SUB-SKILL: Use sspower:subagent-driven-development (recommended) or sspower:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax. Strictly sequential — one worker per task, spec-review then quality-review per task (the Track B codex-worker pattern). NO parallel implementation subagents.

**Goal:** Ship P4 (spec Phases B5+B6, decisions D-B4/D-B5) of the Codex-worker LSP gate: an in-session Codex **Stop gate** that makes Codex keep fixing while LSP errors remain, plus **enforced rules** (Codex never `git commit`/`push`, no `rm -rf`, prompt on `npm/pnpm install`) and a **hardened sandbox/approval profile** (`approval_policy=never` + `sandbox_mode=workspace-write` + `network_access=false`) scoped to the `implement --write` path.

**Architecture:** B5 reuses P3's *shipped* bridge-direct MCP path (`runLspGate`, never model-issued MCP — Codex-0.130 gates model MCP calls behind an un-bypassable per-call approval, see Gotcha) by exposing it as a new `codex-bridge.mjs lsp-check` subcommand that a Codex-native `Stop` hook (`.codex/hooks.json`, Claude-compatible `{decision:"block",reason}` contract — Codex 0.130 ports Claude Code's hook system) invokes. B6 enforces D-B4 via a `.codex/hooks.json` **PreToolUse** hook (Codex's only hard-enforcement primitive; the spec's `.codex/rules/` filename predates the Codex-0.130 hook-port discovery — intent honored, mechanism updated) plus an `AGENTS.md` advisory note, and wires `approval_policy=never`/`sandbox_workspace_write.network_access=false` as `-c` overrides through `runCodexExec`, scoped to `cmdImplement --write` only. Advisory-first (D-B6): the Stop gate logs `would-block` and exits 0 unless `SSPOWER_CODEX_STOP_GATE=1`; promotion to block is a user-gated decision.

**Tech Stack:** Node ESM (`scripts/codex-bridge.mjs`), bash 3.2 hook scripts (macOS floor — no bash-4 syntax), Codex CLI 0.130.0 (`-c key=value` overrides, `.codex/hooks.json` Claude-ported hook contract), vendored codex-lsp MCP-over-stdio (`tools/codex-lsp/dist`), node:test.

---

## Decisions baked in (do NOT revisit — evidence in transcript / wiki)

- **D-1 The new B5 Stop gate uses bridge-direct MCP, never model-issued — scoped to `cmdLspCheck` only.** Codex 0.130 gates *every* model-issued MCP tool call behind a per-call approval that auto-cancels non-interactively; `approval_policy=never` does NOT bypass it (proven P2-T6, `.claude/wiki/gotchas.md`). The Stop hook script calls `node codex-bridge.mjs lsp-check`, which runs the existing `runLspGate` (bridge speaks JSON-RPC to codex-lsp itself). Adding `--dangerously-bypass-approvals-and-sandbox` is forbidden (disables the sandbox). **Scope clarification (plan-review finding):** "never model-issued" describes *this new Stop-gate path only*. P4 does **NOT** modify the existing `lspMcp:true` registration in `cmdImplement`/`runLspRepairLoop`/resume paths (`scripts/codex-bridge.mjs:1432,1525,1659,1822`) — that is P3-shipped behavior and out of P4 scope. Those paths register `-c mcp_servers.lsp.*` so Codex *may* attempt model MCP; per the gotcha that attempt auto-cancels harmlessly (the bridge-direct `runLspGate` is the actual gate, P3). Removing/disabling the vestigial registration is a separate cleanup, NOT this plan. No P4 task touches those lines.
- **D-2 Codex 0.130 hook contract == Claude Code's.** Binary symbols: `struct StopCommandOutputWire`, error `"Stop hook returned decision:block without a non-empty reason"`, `"Stop hook exited with code 2 but did not write a continuation prompt to stderr"`. So Stop output = `{"decision":"block","reason":"<non-empty>"}` (Codex continues) or exit 2 + continuation-prompt-on-stderr. `hooks.json` handler = `{matcher(regex), command, timeout, async, statusMessage}` (matches the shipped PostToolUse entry). No bimodal placeholder — Plan-B-R2 retired.
- **D-3 B6 rules → PreToolUse hook, not a `.rules` file.** Codex 0.130 has no clean `.codex/rules/*.rules` enforcement primitive (instruction mechanisms: soft `AGENTS.md`/`CLAUDE.md`; hard = PreToolUse hook, Claude `permissionDecision` contract). Spec D-B4 *intent* ("Codex never commits/pushes; rules forbidden") is enforced via PreToolUse `deny`/`ask`. Spec-prose filename deviation — surfaced for plan-review.
- **D-4 Profile scope = `cmdImplement` write path only.** `codex-bridge.mjs:1516` (`opts.write ? "workspace-write" : "read-only"`) is the sole write path. `cmdSpecReview`/`cmdPlanReview`/`cmdReview` (1581/1597/1613) stay `sandbox:"read-only"` — unchanged.
- **D-4a (OPEN — security-relevant, gated by Task 0 Step 5b).** `runCodexResume` (codex-bridge.mjs:430-468, used by `runLspRepairLoop`) passes **only** `-m` / `-c model_reasoning_effort` / lspMcp args — it does NOT re-apply `--sandbox`, `-c approval_policy="never"`, or `-c sandbox_workspace_write.network_access=false`. Whether `codex exec resume <session>` **inherits** the originating `codex exec` session's hardened config is Codex-0.130 runtime behavior and is **NOT yet verified** (the :424 comment claims resume rejects `--sandbox`/`-c`, yet `-c model_reasoning_effort` IS accepted there — so the claim is imprecise and must be tested empirically, not assumed). **Security implication:** if resume does NOT inherit, the gate-triggered LSP repair rounds — exactly when Codex is actively editing files to fix diagnostics — run with **default** sandbox/approval/network (potentially network-ON), a regression introduced by this very plan. Task 0 Step 5b empirically resolves this; Task 4 Step 8 acts on the finding (cover or explicitly scope-out-with-stated-risk). `--print-args` alone is INSUFFICIENT (it shows bridge-built args, not Codex's internal session-config inheritance).
- **D-5 network_access=false is safe.** The `[sandbox_workspace_write] network_access` key governs *model-spawned shell* network only; Codex's own LLM API channel is unaffected. codex-lsp is local stdio. Task 0 Step 4 grep re-confirms no codex-spawned implement step needs network.
- **D-6 Advisory-first (D-B6).** Default `SSPOWER_CODEX_STOP_GATE` unset → Stop hook logs `would-block`, exits 0 (Codex stops normally). `=1` → emits `decision:block`. Mirrors P3's `SSPOWER_LSP_GATE_BLOCK`. No time-based auto-promotion.

---

## File map

- **Create** `.codex/codex-lsp-stop.sh` — Codex Stop hook script (bash 3.2; reads stdin JSON, calls `lsp-check`, emits Claude Stop contract).
- **Create** `.codex/codex-guard-pretool.sh` — Codex PreToolUse hook script (bash 3.2; denies `git commit|push`, `rm -rf`; `ask` on `npm|pnpm|yarn install`).
- **Modify** `.codex/hooks.json` — add `Stop` + `PreToolUse` entries (keep existing `PostToolUse`).
- **Create** `AGENTS.md` (repo root) — advisory note mirroring the hard rules (Codex reads it like CLAUDE.md).
- **Modify** `scripts/codex-bridge.mjs` — add `cmdLspCheck` + `lsp-check` dispatch (~35 LOC, reuses `runLspGate`); add `approval_policy`/`network_access` `-c` overrides to `runCodexExec` gated by a new `hardenWrite` option; set `hardenWrite:true` in `cmdImplement` when `opts.write`.
- **Create** `tests/codex-bridge/test-lsp-check.sh` — `lsp-check` JSON contract (clean / errors / fail-open).
- **Create** `tests/codex-bridge/test-harden-write-args.mjs` — `--print-args` asserts the hardened `-c` flags appear iff write, absent for review paths.
- **Create** `tests/hooks/test-codex-stop-gate.sh` — Stop script advisory vs block behaviour.
- **Create** `tests/hooks/test-codex-guard-pretool.sh` — PreToolUse deny/ask matrix.
- **Modify** `docs/ARCHITECTURE.md`, `.claude/wiki/gotchas.md`, `.claude/wiki/decisions.md`, `docs/handoff.md` — document P4.

---

### Task 0: Verification spike — confirm resolved unknowns on THIS machine

**Files:**
- Create: `docs/plans/notes/P4-spike-findings.md`

> All five unknowns were resolved by static analysis of the Codex 0.130 binary + project gotchas. This task re-confirms empirically (guards against static-analysis error) and records findings later tasks cite. ~10 min, no source changes.

- [ ] **Step 1: Confirm Codex version + hook/sandbox/approval vocabulary**

Run (robust binary resolution — no nested node child_process; tolerates the npm-wrapper indirection):
```bash
codex --version
CODEX_WRAPPER="$(readlink -f "$(command -v codex)")"
# npm global wrapper: <prefix>/lib/node_modules/@openai/codex/bin/codex.js
# native blob:    .../@openai/codex/node_modules/@openai/codex-<plat>/vendor/<triple>/codex/codex
CODEX_PKG_DIR="$(cd "$(dirname "$CODEX_WRAPPER")/.." && pwd)"
CODEXNATIVE="$(find "$CODEX_PKG_DIR/node_modules/@openai" -type f -name codex -path '*/vendor/*/codex/codex' 2>/dev/null | head -1)"   # no -maxdepth: blob is ~5 levels deep (Task 0 verified)
[ -z "$CODEXNATIVE" ] && { echo "STOP: codex native blob not found under $CODEX_PKG_DIR — record path layout in findings and escalate"; exit 1; }
strings "$CODEXNATIVE" | grep -oE 'StopCommandOutputWire|approval_policy|sandbox_workspace_write|network_access|on-request' | sort -u
```
Expected: `codex-cli 0.130.0`; the grep prints all of `StopCommandOutputWire approval_policy sandbox_workspace_write network_access on-request`. If `0.130.0` differs, STOP and re-validate the hook contract before proceeding (record actual version in findings).

- [ ] **Step 2: Confirm Stop hook continuation contract**

Run:
```bash
strings "$CODEXNATIVE" | grep -F 'Stop hook returned decision:block without a non-empty reason'
strings "$CODEXNATIVE" | grep -F 'Stop hook exited with code 2 but did not write a continuation prompt to stderr'
```
Expected: both strings present. Record in findings: "Stop block contract = `{decision:block,reason:<non-empty>}` OR exit 2 + stderr continuation prompt (Claude-compatible)."

- [ ] **Step 3: Confirm `-c` override syntax + network key**

Run:
```bash
codex exec --help 2>&1 | grep -A2 -- '-c, --config'
```
Expected: shows `-c key=value` overriding `~/.codex/config.toml`. Record: network-off override = `-c 'sandbox_workspace_write.network_access=false'`; approval = `-c 'approval_policy="never"'`.

- [ ] **Step 4: network_access=false blast-radius grep (D-5 confirm)**

Run:
```bash
grep -nE 'fetch\(|https?://|npm (i|install)|pnpm (i|install)|curl |wget ' scripts/codex-bridge.mjs | grep -viE '//|^\s*\*' | head
```
Expected: the ONLY hit is the codex-CLI-not-found install-hint string near `scripts/codex-bridge.mjs:195` (`Install with: npm install -g @openai/codex`) — diagnostic text, NOT a Codex-spawned implement-run network dependency (Codex's LLM API uses its own auth channel, not sandbox net). Record the grep output verbatim and classify that hit as non-blocking diagnostic text. If any *other* hit indicates a real network dependency inside the implement path, STOP — escalate (network_access=false would break it).

- [ ] **Step 5: Resume config-inheritance probe (D-4a — security-gating)**

Determine empirically whether `codex exec resume` inherits the originating session's `network_access=false`. Run:
```bash
TMP="$(mktemp -d)"; git -C "$TMP" init -q; git -C "$TMP" commit -q --allow-empty -m init
# Create a persisted (non-ephemeral) workspace-write session with network OFF,
# instruct it to attempt a network call and report the outcome.
SID="$(codex exec --json --sandbox workspace-write \
  -c 'approval_policy="never"' -c 'sandbox_workspace_write.network_access=false' \
  -C "$TMP" - <<<'Run: curl -s -m 5 https://example.com >/dev/null 2>&1 && echo NET_OK || echo NET_BLOCKED. Then reply with exactly that token.' \
  2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const m=s.match(/"session_id":"([^"]+)"/);process.stdout.write(m?m[1]:"")})')"
echo "session=$SID"
# Resume the SAME session (the bridge's runCodexResume flag set: --json only,
# no --sandbox / no -c approval/network) and re-probe.
codex exec resume "$SID" --json -C "$TMP" - <<<'Run: curl -s -m 5 https://example.com >/dev/null 2>&1 && echo RESUME_NET_OK || echo RESUME_NET_BLOCKED. Reply with exactly that token.' 2>/dev/null | grep -aoE 'RESUME_NET_(OK|BLOCKED)' | tail -1
rm -rf "$TMP"
```
Expected one of:
- `RESUME_NET_BLOCKED` → resume **inherits** the hardened config. Record "D-4a RESOLVED: resume inherits network-off; Task 4 Step 8 = no extra work needed, document inheritance." 
- `RESUME_NET_OK` → resume does **NOT** inherit → **security gap confirmed**. Record "D-4a CONFIRMED GAP: resume runs network-ON." Task 4 Step 8 MUST then either re-apply the `-c` hardening in `runCodexResume` (if `codex exec resume` accepts them — test `codex exec resume "$SID" -c 'sandbox_workspace_write.network_access=false' ...`) OR, if resume rejects those `-c` keys, explicitly scope repair-round hardening OUT in D-4a + ARCHITECTURE with the stated network-ON-during-repair risk and a follow-up issue.
- Command errors / Codex auth unavailable → record "D-4a UNRESOLVED (probe blocked: <reason>)"; Task 4 Step 8 defaults to the explicit scope-out-with-stated-risk branch (fail safe: do not claim hardening you didn't verify).

- [ ] **Step 6: Write findings file**

Create `docs/plans/notes/P4-spike-findings.md` with the five results above under headings `Version`, `Stop contract`, `Override syntax`, `Network blast radius`, `Resume inheritance (D-4a)`, each with exact command output pasted. End with: `Disposition: D-1..D-6 confirmed; D-4a = <RESOLVED|CONFIRMED GAP|UNRESOLVED> — proceed per Task 4 Step 8.` (or a specific deviation + STOP if a contract step failed).

- [ ] **Step 7: Commit**

```bash
git add docs/plans/notes/P4-spike-findings.md
git commit -m "docs(p4): Task 0 spike — Codex 0.130 contract + resume-inheritance (D-4a) findings"
```

---

### Task 1: `lsp-check` bridge subcommand (B5 backend — reuses shipped runLspGate)

**Files:**
- Modify: `scripts/codex-bridge.mjs` (add `cmdLspCheck`; register in the command dispatch switch)
- Test: `tests/codex-bridge/test-lsp-check.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/codex-bridge/test-lsp-check.sh`:
```bash
#!/usr/bin/env bash
# test-lsp-check: codex-bridge.mjs lsp-check JSON contract
set -u
BRIDGE="$(cd "$(dirname "$0")/../.." && pwd)/scripts/codex-bridge.mjs"
FAIL=0
pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; FAIL=1; }

# (a) clean tree (no changed source files) -> decision clean, exit 0
TMP="$(mktemp -d)"; ( cd "$TMP" && git init -q && git commit -q --allow-empty -m init )
OUT="$(node "$BRIDGE" lsp-check --cd "$TMP" 2>/dev/null)"; RC=$?
echo "$OUT" | grep -q '"decision":"clean"' && [ $RC -eq 0 ] && pass "clean-tree" || fail "clean-tree (rc=$RC out=$OUT)"

# (b) missing --cd -> fail-open: decision clean/skipped, exit 0 (never crash)
OUT="$(node "$BRIDGE" lsp-check --cd /nonexistent/xyz 2>/dev/null)"; RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -qE '"decision":"(clean|skipped)"' && pass "fail-open-badcwd" || fail "fail-open-badcwd (rc=$RC out=$OUT)"

# (c) output is single-line JSON with required keys
echo "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);if("decision"in j&&"status"in j&&"errors"in j)process.exit(0);process.exit(1)})' && pass "json-shape" || fail "json-shape"

rm -rf "$TMP"
[ $FAIL -eq 0 ] && echo "PASS: test-lsp-check" || { echo "FAIL: test-lsp-check"; exit 1; }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/codex-bridge/test-lsp-check.sh`
Expected: `FAIL` — `lsp-check` is not a known subcommand (bridge prints usage / nonzero).

- [ ] **Step 3: Add `cmdLspCheck`**

In `scripts/codex-bridge.mjs`, after `cmdImplement` (ends line ~1576), add:
```javascript
// B5 backend: in-session Stop-gate diagnostics. Reuses the shipped
// bridge-direct runLspGate (NEVER model-issued MCP -- Codex-0.130 gates
// model MCP behind an un-bypassable per-call approval; see gotchas).
// Always exits 0 and prints one JSON line (fail-open / D-B7).
async function cmdLspCheck(argv) {
  const opts = parseOpts(argv);
  const cwd = path.resolve(opts.cd || ".");
  const out = { status: "skipped", decision: "clean", total_errors: 0, errors: [] };
  try {
    if (!fs.existsSync(cwd)) { process.stdout.write(JSON.stringify(out) + "\n"); return; }
    // baseHead=null -> lspChangedFiles diffs working tree vs HEAD (the
    // uncommitted edits Codex just made this session).
    const g = await runLspGate(cwd, null, false);
    out.status = g.status;
    out.decision = g.status === "errors" ? "would-block" : "clean";
    out.total_errors = g.total_errors || 0;
    out.errors = (g.errors || []).map((e) => ({ file: e.file, text: e.text }));
  } catch (e) {
    logEvent("warn", "bridge.lsp", { kind: "lsp_check_threw", msg: String(e && e.message) });
  }
  process.stdout.write(JSON.stringify(out) + "\n");
}
```

- [ ] **Step 4: Register dispatch**

Find the command switch (search `case "implement"` in `scripts/codex-bridge.mjs`). Add alongside it:
```javascript
    case "lsp-check": await cmdLspCheck(argv.slice(1)); break;
```
(Match the exact existing `case`/`break` style and argv-slice convention used by neighbouring cases — read the switch first.)

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/codex-bridge/test-lsp-check.sh`
Expected: `PASS: test-lsp-check`

- [ ] **Step 6: Bridge integrity**

Run: `node --check scripts/codex-bridge.mjs`
Expected: exit 0, no output.

- [ ] **Step 7: Commit**

```bash
git add scripts/codex-bridge.mjs tests/codex-bridge/test-lsp-check.sh
git commit -m "feat(p4): lsp-check subcommand -- B5 in-session gate backend (reuses runLspGate)"
```

---

### Task 2: Codex Stop hook script + `.codex/hooks.json` Stop entry (B5)

**Files:**
- Create: `.codex/codex-lsp-stop.sh`
- Modify: `.codex/hooks.json`
- Test: `tests/hooks/test-codex-stop-gate.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/hooks/test-codex-stop-gate.sh`:
```bash
#!/usr/bin/env bash
# test-codex-stop-gate: .codex/codex-lsp-stop.sh advisory vs block
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SH="$ROOT/.codex/codex-lsp-stop.sh"
FAIL=0; pass(){ echo "PASS: $1"; }; fail(){ echo "FAIL: $1"; FAIL=1; }

TMP="$(mktemp -d)"; ( cd "$TMP" && git init -q && git commit -q --allow-empty -m init )
IN="{\"session_id\":\"x\",\"cwd\":\"$TMP\",\"hook_event_name\":\"Stop\"}"

# (a) clean tree, advisory (env unset) -> exit 0, no decision:block
OUT="$(printf '%s' "$IN" | SSPOWER_CODEX_STOP_GATE= bash "$SH" 2>/dev/null)"; RC=$?
[ $RC -eq 0 ] && ! echo "$OUT" | grep -q '"decision":"block"' && pass "clean-advisory" || fail "clean-advisory (rc=$RC out=$OUT)"

# (b) clean tree, block mode -> still exit 0, no block (nothing to fix)
OUT="$(printf '%s' "$IN" | SSPOWER_CODEX_STOP_GATE=1 bash "$SH" 2>/dev/null)"; RC=$?
[ $RC -eq 0 ] && ! echo "$OUT" | grep -q '"decision":"block"' && pass "clean-blockmode" || fail "clean-blockmode (rc=$RC out=$OUT)"

# (c) bad cwd -> fail-open exit 0, no block
OUT="$(printf '%s' '{"cwd":"/nonexistent/xyz","hook_event_name":"Stop"}' | SSPOWER_CODEX_STOP_GATE=1 bash "$SH" 2>/dev/null)"; RC=$?
[ $RC -eq 0 ] && ! echo "$OUT" | grep -q '"decision":"block"' && pass "fail-open" || fail "fail-open (rc=$RC out=$OUT)"

rm -rf "$TMP"
[ $FAIL -eq 0 ] && echo "PASS: test-codex-stop-gate" || { echo "FAIL: test-codex-stop-gate"; exit 1; }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/hooks/test-codex-stop-gate.sh`
Expected: `FAIL` — `.codex/codex-lsp-stop.sh` does not exist.

- [ ] **Step 3: Create the Stop hook script (bash 3.2)**

Create `.codex/codex-lsp-stop.sh`:
```bash
#!/usr/bin/env bash
# Codex Stop hook (B5). Reads Codex Stop stdin JSON, runs the bridge-direct
# LSP check, and -- only when SSPOWER_CODEX_STOP_GATE=1 -- emits the
# Claude-compatible Stop block contract so Codex keeps fixing. Advisory by
# default (D-B6). Fail-open everywhere (D-B7): any error -> exit 0, no block.
set -u
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
BRIDGE="$SELF_DIR/../scripts/codex-bridge.mjs"
STDIN_JSON="$(cat 2>/dev/null || true)"

# Extract cwd from stdin JSON without bash-4 / jq dependency.
CWD="$(printf '%s' "$STDIN_JSON" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);process.stdout.write(String(j.cwd||""))}catch{process.stdout.write("")}})' 2>/dev/null || true)"
[ -z "$CWD" ] && CWD="$(pwd)"

RES="$(node "$BRIDGE" lsp-check --cd "$CWD" 2>/dev/null || true)"
DEC="$(printf '%s' "$RES" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);process.stdout.write(String(j.decision||"clean")+"\t"+(j.total_errors||0)+"\t"+((j.errors||[]).map(e=>e.file).join(", ")))}catch{process.stdout.write("clean\t0\t")}})' 2>/dev/null || printf 'clean\t0\t')"
DECISION="${DEC%%$'\t'*}"
REST="${DEC#*$'\t'}"; NERR="${REST%%$'\t'*}"; FILES="${REST#*$'\t'}"

if [ "$DECISION" != "would-block" ]; then
  exit 0    # clean / skipped / fail-open
fi

if [ "${SSPOWER_CODEX_STOP_GATE:-}" = "1" ]; then
  REASON="LSP gate: $NERR error-severity diagnostic(s) remain in: $FILES. Fix ONLY these so the language server is clean, then stop. Do not change unrelated code."
  printf '{"decision":"block","reason":%s}\n' "$(printf '%s' "$REASON" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.stringify(s)))')"
  exit 0
fi

# Advisory: record would-block, let Codex stop normally.
printf '[codex-stop-gate] would-block: %s LSP error(s) in %s (advisory; set SSPOWER_CODEX_STOP_GATE=1 to enforce)\n' "$NERR" "$FILES" >&2
exit 0
```
`chmod +x .codex/codex-lsp-stop.sh` (Step 5 verifies).

- [ ] **Step 4: Add the Stop entry to `.codex/hooks.json`**

Modify `.codex/hooks.json` — add a sibling `Stop` array under `hooks` (keep the existing `PostToolUse` array verbatim):
```json
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": ".codex/codex-lsp-stop.sh",
            "timeout": 130,
            "statusMessage": "checking LSP before stop (advisory)"
          }
        ]
      }
    ]
```
(`timeout` 130s ≥ runLspGate's 120s whole-gate cap. No `matcher` — Stop is not tool-matched, per the Claude-ported contract.)

- [ ] **Step 5: chmod + run test to verify it passes**

Run:
```bash
chmod +x .codex/codex-lsp-stop.sh
bash tests/hooks/test-codex-stop-gate.sh
```
Expected: `PASS: test-codex-stop-gate`

- [ ] **Step 6: Validate hooks.json is well-formed**

Run: `node -e 'JSON.parse(require("fs").readFileSync(".codex/hooks.json","utf8"));console.log("OK")'`
Expected: `OK`

- [ ] **Step 7: Commit**

```bash
git add .codex/codex-lsp-stop.sh .codex/hooks.json tests/hooks/test-codex-stop-gate.sh
git commit -m "feat(p4): Codex Stop gate -- in-session LSP block (advisory; D-B6)"
```

---

### Task 3: Codex PreToolUse guard hook + AGENTS.md (B6 rules — D-3)

**Files:**
- Create: `.codex/codex-guard-pretool.sh`
- Modify: `.codex/hooks.json`
- Create: `AGENTS.md`
- Test: `tests/hooks/test-codex-guard-pretool.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/hooks/test-codex-guard-pretool.sh`:
```bash
#!/usr/bin/env bash
# test-codex-guard-pretool: deny git commit/push & rm -rf; ask on installs; allow rest
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SH="$ROOT/.codex/codex-guard-pretool.sh"
FAIL=0; pass(){ echo "PASS: $1"; }; fail(){ echo "FAIL: $1"; FAIL=1; }

# Codex PreToolUse stdin shape (Claude-ported): tool_name + tool_input.command
mk(){ printf '{"hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"command":"%s"}}' "$1" "$2"; }
deny(){ echo "$1" | grep -q '"permissionDecision":"deny"'; }
ask(){ echo "$1" | grep -q '"permissionDecision":"ask"'; }
allow(){ echo "$1" | grep -qE '"permissionDecision":"allow"' || [ -z "$1" ]; }

O="$(mk shell 'git commit -m x' | bash "$SH" 2>/dev/null)"; deny "$O" && pass "deny-commit" || fail "deny-commit ($O)"
O="$(mk shell 'git push origin main' | bash "$SH" 2>/dev/null)"; deny "$O" && pass "deny-push" || fail "deny-push ($O)"
O="$(mk shell 'rm -rf build/' | bash "$SH" 2>/dev/null)"; deny "$O" && pass "deny-rmrf" || fail "deny-rmrf ($O)"
O="$(mk shell 'npm install left-pad' | bash "$SH" 2>/dev/null)"; ask "$O" && pass "ask-npm" || fail "ask-npm ($O)"
O="$(mk shell 'pnpm install' | bash "$SH" 2>/dev/null)"; ask "$O" && pass "ask-pnpm" || fail "ask-pnpm ($O)"
O="$(mk shell 'git status' | bash "$SH" 2>/dev/null)"; allow "$O" && pass "allow-status" || fail "allow-status ($O)"
O="$(mk shell 'node t.js' | bash "$SH" 2>/dev/null)"; allow "$O" && pass "allow-node" || fail "allow-node ($O)"
# fail-open: unparsable stdin -> allow (exit 0, no deny)
O="$(printf 'not json' | bash "$SH" 2>/dev/null)"; RC=$?; { [ $RC -eq 0 ] && ! deny "$O"; } && pass "failopen" || fail "failopen (rc=$RC $O)"

[ $FAIL -eq 0 ] && echo "PASS: test-codex-guard-pretool" || { echo "FAIL: test-codex-guard-pretool"; exit 1; }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/hooks/test-codex-guard-pretool.sh`
Expected: `FAIL` — script absent.

- [ ] **Step 3: Create the guard script (bash 3.2)**

Create `.codex/codex-guard-pretool.sh`:
```bash
#!/usr/bin/env bash
# Codex PreToolUse guard (B6 / D-B4). Enforces: Codex never `git commit`/
# `git push` (sspower owns the git surface); no `rm -rf`; prompt (ask) on
# package installs. Claude-ported PermissionRequest contract. Fail-open:
# unparsable input -> exit 0, allow (advisory infra must never wedge Codex).
set -u
STDIN_JSON="$(cat 2>/dev/null || true)"
CMD="$(printf '%s' "$STDIN_JSON" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);const t=j.tool_input||{};process.stdout.write(String(t.command||t.cmd||""))}catch{process.stdout.write("")}})' 2>/dev/null || true)"

emit(){ # $1=decision $2=reason
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":%s}}\n' \
    "$1" "$(printf '%s' "$2" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.stringify(s)))')"
  exit 0
}

[ -z "$CMD" ] && exit 0   # not a shell tool / unparsable -> allow

case "$CMD" in
  *"git commit"*|*"git push"*|*"git merge"*)
    emit deny "sspower owns the git surface (D-B4). Codex must not commit/push/merge; leave changes uncommitted for the supervisor." ;;
  *"rm -rf "*|*"rm -fr "*)
    emit deny "rm -rf is forbidden inside Codex (D-B4)." ;;
  *"npm install"*|*"npm i "*|*"pnpm install"*|*"pnpm add"*|*"yarn add"*|*"yarn install"*)
    emit ask "Package install requested -- confirm before Codex mutates dependencies." ;;
esac
exit 0   # default allow
```
`chmod +x` in Step 6.

- [ ] **Step 4: Add PreToolUse entry to `.codex/hooks.json`**

Add to the existing `PostToolUse`-bearing `hooks` object a sibling `PreToolUse` array (keep `PostToolUse` and `Stop` verbatim):
```json
    "PreToolUse": [
      {
        "matcher": "^(shell|bash|run|exec)$",
        "hooks": [
          {
            "type": "command",
            "command": ".codex/codex-guard-pretool.sh",
            "timeout": 10,
            "statusMessage": "sspower guard (git/rm/install)"
          }
        ]
      }
    ]
```
> Task 0 Step 1 vocabulary confirms the tool name; if Codex 0.130's shell tool name is not in `^(shell|bash|run|exec)$`, widen the matcher to `.*` and keep the in-script command parse as the real filter (the script already no-ops on empty command — safe).

- [ ] **Step 5: Create `AGENTS.md` (soft mirror)**

Create `AGENTS.md` at repo root:
```markdown
# Agent rules (Codex worker)

sspower drives git. As the Codex worker you MUST NOT run `git commit`,
`git push`, or `git merge` — leave your changes uncommitted; the
supervisor commits. Never run `rm -rf`. Do not install packages
(`npm/pnpm/yarn install|add`) without explicit approval — these are
hook-enforced and will be denied or prompted. Fix LSP error-severity
diagnostics in files you changed before you stop.
```

- [ ] **Step 6: chmod + run test**

Run:
```bash
chmod +x .codex/codex-guard-pretool.sh
bash tests/hooks/test-codex-guard-pretool.sh
```
Expected: `PASS: test-codex-guard-pretool`

- [ ] **Step 7: hooks.json well-formed**

Run: `node -e 'const h=JSON.parse(require("fs").readFileSync(".codex/hooks.json","utf8")).hooks;console.log(Object.keys(h).sort().join(","))'`
Expected: `PostToolUse,PreToolUse,Stop`

- [ ] **Step 8: Commit**

```bash
git add .codex/codex-guard-pretool.sh .codex/hooks.json AGENTS.md tests/hooks/test-codex-guard-pretool.sh
git commit -m "feat(p4): Codex PreToolUse guard + AGENTS.md -- enforce D-B4 (no commit/push/rm-rf; ask installs)"
```

---

### Task 4: Hardened write profile — approval_policy=never + network off (B6 / D-B5, D-4)

**Files:**
- Modify: `scripts/codex-bridge.mjs` (`runCodexExec` ~374-418; `cmdImplement` ~1516-1526)
- Test: `tests/codex-bridge/test-harden-write-args.mjs`

- [ ] **Step 1: Write the failing test**

Create `tests/codex-bridge/test-harden-write-args.mjs`:
```javascript
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
const BRIDGE = new URL("../../scripts/codex-bridge.mjs", import.meta.url).pathname;

function bridgeArgs(extra) {
  const out = execFileSync("node", [BRIDGE, ...extra, "--print-args",
    "--prompt", "noop"], { encoding: "utf8" });
  return JSON.parse(out.trim().split("\n").pop());
}

test("implement --write carries hardened -c overrides", () => {
  const { args: a } = bridgeArgs(["implement", "--write", "--cd", "."]);
  const j = a.join(" ");
  assert.match(j, /approval_policy="never"/);
  assert.match(j, /sandbox_workspace_write\.network_access=false/);
  assert.match(j, /--sandbox workspace-write/);
});

test("implement WITHOUT --write does not harden (read-only, no network knob)", () => {
  const { args: a } = bridgeArgs(["implement", "--cd", "."]);
  const j = a.join(" ");
  assert.doesNotMatch(j, /approval_policy="never"/);
  assert.doesNotMatch(j, /network_access=false/);
  assert.match(j, /--sandbox read-only/);
});

test("review path stays read-only, unhardened", () => {
  const { args: a } = bridgeArgs(["review", "--cd", "."]);
  const j = a.join(" ");
  assert.doesNotMatch(j, /approval_policy="never"/);
  assert.doesNotMatch(j, /network_access=false/);
  assert.match(j, /--sandbox read-only/);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test tests/codex-bridge/test-harden-write-args.mjs`
Expected: FAIL — `approval_policy` not in args (not yet wired).

- [ ] **Step 3: Add `hardenWrite` option to `runCodexExec`**

In `scripts/codex-bridge.mjs`, `runCodexExec` options destructure (~375-384) add `hardenWrite = false,`. Then immediately after the existing `args.push("--sandbox", sandbox);` (line ~392) add:
```javascript
  // D-B5: hardened write profile. approval_policy=never (no interactive
  // approvals in non-interactive exec) + network_access=false (model-spawned
  // shell gets no network; Codex's own LLM channel is unaffected -- D-5).
  // Scoped to the implement --write path only (D-4); reviews stay read-only.
  if (hardenWrite) {
    args.push("-c", 'approval_policy="never"');
    args.push("-c", "sandbox_workspace_write.network_access=false");
  }
```

- [ ] **Step 4: Set `hardenWrite` in `cmdImplement`**

In `cmdImplement`, the `runCodexExec(prompt, { ... })` call (~1516-1526), add to the options object:
```javascript
    hardenWrite: !!opts.write,
```
(Place it adjacent to the existing `sandbox: opts.write ? "workspace-write" : "read-only",` line so the write-coupling is visually obvious.)

- [ ] **Step 5: Run test to verify it passes**

Run: `node --test tests/codex-bridge/test-harden-write-args.mjs`
Expected: all 3 tests PASS.

- [ ] **Step 6: Regression — existing tests still green**

Run:
```bash
node --check scripts/codex-bridge.mjs
bash tests/codex-bridge/test-complete.sh
```
Expected: `node --check` exit 0; `test-complete.sh` PASS (same count as pre-P4 baseline recorded in handoff: 15/0 — if the count legitimately grew, update the assertion and note it).

- [ ] **Step 7: Commit**

```bash
git add scripts/codex-bridge.mjs tests/codex-bridge/test-harden-write-args.mjs
git commit -m "feat(p4): hardened write profile -- approval_policy=never + network off (implement --write only; D-B5)"
```

- [ ] **Step 8: Act on D-4a (resume-hardening) per Task 0 Step 5 finding**

Read `docs/plans/notes/P4-spike-findings.md` → `Resume inheritance (D-4a)`. Branch:

- **RESOLVED (resume inherits, `RESUME_NET_BLOCKED`):** no code change. Add to `runCodexResume`'s doc-comment (codex-bridge.mjs:420-429) one line: `// D-4a verified <date>: resume inherits the originating session's sandbox/approval/network config (probe: Task 0 Step 5). No -c re-application needed.` Commit `docs(p4): D-4a resolved — resume inherits hardened config (verified)`.

- **CONFIRMED GAP (`RESUME_NET_OK`):** test whether resume accepts the keys:
  ```bash
  codex exec resume --help 2>&1 | grep -- '-c, --config' && echo "resume-accepts-c"
  ```
  - If `resume-accepts-c`: in `runCodexResume`, add a `hardenWrite=false` option (mirroring Task 4 Step 3) and, when true, `args.push("-c",'approval_policy="never"'); args.push("-c","sandbox_workspace_write.network_access=false");` after the `effort` push (line ~453). Set `hardenWrite:true` at the `runLspRepairLoop` → `runCodexResume` call (codex-bridge.mjs:1431-1433). Add a test to `test-harden-write-args.mjs`: a resume `--print-args` invocation carries the two `-c` flags. Commit `fix(p4): re-apply network/approval hardening on repair-loop resume (D-4a gap closed)`.
  - If resume rejects `-c` for these keys: do NOT fake it. Edit D-4a in this plan + the ARCHITECTURE P4 section to state explicitly: "LSP repair rounds (`runLspRepairLoop` resume) run WITHOUT network/approval hardening — `codex exec resume` does not accept the keys; mitigation: repair prompt is constrained to fixing named files, advisory-default gate, and the PreToolUse guard (Task 3) still applies to resume tool calls. Residual risk: network reachable during repair edits. Tracked: open a follow-up." Commit `docs(p4): D-4a scoped out with stated residual risk (resume rejects hardening -c)`.

- **UNRESOLVED (probe blocked):** take the scope-out branch above (fail safe — never claim unverified hardening) and additionally note the probe was blocked and must be re-run before B6 promotes from advisory to enforced.

---

### Task 5: Docs + wiki + verification matrix

**Files:**
- Modify: `docs/ARCHITECTURE.md`
- Modify: `.claude/wiki/gotchas.md`
- Modify: `.claude/wiki/decisions.md`
- Modify: `docs/handoff.md`

- [ ] **Step 1: ARCHITECTURE.md — document the Codex Stop gate + guard + profile**

Add a "P4 — Codex Stop gate + rules/sandbox (Track C)" subsection near the existing "Codex LSP self-repair" content describing: `.codex/hooks.json` now carries `PreToolUse` (guard), `PostToolUse` (advisory LSP), `Stop` (in-session gate via `lsp-check` → bridge-direct `runLspGate`); `SSPOWER_CODEX_STOP_GATE` (advisory default, `=1` enforces, D-B6); hardened write profile (`approval_policy=never`+`network_access=false`, `implement --write` only). State explicitly: Stop gate uses bridge-direct MCP, never model-issued (Codex-0.130 approval gate).

- [ ] **Step 2: gotchas.md — append the resolved-contract note**

Append a dated entry: "Codex 0.130 hook system is a port of Claude Code's — Stop = `{decision:block,reason}`/exit-2+stderr; PreToolUse = `permissionDecision` deny/ask/allow; `hooks.json` handler = `{matcher,command,timeout,async,statusMessage}`. `approval_policy=never` does NOT bypass the per-call *model* MCP approval (only `--dangerously-bypass`, forbidden) — Stop gate therefore calls `lsp-check` (bridge-direct), never model MCP."

- [ ] **Step 3: decisions.md — append D-1..D-6**

Append the six baked-in decisions from this plan's header (one line each, dated 2026-05-18) so `brainstorming`/`writing-plans` see them next session.

- [ ] **Step 4: Update handoff.md**

Set Task to P4 status, Resume-Here to the verification commands below, Decisions to D-1..D-6, and note P5 (semble_rs, Phase B7) remains roadmap (trigger: P2–P4 shipped AND semble_rs re-validated on a current repo).

- [ ] **Step 5: Run the full P4 verification matrix**

Run each; all must pass:
```bash
node --check scripts/codex-bridge.mjs
bash tests/codex-bridge/test-lsp-check.sh
bash tests/codex-bridge/test-complete.sh
node --test tests/codex-bridge/test-harden-write-args.mjs
bash tests/hooks/test-codex-stop-gate.sh
bash tests/hooks/test-codex-guard-pretool.sh
bash tests/hooks/test-integration.sh
node -e 'const h=JSON.parse(require("fs").readFileSync(".codex/hooks.json","utf8")).hooks;if(["PostToolUse","PreToolUse","Stop"].every(k=>k in h))console.log("hooks OK");else process.exit(1)'
```
Expected: every command exits 0 / prints its `PASS:` line / `hooks OK`. Record outputs in the commit body.

- [ ] **Step 6: Commit**

```bash
git add docs/ARCHITECTURE.md .claude/wiki/gotchas.md .claude/wiki/decisions.md docs/handoff.md
git commit -m "docs(p4): document Codex Stop gate + guard + hardened profile; verification matrix green"
```

---

## Verification matrix (P4 acceptance — spec §9 "Stop gate blocks on remaining errors; rules forbid git commit inside Codex")

| Criterion | Command | Expected |
|---|---|---|
| B5: lsp-check contract | `bash tests/codex-bridge/test-lsp-check.sh` | `PASS: test-lsp-check` |
| B5: Stop gate advisory/block | `bash tests/hooks/test-codex-stop-gate.sh` | `PASS: test-codex-stop-gate` |
| B5: Stop reuses bridge-direct (no model MCP) | code review of `cmdLspCheck` | calls `runLspGate`, no `lspMcp:true` model path |
| B6: guard deny/ask matrix | `bash tests/hooks/test-codex-guard-pretool.sh` | `PASS: test-codex-guard-pretool` |
| B6: hooks.json events | `node -e '...Object.keys(h)'` | `PostToolUse,PreToolUse,Stop` |
| D-B5: hardened write args | `node --test tests/codex-bridge/test-harden-write-args.mjs` | 3/3 PASS |
| D-4a: resume hardening resolved | `grep -A2 'Resume inheritance' docs/plans/notes/P4-spike-findings.md` | RESOLVED / GAP-closed-in-code / scoped-out-with-stated-risk (never "unverified-but-claimed") |
| D-4: review unaffected | same test, "review path" case | read-only, no `-c` harden |
| Bridge integrity | `node --check scripts/codex-bridge.mjs` | exit 0 |
| Regression | `bash tests/codex-bridge/test-complete.sh` | PASS (handoff baseline 15/0) |
| Hook integration | `bash tests/hooks/test-integration.sh` | all PASS |

## Risks & assumptions

- **R1 — Codex 0.130 hook port fidelity.** Mitigated: Task 0 re-confirms the binary symbols (`StopCommandOutputWire`, error strings) on the executing machine before any hook ships. If a future Codex bump changes the contract, Task 0 Step 1 STOPs.
- **R2 — Shell tool-name matcher.** Codex's shell tool name in the `PreToolUse` matcher is verified at Task 0 Step 1 / Task 3 Step 4; the in-script empty-command no-op makes a too-narrow matcher fail safe (allow), never falsely deny.
- **R3 — Advisory-first (D-B6).** Stop gate ships advisory; `SSPOWER_CODEX_STOP_GATE=1` promotion is a separate user decision after N clean advisory runs — NOT flipped in this plan.
- **R4 — `network_access=false` blast radius.** Task 0 Step 4 grep gates this; D-5 reasoning (sandbox net ≠ Codex LLM channel) is the basis. If the grep finds a real in-run network need, Task 4 STOPs and escalates.
- **R5 — Interactive variant (`approval_policy=on-request`+`auto_review`).** Spec D-B5 mentions a human-TUI variant. Out of scope for this plan: the bridge runs Codex non-interactively (`codex exec`); `on-request` is meaningless there and `auto_review` is a TUI concept. Documented as intentionally deferred (no bridge code path consumes it).
- **R6 — Resume-round hardening (D-4a), security-relevant.** `runLspRepairLoop` resumes Codex to fix LSP errors; `runCodexResume` does not re-apply `network_access=false`/`approval_policy=never`. Whether the resumed session inherits them is unverified until Task 0 Step 5. Gated: Task 4 Step 8 either confirms inheritance, closes the gap in code, or scopes it out with the network-ON-during-repair residual risk stated explicitly (never claimed-but-unverified). The PreToolUse guard (Task 3) still applies to resume tool calls, partially mitigating.
- **R7 — Plan-review gate evidence is weaker than a clean approve.** 3-round cap reached without a verifiable terminal `approve` (round 3 parse empty; Codex reviewed the v1.1.0 cache tree, not canonical — D-C1). Rounds 1–2 substantive defects fixed. A canonical-tree plan-review re-run is advised before B6 promotes from advisory to enforced (`SSPOWER_CODEX_STOP_GATE=1`).
- **Assumption:** Codex tier stays default/`fast` (out-of-repo P1 config); no Track C code sets `service_tier` ([[project-codex-service-tier-flex-unsupported]]).

## Plan-review gate outcome (honest)

3 rounds run; 3-round cap reached. **Not a clean terminal `approve`.**
- **Round 1** (`019e3b58`): `needs-attention` — 1 HIGH (read-only-sandbox misframe → dismissed, not a plan defect), 1 MEDIUM (D-1 model-MCP scope ambiguity → **fixed**), 1 LOW (Task 0 grep not empty → **fixed**).
- **Round 2**: `needs-attention` — HIGH misframe repeated; 1 MEDIUM (Task 0 binary-lookup brittle → **fixed** with robust resolution).
- **Round 3** (`019e3b5d`): Codex self-corrected the misframe after the REVIEWERS-READ-FIRST banner and did genuine validation (ran the Task 0 commands — succeeded), but the bridge's **terminal structured output was empty** (`"Failed to parse structured output", "raw": ""`) because Codex streamed multiple JSON objects. An *interim* `[codex:agent]` chunk showed `"verdict":"approve-with-followups"` but its finding text (`"I'm continuing with read-only inspection and …"`) is a progress announcement, **not a terminal verdict** — it must NOT be cited as approval.
- **Caveat (D-C1):** round-3 Codex inspected the **cache tree** `~/.codex/plugins/cache/sskys18/sspower/1.1.0/…`, not the canonical marketplace tree. Cache may lag this session's edits; gate evidence is weaker than a canonical-tree review. Likely contributed to the recurring misframe.
- **Disposition:** rounds 1–2 substantive defects (2 MEDIUM, 1 LOW) all fixed inline; the only repeated HIGH is a non-defect review-sandbox misframe; round 3 ended inconclusively at the cap. Proceeding under the documented 3-round cap with these corrections — NOT on a claimed clean verdict. A canonical-tree re-review is advisable before B6 hardening promotes from advisory.

## Plan-review disposition (rounds 1–2, Codex `plan-review`, session 019e3b58)

- **HIGH "implementation cannot proceed — read-only sandbox" → DISMISSED (not a plan defect).** The reviewer ran read-only and conflated *reviewing* the plan with *executing* it now. Its own `suggested_fix` ("resume in a `workspace-write` session, keep `network_access=false`") is precisely this plan's execution model (SDD in a writable session, Execution Handoff option 1). No plan change.
- **MEDIUM "never model-issued MCP" scope ambiguity → FIXED.** D-1 now explicitly scopes the claim to the new Stop-gate path and states P4 does not modify the P3-shipped `lspMcp:true` registration (`scripts/codex-bridge.mjs:1432,1525,1659,1822`).
- **LOW Task 0 Step 4 grep not literally empty → FIXED.** Step 4 expected output now anticipates the `:195` install-hint hit and classifies it non-blocking.

## Execution Handoff

**Plan complete. Executable scope = Tasks 0–5 (P4). P5 remains roadmap (own `writing-plans` pass when its trigger fires).**

Three execution options:
1. **Subagent-Driven (recommended)** → sspower:subagent-driven-development, Tasks 0→5 sequential, one Codex worker per task + spec-review then quality-review (the Track B codex-worker pattern). Branch `feat/codex-worker-trackC` already created off `main`.
2. **Inline Execution** → sspower:executing-plans
3. **Codex execute** → `codex-bridge.mjs implement --write`
