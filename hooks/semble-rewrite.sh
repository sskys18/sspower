#!/usr/bin/env bash
# PreToolUse:Bash hook - opportunistic, NEVER-DENY command rewrites:
#   ls -R [path]                 -> semble_rs tree [path]              (explicit ASK; DP-1)
#   grep -R/-r <BARE_IDENT> [p]  -> semble_rs search --compact <q> [p] (explicit ASK; DP-2 lossy)
# Verified CLI signatures (semble_rs --help + live run, 2026-05-19):
#   `semble_rs tree [PATH]`                    - PATH optional 2nd positional
#   `semble_rs search --compact <QUERY> [PATH]`- QUERY then optional PATH
# Fail-OPEN: no semble_rs / no jq / parse fail / non-match -> exit 0 (pass through).
# Disable: export SSPOWER_SEMBLE_REWRITE=0

set -uo pipefail

[[ "${SSPOWER_SEMBLE_REWRITE:-1}" == "0" ]] && exit 0
command -v jq        >/dev/null 2>&1 || exit 0
command -v semble_rs >/dev/null 2>&1 || exit 0

INPUT="$(cat)"
CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')"
[[ -z "$CMD" ]] && exit 0

# Bail ONLY on command-structure metacharacters (compound/redirect/subshell).
# Glob/brace/bracket in a single path token: kept ONLY when originally quoted
# (caller wanted literal `src/[id]`). Unquoted globs imply user wanted shell
# expansion and are bailed on at the call site after dequote_to + has_glob_meta -
# we cannot expand at PreToolUse without arbitrary FS access.
case "$CMD" in
  *'|'*|*'&'*|*';'*|*'>'*|*'<'*|*'$('*|*'`'*|*$'\n'*) exit 0 ;;
esac

# Shell-quote every value interpolated into the emitted command so the rewrite
# is literal-safe regardless of path characters.
shq() { printf '%q' "$1"; }

# Strip matched outer quote pair (single OR double) from a single token,
# writing the result to varname $1 and setting global DEQUOTED=0|1.
# Tokenization (`set -f; TOK=( $CMD )`) splits on whitespace, so `"skills"`
# arrives with literal quote chars - %q would then escape them into
# `\"skills\"` (ENOENT). Embedded-space quoted paths tokenize as >1 token
# and are rejected earlier as bad=1, so this helper handles only the safe
# single-token case. The DEQUOTED flag lets callers distinguish user-
# intended-literal (was quoted -> keep glob chars literal) from user-
# intended-shell-expansion (was unquoted -> bail rather than emit literal).
dequote_to() {
  local _v="$1" _s="$2"
  DEQUOTED=0
  if (( ${#_s} >= 2 )); then
    local _f="${_s:0:1}" _l="${_s: -1}"
    if [[ ( "$_f" == '"' && "$_l" == '"' ) || ( "$_f" == "'" && "$_l" == "'" ) ]]; then
      _s="${_s:1:${#_s}-2}"
      DEQUOTED=1
    fi
  fi
  printf -v "$_v" '%s' "$_s"
}

# True if $1 contains shell glob/brace metacharacters. Unquoted globs in
# the original command imply user wanted shell expansion; we cannot expand
# at PreToolUse without arbitrary FS access -> caller bails (passthrough).
has_glob_meta() { [[ "$1" == *[\*\?\[\{]* ]]; }

# SINGLE emit path: EXPLICIT permissionDecision:"ask" for BOTH ls and grep.
# Rationale (DP-1/DP-2): the rewrite changes semantics (gitignore-aware tree !=
# `ls -R`; semantic search != literal grep) and may drop modifier flags - so it
# must always be shown/confirmed, never auto-allowed. $1=command $2=reason.
emit_ask() {
  jq -n --arg cmd "$1" --arg why "$2" \
        --argjson ti "$(printf '%s' "$INPUT" | jq -c '.tool_input')" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",
      permissionDecisionReason:$why,
      updatedInput:($ti + {command:$cmd})}}'
  exit 0
}

# Tokenize on whitespace. `set -f` disables glob expansion so a literal `*`
# in the command is NOT expanded against cwd. bash-3.2-safe (no mapfile).
set -f
# shellcheck disable=SC2206
TOK=( $CMD )
set +f
(( ${#TOK[@]} == 0 )) && exit 0

# -- ls ... -R ... [path] -> semble_rs tree [path]  (explicit ASK, DP-1) --
# Separated flags OK (`ls -l -R src`). Recursion flag is UPPERCASE -R ONLY:
# `ls -r` is reverse-sort, NOT recursive. Each flag token must be a clean
# short-flag bundle (^-[a-zA-Z]+$); at most one non-flag path. Else skip.
# ASK (not allow): tree is gitignore-aware (DP-1) AND drops ls modifier flags
# (-l/-a/-d/-s/sort/classify) - a semantic change the user must confirm.
if [[ "${TOK[0]}" == "ls" ]]; then
  has_R=0; patharg=""; bad=0
  for (( i=1; i<${#TOK[@]}; i++ )); do
    t="${TOK[$i]}"
    if [[ "$t" == -* ]]; then
      [[ "$t" =~ ^-[a-zA-Z]+$ ]] || { bad=1; break; }     # reject --long, -1=, etc.
      [[ "$t" == *R* ]] && has_R=1                          # UPPERCASE R only
    elif [[ -z "$patharg" ]]; then
      patharg="$t"
    else
      bad=1; break                                          # >1 path arg
    fi
  done
  if (( bad == 0 && has_R == 1 )); then
    dequote_to patharg "${patharg:-.}"
    # Unquoted glob -> user wanted shell expansion -> passthrough.
    if (( DEQUOTED == 0 )) && has_glob_meta "$patharg"; then exit 0; fi
    emit_ask "semble_rs tree $(shq "$patharg")" \
      "semble-rewrite: ls -R -> semble_rs tree (gitignore-aware; drops ls modifier flags - confirm)"
  fi
fi

# -- grep -R|-r <BARE_IDENT> [path] -> semble_rs search --compact (ASK) --
# DP-2 STRICT: every flag token must be EXACTLY -R or -r (no -Rn, -i, -E,
# --recursive ...). Exactly one pattern (bare identifier) + <=1 path. Else skip.
if [[ "${TOK[0]}" == "grep" ]]; then
  has_R=0; bad=0; i=1
  while (( i < ${#TOK[@]} )) && [[ "${TOK[$i]}" == -* ]]; do
    case "${TOK[$i]}" in
      -R|-r) has_R=1 ;;
      *)     bad=1; break ;;
    esac
    (( i++ ))
  done
  if (( bad == 0 && has_R == 1 && i < ${#TOK[@]} )); then
    pat="${TOK[$i]}"; (( i++ ))
    patharg="."
    if (( i < ${#TOK[@]} )); then patharg="${TOK[$i]}"; (( i++ )); fi
    # DP-2: a flag-looking token AFTER the pattern (e.g. `grep -R ident -n`)
    # means a non-R/r flag slipped past the leading-flag loop -> disqualify.
    # Also no trailing tokens beyond a single path arg.
    if (( i == ${#TOK[@]} )) && [[ "$patharg" != -* ]]; then
      dequote_to pat "$pat"
      dequote_to patharg "$patharg"; patharg_dq=$DEQUOTED
      # pat must match bare-identifier regex below (no glob chars allowed),
      # so only patharg needs the unquoted-glob guard.
      if (( patharg_dq == 0 )) && has_glob_meta "$patharg"; then exit 0; fi
      if [[ "$pat" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        emit_ask "semble_rs search --compact $(shq "$pat") $(shq "$patharg")" \
          "semble-rewrite: grep -R -> semble_rs search (semantic!=literal - confirm the substitution)"
      fi
    fi
  fi
fi

exit 0
