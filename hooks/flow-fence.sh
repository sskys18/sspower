#!/usr/bin/env bash
# PreToolUse fence: out-of-phase source mutations -> permission "ask".
# Main-thread only; Workflow/Task subagents EXEMPT (D-HF6). Fail-open: any
# uncertainty -> allow (wedge-priority).
set -uo pipefail
[ "${SSPOWER_FLOW_FENCE:-on}" = "off" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0
INPUT="$(cat 2>/dev/null || true)"

# Subagent-exempt: hooks fire for subagents (D-WF3/D-HF6 [High]); pass when an
# agent context is present.
agent_id="$(printf '%s' "$INPUT" | jq -r '.agent_id // .agent_type // empty' 2>/dev/null || true)"
[ -n "$agent_id" ] && exit 0

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -n "$CWD" ] && [ -d "$CWD" ] && CWD="$(cd "$CWD" && pwd -P)" || CWD="$(pwd -P)"
stage="$(cd "$CWD" 2>/dev/null && bash "$PLUGIN_ROOT/scripts/flow.sh" current-stage 2>/dev/null || true)"
[ -n "$stage" ] || exit 0   # idle -> no fence

tool="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')"
proot="$(cd "$CWD" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$CWD")"

# collect target paths (Write/Edit file_path + MultiEdit edits[])
paths="$(printf '%s' "$INPUT" | jq -r '[.tool_input.file_path // empty, (.tool_input.edits[]?.file_path // empty)] | .[]' 2>/dev/null || true)"

allowed_path() { case "$1" in "$proot"/docs/*|"$proot"/.claude/*|/tmp/*|"$proot"/*plan*.md|"$proot"/*design*.md) return 0;; *) return 1;; esac; }

ask() { printf '%s' "$1" | jq -Rs '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:.}}'; exit 0; }

case "$stage" in
  brainstorm|plan|plan-review)
    while IFS= read -r p; do [ -z "$p" ] && continue
      allowed_path "$p" || ask "FLOW[$stage]: editing $p now skips the plan. Finish the $stage stage first, or allow to override."
    done <<< "$paths" ;;
  test|review|merge)
    while IFS= read -r p; do [ -z "$p" ] && continue
      allowed_path "$p" || ask "FLOW[$stage]: you're past exec. To change code run: flow back (returns to exec). Allow to override."
    done <<< "$paths" ;;
esac
# Bash arm: conservative mutation detection (only in plan-ish stages)
if [ "$tool" = "Bash" ]; then
  case "$stage" in brainstorm|plan|plan-review)
    cmd="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')"
    case "$cmd" in *"sed -i"*|*" tee "*|*">"*|*"git checkout"*|*"git restore"*)
      ask "FLOW[$stage]: that Bash command may write source during $stage. Allow to override." ;;
    esac ;;
  esac
fi
exit 0
