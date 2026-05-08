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
| `codex-diagnostics` | Triage `~/.claude/sspower-codex.log` failures. |

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
SSPOWER_AUTO_REVIEW=off               # Full bypass (emergencies)
SSPOWER_REVIEW_TIMEOUT=90             # Per-call codex timeout (s)
SSPOWER_REVIEW_CACHE_TTL=600          # Verdict cache TTL (s)
SSPOWER_REVIEW_MAX_ROUNDS=3           # Iterations before hard cap
SSPOWER_REVIEW_AUTO_APPLY=on          # Auto-apply codex's suggested patches
SSPOWER_SECURITY_REVIEW=on            # Run security reviewer in parallel
SSPOWER_SECURITY_EFFORT=xhigh         # Reasoning effort for security pass
SSPOWER_REVIEW_SKIP_PATTERN           # Branch-name globs that skip review
SSPOWER_REVIEW_STRICT_PATTERN         # Branch-name globs forced to xhigh
```

When the round counter hits 3 without converging, the hook emits a deny pointing to: `rm <repo>/.git/sspower-review-rounds-<branch>` to retry, or `SSPOWER_AUTO_REVIEW=off` to bypass.

## Codex bridge (`scripts/codex-bridge.mjs`)

Direct integration with the Codex CLI (`@openai/codex`). Skills, agents, and the auto-review hook all dispatch through this bridge — no separate Claude Code plugin involved.

Defaults: `gpt-5.5` model, `xhigh` reasoning effort. Override per-call with `--model` / `--effort`.

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
| Per-call codex options | `--model`, `--effort`, `--cd`, `--write`, `--worktree`, `--auto-commit` |
| Session state | `~/.claude/state/sspower/codex/<id>.{json,events.jsonl}` |
| Verdict cache | `~/.cache/sspower/verdicts/<hash>.json` (10min TTL) |
| Bridge log | `~/.claude/sspower-codex.log` (failures/diagnostics) |

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
