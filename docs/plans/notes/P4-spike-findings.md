# P4 Task 0 — Verification spike findings

> Executed 2026-05-18 (main-thread, branch `feat/codex-worker-trackC`). Empirical re-confirmation of statically-resolved unknowns + the D-4a resume-hardening security probe.

## Version

```
$ codex --version
codex-cli 0.130.0
```
Native blob: `/Users/sskys/.nvm/versions/node/v22.22.1/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex`

Contract vocabulary present:
```
approval_policy
network_access
on-request
sandbox_workspace_write
StopCommandOutputWire
```

> **Plan bug found:** Task 0 Step 1's `find … -maxdepth 3 …` is too shallow — the native blob is ~5 levels under `node_modules/@openai`. Resolver must drop `-maxdepth` (or use a deeper cap). Plan corrected.

## Stop contract

Both binary strings present:
- `Stop hook returned decision:block without a non-empty reason` → block requires `{decision:"block","reason":<non-empty>}`
- `Stop hook exited with code 2 but did not write a continuation prompt to stderr` → exit-2 + stderr continuation also accepted

`-c` help: `Override a configuration value … Use a dotted path (foo.bar.baz) to override nested values.` → `-c 'sandbox_workspace_write.network_access=false'`, `-c 'approval_policy="never"'` valid.

Confirms: Codex 0.130 hook contract == Claude Code's (D-2). No bimodal placeholder.

## Override syntax

`-c, --config <key=value>`, dotted-path for nested. Confirmed.

## Network blast radius

```
$ grep -nE 'fetch\(|https?://|npm (i|install)|pnpm (i|install)|curl |wget ' scripts/codex-bridge.mjs | grep -viE '//|^\s*\*'
195:    die("codex CLI not found. Install with: npm install -g @openai/codex");
```
Single hit = the codex-CLI-not-found install-hint string at `:195`. **Non-blocking diagnostic text**, NOT a Codex-spawned implement-run network dependency. D-5 confirmed.

## Resume inheritance (D-4a) — **CONFIRMED GAP, closable in code**

Codex 0.130 `codex exec --json` uses `thread_id` (not `session_id`). `codex exec resume` rejects `-C` (uses spawn cwd — matches bridge comment codex-bridge.mjs:424) but **accepts `-c`** (bridge already passes `-c model_reasoning_effort` there).

| Probe | Flags | Result |
|---|---|---|
| Origin `codex exec` | `--sandbox workspace-write -c approval_policy="never" -c sandbox_workspace_write.network_access=false` | `NET_BLOCKED` (network off works) |
| `codex exec resume <tid>` — **mimics `runCodexResume`** (`--json` only, no `--sandbox`/`-c` hardening) | none | **`RESUME_NET_OK`** ← network **ON** |
| `codex exec resume <tid>` + the two hardening `-c` flags | `-c sandbox_workspace_write.network_access=false -c approval_policy="never"` | `HARDENED_NET_BLOCKED` (network off restored) |

**Conclusion:** `codex exec resume` does **NOT** inherit the originating session's `network_access=false`/`approval_policy`. As shipped, `runLspRepairLoop` → `runCodexResume` repair rounds run **network-ON** even when `cmdImplement --write` hardened the origin session — a security regression introduced by P4's own gate (Codex has unrestricted network precisely while editing files to fix diagnostics). **The gap IS closable in code**: `codex exec resume` accepts the two `-c` hardening flags and they take effect (`HARDENED_NET_BLOCKED`).

**Disposition:** D-1..D-6 confirmed; **D-4a = CONFIRMED GAP → resume-accepts-`-c` → close in code** (Task 4 Step 8, "resume-accepts-c" branch): add a `hardenWrite` option to `runCodexResume`, push `-c 'approval_policy="never"'` + `-c 'sandbox_workspace_write.network_access=false'` when set, and set `hardenWrite:true` at the `runLspRepairLoop` → `runCodexResume` call (codex-bridge.mjs:1431-1433). Add a `--print-args` test asserting the resume path carries both flags. Proceed.
