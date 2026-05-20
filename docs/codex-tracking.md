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
| `pid` | int | Codex child process pid (used by `kill`/`steer`) |
| `bridge_pid` | int | Node bridge wrapper pid (use this to correlate dispatch ↔ session under concurrent runs) |
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
TMPROOT=$(mktemp -d -t codex-track.XXXXXX)
chmod 700 "$TMPROOT"
PROMPT_FILE="$TMPROOT/p.md"
STDOUT_FILE="$TMPROOT/cx.out"
: > "$PROMPT_FILE" && chmod 600 "$PROMPT_FILE"
: > "$STDOUT_FILE" && chmod 600 "$STDOUT_FILE"
cat > "$PROMPT_FILE" <<'EOF'
... your prompt ...
EOF

# Background dispatch — STDOUT_FILE is 0600 in a 0700 dir; cleaned up at end
node "$BRIDGE" rescue --prompt @"$PROMPT_FILE" > "$STDOUT_FILE" 2>&1 &
WRAPPER_PID=$!

# Poll loop (max 5 polls, 8s each).
# Match on bridge_pid — uniquely identifies this dispatch even under
# concurrent runs. Do NOT match on .pid (that's codex's child).
for i in 1 2 3 4 5; do
  sleep 8
  SID=$(node "$BRIDGE" ps | jq -r --arg p "$WRAPPER_PID" \
    '[.[] | select(.bridge_pid==($p|tonumber))] | .[0].session_id // empty')
  if [ -n "$SID" ]; then
    node "$BRIDGE" status "$SID" | jq '{phase,last_event,duration_ms,trace}'
  fi
  ! kill -0 "$WRAPPER_PID" 2>/dev/null && break
done

wait "$WRAPPER_PID"
cat "$STDOUT_FILE"
rm -rf "$TMPROOT"
```

## Steer mid-flight

When you want to redirect a running session:

```bash
node "$BRIDGE" steer --session-id <id> --prompt "new instruction"
```

This SIGTERMs the Codex child process recorded in `pid` (NOT the node bridge wrapper), polls for exit up to 10 seconds, escalates to SIGKILL if needed and waits another 3 seconds. If the child still survives, `steer` aborts via `die()` rather than risking a parallel resume. Once the old child is verified gone, the same Codex session is resumed with the new prompt. The session ID stays valid because Codex persists it (when the original run was non-ephemeral — `implement` and `rescue --write`). For ephemeral runs (`rescue` without `--write`, `review`, `spec-review`), Codex does not persist a rollout and steer will fail with "no rollout found for thread id".

## When to use which command

- `ps` → list everything, default starting point
- `status <id>` → drill in, see trace counters and phase
- `tail <id>` → live JSONL stream, useful for long sessions
- `steer --session-id <id> --prompt …` → redirect a running write-mode session
- `kill <id>` → force stop, marks state `killed`

## Caveats

- **Codex trust gate**: codex >= 0.131 refuses non-git CWDs unless `--skip-git-repo-check` is passed. The bridge **passes this flag unconditionally** on both `exec` and `exec resume` paths. The bridge accepts an optional `--cd <path>` which is normalized to `cdAbs` and passed as `-C` when present; when no `--cd` is supplied, codex inherits the spawn cwd. Either way, the trust-dir guard is not a useful security boundary for our local invocations, so non-git CWDs (e.g. `/tmp`) work transparently.
- **Rollout flush timing**: short-lived sessions (where Codex completes in <2s) may not produce a rollout artifact, which means `steer` cannot resume them. Use a longer-running prompt or rely on `kill` instead.
- **Two pids per record**: `pid` is Codex's child (signal target for `kill`/`steer`); `bridge_pid` is the node wrapper (use this to correlate "I just dispatched bridge — which session is mine?"). Always match dispatches by `bridge_pid`, not by `pid`.
- **`kill` and `steer` refuse to signal stale records**: if `markStale` flips the status to `stale`/`done`/`error`/`killed`, the bridge will not SIGTERM the recorded pid (PID may have been reused by another OS process). For stale records, manually verify with `ps -p <pid>` then `kill <pid>` directly if needed.
- **`steer` polls for child exit** up to 10s after SIGTERM, escalating to SIGKILL with another 3s wait if the codex child ignores the term signal. If the process survives both signals (13s total), steer aborts rather than starting a parallel resume.
- **`ps`/`status` use weaker liveness check** than `kill`/`steer`. The signal paths apply defense-in-depth (record age <5min, bridge_pid alive, child pid alive); the listing paths only check age + child pid. Result: a stale record where the OS has reused the codex child pid may show `running` in `ps`, but `kill`/`steer` will refuse to signal it. (Followup: align `markStale` with `isLiveRunning`.)
