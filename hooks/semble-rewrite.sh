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
source "$(dirname "${BASH_SOURCE[0]}")/_log.sh" 2>/dev/null || true
trap '_sspower_exit_guard $? "0" hook.semble-rewrite' EXIT

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

# Single-quote-wrap every value interpolated into the emitted command. Bash
# single-quoted strings disable ALL expansion (glob, brace, var, command,
# tilde) - safer than %q, which on bash 3.2 does not escape a leading ~.
# Embedded single-quotes are escaped via the standard '\'' shell idiom.
shq() {
  # bash 3.2 mis-parses inline `'\\''` inside ${//}; build the 4-char
  # replacement ( ' \ ' ' ) via printf and substitute, then sq-wrap.
  local _r; printf -v _r '%s%s%s%s' "'" '\' "'" "'"
  printf "'%s'" "${1//\'/$_r}"
}

# Strip matched outer quote pair (single OR double) from a single token,
# writing the result to varname $1 and setting global QTYPE to '' (none),
# "'" (single), or '"' (double). Tokenization (`set -f; TOK=( $CMD )`)
# splits on whitespace, so `"skills"` arrives with literal quote chars -
# %q would then escape them into `\"skills\"` (ENOENT). The QTYPE flag
# lets callers distinguish user-intended-literal from user-intended-
# expansion at the right granularity: single-quote disables all expansion;
# double-quote disables only glob/brace/tilde; unquoted enables everything.
# Embedded-space quoted paths tokenize as >1 token and are rejected earlier
# as bad=1, so this helper handles only the safe single-token case.
dequote_to() {
  local _v="$1" _s="$2"
  QTYPE=''
  if (( ${#_s} >= 2 )); then
    local _f="${_s:0:1}" _l="${_s: -1}"
    if [[ "$_f" == '"' && "$_l" == '"' ]]; then
      _s="${_s:1:${#_s}-2}"; QTYPE='"'
    elif [[ "$_f" == "'" && "$_l" == "'" ]]; then
      _s="${_s:1:${#_s}-2}"; QTYPE="'"
    fi
  fi
  printf -v "$_v" '%s' "$_s"
}

# True if the shell would expand any character in $2 given quote type $1.
# qtype="'": nothing expands (always safe).
# qtype='"': only $ / backtick / backslash expand.
# qtype='':  everything expands - glob (*?[{), brace, var ($), command (`),
#            escape (\); tilde only at the start of the token.
unsafe_meta() {
  local _q="$1" _s="$2"
  case "$_q" in
    "'") return 1 ;;
    '"') case "$_s" in *\$*|*\`*|*\\*) return 0 ;; esac; return 1 ;;
    '')  case "$_s" in *\**|*\?*|*\[*|*\{*|*\$*|*\`*|*\\*) return 0 ;; esac
         [[ "${_s:0:1}" == '~' ]] && return 0
         return 1 ;;
  esac
}

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
    # User wanted shell expansion - we cannot expand at PreToolUse -> passthrough.
    if unsafe_meta "$QTYPE" "$patharg"; then exit 0; fi
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
      dequote_to pat "$pat";       pat_q=$QTYPE
      dequote_to patharg "$patharg"; patharg_q=$QTYPE
      # bare-ident regex below rejects most meta in pat, but $X / $(..) /
      # backticks would slip through after a single-quote strip - guard
      # both fields uniformly for clarity.
      if unsafe_meta "$pat_q" "$pat"; then exit 0; fi
      if unsafe_meta "$patharg_q" "$patharg"; then exit 0; fi
      if [[ "$pat" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        emit_ask "semble_rs search --compact $(shq "$pat") $(shq "$patharg")" \
          "semble-rewrite: grep -R -> semble_rs search (semantic!=literal - confirm the substitution)"
      fi
    fi
  fi
fi

exit 0
