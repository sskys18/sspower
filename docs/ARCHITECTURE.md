# sspower Architecture

End-to-end overview of the plugin: layout, components, integration points, and runtime behavior. Aimed at maintainers and power users who need to know what runs when, where state lives, and how the pieces compose.

For project history and customizations, see [CUSTOMIZATIONS.md](CUSTOMIZATIONS.md). For Codex CLI install, see [README.codex.md](README.codex.md).

## Identity

- **Plugin name:** `sspower` (`.claude-plugin/plugin.json`)
- **Version:** `1.1.1`
- **Origin:** `git@github.com:sskys18/sspower.git`

## Directory layout

```
sspower/
├── .claude-plugin/plugin.json   # Plugin manifest (name, version, keywords)
├── CLAUDE.md                    # Plugin-scoped instructions (loaded by Claude Code)
├── README.md                    # User-facing overview, install, flow diagram
├── package.json                 # ESM root; hooks/package.json overrides to CJS
│
├── skills/<skill>/SKILL.md      # 19 skills + per-skill references/
├── hooks/                       # Lifecycle hooks (SessionStart, UserPromptSubmit, PreToolUse, …)
├── scripts/                     # codex-bridge.mjs, codex-registry.mjs, graph-append-dirty.py, graph-with-lock.py
├── agents/                      # Subagent prompts (code-reviewer, codex-rescue, security-reviewer, sanity-reviewer)
├── bin/                         # On-PATH entrypoints: sspower-mem, sspower-graph.mjs, sspower-graph-bootstrap.sh
├── .mcp.json                    # Plugin-root MCP server declaration (sspower-graph)
├── commands/                    # Slash command entrypoints (.toml/.md)
├── schemas/                     # Structured-output JSON schemas for Codex
├── docs/                        # This doc, plans, specs, customization notes
├── tests/                       # Skill, hook, graph & brainstorm-server tests
├── __tests__/                   # vitest harness for sspower-graph fixture suite
└── .claude/sspower/             # Per-repo runtime state (followups, proposed-fixes)
```

Per-cwd artifacts written by hooks live outside the plugin:

```
<cwd>/.claude/wiki/sessions/<id>.json         # Per-session JSON sidecar (legacy belt; .md no longer written — Phase E)
<cwd>/.git/sspower-review-rounds-<branch>     # Auto-review iteration counter
<cwd>/.claude/sspower/followups.md            # Advisory issues from approve-with-followups
<cwd>/.claude/sspower/proposed-fixes/round-N.patch  # Codex-suggested patches (auto-applied)
~/.claude/state/sspower/codex/<id>.json       # Codex session registry
~/.claude/state/sspower/codex/<id>.events.jsonl
~/.cache/sspower/verdicts/<hash>.json         # Verdict cache (24h TTL for approve, 10min for other verdicts)
```

## Skills (19)

Skills are loaded on demand by Claude Code's skill router. Each is one directory with `SKILL.md` and optional `references/`. Trigger discipline: Claude must invoke any skill whose description matches the request — even at 1% probability — via the `Skill` tool. Routing is driven by the `prompt-submit` hook + `_intent.sh` classifier (see Hooks); `using-sspower` is the skill *reference/catalog*, consulted on demand — not a per-turn router.

### Process / methodology

| Skill | Purpose |
|-------|---------|
| `using-sspower` | Skill reference/catalog. Consulted on demand; the `prompt-submit` hook does the routing. |
| `brainstorming` | Design before code. Reads project wiki for prior decisions. |
| `writing-plans` | Multi-step plan from spec. HARD-GATE: runs `bridge plan-review` (findings-shaped review of the plan; distinct from `spec-review` which checks impl-vs-spec compliance). |
| `executing-plans` | Walk a written plan with checkpoints. |
| `subagent-driven-development` | Independent-task execution with per-task `bridge spec-review` + `bridge review`. |
| `dispatching-parallel-agents` | Fan out 2+ independent tasks. |
| `systematic-debugging` | Bug / test failure / unexpected behavior. 4-phase investigation, reads wiki gotchas. |
| `test-driven-development` | RED-GREEN-REFACTOR. |
| `verification-before-completion` | Run actual checks before claiming done. |
| `requesting-code-review` | Trigger review for completed work. |
| `receiving-code-review` | Process incoming review feedback. |
| `second-opinion` | Independent codex-backed review when stuck or before merge. |
| `finishing-a-development-branch` | Final step: HARD-GATE `bridge review` on full branch diff. |
| `using-git-worktrees` | Isolated branch creation. Read-only env detection for sandbox-aware skills. |
| `writing-skills` | Author / edit / verify a skill. |

### Codex integration

| Skill | Purpose |
|-------|---------|
| `codex-tracking` | List / inspect / kill / steer running bridge sessions. |
| `codex-diagnostics` | Triage `~/.claude/sspower/codex.log` failures. |

### Diet mode + tooling

| Skill | Purpose |
|-------|---------|
| `diet` | Token-efficient response mode (lite / full / ultra / off); also governs commit-message + code-review formatting. |
| `compress-memory` | Compress natural-language memory files. |

## Hooks

Configured in `hooks/hooks.json`. ESM root with hooks dir overridden to CJS via `hooks/package.json` (`{"type":"commonjs"}`).

| Event | Hook | Sync? | Purpose |
|-------|------|-------|---------|
| `SessionStart` | `session-start` | sync | Boot tasks (wiki link, state dirs). |
| `SessionStart` | `diet-activate.js` | sync, 5s | Activate diet mode (default `full`). |
| `SessionStart` | `semble-session.sh` | sync, 5s | semble/codex-lsp availability + detached warm. |
| `UserPromptSubmit` | `prompt-submit` | sync | Workflow-engine router: classify intent (`_intent.sh`), auto-start a flow on multi-step work, else inject one targeted skill trigger. |
| `UserPromptSubmit` | `diet-track.js` | sync, 5s | Reinforce diet on each turn. |
| `UserPromptSubmit` | `codex-track-prompt.sh` | sync, 2s | Surface running/recent codex sessions. |
| `UserPromptSubmit` | `semble-context.sh` | sync, 8s | Coding-intent `semble_rs plan` inject (advisory). |
| `PreToolUse:Bash` | `semble-rewrite.sh` | sync, 3s | **Runs FIRST.** `ls -R`->`semble_rs tree` & `grep -R ident`->`semble_rs search`, both explicit ASK, gitignore-aware. Owns these 2 patterns. |
| `PreToolUse:Bash` | `cmd-rewrite.sh` | sync, 3s | `rtk` token-saver for ALL OTHER commands (git/read/find/gh/pnpm...). Receives `semble_rs ...` for the 2 patterns and passes through (no rtk equiv). |
| `PreToolUse:Bash` | `auto-spec-gate.sh` | sync, 600s | Spec-review gate at SDD chokepoints. |
| `PreToolUse:Bash` | `auto-review.sh` | sync, 600s | Codex review gate at git/gh chokepoints. |
| `PostToolUse:Write\|Edit\|MultiEdit` | `codex-lsp-posttool.sh` | sync, 6s | De-fanged advisory LSP on Claude's edits. |
| `PreCompact` | `wiki-archive.sh` | async | Archive session into `<cwd>/.claude/wiki/`. |
| `SessionEnd` | `wiki-archive.sh` | async | Same as PreCompact, on natural exit. |

### `auto-review.sh` (push gate)

Intercepts `git push`, `git merge`, `gh pr create`, `gh pr ready` (NOT `gh pr merge` — by then the diff was already reviewed). Runs Codex review on `BASE..HEAD` diff and blocks unless verdict is `approve` or `approve-with-followups`.

**Chain policy** (security-critical):

- Chokepoints must run as standalone Bash invocations.
- Predecessors with `&&`, `||`, `;`, `&` are denied (could mutate state before review).
- Successors are denied except read-only output pipes (`| tail`, `| grep`, `| jq`, `| sed`, `| awk`, `| head`, `| tee`, …).
- Use `git -C <path> push`, never `cd <path> && git push`.

To capture push output: `git push > /tmp/push.log 2>&1` on its own line, then read the file.

**Verdict assembly** (single MAIN reviewer):

1. Spawn one codex MAIN reviewer on the branch diff. Security + sanity reviewers were removed from auto-review — invoke `agents/security-reviewer.md` (vuln pass) or `agents/sanity-reviewer.md` (independent second opinion) manually via the Agent tool when wanted.
2. Verdict normalized to `{approve, approve-with-followups, needs-attention, unknown}` — anything else falls to `unknown` (denies).
3. Empty MAIN response (all reviewers timed out): `kind=codex_timeout_allow` → exit 0 ALLOW (infra-failure carve-out).
4. Result wrapped via `jq` → `{"verdict": "...", "issues": [...]}`. Jq failure → `unknown` (denies).

**Loop guards** (defense against runaway review chains):

| Guard | Mechanism |
|-------|-----------|
| Re-entry | `SSPOWER_REVIEW_IN_FLIGHT=1` set by bridge before spawning codex |
| Depth | `SSPOWER_REVIEW_DEPTH >= 1` skips |
| Per-repo opt-out | `<repo>/.sspower-skip-auto-review` |
| Verdict cache | `~/.cache/sspower/verdicts/<diff-hash>.json`, split TTL: 24h (approve/approve-with-followups), 10min (other) |
| Round counter | `<repo>/.git/sspower-review-rounds-<branch>`, capped at 3 |
| Branch tier | `wip/*`, `tmp/*`, `draft/*`, `scratch/*` skip; `main`, `master`, `prod`, `release/*` always strict |

**Tunables** (env):

```
# Auto-review (hooks/auto-review.sh)
SSPOWER_AUTO_REVIEW=off               # Full bypass (emergencies)
SSPOWER_REVIEW_TIMEOUT=90             # Per-call codex timeout (s)
SSPOWER_REVIEW_CACHE_TTL=600          # Non-approve verdict cache TTL (s; 10min)
SSPOWER_REVIEW_APPROVE_TTL=86400       # Approve-class verdict cache TTL (s; 24h)
SSPOWER_REVIEW_MAX_ROUNDS=3           # Iterations before hard cap
# Auto-apply was removed: suggested patches are saved to
# <repo>/.claude/sspower/proposed-fixes/round-N.patch for manual review.
# Inspect the patch and `git apply` it yourself if the diff is acceptable.
SSPOWER_REVIEW_PROFILE                # Override round-aware main-review profile (unset → tier-derived)
SSPOWER_REVIEW_SKIP_PATTERN           # Branch-name globs that skip review
SSPOWER_REVIEW_STRICT_PATTERN         # Branch-name globs forced to xhigh
# Security + sanity reviewers were removed from auto-review.sh.
# Invoke on demand via subagents:
#   agents/security-reviewer.md  — vuln / auth / crypto pass
#   agents/sanity-reviewer.md    — independent second opinion (real-blocker-only)

# LSP gate (scripts/codex-bridge.mjs, .codex/codex-lsp-posttool.sh, scripts/lib/codex-lsp-path.mjs)
SSPOWER_LSP_GATE_BLOCK=1              # Promote bridge B3/B4 post-run gate would-block → block (default advisory)
SSPOWER_LSP_SELFREPAIR_BLOCK=1       # Promote B2 self-repair PostToolUse hook to blocking (default advisory)
SSPOWER_CODEX_STOP_GATE=1            # Promote P4 Codex Stop hook would-block → block (default advisory; D-B6)
SSPOWER_CODEX_LSP_CLI                 # Override codex-lsp CLI path (unset → vendored tools/codex-lsp → fail-open)

# Diet hooks (hooks/diet-*.js)
SSPOWER_DIET=off                      # Kill switch — diet hooks fully inert
SSPOWER_DIET_DEFAULT                  # Default diet mode (lite|full|ultra; overrides diet.json)

# Codex log rotation (hooks/_log.sh)
SSPOWER_LOG_FILE                      # Log path (default ~/.claude/sspower/codex.log)
SSPOWER_LOG_MAX_LINES=1000            # Rotate when log exceeds this many lines
SSPOWER_LOG_KEEP_TAIL=500             # Lines retained after rotation
```

When the round counter hits 3 without converging, the hook emits a deny pointing to: `rm <repo>/.git/sspower-review-rounds-<branch>` to retry, or `SSPOWER_AUTO_REVIEW=off` to bypass.

## Codex bridge (`scripts/codex-bridge.mjs`)

> **Canonical source:** Claude Code loads the **marketplace** tree
> (`~/.claude/plugins/marketplaces/sskys18/plugins/sspower/scripts/codex-bridge.mjs`),
> registered via `~/.claude/settings.json` (`source_type=local`). The
> `~/.codex/plugins/cache/sskys18/sspower/<version>/scripts/codex-bridge.mjs`
> copy is stale dead weight — never edit it, never rely on it. All bridge
> edits target the marketplace tree (decision D-C1).

Direct integration with the Codex CLI (`@openai/codex`). Skills, agents, and the auto-review hook all dispatch through this bridge — no separate Claude Code plugin involved.

Defaults: governed by `~/.codex/config.toml` profiles. The bridge maps each subcommand to a profile via `COMMAND_PROFILE` (`complete`→`quick`; `implement`/`review`/`spec-review`/`plan-review`→`normal`) and passes `-p <profile>`. **`resume` is excluded — `codex exec resume` has no `--profile`; it inherits root `config.toml` (root `service_tier=flex` is load-bearing) and only emits explicit `--model`/`--effort` overrides.** Explicit `--profile`/`--model`/`--effort` patch individual fields of the selected profile (see `scripts/codex-bridge.mjs` `parseOpts`/`runCodexExec`).

### Subcommands

| Command | Sandbox | Persistent? | Schema |
|---------|---------|-------------|--------|
| `setup` | n/a | n/a | Self-test: codex-bin reachable, schemas present |
| `implement [--write]` | `read-only` / `workspace-write` | yes (resume-able) | `implementation-output` |
| `spec-review` | `read-only` | no (ephemeral) | `spec-review-output` |
| `review` | `read-only` | no (ephemeral) | `quality-review-output` |
| `rescue [--write]` | `read-only` / `workspace-write` | persist on `--write` | none |
| `resume --session-id <id>` | inherits | yes | optional via prompt-wrapping |
| `ps` / `status` / `tail` / `kill` / `steer` | n/a | session registry ops |

`--write` switches sandbox to `workspace-write`. All write paths take optional `--cd`, `--worktree <branch>`, `--auto-commit [msg]`.

### Sandbox model

Codex CLI runs every `exec` invocation under a Seatbelt sandbox. Two relevant modes:

| Mode | Filesystem | Network |
|------|------------|---------|
| `read-only` | reads anywhere; no writes | none |
| `workspace-write` | writes confined to cwd subtree | configurable per `~/.codex/config.toml` |

The bridge passes `--sandbox <mode>` to every `codex exec`. There is no `danger-full-access` opt-in path in sspower — by design.

**Required `~/.codex/config.toml` (host-level)**:

```toml
[sandbox_workspace_write]
network_access = true                # pnpm install / git fetch unblocked
exclude_tmpdir_env_var = false       # $TMPDIR writable
exclude_slash_tmp = false            # /tmp writable
```

**Linked-worktree gotcha:** in a worktree at `<repo>/.worktrees/<name>/`, the worktree-private gitdir lives at `<repo>/.git/worktrees/<name>/` — *outside* cwd. Under `workspace-write`, codex's `git add` fails with `Operation not permitted` on `index.lock`. Bridge does NOT auto-grant write access to that gitdir (would expose taint surface — see autoCommit guards below); instead, prompts that need git operations should let the bridge handle commits via `--auto-commit`, or the user runs git on the host afterward.

### `autoCommit` guards (`--auto-commit`)

Runs after `codex exec` returns DONE, with full host perms. Two refusal conditions, both intended as defense-in-depth even though codex currently has no gitdir write path:

1. **HEAD snapshot mismatch.** Bridge reads `git rev-parse HEAD` before `codex exec`, stashes as `baseHead`. After codex returns, re-reads HEAD; if changed, refuses to commit and emits `[codex:auto-commit] Refused: HEAD changed during codex run`. Prevents tainted commit parents.
2. **Planted commit-state files.** Checks `MERGE_HEAD`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`, `REBASE_HEAD` via `git rev-parse --verify -q`. If any exists, refuses (would create unintended merge / cherry-pick parent).

On refusal: returns `null`, the implement command surfaces the warning to stderr, no commit is created. User inspects manually.

### Session registry

Every persistent run writes:

- `~/.claude/state/sspower/codex/<id>.json` — current state record (status, phase, dur, tools/edits/execs counters, tokens, error)
- `~/.claude/state/sspower/codex/<id>.events.jsonl` — event log (one JSON object per line, append-only)

States: `running` → `done` (exit 0) | `failed` (exit non-0) | `killed` (SIGTERM via `bridge kill`). Stale-zombie detection via `kill -0 <pid>`.

The `codex-track-prompt.sh` UserPromptSubmit hook scans the registry and injects a one-line summary of running + recently-finished (<5min) sessions on every turn. Hook timeout 2s; silent when no sessions.

CLI surfaces (all read the registry):

```
codex-bridge.mjs ps                          # All active+recent
codex-bridge.mjs status <session_id>         # JSON state record
codex-bridge.mjs tail <session_id>           # Stream events live
codex-bridge.mjs kill <session_id>           # SIGTERM, mark killed
codex-bridge.mjs steer --session-id <id> --prompt <p>   # Kill + resume with new prompt
```

Equivalent slash command: `/codex-track`. Skill: `codex-tracking`.

Registry writes are best-effort — failures disable registry for the run but never crash the bridge.

## Agents (`agents/`)

| Agent | Trigger | Backing |
|-------|---------|---------|
| `code-reviewer` | After major project step. Reviews against original plan + standards. | Claude (inherits parent model). |
| `codex-rescue` | Stuck after 2+ fix attempts. Hands work to Codex via bridge. | Codex via `codex-bridge.mjs`. |

Both consume the same context the parent has, but with focused per-agent prompts.

## Schemas (`schemas/`)

Structured-output contracts passed to `codex exec --output-schema`. Codex returns JSON conforming to the schema, parsed by the bridge into `result.structured`.

| Schema | Used by |
|--------|---------|
| `implementation-output.json` | `bridge implement` |
| `spec-review-output.json` | `bridge spec-review` |
| `quality-review-output.json` | `bridge review` |

Resume mode (`bridge resume`) doesn't support `--output-schema`, so the bridge wraps the prompt with explicit JSON instruction and parses the response text.

## Slash commands (`commands/`)

| Command | Skill / target |
|---------|----------------|
| `/diet [lite\|full\|ultra\|off]` | `diet` skill |
| `/codex-track` | `codex-tracking` skill |

Each command is a `.toml` (or `.md`) entrypoint that invokes the matching skill.

## Skill HARD-GATEs

Three skills enforce the same Codex review at earlier checkpoints than the push hook, so issues surface before reaching `git push`:

1. `writing-plans` → `bridge spec-review` before handing off.
2. `subagent-driven-development` → `bridge spec-review` + `bridge review` per task.
3. `finishing-a-development-branch` → `bridge review` on full branch diff before merge / PR.

Skill-level gates complement the hook-level gate. Bypass: `SSPOWER_AUTO_REVIEW=off` (rare; intended for emergencies only).

## Project wiki

Each session is archived (PreCompact + SessionEnd) into `<cwd>/.claude/wiki/`:

```
<cwd>/.claude/wiki/
└── sessions/<session-id>.json   # Structured JSON sidecar — legacy belt (removed in Phase F)
```

Phase E: the per-session `.md` summary is no longer written — its content is
ingested into `sspower-mem` as an `episodic` block. `append_index_entry` is
removed (no `index.md`); `decisions.md`/`gotchas.md` seeding is dropped.
`brainstorming`, `writing-plans`, and `systematic-debugging`
read/write decisions + gotchas via the `sspower-mem` CLI, so prior context
informs every new design and bug investigation.

JSON sidecars are also symlinked into `~/.claude/sessions/` for cross-project tooling (e.g. daily-rollup skills).

## Diet mode

SessionStart hook activates `full` by default. Per-turn `diet-track.js` reinforces to prevent drift.

| Level | Effect |
|-------|--------|
| `lite` | Drop pleasantries / hedging only |
| `full` | Drop articles, fragments OK, short synonyms (default) |
| `ultra` | Telegraph mode, max compression |
| `off` | Normal prose |

**Always exempt** (write normal): code blocks, commits, security warnings, error quotations.

Toggle: `/diet <level>`, "stop diet", "normal mode". Persists until session end or change.

## Per-repo state (`<cwd>/.claude/sspower/`)

| File | Source | Purpose |
|------|--------|---------|
| `followups.md` | `approve-with-followups` verdicts | Advisory issues to address later |
| `proposed-fixes/round-N.patch` | Codex's suggested patches | Saved for manual review only (auto-apply was removed). Read the patch and `git apply` it yourself if accepted. |

`.claude/` is typically already gitignored; if not, add `.claude/` (or `.claude/sspower/`) to the consuming-repo `.gitignore`.

## Configuration cheat sheet

| Concern | Where |
|---------|-------|
| Plugin metadata | `.claude-plugin/plugin.json` |
| Hook registration | `hooks/hooks.json` |
| Skill instructions | `skills/<name>/SKILL.md` |
| Codex CLI defaults | `~/.codex/config.toml` (model, sandbox, profiles, projects.trust_level) |
| Auto-review tunables | env vars (`SSPOWER_AUTO_REVIEW`, `SSPOWER_REVIEW_*`) |
| Per-repo opt-out | `<repo>/.sspower-skip-auto-review` |
| Per-call codex options | `--profile`, `--model`, `--effort`, `--cd`, `--write`, `--worktree`, `--auto-commit` |
| Session state | `~/.claude/state/sspower/codex/<id>.{json,events.jsonl}` |
| Verdict cache | `~/.cache/sspower/verdicts/<hash>.json` (24h TTL for approve, 10min for other) |
| Bridge log | `~/.claude/sspower/codex.log` (failures/diagnostics) |

## Codex LSP self-repair (P2, advisory)

Track B P2 gives Codex worker runs the same language servers and an
internal LSP self-repair path. **Advisory only** (spec D-B6): nothing
blocks Codex until an operator explicitly flips the gate after reviewing
clean runs.

**Two independent paths:**

1. **B1 — LSP MCP server.** `codex-bridge.mjs` registers the vendored
   `tools/codex-lsp/dist/cli.js mcp` as `mcp_servers.lsp` via per-run
   `-c mcp_servers.lsp.*` dotted-path overrides on `implement`/`resume`
   only (never review/spec-review/plan-review/complete). No file is
   written — Codex 0.130.0 merges only `~/.codex/config.toml` + `-c`
   overrides + profiles, never a project-local `.codex/config.toml`, so
   `-c` is the clobber-free mechanism. Fail-open: if codex-lsp is
   unresolved, nothing is registered and the bridge logs
   `bridge.lsp kind=codex_lsp_unresolved_skip`, never crashing.
2. **B2 — PostToolUse hook.** Repo-local `.codex/hooks.json` runs
   `.codex/codex-lsp-posttool.sh` after Codex edits. In advisory default
   it strips codex-lsp's `block` decision to `approve`; it passes the
   `block` through **only** when `SSPOWER_LSP_SELFREPAIR_BLOCK=1`.

**Known boundary — B1 MCP round-trip not functional at P2 (verified
2026-05-18, evidence chain):**

- Registration **is consumed** by Codex 0.130.0: a `lsp.status` smoke
  produced `item.mcp_tool_call` events, exit 0, no `service_tier` 400.
- The tool call **fails**: `status:"failed"`, error `"user cancelled
  MCP tool call"` — despite no human in the loop.
- **Sandbox ruled out:** identical failure under `read-only` and
  `workspace-write`.
- **`approval_policy=never` ruled out:** identical failure with
  explicit `-c approval_policy=never` (debug log still shows
  `ResolveElicitation{ server:"lsp", request_id:
  "mcp_tool_call_approval_...", decision: Cancel }`).
- **Granular knobs ruled out:** identical failure with
  `approval_policy={granular={mcp_elicitations=true,...}}` +
  `approvals_reviewer=auto_review`.
- **codex-lsp server is healthy standalone:** `node
  tools/codex-lsp/dist/cli.js mcp` answers `initialize`
  (protocolVersion 2024-11-05), `tools/list` (7 tools) AND
  `tools/call status` (18ms, full result) over newline-delimited
  JSON-RPC, no stderr.
- **Confirmed root cause:** Codex 0.130.0 gates every MCP tool call
  behind a per-call approval/elicitation
  (`mcp_tool_call_approval_*`) **distinct from `approval_policy`**.
  In non-interactive `codex exec` it auto-resolves `decision:
  Cancel`. The ONLY config that lets the round-trip complete is
  `--dangerously-bypass-approvals-and-sandbox` (verified: tool call
  `status:"completed"`, full LSP status returned) — which also
  **disables the sandbox entirely**. No documented per-server trust
  key, granular flag, or `approvals_reviewer` setting bypasses it
  without also disabling the sandbox. Not a defect in the vendoring,
  resolver, hook, or `-c` registration (each verified working).

**This finding validates the planned P3 architecture.** Spec §5.7a /
Phase B3 (**P3**) specifies `scripts/mcp-lsp-client.mjs` — a
bridge-side MCP client that queries codex-lsp **directly** (the bridge
speaks JSON-RPC to `cli.js mcp` itself, post-run, per changed file).
That path **never traverses Codex's model tool-call approval gate** —
it is the exact bridge↔codex-lsp channel proven working standalone
(initialize + tools/list + tools/call status, 18ms). So routing LSP
through Codex's *model* (B1-via-`-c mcp_servers`) is the dead end;
routing it through the *bridge* (P3) structurally sidesteps the
Codex 0.130.0 approval gate. The standalone handshake above **is**
the P3 re-plan trigger evidence ("codex-lsp `mcp` stdio mode manually
smoke-tested working").

The bridge-computed `_lsp` is injected into the runtime structured
result object post-parse; it is deliberately NOT declared in
`schemas/implementation-output.json` because OpenAI strict
structured-output (`--output-schema`) forbids optional properties and
open objects — declaring it 400s the Codex API.

**P2 §9 acceptance:** clause 2 ("Codex self-repairs a seeded TS error
in advisory mode") is **met** — the B2 hook path repaired `export
const x: number = "not a number";` → `export const x: number = 0;`,
advisory, run not blocked. Clause 1 ("lsp.status smoke passes") was
initially blocked: B1-via-Codex-model registration is consumed and the
codex-lsp server is healthy, but the Codex-model→MCP round-trip is
blocked by Codex 0.130.0's per-tool-call approval gate (only
`--dangerously-bypass-approvals-and-sandbox` overrides it, at
unacceptable security cost) — **now resolved by the bridge-side gate
below**, not a bridge approval-bypass.

### B1 resolution — bridge-side LSP gate (B3+B4, shipped)

The bridge no longer asks Codex's *model* to call `lsp.*`. Instead
`scripts/mcp-lsp-client.mjs` (a minimal newline-delimited
JSON-RPC-2.0-over-stdio MCP client) is spawned by `codex-bridge.mjs`
**after** an `implement`/`resume` run completes and queries the
vendored `codex-lsp mcp` server **directly**, per changed file
(`diagnostics`, `severity:"error"`). Because this bridge↔codex-lsp
channel never traverses Codex's model tool-call path, it **structurally
sidesteps the 0.130.0 per-tool-call approval gate** that blocked
B1-via-model.

- **Gate** (`runLspGate`): changed files = committed-since-baseHead ∪
  unstaged ∪ staged ∪ untracked, filtered to LSP-serviceable
  extensions; result normalized into bridge-injected
  `result.structured._lsp` (D-B1: bridge truth overrides Codex
  self-report). `_lsp` is injected post-parse and is **not** in the
  JSON-Schema file (see strict-output note above).
- **Repair loop** (`runLspRepairLoop`): ≤2 `codex exec resume` rounds,
  terminating on the seven §5.7b conditions; `_lsp.decision ∈
  {clean, would-block, block}`.
- **Advisory default (D-B6):** `decision="would-block"`, run not
  failed. `SSPOWER_LSP_GATE_BLOCK=1` promotes to `block` (distinct
  from B2's `SSPOWER_LSP_SELFREPAIR_BLOCK`; independently promotable).
- **Fail-open (D-B7):** unresolved codex-lsp / MCP init fail / per-file
  or 120s-gate timeout → `_lsp.status ∈ {skipped, unavailable}`, gate
  passes, logged `bridge.lsp …`.

**Verified end-to-end (2026-05-18 dogfood, real Codex):** a seeded
`bad.ts` (`export const x: number = "not a number";`) → gate detected
the error → repair loop fired (`repair_rounds: 1`) → Codex `resume`
fixed it → re-gate `_lsp:{status:"clean",decision:"clean"}`, run exit
0. A clean run reported `_lsp.status="clean"`, `repair_rounds:0`. In
both runs **zero** `user cancelled MCP tool call` — confirming the
bridge-direct path bypasses the Codex approval gate. **Spec §9 P2/P3
clause 1 is now met via the bridge gate**, not the in-Codex MCP path.

**Promotion (advisory → block), per-phase, never automated (D-B6):**
the operator confirms **≥10** consecutive `implement`/`resume` runs
whose `~/.claude/sspower/codex.log` shows no unresolved `_lsp` /
self-repair regressions, then exports `SSPOWER_LSP_SELFREPAIR_BLOCK=1`
to flip B2 from advisory to blocking. Audit recipe:

```bash
grep -c 'kind=disabled_passthrough\|bridge.lsp' ~/.claude/sspower/codex.log 2>/dev/null || echo 0
```

(runs without error; count ≥0 — a count of 0 means no unresolved-skip
or passthrough events were logged, i.e. codex-lsp resolved cleanly).

## P4 — Codex Stop gate + rules/sandbox profiles (Track C, shipped)

P4 (spec Phases B5+B6, D-B4/D-B5) hardens the worker on three axes.
Codex 0.130's hook system is a **port of Claude Code's** — verified
against the native binary (`struct StopCommandOutputWire`; errors
`"Stop hook returned decision:block without a non-empty reason"`,
`"… exited with code 2 …"`). `.codex/hooks.json` now carries three
events:

- **`PreToolUse`** → `.codex/codex-guard-pretool.sh` (B6/D-B4),
  matcher `.*` (fire on every tool — the Codex 0.130 shell
  `tool_name` token is not pinned: the blob shows `bash`/`exec`/`run`
  AND `local_shell`/`exec_command`; an anchored matcher that missed
  the real token would be a silent total bypass, so the in-script
  classifier is the sole authority and no-ops `allow` on tools with
  no command):
  **threat model = cooperative worker, NOT an adversary.** It
  pattern-classifies the command in node (segment split + per-segment
  regex; more robust than bash substring but **not** a full shell
  parser) and emits the Claude-ported `permissionDecision` — `deny`
  for `git commit|push|merge` & recursive `rm`, `ask` for
  `npm|pnpm|yarn` installs, else allow. **deny** fires only when the
  resolved git subcommand is exactly `commit`/`push`/`merge` — so
  `git merge-base`/`merge-tree`/`merge-file` are allowed (the
  `sub === "merge"` exact check). D-B4's deny scope is specifically
  history/remote mutation (`commit`/`push`/`merge`); `merge-base` and
  `merge-tree` are read-only queries, and while `merge-file` does
  rewrite a local file it is an ordinary file edit — not a
  git-history/remote op — so it is intentionally outside this guard's
  policy (the same as any other file write the guard does not
  police). For
  the git/rm deny matrix it handles the routine evasion shapes a
  cooperative worker produces — path-qualified bins (`/usr/bin/git`),
  `git -C/-c` global opts, `rm` flag variants (`-r -f`,
  `--recursive`, `-fr`), and **one** level of `bash -c`/`sh -c`. The
  **`ask`** install rule matches `npm install|npm i|npm ci|pnpm
  install|pnpm add|yarn install|yarn add` as a word-bounded match on
  the (one-level-unwrapped) command string — it is NOT
  segment-anchored or path-qualified (cooperative-worker scope; a
  non-leading occurrence can still `ask`, which is low-harm; tracked
  in followups). It does **NOT** defend against
  deliberate adversarial evasion — **shell quoting/escaping evasion
  of the deny matcher** (exotic/concatenated quoting, `$'…'`,
  variable/`$(…)` expansion of the binary or subcommand), **git
  global-option forms outside the recognised set** (the strip-list of
  `git` global options is finite; an *unrecognised* global token
  before the subcommand can cause the matcher to read that token as
  the subcommand and miss the real `commit`/`push`/`merge`), deeper
  shell nesting, `xargs`, `find -exec`, `eval`, command
  substitution. The guard handles the routine cooperative forms
  (bare, single/double-quoted and `=`-form values with spaces,
  backslash-escaped spaces, the common `-C`/`-c`/`--git-dir`/
  `--work-tree`/… globals) but a regex classifier **cannot** fully
  reproduce shell word-splitting + git option parsing; exhaustive
  parse is architecturally out of scope at the PreToolUse layer. The real
  perimeter for adversarial cases is the hardened sandbox +
  `approval_policy=never` + `network_access=false` below; this hook
  is advisory + defense-in-depth on the routine path. Fail-open.
- **`PostToolUse`** → existing codex-lsp advisory (P2), unchanged.
- **`Stop`** → `.codex/codex-lsp-stop.sh` (B5): runs
  `codex-bridge.mjs lsp-check` (a thin CLI over the shipped
  bridge-direct `runLspGate` — **never** model-issued MCP, per the
  0.130 approval-gate finding). Advisory by default;
  `SSPOWER_CODEX_STOP_GATE=1` emits `{decision:"block",reason}` so
  Codex keeps fixing in-session. D-B7 fail-open everywhere, including
  reason-escaping failure → no block (never malformed JSON).

**Hardened write profile (B6/D-B5).** `runCodexExec` gains
`hardenWrite`; when set it appends `-c approval_policy="never"` and
`-c sandbox_workspace_write.network_access=false` after `--sandbox`.
`cmdImplement` ties it to `--write` only — `spec-review`/`plan-review`/
`review` stay `read-only`, unhardened (D-4).

**D-4a (security, empirically resolved).** Task-0 spike proved
`codex exec resume` does **not** inherit the originating session's
`network_access=false` (a resumed session ran `curl` successfully)
but **does** accept the two `-c` flags (with them, blocked). So
`runCodexResume` gains the same `hardenWrite` gate, and **every**
write-capable resume caller — `runLspRepairLoop` (gate-triggered
repair), `cmdResume` (SDD fix-loop), `cmdSteer` — passes
`hardenWrite:true`. Without this, gate-triggered repair rounds would
run network-ON precisely while Codex edits files. (Codex's own LLM
API channel is unaffected by the sandbox network knob — only
model-spawned shell network is denied.)

`SSPOWER_CODEX_STOP_GATE` is advisory→block per D-B6 (operator-gated,
never automated), independent of `SSPOWER_LSP_GATE_BLOCK` /
`SSPOWER_LSP_SELFREPAIR_BLOCK`.

### P5 - semble_rs context layer (Phase B7, advisory)

Four Claude-side hooks, all advisory + fail-open (D-B6; semble_rs/codex-lsp pre-1.0, R1):

- `hooks/semble-context.sh` (UserPromptSubmit) - coding-intent-gated
  `semble_rs plan` repo orientation injected as `additionalContext`, char-capped,
  6 s hard timeout, fail-open. Coding-intent gate shares the `_intent.sh`
  classifier with `prompt-submit`.
- `hooks/semble-rewrite.sh` (PreToolUse:Bash, **runs FIRST** - before
  cmd-rewrite & auto-review) -
  `ls -R` -> `semble_rs tree` (gitignore-correct, DP-1; UPPERCASE-R only) and
  `grep -R <BARE_IDENT>` -> `semble_rs search --compact` (semantic != literal, DP-2),
  BOTH via explicit `permissionDecision:"ask"` (single emit path - no
  auto-allow surface; rewrites change semantics so are always confirmed).
  NEVER deny. Bails on any compound command; emitted paths shell-quoted.

  **Hook ordering is load-bearing (2026-05-19).** Claude Code chains
  `updatedInput` across sibling PreToolUse hooks in array order. When
  `cmd-rewrite` ran first (shipped P5), rtk rewrote `ls -R`/`grep -R` to
  `rtk ...` and the chained `semble-rewrite` no longer matched -> P5's
  rewrite was dead. Fix = `semble-rewrite` first; it owns the 2 patterns,
  emits `semble_rs ...`+ask, and `cmd-rewrite` passes that through (rtk
  has no `semble_rs` equivalent, exit 1). This corrects the shipped P5
  plan's DP-3 assumption (it claimed semble-rewrite would no-op as
  already-rewritten; it actually no-op'd because rtk-prefixed - wrong
  reason, zero value). rtk keeps its broad token-saving surface for
  every other command. Spec: `docs/specs/2026-05-19-semble-rewrite-ownership-design.md`.
- `hooks/semble-session.sh` (SessionStart) - availability line + DETACHED model
  warm (cold = one-time ~60 MB dl; never blocks session start).
- `hooks/codex-lsp-posttool.sh` (PostToolUse:Write|Edit|MultiEdit) - vendored
  codex-lsp on the just-edited file, **de-fanged**: codex-lsp's native
  `decision:block` is stripped; only `additionalContext` surfaces (advisory, D-B6).

OUT OF SCOPE (P5): advisory -> block promotion (D-B6, operator-gated, separate step);
`semble_rs digest`; PreToolUse:Read deny-guard; Claude-side Stop block-gate
(spec §11). The `grep` -> semantic-search mismatch is bounded by the bare-identifier
gate + ask-only, accepted as a lossy-but-visible convenience, not a correctness path.

## sspower-graph (P3 shipped at 1.4.0-rc.0)

Per-project symbol graph subsystem inspired by codegraph (MIT). Built on
ast-grep, exposed to Claude Code + sub-agents via MCP stdio.

**Status:** P0/P1/P2 shipped at 1.3.0. P3 ship candidate is
1.4.0-rc.0: seven MCP tools (`graph_status`, `graph_callers`,
`graph_callees`, `graph_trace`, `graph_impact`, `graph_node`,
`graph_context`), per-project session-state lookup, and graph MCP
adoption metrics. CLI surface remains: `build`, `refresh`,
`session-refresh`, `callers`, `callees`, `trace`, `impact`, `context`,
`node`, `status`, `metric`. Languages indexed: TypeScript, JavaScript,
Python, Go, Rust (each fixture-gated at P≥0.85, R≥0.70). Perf gates:
10k-file build <60s, warm callers p95 <1s, MCP representative tool p95
tracked via `tests/graph/perf-mcp.mjs`.

**Entry points:**

| Path | Role |
|------|------|
| `.mcp.json` | Plugin-root MCP server declaration. Registers `sspower-graph` with `command = bin/sspower-graph-bootstrap.sh`. |
| `bin/sspower-graph.mjs` | CLI + MCP stdio server. P3 exposes 7 graph query tools and the `metric` CLI aggregator. Uses `@modelcontextprotocol/sdk` with `ListToolsRequestSchema` / `CallToolRequestSchema`. |
| `bin/sspower-graph-bootstrap.sh` | Lazy `bun install` wrapper invoked by `.mcp.json`. Enforces Node ≥22, preserves caller cwd, and fails fast on MCP server-key collisions. |
| `hooks/_intent.sh` (`architecture` class) | Routes prompts like "callers of X" / "how does X reach Y" / "trace X" so future graph-context hook (P4) can inject without colliding with the qa guard. |
| `scripts/graph-append-dirty.py` | JSONL appender for `<cwd>/.claude/graph/dirty`. Reuses `sspower_mem.lock.acquire_lock` (anchored, O_NOFOLLOW). |
| `scripts/graph-with-lock.py` | Holds `<cwd>/.claude/graph/.lock` for the duration of a child process. Brackets the cross-language Node↔Python SQLite transaction (P2). |
| `scripts/graph/mcp-tools/` | P3 per-tool MCP handlers, dispatcher, and metric writer/reconciler. |
| `__tests__/graph-fixtures/` | vitest fixture harness plus P2 CLI back-compat goldens. |
| `tests/graph/test-mcp-integration.mjs` | Executable MCP smoke through bootstrap (StdioClientTransport → initialize → tools/list → tools/call for 7 tools). |

**Hard deps (P0):** ast-grep ≥0.43 (brew), Node ≥22 (bootstrap-enforced),
bun (committed `bun.lock`), `@modelcontextprotocol/sdk` ^1.0, vitest ^2.1.

**Per-cwd state:**
```
<cwd>/.claude/graph/index.sqlite      # WAL-mode SQLite cache
<cwd>/.claude/graph/dirty             # JSONL: {op,path} per PostToolUse event
<cwd>/.claude/graph/.lock             # POSIX fcntl flock anchor
<cwd>/.claude/graph/version           # schema rev + ast-grep version + git_filesethash
~/.claude/state/sspower/sessions/<sha8>.json       # P3 per-project session id
~/.claude/state/sspower/graph-mcp/sessions.json    # P3 adoption metrics
```

**Spec + plan:**
- [docs/specs/2026-05-26-codegraph-style-graph-design.md](specs/2026-05-26-codegraph-style-graph-design.md) — 5 codex plan-review passes to `approve-with-followups`. 40 locked decisions.
- [docs/specs/2026-05-27-codegraph-graph-P3-design.md](specs/2026-05-27-codegraph-graph-P3-design.md) — P3 MCP expansion + metric design.
- [docs/plans/2026-05-26-codegraph-graph-P0.md](plans/2026-05-26-codegraph-graph-P0.md) — P0 plan, `approve` verdict.
- [docs/plans/2026-05-27-codegraph-graph-P3.md](plans/2026-05-27-codegraph-graph-P3.md) — P3 implementation plan.
- [docs/codegraph-graph-P0-followups.md](codegraph-graph-P0-followups.md) — A1/A2/A3 resolved inline.

**Anti-goal circuit-breaker:** if the full MCP layer (P3) exceeds 2 weeks,
ship `codegraph install` companion via sspower installer instead. Don't
sunk-cost rebuilding what's MIT-licensed and already shipping at
[colbymchenry/codegraph](https://github.com/colbymchenry/codegraph).

## Reference docs

- [README.md](../README.md) — user-facing overview
- [CUSTOMIZATIONS.md](CUSTOMIZATIONS.md) — project history and customizations
- [README.codex.md](README.codex.md) — Codex CLI install + auth
- [MAINTENANCE.md](MAINTENANCE.md) — maintenance guide
- [codex-tracking.md](codex-tracking.md) — registry parity table, schema, caveats
- [auto-review-followups.md](auto-review-followups.md) — followup file conventions
- [testing.md](testing.md) — skill + brainstorm-server tests
- [handoff.md](handoff.md) — handoff skill conventions
- [specs/2026-05-26-codegraph-style-graph-design.md](specs/2026-05-26-codegraph-style-graph-design.md) — sspower-graph design spec
- [plans/2026-05-26-codegraph-graph-P0.md](plans/2026-05-26-codegraph-graph-P0.md) — sspower-graph P0 plan
