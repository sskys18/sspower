---
name: codex-tracking
description: Inspect, steer, and kill running Codex bridge sessions. Trigger when user asks "what is codex doing", "list codex sessions", "kill codex", "steer codex to X", "show me what codex is up to", or invokes /codex-track.
---

# Codex Session Tracking

The Codex bridge writes per-session state to `~/.claude/state/sspower/codex/`. Use these commands to surface what's running.

## Commands

Resolve bridge path first:

```bash
BRIDGE=$(find ~/.claude/plugins -name codex-bridge.mjs -path "*/sspower/*" | head -1)
```

| Action | Command |
|---|---|
| List sessions | `node "$BRIDGE" ps` |
| Inspect one | `node "$BRIDGE" status <session_id>` |
| Stream events | `node "$BRIDGE" tail <session_id>` |
| Steer (kill+resume) | `node "$BRIDGE" steer --session-id <id> --prompt @file` |
| Force kill | `node "$BRIDGE" kill <session_id>` |

## Status fields

- `status`: `running` / `done` / `error` / `killed` / `stale`
- `phase`: last event kind (`exec`, `edit`, `think`, `agent`, `result`, `token`)
- `last_event`: rendered line from bridge
- `trace.tool_calls / edits / execs / errors / tokens`
- `duration_ms`: elapsed since start

## When to use

- User says "what's codex doing?" → `ps` to list, then `status` for any running session
- User says "kill that codex" → `ps` for newest running, then `kill <id>`
- User redirects mid-flight ("tell codex to switch to X") → write a prompt file, then `steer --session-id <id> --prompt @file`
- Post-mortem on a finished/errored session → read `~/.claude/state/sspower/codex/<id>.events.jsonl`

## Stale detection

If `updated_at` is older than 5 minutes AND the recorded pid is dead, `ps` and `status` mark the record `stale`. The bridge sweeps records older than 24 hours on every spawn.

## Steering recipe

```bash
NEW_PROMPT=$(mktemp)
chmod 600 "$NEW_PROMPT"
cat > "$NEW_PROMPT" <<'EOF'
new instruction for codex
EOF
node "$BRIDGE" steer --session-id <id> --prompt @"$NEW_PROMPT"
rm -f "$NEW_PROMPT"
```

Steering SIGTERMs the running bridge process and starts a `resume` against the same Codex session, so context (prior reasoning, file edits) is preserved.
