#!/usr/bin/env bash
# sspower-graph bootstrap wrapper for .mcp.json invocation.
set -euo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"

# Node >=22.5 runtime check (engines.node is documented in package.json but
# not enforced by package managers without engine-strict).
# P1 raised the floor from 22.0 to 22.5: node:sqlite gained its stable
# DatabaseSync API in 22.5 and earlier 22.x requires --experimental-sqlite.
NODE_BIN="${NODE:-node}"
if ! command -v "$NODE_BIN" >/dev/null 2>&1; then
  echo "sspower-graph: node not found on PATH (need >=22.5)" >&2
  exit 127
fi
NODE_VER=$("$NODE_BIN" -p 'process.versions.node' 2>/dev/null || echo 0)
NODE_MAJOR=$("$NODE_BIN" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
NODE_MINOR=$("$NODE_BIN" -p 'process.versions.node.split(".")[1]' 2>/dev/null || echo 0)
if [ "$NODE_MAJOR" -lt 22 ] || { [ "$NODE_MAJOR" -eq 22 ] && [ "$NODE_MINOR" -lt 5 ]; }; then
  echo "sspower-graph: node v$NODE_VER too old; need >=22.5 (node:sqlite stable surface)" >&2
  exit 1
fi

# Lockfile-deterministic install: bun is the supported installer (bun.lock
# is committed). The advisory v0 review (2026-05-26) flagged the npm
# fallback as unreproducible since no package-lock.json is committed —
# bun-only is the chosen resolution.
if [ ! -d "$ROOT/node_modules/@modelcontextprotocol" ]; then
  if ! command -v bun >/dev/null 2>&1; then
    echo "sspower-graph: bun required for first-run install (matches bun.lock)" >&2
    echo "  install: https://bun.sh — or pre-populate node_modules from another machine" >&2
    exit 127
  fi
  bun install --frozen-lockfile --production --silent >/dev/null 2>&1 \
    || bun install --frozen-lockfile --production >&2
fi

exec "$NODE_BIN" "$ROOT/bin/sspower-graph.mjs" "$@"
