# Codex-Worker LSP Gate — Track B (P2 + P6 executable; P3–P5 roadmap) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use sspower:subagent-driven-development to implement the **executable** phases (P2, P6) task-by-task. P3–P5 are roadmap-with-triggers — do NOT implement them from this document; each gets its own `writing-plans` pass when its trigger fires. Steps use checkbox (`- [ ]`).

**Goal:** Ship P2 (Codex sees the same LSP + internal self-repair, advisory) and P6 (cleanup C4–C9) of Track B from spec v6. P3–P5 (bridge MCP gate, Stop gate/rules, semble_rs) are documented as a phased roadmap with explicit re-plan triggers — they are PROVISIONAL and structurally depend on P2 proving out (spec §5/§9/D-B6).

**Architecture:** codex-lsp is vendored as a 0-dependency self-contained compiled-ESM bundle under `tools/codex-lsp/` (MIT, pinned). Codex worker runs see the same language servers via `~/.codex/lsp-client.json` + a bridge-generated per-run `.codex/config.toml` MCP fragment. A repo-local `.codex/hooks.json` PostToolUse hook gives Codex internal LSP self-repair, **advisory only** (D-B6: never blocks until a user explicitly flips an env gate after N clean logged runs). P6 is independent cleanup with no spike precondition — it has no *dependency* on P2 so it can ship immediately after, but execution is **strictly sequential** (P2 Tasks 1–7, then P6 Tasks 8–14): SDD forbids parallel implementation subagents.

**Tech Stack:** Node ESM, codex-lsp (`@code-yeongyu/codex-lsp` v0.1.0, MIT, 0-dep), `typescript-language-server` (on PATH), Codex CLI MCP-over-stdio, bash hooks, JSON Schema.

---

## Source & scope

- **Spec:** `docs/specs/2026-05-17-codex-worker-lsp-gate-design.md` **v6**. P0+P1 shipped (PR #6).
- **Branch:** `design/codex-worker-lsp-gate` (P0+P1 committed `b548683`/`d538bd6`/`e0a33d2`/`f4e77e0`; pushed; PR #6 open). Track B continues on the same branch (or a fresh `feat/trackB` branch — decided at execution handoff).
- **Executable here:** **P2** (spec Phases B1+B2) + **P6** (Cleanup C4–C9).
- **Roadmap only (NO task matrix — re-plan per trigger):** **P3** (B3+B4), **P4** (B5+B6), **P5** (B7).
- **Out of scope:** P0/P1 (done), Track B blocking promotion (D-B6 — user-gated, not automated), forking codex-lsp (D-B3).

## Decisions resolved during planning (authoritative)

| Topic | Decision | Reasoning |
|---|---|---|
| codex-lsp vendoring (§5.7a) | **Vendor compiled `dist/` → `tools/codex-lsp/dist/` + `LICENSE` + `PROVENANCE.md`**; `SSPOWER_CODEX_LSP_CLI` env overrides. | `package.json` deps=0; move-test proved `dist/` runs standalone (no node_modules). MIT (Copyright 2026 Yeongyu Kim) permits vendoring w/ attribution. No submodule (overkill for 0-dep static bundle), no setup build (already compiled), no runtime network. Pin upstream `05e8f07` in PROVENANCE for rebuild. |
| Codex tier for Track B calls | All Track B `codex exec` runs inherit the **default-tier / `fast`** config from P1 (out-of-repo `~/.codex/config.toml`: `normal`+root=default-tier, `deep`/`quick`=fast). **`flex` is API-rejected on this account** (spec v6). No Track B code may set `service_tier`. | Memory: `project-codex-service-tier-flex-unsupported`. |
| Advisory→block promotion (D-B6) | Per-phase **explicit env gate** + **log-count precondition**, never automated. P2 gate env: `SSPOWER_LSP_SELFREPAIR_BLOCK` (default unset=advisory). | Spec D-B6 "user reviews N clean advisory runs then flips env". |
| P6 sequencing | P6 (C4–C9) has **no dependency** on P2 (pure cleanup, no spike precondition) but executes **sequentially after** P2 — one SDD worker per task, never parallel implementation subagents. | Advisor: P6 is cleanup-track; SDD red-flag forbids parallel impl workers. |

## Pre-flight (done)

- [x] Wiki: `decisions.md`/`gotchas.md` empty; recent sessions = config-consolidation/sspower-mem/this P0+P1 — no conflicts.
- [x] Tool reality: `semble_rs` present (`~/.cargo/bin/semble_rs`); codex-lsp MIT 0-dep self-contained (verified by isolated move-test); `bun`+`typescript-language-server` present; codex-lsp only in transient `/tmp` (P2 Task 1 vendors it).

---

# PHASE P2 — Codex sees the same LSP + internal self-repair (advisory)

> Spec Phases B1+B2, §5, §5.7a (discovery only — NOT the bridge MCP client, that's P3), D-B2, D-B6. Success criterion (spec §9 P2): `lsp.status` smoke passes; Codex self-repairs a seeded TS error in advisory mode.

### Task 1: Vendor codex-lsp into the repo

**Files:**
- Create: `tools/codex-lsp/dist/**` (copied compiled bundle), `tools/codex-lsp/LICENSE`, `tools/codex-lsp/PROVENANCE.md`

- [ ] **Step 1: Confirm source bundle present + self-contained**

Run: `node /tmp/codex-lsp/dist/cli.js 2>&1 | head -1`
Expected: `Usage: codex-lsp [mcp | hook post-tool-use]` (proves the `/tmp` bundle runs). If `/tmp/codex-lsp` is gone (reboot/tmp-clean): `git clone https://github.com/code-yeongyu/codex-lsp /tmp/codex-lsp && git -C /tmp/codex-lsp checkout 05e8f07 && cd /tmp/codex-lsp && bun install && bun run build` (bun + typescript-language-server are on PATH), then re-check.

- [ ] **Step 2: Copy the compiled bundle (strip sourcemaps to shrink)**

Run:
```bash
mkdir -p tools/codex-lsp
cp -R /tmp/codex-lsp/dist tools/codex-lsp/dist
find tools/codex-lsp/dist -name '*.map' -delete
cp /tmp/codex-lsp/LICENSE tools/codex-lsp/LICENSE
du -sh tools/codex-lsp/dist
```
Expected: `tools/codex-lsp/dist/cli.js` exists; size < 600K; LICENSE is the MIT text (`Copyright (c) 2026 Yeongyu Kim`).

- [ ] **Step 3: Write provenance**

Create `tools/codex-lsp/PROVENANCE.md`:
```markdown
# Vendored: @code-yeongyu/codex-lsp

- Upstream: https://github.com/code-yeongyu/codex-lsp
- Pinned commit: 05e8f07 ("fix(lsp): make config-loader test platform-aware")
- Version: 0.1.0
- License: MIT (see ./LICENSE — Copyright (c) 2026 Yeongyu Kim)
- Vendored: compiled `dist/` only (0 runtime deps — `package.json` dependencies={}; verified self-contained by isolated run). Sourcemaps stripped.
- Rebuild: `git clone <upstream> && git checkout 05e8f07 && bun install && bun run build`, then copy `dist/` here and `find -name '*.map' -delete`.
- Override at runtime: export `SSPOWER_CODEX_LSP_CLI=/abs/path/to/cli.js`.
```

- [ ] **Step 4: Verify vendored copy runs standalone**

Run: `node tools/codex-lsp/dist/cli.js 2>&1 | head -1`
Expected: `Usage: codex-lsp [mcp | hook post-tool-use]`

- [ ] **Step 5: Confirm `.gitignore` does not exclude it**

Run: `git check-ignore tools/codex-lsp/dist/cli.js; echo "ignored=$?"`
Expected: `ignored=1` (NOT ignored — exit 1 means not matched). If ignored, add `!tools/codex-lsp/` exception to the repo `.gitignore`.

### Task 2: codex-lsp discovery contract (shared resolver)

**Files:**
- Create: `scripts/lib/codex-lsp-path.mjs` (single source for resolving the cli.js path)

- [ ] **Step 1: Write the resolver**

Create `scripts/lib/codex-lsp-path.mjs`:
```javascript
// Single source of truth for locating the vendored codex-lsp CLI.
// Order: SSPOWER_CODEX_LSP_CLI override → vendored tools/codex-lsp → null (fail-open).
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const PLUGIN_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");

export function resolveCodexLspCli() {
  const override = process.env.SSPOWER_CODEX_LSP_CLI;
  if (override && fs.existsSync(override)) return override;
  const vendored = path.join(PLUGIN_ROOT, "tools", "codex-lsp", "dist", "cli.js");
  if (fs.existsSync(vendored)) return vendored;
  return null; // caller must fail-open (skip + log), never crash
}
```

- [ ] **Step 2: Unit-test the resolver**

Create `tests/codex-bridge/test-lsp-path.sh`:
```bash
#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
R="node -e 'import(\"$ROOT/scripts/lib/codex-lsp-path.mjs\").then(m=>console.log(m.resolveCodexLspCli()))'"
OUT=$(eval "$R")
case "$OUT" in
  */tools/codex-lsp/dist/cli.js) echo "PASS: resolves vendored" ;;
  *) echo "FAIL: expected vendored path, got $OUT"; exit 1 ;;
esac
OUT2=$(SSPOWER_CODEX_LSP_CLI=/nonexistent eval "$R")
case "$OUT2" in
  */tools/codex-lsp/dist/cli.js) echo "PASS: bad override falls back to vendored" ;;
  *) echo "FAIL: override fallback, got $OUT2"; exit 1 ;;
esac
echo "PASS: test-lsp-path"
```

- [ ] **Step 3: Run it**

Run: `bash tests/codex-bridge/test-lsp-path.sh`
Expected: ends `PASS: test-lsp-path`

### Task 3: `~/.codex/lsp-client.json` (Codex sees the language servers)

**Files:**
- Create: `~/.codex/lsp-client.json` (out-of-repo, user-global — like config.toml, plan R1; NOT committed)
- Create: `scripts/setup-codex-lsp.mjs` (idempotent writer, committed; invoked by `codex-bridge.mjs setup`)

- [ ] **Step 1: Write the idempotent setup script**

Create `scripts/setup-codex-lsp.mjs`:
```javascript
#!/usr/bin/env node
// Idempotently writes ~/.codex/lsp-client.json mapping languages to the
// language servers already on PATH. Out-of-repo (user-global), like config.toml.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";

function onPath(bin) {
  try { execFileSync("command", ["-v", bin], { shell: "/bin/bash", stdio: "ignore" }); return true; }
  catch { return false; }
}
const servers = {};
if (onPath("typescript-language-server"))
  servers.typescript = { command: "typescript-language-server", args: ["--stdio"] };
// python/rust/go/c_cpp added only if their servers are present (no hard dep).
for (const [lang, bin, args] of [
  ["python", "pyright-langserver", ["--stdio"]],
  ["rust", "rust-analyzer", []],
  ["go", "gopls", []],
]) if (onPath(bin)) servers[lang] = { command: bin, args };

const dst = path.join(os.homedir(), ".codex", "lsp-client.json");
fs.mkdirSync(path.dirname(dst), { recursive: true });
const next = JSON.stringify({ servers }, null, 2) + "\n";
const prev = fs.existsSync(dst) ? fs.readFileSync(dst, "utf8") : "";
if (prev === next) { console.log("[setup-codex-lsp] up-to-date"); process.exit(0); }
fs.writeFileSync(dst, next);
console.log(`[setup-codex-lsp] wrote ${dst} (${Object.keys(servers).join(",") || "none"})`);
```

- [ ] **Step 2: Run it; verify**

Run: `node scripts/setup-codex-lsp.mjs && node -e 'console.log(JSON.stringify(require(require("os").homedir()+"/.codex/lsp-client.json")))'`
Expected: stdout shows `typescript` mapped to `typescript-language-server --stdio`; file valid JSON.

- [ ] **Step 3: Idempotency check**

Run: `node scripts/setup-codex-lsp.mjs`
Expected: `[setup-codex-lsp] up-to-date`

- [ ] **Step 4: Wire into `codex-bridge.mjs setup`**

In `scripts/codex-bridge.mjs` `cmdSetup()` (locate: `grep -n 'async function cmdSetup' scripts/codex-bridge.mjs`), add a step that runs `setup-codex-lsp.mjs` via `execFileSync(process.execPath, [path.join(BRIDGE_DIR? , "setup-codex-lsp.mjs")], {stdio:"inherit"})` (match existing setup-step style; re-read cmdSetup before editing). Verify: `node scripts/codex-bridge.mjs setup 2>&1 | grep -i lsp` → shows the lsp-client setup line.

### Task 4: B2 — Codex-internal LSP self-repair hook (repo-local, advisory)

**Files:**
- Create: `.codex/hooks.json` (repo-local, committed — Codex worker's own hooks, NOT the plugin's `hooks/`)
- Create: `.codex/codex-lsp-posttool.sh` (thin wrapper resolving the vendored cli + fail-open)

- [ ] **Step 1: Wrapper that fail-opens when codex-lsp absent**

Create `.codex/codex-lsp-posttool.sh`:
```bash
#!/bin/bash
# Codex PostToolUse → codex-lsp diagnostics on the just-edited file.
# Advisory: ALWAYS exit 0 (D-B6 — never blocks Codex until the user flips
# SSPOWER_LSP_SELFREPAIR_BLOCK). Fail-open if codex-lsp unresolved.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$(node -e 'import(process.argv[1]).then(m=>{const p=m.resolveCodexLspCli();process.stdout.write(p||"")})' "$ROOT/scripts/lib/codex-lsp-path.mjs" 2>/dev/null)"
[ -z "$CLI" ] && { echo '{"decision":"approve","reason":"codex-lsp unresolved — advisory skip"}'; exit 0; }
OUT="$(node "$CLI" hook post-tool-use 2>/dev/null || true)"
if [ "${SSPOWER_LSP_SELFREPAIR_BLOCK:-}" = "1" ] && printf '%s' "$OUT" | grep -q '"decision":"block"'; then
  printf '%s\n' "$OUT"; exit 0   # block decision passed through ONLY when gate flipped
fi
# Advisory default: strip any block decision → approve, but keep diagnostics as context.
printf '%s' "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);j.decision="approve";console.log(JSON.stringify(j))}catch{console.log("{\"decision\":\"approve\"}")}})'
exit 0
```

- [ ] **Step 2: Repo-local `.codex/hooks.json`**

Create `.codex/hooks.json`:
```json
{
  "hooks": {
    "PostToolUse": [
      { "matcher": "^(apply_patch|Edit|Write|MultiEdit)$",
        "hooks": [ { "type": "command", "command": "\"${CODEX_PROJECT_DIR:-.}/.codex/codex-lsp-posttool.sh\"", "timeout": 30 } ] }
    ]
  }
}
```
(Mirror the actual codex hooks.json schema codex-lsp's own `hooks/` dir uses — re-read `/tmp/codex-lsp/hooks/` or its README for the exact key names before finalizing; adjust matcher/command keys to match Codex's hook contract, not Claude's.)

- [ ] **Step 3: chmod + advisory invariant test**

Create `tests/codex-bridge/test-lsp-selfrepair-advisory.sh`:
```bash
#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
chmod +x "$ROOT/.codex/codex-lsp-posttool.sh"
# Default (no gate env): even if codex-lsp emits block, wrapper must return approve.
OUT=$(cd "$ROOT" && SSPOWER_LSP_SELFREPAIR_BLOCK= bash .codex/codex-lsp-posttool.sh </dev/null 2>/dev/null || true)
echo "$OUT" | grep -q '"decision":"approve"' && echo "PASS: advisory default = approve" || { echo "FAIL: $OUT"; exit 1; }
echo "PASS: test-lsp-selfrepair-advisory"
```
Run: `bash tests/codex-bridge/test-lsp-selfrepair-advisory.sh` → ends `PASS`.

### Task 5: Per-run MCP fragment for Codex worker runs (B1, §5.7a config side ONLY)

> NOTE: This is the **config registration** so a Codex worker run can call `lsp.*` itself. The **bridge-side post-run MCP client** (`scripts/mcp-lsp-client.mjs`, ~150 LOC JSON-RPC) is **P3**, not here.

**Files:**
- Modify: `scripts/codex-bridge.mjs` (the function that prepares a Codex run's working dir / config — locate where `runCodexExec` sets `-C`/cwd; add per-run `.codex/config.toml` MCP fragment generation + teardown)

- [ ] **Step 1: Locate the run-prep seam**

Run: `grep -nE 'function runCodexExec|cdAbs|args.push\("-C"|secureTmpDir|cleanupTmpDir' scripts/codex-bridge.mjs | head`
Re-read `runCodexExec` (~`grep -n 'function runCodexExec'`) fully before editing.

- [ ] **Step 2: Generate a per-run MCP fragment for implement/resume only**

In `runCodexExec`, when the subcommand is `implement` (and in `runCodexResume`), before spawn: if `resolveCodexLspCli()` is non-null, write into the run's `--cd` dir `.codex/config.toml` a fragment:
```toml
[mcp_servers.lsp]
command = "node"
args = ["<ABS path from resolveCodexLspCli()>", "mcp"]
[mcp_servers.lsp.env]
PATH = "<process.env.PATH>"
HOME = "<os.homedir()>"
```
`required = false` always at P2 (advisory; `required=true` is P3). Track the written path; remove it in the bridge cleanup path (alongside `cleanupTmpDir()`). For `review`/`spec-review`/`plan-review`/`complete`: do NOT write the fragment (no LSP need). Import `resolveCodexLspCli` from `scripts/lib/codex-lsp-path.mjs`.

- [ ] **Step 3: Fail-open + idempotent**

If the run dir already has a user `.codex/config.toml`, **append/merge** the `[mcp_servers.lsp]` block to a bridge-generated sibling include or a clearly-fenced managed region (re-read how Codex merges `.codex/config.toml`; if it does not merge, write the fragment only when no user file exists and log a skip otherwise). Never overwrite a user file. If `resolveCodexLspCli()` is null → write nothing, `logEvent("info","bridge.lsp",{kind:"codex_lsp_unresolved_skip"})`.

- [ ] **Step 4: `--print-args`-style verify (no real spawn)**

Extend the existing `--print-args` dry-run (P1) to also print whether an MCP fragment WOULD be written + its target path for a given subcommand. Run:
```bash
node scripts/codex-bridge.mjs implement --print-args --prompt noop --cd /tmp 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);print("mcp_fragment="+str(d.get("mcpFragment","<none>")))'
```
Expected: for `implement` → a `.codex/config.toml` path under `/tmp`; for `review` (`review --print-args ...`) → `<none>`.

### Task 6: P2 smoke + REAL dogfood (mandatory — not dry-run-only)

- [ ] **Step 1: `lsp.status` smoke (real Codex, read-only)**

Run:
```bash
node scripts/codex-bridge.mjs implement --cd /tmp --prompt "Call the lsp.status MCP tool and report its raw output. Do not edit any file." > /tmp/p2-smoke.log 2>&1
grep -iE 'lsp|status|codex:done|error' /tmp/p2-smoke.log | tail -5
```
Expected: exit 0; log shows Codex invoked the `lsp` MCP server (no `service_tier` 400; no MCP-connection failure). If codex-lsp unresolved, the bridge fail-opens (logged skip) — acceptable, note it.

- [ ] **Step 2: Seeded-error self-repair dogfood (advisory)**

```bash
D=$(mktemp -d); cd "$D"; git init -q; printf 'export const x: number = "not a number";\n' > bad.ts
node "$OLDPWD/scripts/codex-bridge.mjs" implement --write --cd "$D" --prompt "Fix the TypeScript type error in bad.ts so it compiles. Keep it one line." > /tmp/p2-repair.log 2>&1
cat "$D/bad.ts"; grep -iE 'codex:done|_lsp|decision|error' /tmp/p2-repair.log | tail -5; cd "$OLDPWD"
```
Expected: `bad.ts` now type-correct (e.g. `export const x: number = 0;`); run exit 0; in advisory mode the run is NOT blocked regardless of intermediate diagnostics (D-B6). Capture this as the spec §9 P2 success evidence.

- [ ] **Step 3: D-B6 promotion mechanics documented + log-grep verified**

Append to `docs/ARCHITECTURE.md` a "Codex LSP self-repair (P2, advisory)" note: gate env **`SSPOWER_LSP_SELFREPAIR_BLOCK=1`** flips advisory→block; promotion precondition = operator confirms **≥10** consecutive runs whose `~/.claude/sspower/codex.log` show no unresolved `_lsp`/self-repair regressions. Verify the grep recipe works:
```bash
grep -c 'kind=disabled_passthrough\|bridge.lsp' ~/.claude/sspower/codex.log 2>/dev/null || echo 0
```
Expected: runs without error (count ≥0). The note must state the env name, the count (10), and this exact grep.

### Task 7: P2 commit

- [ ] **Step 1: Stage**

Run: `git add tools/codex-lsp scripts/lib/codex-lsp-path.mjs scripts/setup-codex-lsp.mjs scripts/codex-bridge.mjs .codex/ tests/codex-bridge/test-lsp-path.sh tests/codex-bridge/test-lsp-selfrepair-advisory.sh docs/ARCHITECTURE.md && git status --porcelain`
Expected: vendored tree + new scripts/tests staged; no `~/.codex/*` (out-of-repo).

- [ ] **Step 2: Commit (standalone — chokepoint)**

```bash
git commit -m "feat(p2): Track B B1+B2 — vendor codex-lsp (MIT, pinned 05e8f07), lsp-client setup, advisory self-repair hook"
```
Expected: succeeds (no `docs/plans/*` staged; not a push).

---

# PHASE P6 — Cleanup C4–C9 (sequential after P2; no spike precondition)

> Spec §7 / §9 P6. No *dependency* on B* (pure cleanup) but executed **after** P2, **sequentially** — one SDD worker per task, no parallel implementation subagents.

### Task 8: C6 — stale `.git/sspower-review-rounds-*` auto-cleanup

**Files:** Modify `hooks/auto-review.sh` (round-counter logic — locate `grep -n 'sspower-review-rounds' hooks/auto-review.sh`)

- [ ] **Step 1:** Re-read the round-counter read/write block. Add: on a clean `approve` verdict for a branch, `rm -f` that branch's `.git/sspower-review-rounds-<branch>` file (reset rounds after success). Also at top of the round logic, prune `sspower-review-rounds-*` files older than 7 days: `find "$(git rev-parse --git-dir)" -maxdepth 1 -name 'sspower-review-rounds-*' -mtime +7 -delete 2>/dev/null || true`.
- [ ] **Step 2:** `bash -n hooks/auto-review.sh` → OK. Simulate: `touch -t 202501010000 "$(git rev-parse --git-dir)/sspower-review-rounds-stale-test"; ` then run the prune line standalone; confirm the stale file is gone, a fresh one survives.

### Task 9: C8 — `SSPOWER_DIET=off` permanent disable

**Files:** Modify `hooks/diet-activate.js` (or the SessionStart diet hook — locate `grep -rl SSPOWER_DIET hooks/`)

- [ ] **Step 1:** Re-read the diet-activation hook. At the top, if `process.env.SSPOWER_DIET === "off"` → emit nothing (no diet directive) and exit 0. Preserve all other behavior.
- [ ] **Step 2:** Verify: `SSPOWER_DIET=off node hooks/diet-activate.js </dev/null` → empty/no diet block; unset → normal diet output. Add `tests/hooks/test-diet-off.sh` asserting both.

### Task 10: C9 — schema validation for `resume`/`complete`

**Files:** Modify `scripts/codex-bridge.mjs` (`cmdResume`, `cmdComplete`)

- [ ] **Step 1:** Re-read `cmdResume`. It accepts an optional `--schema`/default schema. Add: when a schema is in effect, validate the parsed structured output against it (reuse the same validation path `cmdImplement` uses — `grep -n 'output-schema\|validate\|ajv\|schemaPath' scripts/codex-bridge.mjs`; mirror that). On invalid: surface a structured error, non-zero exit (consistent with `cmdImplement`).
- [ ] **Step 2:** `cmdComplete` already builds OpenAI shape — add a guard: if `_runCodexComplete` produced no `lastMessage`, emit the existing `_emitCompleteError` path (don't silently emit empty content). Re-read `_runCodexComplete` return contract first.
- [ ] **Step 3:** Verify via `--print-args` + a stubbed run (extend `test-complete.sh`): `complete` with empty model output → structured error, non-zero. `node --check` OK.

### Task 11: C5 — document/wire real env knobs

**Files:** Modify `docs/ARCHITECTURE.md`; audit `scripts/codex-bridge.mjs` + `hooks/` for `SSPOWER_LOG_*` / unread env

- [ ] **Step 1:** `grep -rnE 'SSPOWER_[A-Z_]+' scripts/ hooks/ | sort -u` → produce the actual env-var inventory. Cross-check against ARCHITECTURE's documented list.
- [ ] **Step 2:** For each env var read in code but undocumented → add to ARCHITECTURE env table. For each documented but never read (`SSPOWER_LOG_*` suspected) → either wire it (if trivially intended) or delete the doc line. Decide per-var with the grep evidence; record the disposition inline.
- [ ] **Step 3:** Verify: every `SSPOWER_*` in the ARCHITECTURE table has ≥1 `grep` hit in `scripts/`/`hooks/`; no code-read env var is missing from the table.

### Task 12: C7 — auto-apply patch audit trail / opt-out visibility

**Files:** Modify `hooks/auto-review.sh` (the `proposed-fixes`/`git apply --3way` auto-apply path — locate `grep -n 'proposed-fixes\|git apply\|AUTO_APPLY' hooks/auto-review.sh`)

- [ ] **Step 1:** Re-read the auto-apply block. After a successful auto-apply, append a line to `<repo>/.claude/sspower/applied-patches.log`: ISO ts, branch, round, patch file, `git rev-parse HEAD`. Create dir if needed; best-effort (never crash the hook).
- [ ] **Step 2:** Ensure the existing `SSPOWER_REVIEW_AUTO_APPLY=off` path is logged too (kind=auto_apply_skipped) so opt-out is visible. Verify by simulating both branches with a fake patch + grep the log.

### Task 13: C4 — hook integration tests

**Files:** Create `tests/hooks/test-integration.sh` (chain policy, verdict assembly, round cap)

- [ ] **Step 1:** Write tests asserting: (a) chain policy — the real `auto-review.sh` chain branch (NOT a `chained-shell-check.sh`; no such plugin hook exists, and `git commit` is not a chokepoint) denies a chained `git push && echo` and allows a standalone `git push > f` (hook driven directly with crafted PreToolUse JSON on stdin); (b) `auto-review.sh` round-cap: with `sspower-review-rounds-<b>` = `SSPOWER_REVIEW_MAX_ROUNDS`, the hook short-circuits (assert via log/exit, no Codex spawn — stub bridge via `CLAUDE_PLUGIN_ROOT`); (c) **verdict assembly** (spec C4's third area — SSOT over the plan's earlier "verdict cache hit" wording): drive the real `COMBINED_VERDICT` precedence ladder + fail-closed `unknown` default + deny-payload/`kind="deny_verdict"` assembly + multi-source `_source`-tagged merge (auto-review.sh ~:505-688). Verdict-cache-hit coverage is ALSO included as additive bonus (the cache is real and worth testing — same-diff-hash-twice → 2nd cache-served). Each assertion isolated, no network.
- [ ] **Step 2:** Run `bash tests/hooks/test-integration.sh` → all PASS. These are the spec §9 P6 success criterion ("hook integration tests green").

### Task 14: P6 commit

- [ ] **Step 1:** `git add hooks/ scripts/codex-bridge.mjs tests/hooks/ docs/ARCHITECTURE.md && git status --porcelain`
- [ ] **Step 2 (standalone):** `git commit -m "chore(p6): cleanup C4-C9 — rounds-file GC, SSPOWER_DIET=off, resume/complete schema validation, env-knob audit, patch audit log, hook integration tests"`

---

# P3 / P4 / P5 — ROADMAP ONLY (re-plan per trigger; do NOT implement from this doc)

These are PROVISIONAL (spec v6 status header). They are intentionally **not** task matrices — each depends on the prior phase's real-world outcomes (spec D-B6, §5.7a/b). Implementing them from speculative detail now would violate the no-placeholder rule and re-introduce the churn P1 spent 30+ review passes eliminating.

### P3 — Bridge-side LSP gate + repair loop (spec Phases B3+B4, §5.7a, §5.7b, D-B3, D-B7)
- **Scope:** `scripts/mcp-lsp-client.mjs` (~150 LOC minimal JSON-RPC-over-stdio MCP client: `initialize` → `tools/call lsp.diagnostics` per changed file → id correlation → Content-Length framing → per-call 30s / gate 120s timeout → `shutdown`); bridge post-run gate (changed files via `git diff --name-only baseHead` → MCP diagnostics → `_lsp`/`_verification` schema fields per §5.7); repair loop with the 7 §5.7b termination conditions; advisory `_lsp.decision ∈ {clean,would-block,block}`; fail-OPEN on infra.
- **Re-plan trigger:** P2 shipped AND operator confirms ≥10 clean advisory self-repair runs (Task 6 Step 3 mechanism) AND codex-lsp `mcp` stdio mode manually smoke-tested working. → invoke `writing-plans` for P3 with the P2 dogfood evidence + measured codex-lsp MCP behavior as inputs.
- **Why not now:** the MCP client's exact framing/lifecycle (§5.7a) must be written against codex-lsp's *observed* MCP wire behavior, not its docs — unknown until P2's vendored copy is exercised.

### P4 — Codex Stop gate + rules/sandbox profiles (spec Phases B5+B6, D-B4, D-B5)
- **Scope:** `.codex/hooks.json` Stop hook (depends on P3's MCP query path); `.codex/rules/sspower.rules` (forbid git commit/push, rm -rf; prompt on installs); bridge profile `approval_policy=never`+`sandbox_mode=workspace-write`+`network_access=false`; interactive `on-request`+auto_review.
- **Re-plan trigger:** P3 shipped AND bridge `_lsp.decision` repair loop converges in real use. → `writing-plans` for P4.
- **Why not now:** Stop gate reuses P3's MCP client; rules profile interacts with P3's repair-resume — both unbuilt.

### P5 — semble_rs context + command rewrite (spec Phase B7, D-B6)
- **Scope:** `UserPromptSubmit` coding-intent-gated `semble_rs plan`/`search --compact` context inject (advisory, length-capped); `PreToolUse:Bash` rewrite `ls -R`→`semble_rs tree`, bare `grep -R`→`semble_rs search --compact` (allow/ask, never deny); `SessionStart` availability check + warm; `PostToolUse:Write|Edit` codex-lsp on Claude's own edits (advisory).
- **Re-plan trigger:** P2–P4 shipped AND `semble_rs` re-validated on a *current working* repo (spec §2 spike was `~/Mine/kimp` pre-P1) — measure search/tree token deltas + warm latency fresh. → `writing-plans` for P5.
- **Why not now:** spec §2 explicitly marks semble_rs pre-1.0/unproven; the rewrite hooks touch every Bash call — must follow P2–P4 proving the advisory-first machinery safe.

---

## Verification matrix (P2 + P6 acceptance — spec §9)

| Criterion | Command | Expected |
|---|---|---|
| P2: codex-lsp vendored, runs | `node tools/codex-lsp/dist/cli.js 2>&1 \| head -1` | `Usage: codex-lsp [mcp \| hook post-tool-use]` |
| P2: license present | `grep -c 'MIT' tools/codex-lsp/LICENSE` | ≥1 |
| P2: resolver | `bash tests/codex-bridge/test-lsp-path.sh` | `PASS: test-lsp-path` |
| P2: lsp-client.json | `node scripts/setup-codex-lsp.mjs` ×2 | 2nd run `up-to-date` |
| P2: advisory invariant | `bash tests/codex-bridge/test-lsp-selfrepair-advisory.sh` | `PASS` |
| P2: smoke (real) | Task 6 Step 1 | exit 0, no 400, MCP reached or logged fail-open |
| P2: self-repair dogfood (real) | Task 6 Step 2 | `bad.ts` type-correct, run not blocked |
| P6: C9 | extended `test-complete.sh` | empty-output → structured error, nonzero |
| P6: C8 | `tests/hooks/test-diet-off.sh` | PASS both states |
| P6: C4 | `tests/hooks/test-integration.sh` | all PASS |
| P6: C5 | env grep cross-check | no undocumented code-read env; no dead doc env |
| Bridge integrity | `node --check scripts/codex-bridge.mjs` | OK |
| Regression | `tests/codex-bridge/test-complete.sh` | PASS=14 (or updated count) |

## Risks & assumptions

- **R1 — codex-lsp v0.1.0, pre-1.0.** Mitigated: vendored+pinned (`05e8f07`); advisory-only (D-B6); fail-open everywhere (`resolveCodexLspCli()` null → skip+log, never crash).
- **R2 — Codex hook schema for `.codex/hooks.json` may differ from Claude's.** Task 4 Step 2 explicitly requires re-reading codex-lsp's own `hooks/` dir / Codex docs for the real key names before finalizing — do not assume Claude's hook JSON shape.
- **R3 — Codex `.codex/config.toml` merge semantics unknown** (Task 5 Step 3). The plan mandates: never overwrite a user file; if Codex doesn't merge fragments, write only when absent + log skip. Verify Codex's actual merge behavior at execution; if it can't merge, P2 MCP-registration degrades to "only when no user .codex/config.toml" — acceptable for advisory P2.
- **R4 — `/tmp/codex-lsp` is transient.** Task 1 Step 1 has the rebuild path (clone+checkout 05e8f07+bun build). bun + typescript-language-server confirmed on PATH.
- **R5 — out-of-repo state.** `~/.codex/lsp-client.json` (Task 3) and `~/.codex/config.toml` are user-global, NOT committed (plan R1). Re-run `codex-bridge.mjs setup` after any environment rebuild.
- **R6 — session scope (honest).** This plan is authored in an already-very-long session. Execution order: **P2 then P6** via subagent-driven-development; a `docs/handoff.md` is written at the natural break; **P3+ resume in a fresh session** (their re-plan triggers gate them anyway). Do not attempt P3–P5 in this continuation.
- **Assumption:** Codex tier stays default/`fast` (P1 config, out-of-repo). No Track B code sets `service_tier` ([[project-codex-service-tier-flex-unsupported]]).

## Execution Handoff

**Plan complete. Executable scope = P2 + P6. Three execution options:**
1. **Subagent-Driven (recommended)** → sspower:subagent-driven-development (P2 Tasks 1–7, then P6 Tasks 8–14)
2. **Inline Execution** → sspower:executing-plans
3. **Codex execute** → `codex-bridge.mjs implement --write`

P3–P5 are roadmap-only — each re-plans via `writing-plans` when its trigger fires (NOT executed from this document).

**Which approach?**
