#!/usr/bin/env bash
# PostToolUse:Write|Edit|MultiEdit — append JSONL dirty records.
# Gates: file under $PWD, known source extension, index exists.
# Fail-OPEN: any error -> exit 0.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_log.sh" 2>/dev/null || true
trap '_sspower_exit_guard $? "0" hook.graph-mark-dirty' EXIT

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
GRAPH_DIR="$PWD/.claude/graph"

[[ -e "$GRAPH_DIR/index.sqlite" ]] || exit 0
command -v jq      >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

INPUT="$(cat)"
[[ -n "$INPUT" ]] || exit 0

PATHS="$(echo "$INPUT" | jq -r '
  (.tool_input.file_path // empty),
  (.tool_input.edits[]?.file_path // empty)
' 2>/dev/null)" || exit 0
[[ -n "$PATHS" ]] || exit 0

SOURCE_EXT_RE='\.(ts|tsx|mts|cts|js|jsx|mjs|cjs|py|go|rs)$'
ABS_CWD="$(cd "$PWD" && pwd)"

while IFS= read -r raw_path; do
  [[ -z "$raw_path" ]] && continue
  if [[ "$raw_path" = /* ]]; then
    abs="$raw_path"
  else
    abs="$ABS_CWD/$raw_path"
  fi
  abs="$(python3 -c 'import os, sys; print(os.path.normpath(sys.argv[1]))' "$abs" 2>/dev/null)" || continue
  case "$abs" in
    "$ABS_CWD"/*) ;;
    *) continue ;;
  esac
  [[ "$abs" =~ $SOURCE_EXT_RE ]] || continue
  if [[ -e "$abs" ]]; then op="upsert"; else op="delete"; fi
  CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" python3 \
    "$PLUGIN_ROOT/scripts/graph-append-dirty.py" \
    --graph-dir "$GRAPH_DIR" --op "$op" --path "$abs" \
    >/dev/null 2>&1 || true
done <<< "$PATHS"

exit 0
