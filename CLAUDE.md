# sspower

Fork of [Superpowers](https://github.com/obra/superpowers) v5.0.5 — customized for Claude Code.

## Structure

```
skills/          — one dir per skill, each with SKILL.md + references/
hooks/           — SessionStart (diet-activate + semble-session), UserPromptSubmit (diet-track + codex-track-prompt + semble-context), PreToolUse:Bash (semble-rewrite → cmd-rewrite → auto-review, in that order; semble-rewrite owns `ls -R`/`grep -R <IDENT>` first so rtk does not auto-run them), PostToolUse:Write|Edit|MultiEdit (codex-lsp-posttool), PreCompact + SessionEnd (wiki-archive)
agents/          — subagent prompts (code-reviewer, codex-rescue, security-reviewer, sanity-reviewer)
scripts/         — codex-bridge.mjs (native Codex CLI integration), codex-registry.mjs (session state for tracking), sspower_mem/ (Python package for sspower-mem memory CLI; uv/uvx-runnable)
schemas/         — structured output contracts for Codex (implementation, spec-review, quality-review)
commands/        — slash command entrypoints (diet, diet-commit, diet-review, codex-track)
docs/            — customization docs, plans, specs
tests/           — skill and brainstorm-server tests
```

## Key Rules

- Skills use progressive disclosure: lean SKILL.md + `references/` loaded on demand
- `using-sspower` replaces upstream `using-superpowers` for skill routing
- `second-opinion` and Codex integration require Codex CLI installed locally (`npm install -g @openai/codex`) and authenticated (`codex login`). Uses native `scripts/codex-bridge.mjs`, not the external openai-codex plugin. Bridge defaults to `gpt-5.5` + `high` reasoning effort (`xhigh` caused stalls). Security + sanity reviewers were removed from `auto-review.sh` — invoke on demand via subagents: `agents/security-reviewer.md` (vuln/auth/crypto pass) and `agents/sanity-reviewer.md` (independent second opinion, real-blocker-only). The `second-opinion` skill routes to sanity-reviewer for before-merge / stuck-after-2-attempts cases
- Diet hooks: `hooks/package.json` is `{"type":"commonjs"}` even though the repo root is ESM — needed because hook files use CJS. Don't delete it
- Project wiki lives at `<cwd>/.claude/wiki/`: per-session JSON+MD in `sessions/`, plus `decisions.md`, `gotchas.md`, `index.md`. Sidecars are also symlinked into `~/.claude/sessions/` for cross-project tooling
- All skill changes must be eval-tested before committing
- `git push` / `gh pr create` / `gh pr ready` / `git merge` trigger an auto-review hook that blocks unless Codex verdict is `approve` or `approve-with-followups`. `gh pr merge` is intentionally NOT a chokepoint: by merge time the diff was already reviewed at PR open/ready, and the local branch diff this hook computes is not necessarily the diff being merged. Bypass: `SSPOWER_AUTO_REVIEW=off` (emergencies only). Three SKILL.md HARD-GATEs (writing-plans, subagent-driven-development, finishing-a-development-branch) enforce the same review at earlier checkpoints
- Auto-review chain policy: chokepoints (`git commit` / `git push` / `git merge` / `gh pr ...`) must run as standalone Bash invocations. Read-only output pipes (`| tail`, `| grep`, `| jq`, etc.) ARE allowed after the chokepoint. Use `git -C <path>` not `cd <path> && git ...`. The hook deny message names the rule that fired
- Auto-review loop guards: re-entry env (`SSPOWER_REVIEW_IN_FLIGHT`), depth counter (`SSPOWER_REVIEW_DEPTH`), verdict cache (`~/.cache/sspower/verdicts/<hash>.json`, 10min TTL), bridge timeout (90s), iteration cap (3 rounds per branch, tracked at `<repo>/.git/sspower-review-rounds-<branch>`). Tunables: `SSPOWER_REVIEW_CACHE_TTL`, `SSPOWER_REVIEW_TIMEOUT`, `SSPOWER_REVIEW_MAX_ROUNDS`. Auto-apply was removed — codex's suggested patches are saved at `<repo>/.claude/sspower/proposed-fixes/round-N.patch` for manual review (`git apply` if accepted)
- Per-repo state at `<repo>/.claude/sspower/`: `followups.md` (advisory issues from `approve-with-followups` verdicts) and `proposed-fixes/round-N.patch` (codex-suggested patches saved for manual review; auto-apply removed — inspect and `git apply` yourself if accepted). `.claude/` is already typically gitignored; if not, add it (or `.claude/sspower/`) to the consuming repo's `.gitignore`
- Codex session tracking: bridge writes per-session state to `~/.claude/state/sspower/codex/<id>.json` and event log to `<id>.events.jsonl`. Surface via `codex-bridge.mjs ps|status|kill|steer|tail`, the `codex-tracking` skill, or `/codex-track` slash command. See `docs/codex-tracking.md` for parity table, schema, and caveats. Registry writes are best-effort — failures disable registry for the run but do NOT crash the bridge
- Codex auto-surface: `hooks/codex-track-prompt.sh` runs on UserPromptSubmit, scans the registry, and injects compact one-line summaries of running + recently-finished (<5min) sessions into Claude's context. **Default: OFF (opt-in)** — costs ~300-500 tokens/turn even when no codex work is relevant. Enable per-shell: `export SSPOWER_CODEX_SURFACE=on`. Globally: add to `~/.claude/settings.json` env block. Stale zombies (status=running but supervising pid dead) are detected via `kill -0` and shown as `stale` only if recently updated. Hook timeout 2s, silent on no sessions or when disabled. Hard cap 5 lines
