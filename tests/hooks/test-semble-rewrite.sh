#!/usr/bin/env bash
set -uo pipefail
H="$(cd "$(dirname "$0")/../.." && pwd)/hooks/semble-rewrite.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: test-semble-rewrite (no jq - harness dep)"; exit 0; }
FAIL=0; ok(){ echo "PASS: $1"; }; bad(){ echo "FAIL: $1 :: $2"; FAIL=1; }
skip(){ echo "SKIP: $1"; }
# jq builder - valid JSON even when the command contains quotes / regex chars.
j(){ jq -nc --arg c "$1" '{tool_input:{command:$c}}'; }

# Inv-4 (semble-independent): hooks.json reorder is actually in place -
# semble-rewrite BEFORE cmd-rewrite, and auto-review is the LAST Bash hook
# (last-anchored, not loose order). Must run even when semble_rs absent.
HJ="$(cd "$(dirname "$0")/../.." && pwd)/hooks/hooks.json"
if jq -e '
  ([.hooks.PreToolUse[]|select(.matcher=="Bash")|.hooks[].command]) as $c
  | ($c|map(test("semble-rewrite"))|index(true)) as $s
  | ($c|map(test("cmd-rewrite"))|index(true)) as $m
  | ($c|length) as $n
  | ($s != null and $m != null and ($s < $m) and ($c[$n-1]|test("auto-review")))
' "$HJ" >/dev/null 2>&1; then
  ok "chain Inv-4: semble-rewrite<cmd-rewrite & auto-review LAST"
else
  bad "Inv-4 order" "$(jq -c '[.hooks.PreToolUse[]|select(.matcher=="Bash")|.hooks[].command]' "$HJ")"
fi

# The hook will not rewrite to a binary that is absent (it would emit a broken
# command). So with no semble_rs the ONLY correct behavior is fail-open
# passthrough for EVERY input - assert that deterministically and stop.
if ! command -v semble_rs >/dev/null 2>&1; then
  for c in 'ls -R src' 'grep -R ident .' 'ls -la' 'cat x'; do
    O="$(j "$c" | "$H")"; [[ -z "$O" ]] && ok "no-semble passthrough: $c" || bad "no-semble passthrough: $c" "$O"
  done
  [[ $FAIL -eq 0 ]] && echo "PASS: test-semble-rewrite" || { echo "FAIL: test-semble-rewrite"; exit 1; }
  exit 0
fi

# ls -> EXPLICIT permissionDecision:"ask" (single emit path; no auto-allow).
O="$(j 'ls -R src' | "$H")"
echo "$O" | jq -e '(.hookSpecificOutput.permissionDecision=="ask") and (.hookSpecificOutput.updatedInput.command=="semble_rs tree src")' >/dev/null \
  && ok "ls -R -> ask" || bad "ls -R ask" "$O"

O="$(j 'ls -l -R src' | "$H")"   # separated flags must still classify
echo "$O" | jq -e '(.hookSpecificOutput.permissionDecision=="ask") and (.hookSpecificOutput.updatedInput.command=="semble_rs tree src")' >/dev/null \
  && ok "ls -l -R src (separated) -> ask" || bad "ls separated" "$O"

O="$(j 'ls -laR' | "$H")"
echo "$O" | jq -e '(.hookSpecificOutput.permissionDecision=="ask") and (.hookSpecificOutput.updatedInput.command=="semble_rs tree .")' >/dev/null \
  && ok "ls -laR -> ask, tree ." || bad "ls -laR" "$O"

# grep -> EXPLICIT permissionDecision:"ask" (DP-2 - not unset fall-through).
O="$(j 'grep -R runLspGate src' | "$H")"
echo "$O" | jq -e '(.hookSpecificOutput.permissionDecision=="ask") and (.hookSpecificOutput.updatedInput.command=="semble_rs search --compact runLspGate src")' >/dev/null \
  && ok "grep ident -> explicit ask" || bad "grep ask" "$O"

O="$(j 'grep -r ident' | "$H")"  # -r, default path .
echo "$O" | jq -e '(.hookSpecificOutput.permissionDecision=="ask") and (.hookSpecificOutput.updatedInput.command=="semble_rs search --compact ident .")' >/dev/null \
  && ok "grep -r ident -> ask, path defaults ." || bad "grep -r default path" "$O"

# DP-2 locked: separated recursive flags `grep -R -r x .` classify correctly.
O="$(j 'grep -R -r x .' | "$H")"
echo "$O" | jq -e '(.hookSpecificOutput.permissionDecision=="ask") and (.hookSpecificOutput.updatedInput.command=="semble_rs search --compact x .")' >/dev/null \
  && ok "grep -R -r x . (separated recursive flags) -> ask" || bad "grep separated -R -r" "$O"

# ls ask assertions covered above.
# DP-1: lowercase `ls -r` is REVERSE-sort, NOT recursive -> must NOT rewrite.
# DP-2 STRICT: anything beyond exactly -R/-r (grep) must pass through.
for c in 'ls -r src' 'ls -lr' 'ls -r' \
         'grep -Rn ident .' 'grep -R -i Foo src' 'grep -Rw foo .' 'grep -RF lit .' \
         'grep -RE pat .' 'grep --recursive ident .' 'grep -R "a.*b" .' \
         'grep -R ident -n' 'grep -R Foo -i' 'grep -R x a b' \
         'ls -la' 'cat foo' 'ls -R | head' 'ls -R && pwd' 'ls -R src&' 'ls --color -R .'; do
  O="$(j "$c" | "$H")"; [[ -z "$O" ]] && ok "noop: $c" || bad "noop: $c" "$O"
done

O="$(SSPOWER_SEMBLE_REWRITE=0 sh -c "printf '{\"tool_input\":{\"command\":\"ls -R\"}}' | '$H'")"
[[ -z "$O" ]] && ok "disable env" || bad "disable env" "$O"

# ── Quoted-path safety (Codex-flagged 2026-05-20) ────────────────────
# Single-token matched-quote paths must dequote BEFORE %q, else %q escapes
# the quotes into literal '"skills"' (ENOENT). Embedded-space quoted paths
# tokenize as >1 path arg and already fall through (noop) - covered below.
O="$(j 'ls -R "skills"' | "$H")"
echo "$O" | jq -e '(.hookSpecificOutput.permissionDecision=="ask") and (.hookSpecificOutput.updatedInput.command=="semble_rs tree skills")' >/dev/null \
  && ok "ls -R \"skills\" -> ask, tree skills (dequoted)" || bad "ls -R dq path" "$O"

O="$(j "ls -R 'skills'" | "$H")"
echo "$O" | jq -e '(.hookSpecificOutput.permissionDecision=="ask") and (.hookSpecificOutput.updatedInput.command=="semble_rs tree skills")' >/dev/null \
  && ok "ls -R 'skills' -> ask, tree skills (dequoted)" || bad "ls -R sq path" "$O"

O="$(j 'grep -R ident "src"' | "$H")"
echo "$O" | jq -e '(.hookSpecificOutput.permissionDecision=="ask") and (.hookSpecificOutput.updatedInput.command=="semble_rs search --compact ident src")' >/dev/null \
  && ok "grep -R ident \"src\" -> ask, search src (dequoted)" || bad "grep dq path" "$O"

O="$(j "grep -R ident 'src'" | "$H")"
echo "$O" | jq -e '(.hookSpecificOutput.permissionDecision=="ask") and (.hookSpecificOutput.updatedInput.command=="semble_rs search --compact ident src")' >/dev/null \
  && ok "grep -R ident 'src' -> ask, search src (dequoted)" || bad "grep sq path" "$O"

# Embedded-space quoted path: tokenizer splits inside quotes -> >1 path arg
# -> bad=1 -> noop passthrough (correct fail-safe).
for c in 'ls -R "src/my dir"' "ls -R 'src/my dir'" 'grep -R ident "src/my dir"'; do
  O="$(j "$c" | "$H")"
  [[ -z "$O" ]] && ok "embedded-space quoted -> noop: $c" || bad "embedded-space: $c" "$O"
done

# ── Reorder chain invariants (semble-dependent) ──────────────────────
# Inv-1: semble-rewrite (now FIRST) emits ask + semble cmd on bare ls -R.
O="$(j 'ls -R src' | "$H")"
echo "$O" | jq -e '(.hookSpecificOutput.permissionDecision=="ask") and (.hookSpecificOutput.updatedInput.command=="semble_rs tree src")' >/dev/null \
  && ok "chain Inv-1: semble first -> ask+tree" || bad "Inv-1" "$O"

# Inv-2: semble's emitted command passes through cmd-rewrite untouched
# (rtk has no semble_rs equivalent) -> semble's decision survives the chain.
CR="$(cd "$(dirname "$0")/../.." && pwd)/hooks/cmd-rewrite.sh"
if command -v rtk >/dev/null 2>&1; then
  O="$(printf '{"tool_input":{"command":"semble_rs tree src"}}' | "$CR" 2>/dev/null)"
  [[ -z "$O" ]] && ok "chain Inv-2: cmd-rewrite passthrough semble tree" || bad "Inv-2 (rtk grabbed semble_rs?)" "$O"
  O="$(printf '{"tool_input":{"command":"semble_rs search --compact runLspGate ."}}' | "$CR" 2>/dev/null)"
  [[ -z "$O" ]] && ok "chain Inv-2b: passthrough semble search" || bad "Inv-2b" "$O"
else
  skip "chain Inv-2 (rtk absent - cmd-rewrite no-ops, passthrough holds trivially)"
fi

# Inv-3: non-overlap command -> semble-rewrite no-ops (empty) so the
# original reaches cmd-rewrite/rtk unchanged (rtk broad surface intact).
for c in 'git status' 'cat foo.txt' 'npm install' 'ls -la'; do
  O="$(j "$c" | "$H")"
  [[ -z "$O" ]] && ok "chain Inv-3 non-overlap untouched: $c" || bad "Inv-3: $c" "$O"
done

[[ $FAIL -eq 0 ]] && echo "PASS: test-semble-rewrite" || { echo "FAIL: test-semble-rewrite"; exit 1; }
