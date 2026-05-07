# sspower

Fork of [Superpowers](https://github.com/obra/superpowers) v5.0.5 — customized for Claude Code.

## Structure

```
skills/          — one dir per skill, each with SKILL.md + references/
hooks/           — SessionStart (diet-activate), UserPromptSubmit (diet-track + codex-track-prompt), PreToolUse:Bash (cmd-rewrite + auto-review), PreCompact + SessionEnd (wiki-archive)
agents/          — subagent prompts (code-reviewer, codex-rescue)
scripts/         — codex-bridge.mjs (native Codex CLI integration), codex-registry.mjs (session state for tracking)
schemas/         — structured output contracts for Codex (implementation, spec-review, quality-review)
commands/        — slash command entrypoints (diet, diet-commit, diet-review, codex-track)
docs/            — customization docs, plans, specs
tests/           — skill and brainstorm-server tests
```

## Key Rules

- Skills use progressive disclosure: lean SKILL.md + `references/` loaded on demand
- `using-sspower` replaces upstream `using-superpowers` for skill routing
- `second-opinion` and Codex integration require Codex CLI installed locally (`npm install -g @openai/codex`) and authenticated (`codex login`). Uses native `scripts/codex-bridge.mjs`, not the external openai-codex plugin. Bridge defaults to `gpt-5.5` + `xhigh` reasoning effort
- Diet hooks: `hooks/package.json` is `{"type":"commonjs"}` even though the repo root is ESM — needed because hook files use CJS. Don't delete it
- Project wiki lives at `<cwd>/.claude/wiki/`: per-session JSON+MD in `sessions/`, plus `decisions.md`, `gotchas.md`, `index.md`. Sidecars are also symlinked into `~/.claude/sessions/` for cross-project tooling
- All skill changes must be eval-tested before committing
- `git push` / `gh pr create` / `gh pr ready` / `git merge` trigger an auto-review hook that blocks unless Codex verdict is `approve` or `approve-with-followups`. `gh pr merge` is intentionally NOT a chokepoint: by merge time the diff was already reviewed at PR open/ready, and the local branch diff this hook computes is not necessarily the diff being merged. Bypass: `SSPOWER_AUTO_REVIEW=off` (emergencies only). Three SKILL.md HARD-GATEs (writing-plans, subagent-driven-development, finishing-a-development-branch) enforce the same review at earlier checkpoints
- Auto-review chain policy: chokepoints (`git commit` / `git push` / `git merge` / `gh pr ...`) must run as standalone Bash invocations. Read-only output pipes (`| tail`, `| grep`, `| jq`, etc.) ARE allowed after the chokepoint. Use `git -C <path>` not `cd <path> && git ...`. The hook deny message names the rule that fired
- Auto-review loop guards: re-entry env (`SSPOWER_REVIEW_IN_FLIGHT`), depth counter (`SSPOWER_REVIEW_DEPTH`), verdict cache (`~/.cache/sspower/verdicts/<hash>.json`, 10min TTL), bridge timeout (90s), iteration cap (3 rounds per branch, tracked at `<repo>/.git/sspower-review-rounds-<branch>`). Tunables: `SSPOWER_REVIEW_CACHE_TTL`, `SSPOWER_REVIEW_TIMEOUT`, `SSPOWER_REVIEW_MAX_ROUNDS`, `SSPOWER_REVIEW_AUTO_APPLY`
- Per-repo state at `<repo>/.sspower/`: `followups.md` (advisory issues from `approve-with-followups` verdicts) and `proposed-fixes/round-N.patch` (codex-suggested patches auto-applied via `git apply --3way`). Add `.sspower/` to the consuming repo's `.gitignore` if you don't want this state versioned
- Codex session tracking: bridge writes per-session state to `~/.claude/state/sspower/codex/<id>.json` and event log to `<id>.events.jsonl`. Surface via `codex-bridge.mjs ps|status|kill|steer|tail`, the `codex-tracking` skill, or `/codex-track` slash command. See `docs/codex-tracking.md` for parity table, schema, and caveats. Registry writes are best-effort — failures disable registry for the run but do NOT crash the bridge
- Codex auto-surface: `hooks/codex-track-prompt.sh` runs on UserPromptSubmit, scans the registry, and injects compact one-line summaries of running + recently-finished (<5min) sessions into Claude's context on every prompt. Stale zombies (status=running but supervising pid dead) are detected via `kill -0` and shown as `stale` only if recently updated. Hook timeout 2s, silent on no sessions. Disable by removing the hook entry from `hooks/hooks.json`
