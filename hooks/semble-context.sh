#!/usr/bin/env bash
# UserPromptSubmit hook - inject token-cheap repo orientation via `semble_rs plan`
# on coding-intent prompts. Advisory only (additionalContext). Fail-OPEN: any
# error / missing semble_rs / timeout -> emit nothing, exit 0.
#
# Disable: export SSPOWER_SEMBLE=0
# Opt-out per-prompt: prompt starts with raw: RAW: nosemble: NOSEMBLE:
# Tune: SSPOWER_SEMBLE_TIMEOUT (s, default 6), SSPOWER_SEMBLE_MAX_CHARS (default 3000)
#
# CLI signature (verified `semble_rs plan --help` + run): `semble_rs plan
# <TASK> [PATH]` - PATH is a real second positional (default `.`). The
# two-arg form `semble_rs plan "$USER_PROMPT" "$CWD"` below is correct and
# empirically confirmed (output prints `Path: <CWD>`).

set -uo pipefail   # NOT -e: we must fail open, not abort
source "$(dirname "${BASH_SOURCE[0]}")/_log.sh" 2>/dev/null || true
trap '_sspower_exit_guard $? "0" hook.semble-context' EXIT

DIAG_LOG="${HOME}/.claude/sspower/codex.log"

log_hook() {
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$(dirname "$DIAG_LOG")" 2>/dev/null
  ( printf '%s [%s] hook.semble-context %s\n' "$ts" "$1" "$2" >> "$DIAG_LOG" ) 2>/dev/null || true
}

INPUT="$(cat)"

emit_nothing() { exit 0; }   # UserPromptSubmit: no JSON == no added context

# jq is a hard dep for safe JSON in/out (it backs cmd-rewrite, codex-lsp-posttool
# already). Missing jq -> fail-OPEN silent, never hand-roll fragile escaping.
command -v jq >/dev/null 2>&1 || emit_nothing

extract_field() { printf '%s' "$INPUT" | jq -r ".${1} // empty" 2>/dev/null; }
USER_PROMPT="$(extract_field prompt)"
CWD="$(extract_field cwd)"; [[ -z "$CWD" ]] && CWD="$(pwd)"

emit_context() {
  # jq builds + escapes the JSON (handles all control chars, not just \n\t\r).
  jq -n --arg c "$1" \
    '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$c}}'
  exit 0
}

# -- Gate ----------------------------------------------------------------
[[ "${SSPOWER_SEMBLE:-1}" == "0" ]] && emit_nothing
command -v semble_rs >/dev/null 2>&1 || { log_hook info "kind=skip reason=no-semble"; emit_nothing; }
[[ -z "$USER_PROMPT" ]] && emit_nothing
(( ${#USER_PROMPT} < 20 )) && emit_nothing

MAX_CHARS="${SSPOWER_SEMBLE_MAX_CHARS:-3000}"
[[ "$MAX_CHARS" =~ ^[0-9]+$ ]] || MAX_CHARS=3000
MAX_CHARS=$((10#$MAX_CHARS))
(( ${#USER_PROMPT} > 8000 )) && emit_nothing   # already context-rich

[[ "$USER_PROMPT" =~ ^/ ]] && emit_nothing
[[ "$USER_PROMPT" =~ ^(raw:|RAW:|nosemble:|NOSEMBLE:) ]] && emit_nothing

LC="$(printf '%s' "$USER_PROMPT" | tr '[:upper:]' '[:lower:]')"
case "$LC" in
  "what is"*|"what's"*|"show"*|"list"*|"explain"*|"describe"*|"tell me"*) emit_nothing ;;
  "hi"|"hello"|"hey"|"thanks"|"thank you"|"ok"|"yes"|"no"|"done"|"go"|"push") emit_nothing ;;
  "help"|"status"|"why"*) emit_nothing ;;
esac
if source "$(dirname "${BASH_SOURCE[0]}")/_intent.sh" 2>/dev/null \
   && command -v sspower_classify_intent >/dev/null 2>&1; then
  [ "$(sspower_classify_intent "$USER_PROMPT")" = "qa" ] \
    && { log_hook info "kind=skip reason=no-coding-intent"; emit_nothing; }
else
  # fail-open: _intent.sh unavailable -> exact legacy regex
  echo "$LC" | grep -qE '\b(add|fix|build|refactor|implement|change|write|create|debug|update|modify|remove|delete|rename|move|migrate|port|wire|ship|integrate|setup|install|configure|test|bug|error|broken|failing|crash)\b' \
    || { log_hook info "kind=skip reason=no-coding-intent"; emit_nothing; }
fi

# Only inject inside a git repo (semble is gitignore-aware; non-repo = noise)
git -C "$CWD" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { log_hook info "kind=skip reason=not-git"; emit_nothing; }

# -- Run semble_rs plan with portable hard timeout, fail-open ------------
SEM_TIMEOUT="${SSPOWER_SEMBLE_TIMEOUT:-6}"
[[ "$SEM_TIMEOUT" =~ ^[0-9]+$ ]] || SEM_TIMEOUT=6
SEM_TIMEOUT=$((10#$SEM_TIMEOUT))

if command -v gtimeout >/dev/null 2>&1; then TO=(gtimeout "$SEM_TIMEOUT")
elif command -v timeout >/dev/null 2>&1; then TO=(timeout "$SEM_TIMEOUT")
elif command -v perl >/dev/null 2>&1; then TO=(perl -e 'alarm shift; exec @ARGV' "$SEM_TIMEOUT")
else TO=(); fi   # no timeout binary AND no perl (extreme): run unbounded, never hard-fail

START="$(date +%s)"
OUT=""
# bash-3.2-safe empty-array expansion (${arr[@]+...}) - no set -u unbound error.
if OUT="$(${TO[@]+"${TO[@]}"} semble_rs plan "$USER_PROMPT" "$CWD" 2>/dev/null)"; then
  DUR=$(( $(date +%s) - START ))
  if [[ -n "$OUT" ]]; then
    # HARD char cap: final string (slice + marker) is <= MAX_CHARS, not
    # MAX_CHARS + marker. Marker reserved at 28 chars; floor MAX_CHARS at 64.
    if (( ${#OUT} > MAX_CHARS )); then
      (( MAX_CHARS < 64 )) && MAX_CHARS=64
      MARK="
[...truncated]"
      OUT="${OUT:0:$(( MAX_CHARS - ${#MARK} ))}${MARK}"
    fi
    log_hook info "kind=inject dur=${DUR}s bytes=${#OUT} cwd=$CWD"
    emit_context "[semble_rs repo orientation - advisory, token-cheap; verify before acting]:
${OUT}"
  fi
  log_hook warn "kind=empty dur=${DUR}s cwd=$CWD"; emit_nothing
else
  RC=$?; DUR=$(( $(date +%s) - START ))
  case "$RC" in
    124|142) log_hook warn "kind=timeout dur=${DUR}s cwd=$CWD" ;;
    *)       log_hook error "kind=semble_failed rc=$RC dur=${DUR}s cwd=$CWD" ;;
  esac
  emit_nothing
fi
