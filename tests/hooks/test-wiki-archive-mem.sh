#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="${ROOT}/hooks/wiki-archive.py"
command -v jq      >/dev/null 2>&1 || { echo "SKIP: test-wiki-archive-mem (no jq)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: test-wiki-archive-mem (no python3)"; exit 0; }
FAIL=0; ok(){ echo "PASS: $1"; }; bad(){ echo "FAIL: $1 :: $2"; FAIL=1; }

WORK="$(mktemp -d)"
trap 'rm -r "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/home"
export HOME="$WORK/home"
export UV_LOG="$WORK/uvx.log"
export CONTENT_LOG="$WORK/content.log"
: > "$UV_LOG"
: > "$CONTENT_LOG"

# Fake `uvx`: log full argv to $UV_LOG, verify --content-file exists and
# carries the rendered summary, then exit with $FAKE_UVX_RC (default 0).
cat > "$WORK/bin/uvx" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${UV_LOG:?}"
prev=""
content_file=""
for arg in "$@"; do
  if [ "$prev" = "--content-file" ]; then
    content_file="$arg"
    break
  fi
  prev="$arg"
done
if [ -n "$content_file" ]; then
  if [ ! -f "$content_file" ]; then
    echo "content-file missing: $content_file" >&2
    exit 31
  fi
  cp "$content_file" "${CONTENT_LOG:?}"
  grep -q '# .* SessionEnd' "$content_file" || { echo "missing title" >&2; exit 32; }
  grep -q 'Project:' "$content_file" || { echo "missing project" >&2; exit 33; }
  grep -q 'hello' "$content_file" || { echo "missing user prompt" >&2; exit 34; }
fi
exit "${FAKE_UVX_RC:-0}"
STUB
chmod +x "$WORK/bin/uvx"

# Minimal real transcript: one user turn + one assistant turn.
PROJ="$WORK/proj"; mkdir -p "$PROJ"
TRANSCRIPT="$WORK/transcript.jsonl"
cat > "$TRANSCRIPT" <<'JSONL'
{"type":"user","timestamp":"2026-05-21T10:00:00.000Z","message":{"role":"user","content":"hello"}}
{"type":"assistant","timestamp":"2026-05-21T10:00:05.000Z","message":{"role":"assistant","model":"claude-opus-4-7","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":10,"output_tokens":5}}}
JSONL

payload() {
  jq -nc --arg tp "$TRANSCRIPT" --arg cwd "$PROJ" \
     '{session_id:"sess-abc123def456",transcript_path:$tp,cwd:$cwd,hook_event_name:"SessionEnd"}'
}

# Case A: backend reachable (fake uvx rc=0) -> add invoked with the exact spec argv.
: > "$UV_LOG"
: > "$CONTENT_LOG"
payload | FAKE_UVX_RC=0 PATH="$WORK/bin:$PATH" python3 "$HOOK"; RC=$?
LOG="$(cat "$UV_LOG")"
[ "$RC" -eq 0 ] && ok "case A: hook exits 0" || bad "case A exit" "rc=$RC"
assert_arg() { case "$LOG" in *"$1"*) ok "case A: $2" ;; *) bad "case A: $2" "$LOG" ;; esac ; }
assert_arg '--offline --from'      'invoked via uvx --offline --from'
assert_arg 'scripts/sspower_mem'   '--from points at sspower_mem source'
assert_arg 'sspower-mem add'       'sspower-mem add subcommand'
assert_arg "--cwd $PROJ"           '--cwd is the payload cwd'
assert_arg '--scope project'       'scope project'
assert_arg '--layer episodic'      'layer episodic'
assert_arg '--content-file'        '--content-file passed (not --content)'
grep -q 'hello' "$CONTENT_LOG" \
  && ok "case A: content-file carries rendered user prompt" \
  || bad "case A content-file" "$(cat "$CONTENT_LOG" 2>/dev/null)"

# Case A2: sessions/*.md is NOT written; sessions/*.json IS still written (legacy belt).
ls "$PROJ"/.claude/wiki/sessions/*.json >/dev/null 2>&1 \
  && ok "case A2: legacy belt sessions/*.json still written" \
  || bad "case A2: json belt missing" "$(ls -la "$PROJ"/.claude/wiki/sessions/ 2>&1)"
ls "$PROJ"/.claude/wiki/sessions/*.md >/dev/null 2>&1 \
  && bad "case A2: sessions/*.md still written (should be dropped)" "$(ls "$PROJ"/.claude/wiki/sessions/)" \
  || ok "case A2: sessions/*.md no longer written"
[ -e "$PROJ/.claude/wiki/index.md" ] \
  && bad "case A2: index.md still written (legacy index writer should be removed)" "exists" \
  || ok "case A2: index.md no longer written"

# Case B: backend degraded (fake uvx rc=10) -> hook still exits 0.
: > "$UV_LOG"
payload | FAKE_UVX_RC=10 PATH="$WORK/bin:$PATH" python3 "$HOOK"; RC=$?
[ "$RC" -eq 0 ] && ok "case B: rc=10 hook exits 0" || bad "case B exit" "rc=$RC"
grep -q 'sspower-mem add' "$UV_LOG" \
  && ok "case B: add was attempted (rc=10 path exercised)" \
  || bad "case B: add not attempted" "$(cat "$UV_LOG")"

# Case C: HARD failure (fake uvx rc=20) -> hook MUST propagate with exit 20.
: > "$UV_LOG"
payload | FAKE_UVX_RC=20 PATH="$WORK/bin:$PATH" python3 "$HOOK"; RC=$?
[ "$RC" -eq 20 ] && ok "case C: rc=20 propagated as exit 20" || bad "case C exit" "rc=$RC (expected 20)"

# Case D: backend dep-missing (fake uvx rc=30) -> hook exits 0.
: > "$UV_LOG"
payload | FAKE_UVX_RC=30 PATH="$WORK/bin:$PATH" python3 "$HOOK"; RC=$?
[ "$RC" -eq 0 ] && ok "case D: rc=30 hook exits 0" || bad "case D exit" "rc=$RC"

# Case E: uvx-internal exit 7 -> Python wrapper normalizes to 30 -> hook exits 0.
: > "$UV_LOG"
payload | FAKE_UVX_RC=7 PATH="$WORK/bin:$PATH" python3 "$HOOK"; RC=$?
[ "$RC" -eq 0 ] && ok "case E: unmapped rc normalizes to 30, hook exits 0" || bad "case E exit" "rc=$RC"

# Case F: uvx absent -> pre-flight shutil.which -> rc=30 -> hook exits 0.
: > "$UV_LOG"
payload | PATH="/usr/bin:/bin" python3 "$HOOK"; RC=$?
[ "$RC" -eq 0 ] && ok "case F: uvx missing, hook exits 0" || bad "case F exit" "rc=$RC"

# Case G: empty payload cwd -> ingest skipped entirely. Spec §9 877-880
# forbids a project-scope `add` without --cwd (would fall back to the hook
# process cwd). The hook must NOT invoke sspower-mem at all here.
: > "$UV_LOG"
jq -nc --arg tp "$TRANSCRIPT" \
   '{session_id:"s",transcript_path:$tp,cwd:"",hook_event_name:"SessionEnd"}' \
  | FAKE_UVX_RC=0 PATH="$WORK/bin:$PATH" python3 "$HOOK"; RC=$?
[ "$RC" -eq 0 ] && ok "case G: empty cwd, hook exits 0" || bad "case G exit" "rc=$RC"
grep -q 'sspower-mem add' "$UV_LOG" \
  && bad "case G: add invoked without payload cwd" "$(cat "$UV_LOG")" \
  || ok "case G: empty cwd skips ingest (no add call)"

[ "$FAIL" -eq 0 ] && echo "PASS: test-wiki-archive-mem" || { echo "FAIL: test-wiki-archive-mem"; exit 1; }
