#!/usr/bin/env bash
# Tests for hooks/flow-fence.sh - PreToolUse soft-ask phase fence.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/hooks/flow-fence.sh"
FLOW="$ROOT/scripts/flow.sh"
PASS=0; FAIL=0

# substring-present assertion (non-empty expected output)
ck() { if printf '%s' "$3" | grep -qF "$2"; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (want $2, got: $3)"; FAIL=$((FAIL+1)); fi; }
# allow assertion: fence stays silent (empty stdout)
ck_allow() { if [ -z "$2" ]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (want empty, got: $2)"; FAIL=$((FAIL+1)); fi; }

# Resolve R to its physical path so JSON file_path matches the fence's
# git-show-toplevel proot (macOS /var -> /private/var symlink).
R="$(cd "$(mktemp -d)" && pwd -P)"
export HOME="$R"            # isolate flow state under R
( cd "$R" && git init -q )
( cd "$R" && bash "$FLOW" start --stage plan "fence" >/dev/null )

# src write in plan stage -> ask
out="$(printf '{"tool_name":"Write","cwd":"%s","tool_input":{"file_path":"%s/src/x.ts"}}' "$R" "$R" | bash "$HOOK")"
ck "plan: src write -> ask" '"permissionDecision": "ask"' "$out"
# docs write -> allow (silent)
out="$(printf '{"tool_name":"Write","cwd":"%s","tool_input":{"file_path":"%s/docs/x.md"}}' "$R" "$R" | bash "$HOOK")"
ck_allow "plan: docs write -> allow" "$out"
# subagent context -> exempt (allow) even for src
out="$(printf '{"tool_name":"Write","cwd":"%s","agent_id":"abc","tool_input":{"file_path":"%s/src/x.ts"}}' "$R" "$R" | bash "$HOOK")"
ck_allow "subagent src write -> exempt" "$out"
# Bash mutation in plan stage -> ask
out="$(printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"sed -i s/a/b/ src/x.ts"}}' "$R" | bash "$HOOK")"
ck "plan: Bash sed -i -> ask" '"permissionDecision": "ask"' "$out"
# fence off -> allow
out="$(printf '{"tool_name":"Write","cwd":"%s","tool_input":{"file_path":"%s/src/x.ts"}}' "$R" "$R" | SSPOWER_FLOW_FENCE=off bash "$HOOK")"
ck_allow "fence off -> allow" "$out"

# advance to exec -> source writes now allowed (silent)
mkdir -p "$R/docs"; echo plan > "$R/docs/p.md"
( cd "$R" && bash "$FLOW" set-plan "docs/p.md" >/dev/null )
( cd "$R" && bash "$FLOW" advance >/dev/null )                       # plan -> plan-review
( cd "$R" && bash "$FLOW" set-plan-review approve >/dev/null )
( cd "$R" && bash "$FLOW" advance >/dev/null )                       # plan-review -> exec
out="$(printf '{"tool_name":"Write","cwd":"%s","tool_input":{"file_path":"%s/src/x.ts"}}' "$R" "$R" | bash "$HOOK")"
ck_allow "exec: src write -> allow" "$out"

# idle (no flow) -> allow
( cd "$R" && bash "$FLOW" abort >/dev/null )
out="$(printf '{"tool_name":"Write","cwd":"%s","tool_input":{"file_path":"%s/src/x.ts"}}' "$R" "$R" | bash "$HOOK")"
ck_allow "idle: src write -> allow" "$out"

rm -rf "$R"
echo "---"; echo "passed:$PASS failed:$FAIL"; [ "$FAIL" -eq 0 ]
