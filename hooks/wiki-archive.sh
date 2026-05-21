#!/usr/bin/env bash
# sspower wiki-archive — PreCompact/SessionEnd hook.
# Delegates to wiki-archive.py which writes per-project session summaries.

set -euo pipefail

# CLAUDE_PLUGIN_ROOT is set by the Claude Code harness for plugin hooks.
# Fallback to script-relative path so this still works if invoked manually.
SCRIPT_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Phase E pre-flight: warn once if uvx is absent. The .py still runs the
# legacy JSON belt; only the sspower-mem ingest is lost.
command -v uvx >/dev/null 2>&1 || \
  echo "[wiki-archive] uvx not found; sspower-mem ingest skipped (legacy JSON belt still runs). Install: brew install uv" >&2

exec python3 "${SCRIPT_DIR}/hooks/wiki-archive.py"
