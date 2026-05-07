# Codex Session Tracking

The bridge writes per-session state to `~/.claude/state/sspower/codex/` so Claude Code (or you) can see what Codex is doing mid-flight.

## Parity vs Claude subagents

| Feature | Claude subagent | Codex bridge |
|---|---|---|
| Background dispatch | yes | yes (Bash run_in_background) |
| Live event stream | yes | yes (`tail` subcommand on JSONL events) |
| Completion notify | yes | yes (Bash bg task) |
| TaskList equivalent | TaskList tool | `ps` subcommand |
| TaskGet equivalent | TaskGet | `status <id>` |
| TaskStop equivalent | TaskStop | `kill <id>` |
| Mid-flight steer | SendMessage | `steer --session-id` (kill+resume) |
| Bidirectional stdin | yes | **no** — Codex CLI limitation |

## State file schema

`<session_id>.json`:

| Field | Type | Meaning |
|---|---|---|
| `session_id` | string | Codex session UUID, also resume key |
| `pid` | int | Codex child process pid (NOT the node wrapper) |
| `subcommand` | string | `implement` / `rescue` / `review` / etc. |
| `cwd` | string | Working directory bridge ran in |
| `started_at` | ISO8601 | Bridge spawn time |
| `updated_at` | ISO8601 | Last event timestamp |
| `status` | enum | `running` / `done` / `error` / `killed` / `stale` |
| `phase` | string | Most recent event kind |
| `last_kind` | string | Same as phase, retained for parity with bridge internal naming |
| `last_event` | string | Rendered stderr line, truncated |
| `trace.tool_calls` | int | Cumulative tool invocations |
| `trace.edits` | int | Files patched |
| `trace.execs` | int | Shell commands run |
| `trace.errors` | int | stream_error + turn_aborted |
| `trace.tokens` | object | `{input, output, total}` |
| `duration_ms` | int | Elapsed since spawn |
| `exit_code` | int / null | null while running |

## Lifecycle

1. Bridge spawns → no state file yet
2. First Codex event with `session_id` → state written, `status=running`
3. Each subsequent event → `updated_at`, `phase`, `trace` updated atomically
4. Bridge exits → `status=done` (exit 0) or `error` (exit ≠ 0)
5. External `kill` subcommand → SIGTERM + `status=killed`
6. No update >5min AND pid dead → `status=stale` (read-time computation, not a stored value)
7. mtime >24h → swept on next bridge invocation

## Concurrency

Each session ID is unique to one bridge process. Multiple bridges can run concurrently; they write to separate state files. Atomic writes via `tmp + rename`. Readers see a complete previous snapshot or the new one, never partial JSON.

## Cleanup

- Auto: bridge sweeps records mtime >24h and caps at 50 newest on every spawn
- Manual: `rm ~/.claude/state/sspower/codex/<id>.{json,events.jsonl}`

## Subagent dispatch recipe

```bash
BRIDGE=$(find ~/.claude/plugins -name codex-bridge.mjs -path "*/sspower/*" | head -1)
PROMPT_FILE=$(mktemp -d)/p.md
chmod 600 "$PROMPT_FILE"
cat > "$PROMPT_FILE" <<'EOF'
... your prompt ...
EOF

# Background dispatch
node "$BRIDGE" rescue --prompt @"$PROMPT_FILE" > /tmp/cx.out 2>&1 &
WRAPPER_PID=$!
START_TS=$(date -u +"%Y-%m-%dT%H:%M:%S")

# Poll loop (max 5 polls, 8s each).
# NOTE: registry stores codex's child pid, not WRAPPER_PID — match by
# subcommand + started_at window instead.
for i in 1 2 3 4 5; do
  sleep 8
  SID=$(node "$BRIDGE" ps | jq -r --arg t "$START_TS" \
    '[.[] | select(.subcommand=="rescue" and .started_at >= $t)] | .[0].session_id // empty')
  if [ -n "$SID" ]; then
    node "$BRIDGE" status "$SID" | jq '{phase,last_event,duration_ms,trace}'
  fi
  ! kill -0 "$WRAPPER_PID" 2>/dev/null && break
done

wait "$WRAPPER_PID"
cat /tmp/cx.out
```

## Steer mid-flight

When you want to redirect a running session:

```bash
node "$BRIDGE" steer --session-id <id> --prompt "new instruction"
```

This SIGTERMs the running bridge, waits 2s, then resumes the same Codex session with the new prompt. The session ID stays valid because Codex persists it (when the original run was non-ephemeral — `implement` and `rescue --write`). For ephemeral runs (`rescue` without `--write`, `review`, `spec-review`), Codex does not persist a rollout and steer will fail with "no rollout found for thread id".

## When to use which command

- `ps` → list everything, default starting point
- `status <id>` → drill in, see trace counters and phase
- `tail <id>` → live JSONL stream, useful for long sessions
- `steer --session-id <id> --prompt …` → redirect a running write-mode session
- `kill <id>` → force stop, marks state `killed`

## Caveats

- **Codex trust gate**: `--cd <dir>` requires the dir to be a trusted git repository (Codex CLI behavior). The bridge does not pass `--skip-git-repo-check`. If you need to run Codex against a fresh dir, `git init` it first.
- **Rollout flush timing**: short-lived sessions (where Codex completes in <2s) may not produce a rollout artifact, which means `steer` cannot resume them. Use a longer-running prompt or rely on `kill` instead.
- **Registry pid is Codex's child pid**, not the node wrapper. When matching sessions to a known process, use `subcommand` + `started_at` window, not the wrapper pid.
