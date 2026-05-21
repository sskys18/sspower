# sspower Maintenance Guide

## Overview

sspower is a standalone skill framework for Claude Code with native Codex
integration. It is distributed as a plugin through the `sskys18` marketplace.

## Repo

```
origin  https://github.com/sskys18/sspower.git
```

## Plugin Identity

| Field | Value |
|-------|-------|
| `.claude-plugin/plugin.json` name | `sspower` |
| marketplace.json name | `sskys18` |
| settings.json key | `sspower@sskys18` |
| Plugin path | `~/.claude/plugins/marketplaces/sskys18/plugins/sspower/` |

## After Making Changes

```bash
# 1. Edit files, commit, push
git add -A
git commit -F <message-file>
git push origin main

# 2. Restart Claude Code to pick up changes
```

The repo is checked out directly inside the marketplace tree — no separate
cache sync step is needed.

## Versioning

Bump on release:
- `.claude-plugin/plugin.json` (`version`)
- `package.json` (`version`)
- `.claude-plugin/marketplace.json` (plugin entry `version`)

## Key Config Files

- `~/.claude/settings.json` — `enabledPlugins` and `extraKnownMarketplaces`
- `~/.claude/plugins/installed_plugins.json` — install entry for `sspower@sskys18`
- `~/.claude/plugins/known_marketplaces.json` — marketplace registration
