# sspower Customizations

sspower is a standalone skill framework for Claude Code. It began as a fork of
[Superpowers](https://github.com/obra/superpowers) v5.0.5 and has since diverged
into an independent project with native Codex integration and macOS-first design.
This doc records what changed relative to that v5.0.5 starting point.

## New Skills

| Skill | Purpose |
|-------|---------|
| `using-sspower` | Custom skill routing, red-flags table, platform adaptation |
| `second-opinion` | Independent review via Codex subagent before merging or after 2+ failed fix attempts |

## Modified Skills

All inherited skills received **reference extraction** — large inline examples and rationale blocks were moved to `references/` subdirectories to reduce SKILL.md token load. Modified skills:

- `brainstorming` — added `references/design-process.md`, `references/after-design.md`
- `dispatching-parallel-agents` — added `references/examples.md`
- `finishing-a-development-branch` — added `references/option-details.md`
- `receiving-code-review` — added `references/response-patterns.md`
- `subagent-driven-development` — added `references/advantages.md`, `references/example-workflow.md`
- `systematic-debugging` — added `references/phases.md`, `references/rationalizations.md`
- `test-driven-development` — added `references/rationalizations.md`
- `writing-plans` — added `references/plan-template.md`
- `writing-skills` — added `references/cso-guide.md`, `references/quality-checklist.md`, `references/skill-creation-process.md`

## Docs

- `docs/ARCHITECTURE.md` — end-to-end architecture overview
- `docs/MAINTENANCE.md` — maintenance guide
- `docs/README.codex.md` — Codex CLI install + usage
- `docs/README.opencode.md` — OpenCode install + usage

## Versioning

sspower v1.x — independent project. Version tracked in:

- `package.json`
- `.claude-plugin/plugin.json`

## Trimmed from the v5.0.5 base

| Removed | Reason |
|---------|--------|
| `.cursor-plugin/` | Cursor config |
| `gemini-extension.json`, `GEMINI.md` | Gemini config |
| `commands/` | Deprecated slash commands (replaced by skills) |
| `hooks/hooks-cursor.json`, `hooks/run-hook.cmd` | Cursor hooks, Windows batch |
| `.version-bump.json` | Old release tooling |
| `AGENTS.md`, `CHANGELOG.md`, `CODE_OF_CONDUCT.md`, `RELEASE-NOTES.md` | Stale docs |
| `using-superpowers` skill | Replaced by `using-sspower` |
