# sspower Architecture

End-to-end overview of the plugin: layout, components, integration points, and runtime behavior. Aimed at maintainers and power users who need to know what runs when, where state lives, and how the pieces compose.

For upstream-fork delta only, see [CUSTOMIZATIONS.md](CUSTOMIZATIONS.md). For Codex CLI install, see [README.codex.md](README.codex.md).

## Identity

- **Plugin name:** `sspower` (`.claude-plugin/plugin.json`)
- **Version:** `1.1.0`
- **Origin:** `git@github.com:sskys18/sspower.git`
- **Upstream:** `obra/superpowers` v5.0.5 (synced via `upstream` remote)

## Directory layout

```
sspower/
├── .claude-plugin/plugin.json   # Plugin manifest (name, version, keywords)
├── CLAUDE.md                    # Plugin-scoped instructions (loaded by Claude Code)
├── README.md                    # User-facing overview, install, flow diagram
├── package.json                 # ESM root; hooks/package.json overrides to CJS
│
├── skills/<skill>/SKILL.md      # 22 skills + per-skill references/
├── hooks/                       # Lifecycle hooks (SessionStart, UserPromptSubmit, PreToolUse, …)
├── scripts/                     # codex-bridge.mjs, codex-registry.mjs
├── agents/                      # Subagent prompts (code-reviewer, codex-rescue)
├── commands/                    # Slash command entrypoints (.toml/.md)
├── schemas/                     # Structured-output JSON schemas for Codex
├── docs/                        # This doc, plans, specs, customization notes
├── tests/                       # Skill & brainstorm-server tests
└── .claude/sspower/             # Per-repo runtime state (followups, proposed-fixes)
```

Per-cwd artifacts written by hooks live outside the plugin:

```
<cwd>/.claude/wiki/sessions/<id>.{json,md}    # Project wiki, archived per session
<cwd>/.git/sspower-review-rounds-<branch>     # Auto-review iteration counter
<cwd>/.claude/sspower/followups.md            # Advisory issues from approve-with-followups
<cwd>/.claude/sspower/proposed-fixes/round-N.patch  # Codex-suggested patches (auto-applied)
~/.claude/state/sspower/codex/<id>.json       # Codex session registry
~/.claude/state/sspower/codex/<id>.events.jsonl
~/.cache/sspower/verdicts/<hash>.json         # Verdict cache (10min TTL)
```

## Skills (22)

Skills are loaded on demand by Claude Code's skill router. Each is one directory with `SKILL.md` and optional `references/`. Trigger discipline: Claude must invoke any skill whose description matches the request — even at 1% probability — via the `Skill` tool. `using-sspower` runs every turn as a backup router.

### Process / methodology

| Skill | Purpose |
|-------|---------|
| `using-sspower` | Meta-router. Fires every turn, surfaces relevant skills. |
| `brainstorming` | Design before code. Reads project wiki for prior decisions. |
| `writing-plans` | Multi-step plan from spec. HARD-GATE: runs `bridge spec-review`. |
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
| `codex-enrich` | Send a user prompt to Codex, return enriched prompt validated against the codebase. |
| `codex-tracking` | List / inspect / kill / steer running bridge sessions. |
| `codex-diagnostics` | Triage `~/.claude/sspower/codex.log` failures. |

### Diet mode + tooling

| Skill | Purpose |
|-------|---------|
| `diet` | Token-efficient response mode (lite / full / ultra / off). |
| `diet-commit` | Compact Conventional Commit messages. |
| `diet-review` | One-line PR comments (location, problem, fix). |
| `compress-memory` | Compress natural-language memory files. |

## Hooks

Configured in `hooks/hooks.json`. ESM root with hooks dir overridden to CJS via `hooks/package.json` (`{"type":"commonjs"}`).

| Event | Hook | Sync? | Purpose |
|-------|------|-------|---------|
| `SessionStart` | `session-start` | sync | Boot tasks (wiki link, state dirs). |
| `SessionStart` | `diet-activate.js` | sync, 5s | Activate diet mode (default `full`). |
| `UserPromptSubmit` | `prompt-submit` | sync | Inject project wiki + global rules. |
| `UserPromptSubmit` | `diet-track.js` | sync, 5s | Reinforce diet on each turn. |
| `UserPromptSubmit` | `codex-track-prompt.sh` | sync, 2s | Surface running/recent codex sessions. |
| `PreToolUse:Bash` | `cmd-rewrite.sh` | sync, 3s | Optional command rewriter (`rtk`) for token savings. |
| `PreToolUse:Bash` | `auto-spec-gate.sh` | sync, 600s | Spec-review gate at SDD chokepoints. |
| `PreToolUse:Bash` | `auto-review.sh` | sync, 600s | Codex review gate at git/gh chokepoints. |
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

**Verdict assembly** (parallel main + security review):

1. Spawn main + security codex reviewers in parallel (security disabled when `SSPOWER_SECURITY_REVIEW=off` or `SSPOWER_SECURITY_EFFORT=off`).
2. Each verdict normalized to `{approve, approve-with-followups, needs-attention, unknown}` — anything else falls to `unknown` (denies).
3. Disabled security reviewer treated as `approve` (single-reviewer mode); enabled-but-empty raw response → `unknown` (fail closed).
4. Combined verdict: any `unknown` → `unknown`; else any `needs-attention` → `needs-attention`; else any `approve-with-followups` → `approve-with-followups`; else `approve`.
5. Result wrapped via `jq` → `{"verdict": "...", "issues": [...]}`. Jq failure also → `unknown`.

**Loop guards** (defense against runaway review chains):

| Guard | Mechanism |
|-------|-----------|
| Re-entry | `SSPOWER_REVIEW_IN_FLIGHT=1` set by bridge before spawning codex |
| Depth | `SSPOWER_REVIEW_DEPTH >= 1` skips |
| Per-repo opt-out | `<repo>/.sspower-skip-auto-review` |
| Verdict cache | `~/.cache/sspower/verdicts/<diff-hash>.json`, 10min TTL |
| Round counter | `<repo>/.git/sspower-review-rounds-<branch>`, capped at 3 |
| Branch tier | `wip/*`, `tmp/*`, `draft/*`, `scratch/*` skip; `main`, `master`, `prod`, `release/*` always strict |

**Tunables** (env):

```
# Auto-review (hooks/auto-review.sh)
SSPOWER_AUTO_REVIEW=off               # Full bypass (emergencies)
SSPOWER_REVIEW_TIMEOUT=90             # Per-call codex timeout (s)
SSPOWER_REVIEW_CACHE_TTL=600          # Verdict cache TTL (s; 10min)
SSPOWER_REVIEW_MAX_ROUNDS=3           # Iterations before hard cap
SSPOWER_REVIEW_AUTO_APPLY=on          # Auto-apply codex's suggested patches
SSPOWER_REVIEW_PROFILE                # Override round-aware main-review profile (unset → tier-derived)
SSPOWER_SECURITY_REVIEW=on            # Run security reviewer in parallel
SSPOWER_SECURITY_EFFORT=xhigh         # Reasoning effort for security pass
SSPOWER_SECURITY_REPOS                # ':'-list of repo paths forced to security tier (built-in default list)
SSPOWER_SANITY_REVIEW=off             # Enable extra sanity pass (set on)
SSPOWER_SANITY_EFFORT=medium          # Sanity-pass effort (off|low|medium|high|xhigh)
SSPOWER_REVIEW_SKIP_PATTERN           # Branch-name globs that skip review
SSPOWER_REVIEW_STRICT_PATTERN         # Branch-name globs forced to xhigh

# LSP gate (scripts/codex-bridge.mjs, .codex/codex-lsp-posttool.sh, scripts/lib/codex-lsp-path.mjs)
SSPOWER_LSP_GATE_BLOCK=1              # Promote bridge B3/B4 post-run gate would-block → block (default advisory)
SSPOWER_LSP_SELFREPAIR_BLOCK=1       # Promote B2 self-repair PostToolUse hook to blocking (default advisory)
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

Defaults: governed by `~/.codex/config.toml` profiles. The bridge maps each subcommand to a profile via `COMMAND_PROFILE` (`complete`→`quick`; `implement`/`review`/`spec-review`/`plan-review`→`normal`) and passes `-p <profile>`. **`resume` is excluded — `codex exec resume` has no `--profile`; it inherits root `config.toml` (root `service_tier=flex` is load-bearing) and only emits explicit `--model`/`--effort` overrides.** Explicit `--profile`/`--model`/`--effort` patch individual fields of the selected profile (see `scripts/codex-bridge.mjs` `parseOpts`/`runCodexExec`). `auto-review.sh` security pass keeps `xhigh` via `SSPOWER_SECURITY_EFFORT`.

### Subcommands

| Command | Sandbox | Persistent? | Schema |
|---------|---------|-------------|--------|
| `setup` | n/a | n/a | Self-test: codex-bin reachable, schemas present |
| `implement [--write]` | `read-only` / `workspace-write` | yes (resume-able) | `implementation-output` |
| `spec-review` | `read-only` | no (ephemeral) | `spec-review-output` |
| `review` | `read-only` | no (ephemeral) | `quality-review-output` |
| `rescue [--write]` | `read-only` / `workspace-write` | persist on `--write` | none |
| `resume --session-id <id>` | inherits | yes | optional via prompt-wrapping |
| `enrich` | `read-only` | no | none |
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
| `/diet-commit` | `diet-commit` skill |
| `/diet-review` | `diet-review` skill |
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
├── sessions/<session-id>.json   # Structured sidecar (decisions, files, gotchas)
├── sessions/<session-id>.md     # Human-readable summary
├── decisions.md                 # Auto-aggregated, append-only
├── gotchas.md                   # Auto-aggregated, append-only
└── index.md                     # One row per session
```

`brainstorming`, `writing-plans`, and `systematic-debugging` read `decisions.md` + `gotchas.md` before proposing work, so prior context informs every new design and bug investigation.

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
| `proposed-fixes/round-N.patch` | Codex's suggested patches | Auto-applied via `git apply --3way` when `SSPOWER_REVIEW_AUTO_APPLY=on` (default) |

`.claude/` is typically already gitignored; if not, add `.claude/` (or `.claude/sspower/`) to the consuming-repo `.gitignore`.

## Configuration cheat sheet

| Concern | Where |
|---------|-------|
| Plugin metadata | `.claude-plugin/plugin.json` |
| Hook registration | `hooks/hooks.json` |
| Skill instructions | `skills/<name>/SKILL.md` |
| Codex CLI defaults | `~/.codex/config.toml` (model, sandbox, profiles, projects.trust_level) |
| Auto-review tunables | env vars (`SSPOWER_AUTO_REVIEW`, `SSPOWER_REVIEW_*`, `SSPOWER_SECURITY_*`) |
| Per-repo opt-out | `<repo>/.sspower-skip-auto-review` |
| Per-call codex options | `--profile`, `--model`, `--effort`, `--cd`, `--write`, `--worktree`, `--auto-commit` |
| Session state | `~/.claude/state/sspower/codex/<id>.{json,events.jsonl}` |
| Verdict cache | `~/.cache/sspower/verdicts/<hash>.json` (10min TTL) |
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

## Sync with upstream

```bash
git fetch upstream
git merge upstream/main   # or rebase; resolve keeping sspower customizations
```

Watch for upstream changes to `using-superpowers` (we override with `using-sspower`), removed-from-fork files (see CUSTOMIZATIONS.md), and `commands/` (deprecated upstream, replaced by skills).

## Reference docs

- [README.md](../README.md) — user-facing overview
- [CUSTOMIZATIONS.md](CUSTOMIZATIONS.md) — fork delta vs upstream
- [README.codex.md](README.codex.md) — Codex CLI install + auth
- [MAINTENANCE.md](MAINTENANCE.md) — fork maintenance guide
- [codex-tracking.md](codex-tracking.md) — registry parity table, schema, caveats
- [auto-review-followups.md](auto-review-followups.md) — followup file conventions
- [testing.md](testing.md) — skill + brainstorm-server tests
- [handoff.md](handoff.md) — handoff skill conventions
