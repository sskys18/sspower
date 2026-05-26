#!/usr/bin/env bash
# sspower-graph bootstrap wrapper for .mcp.json invocation.
set -euo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"

if [ ! -d "$ROOT/node_modules/@modelcontextprotocol" ]; then
  # Prefer bun (fast, deterministic, matches fakechat marketplace pattern).
  # Fall back to npm if bun is absent.
  if command -v bun >/dev/null 2>&1; then
    bun install --production --silent >/dev/null 2>&1 \
      || bun install --production >&2
  else
    npm install --omit=dev --no-audit --no-fund --silent --prefer-offline \
      >/dev/null 2>&1 \
      || npm install --omit=dev --no-audit --no-fund --silent >&2
  fi
fi

exec node "$ROOT/bin/sspower-graph.mjs" "$@"
