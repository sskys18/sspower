#!/usr/bin/env bash
# test-codex-guard-pretool: deny git commit/push/merge & recursive rm
# (incl. bypass variants); ask installs; allow rest incl git merge-base.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SH="$ROOT/.codex/codex-guard-pretool.sh"
FAIL=0; pass(){ echo "PASS: $1"; }; fail(){ echo "FAIL: $1"; FAIL=1; }

mk(){ printf '{"hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"command":"%s"}}' "$1" "$2"; }
deny(){ echo "$1" | grep -q '"permissionDecision":"deny"'; }
ask(){ echo "$1" | grep -q '"permissionDecision":"ask"'; }
allow(){ echo "$1" | grep -qE '"permissionDecision":"allow"' || [ -z "$1" ]; }

# --- deny: direct ---
O="$(mk shell 'git commit -m x' | bash "$SH" 2>/dev/null)"; deny "$O" && pass "deny-commit" || fail "deny-commit ($O)"
O="$(mk shell 'git push origin main' | bash "$SH" 2>/dev/null)"; deny "$O" && pass "deny-push" || fail "deny-push ($O)"
O="$(mk shell 'git merge feature' | bash "$SH" 2>/dev/null)"; deny "$O" && pass "deny-merge" || fail "deny-merge ($O)"
O="$(mk shell 'rm -rf build/' | bash "$SH" 2>/dev/null)"; deny "$O" && pass "deny-rmrf" || fail "deny-rmrf ($O)"
# --- deny: bypass variants (the security-critical cases) ---
O="$(mk shell 'git -C /tmp/x commit -m y' | bash "$SH" 2>/dev/null)"; deny "$O" && pass "deny-git-C-commit" || fail "deny-git-C-commit ($O)"
O="$(mk shell 'git -c user.email=a@b push' | bash "$SH" 2>/dev/null)"; deny "$O" && pass "deny-git-c-push" || fail "deny-git-c-push ($O)"
# quoted -C arg containing spaces (single-quoted; the dq form is the
# symmetric regex branch but un-JSON-escapable via mk()'s naive printf).
O="$(mk shell "git -C '/a b/repo' commit -m z" | bash "$SH" 2>/dev/null)"; deny "$O" && pass "deny-git-C-spaces-sq" || fail "deny-git-C-spaces-sq ($O)"
O="$(mk shell "git --git-dir='/a b/.git' commit -m z" | bash "$SH" 2>/dev/null)"; deny "$O" && pass "deny-gitdir-eq-spaces" || fail "deny-gitdir-eq-spaces ($O)"
O="$(mk shell 'git -C /My\\ Documents/r commit' | bash "$SH" 2>/dev/null)"; deny "$O" && pass "deny-git-C-bslash-space" || fail "deny-git-C-bslash-space ($O)"
O="$(mk shell "git -C '/a b/r' -c k=v push" | bash "$SH" 2>/dev/null)"; deny "$O" && pass "deny-multi-global-spaces" || fail "deny-multi-global-spaces ($O)"
O="$(mk shell 'rm -r -f build' | bash "$SH" 2>/dev/null)"; deny "$O" && pass "deny-rm-r-f" || fail "deny-rm-r-f ($O)"
O="$(mk shell 'rm --recursive --force d' | bash "$SH" 2>/dev/null)"; deny "$O" && pass "deny-rm-recursive" || fail "deny-rm-recursive ($O)"
O="$(mk shell 'rm -fr d' | bash "$SH" 2>/dev/null)"; deny "$O" && pass "deny-rm-fr" || fail "deny-rm-fr ($O)"
O="$(mk shell 'echo hi && git push' | bash "$SH" 2>/dev/null)"; deny "$O" && pass "deny-seg-push" || fail "deny-seg-push ($O)"
O="$(mk shell '/usr/bin/git commit -m z' | bash "$SH" 2>/dev/null)"; deny "$O" && pass "deny-pathqual-git" || fail "deny-pathqual-git ($O)"
O="$(mk shell '/bin/rm -rf /tmp/x' | bash "$SH" 2>/dev/null)"; deny "$O" && pass "deny-pathqual-rm" || fail "deny-pathqual-rm ($O)"
O="$(mk shell "bash -c 'git push origin main'" | bash "$SH" 2>/dev/null)"; deny "$O" && pass "deny-bashc-push" || fail "deny-bashc-push ($O)"
O="$(mk shell "sh -c 'rm -rf build'" | bash "$SH" 2>/dev/null)"; deny "$O" && pass "deny-shc-rmrf" || fail "deny-shc-rmrf ($O)"
# --- ask ---
O="$(mk shell 'npm install left-pad' | bash "$SH" 2>/dev/null)"; ask "$O" && pass "ask-npm" || fail "ask-npm ($O)"
O="$(mk shell 'pnpm install' | bash "$SH" 2>/dev/null)"; ask "$O" && pass "ask-pnpm" || fail "ask-pnpm ($O)"
# --- allow incl. false-deny guards ---
O="$(mk shell 'git status' | bash "$SH" 2>/dev/null)"; allow "$O" && pass "allow-status" || fail "allow-status ($O)"
O="$(mk shell 'node t.js' | bash "$SH" 2>/dev/null)"; allow "$O" && pass "allow-node" || fail "allow-node ($O)"
O="$(mk shell 'git merge-base main HEAD' | bash "$SH" 2>/dev/null)"; allow "$O" && pass "allow-merge-base" || fail "allow-merge-base ($O)"
O="$(mk shell 'git -C /r merge-base a b' | bash "$SH" 2>/dev/null)"; allow "$O" && pass "allow-C-merge-base" || fail "allow-C-merge-base ($O)"
O="$(mk shell 'npm info left-pad' | bash "$SH" 2>/dev/null)"; allow "$O" && pass "allow-npm-info" || fail "allow-npm-info ($O)"
O="$(mk shell 'rm file.txt' | bash "$SH" 2>/dev/null)"; allow "$O" && pass "allow-rm-plain" || fail "allow-rm-plain ($O)"
O="$(mk shell 'echo remember to git commit later' | bash "$SH" 2>/dev/null)"; allow "$O" && pass "allow-inert-text" || fail "allow-inert-text ($O)"
O="$(mk shell 'git log --oneline' | bash "$SH" 2>/dev/null)"; allow "$O" && pass "allow-git-log" || fail "allow-git-log ($O)"
# --- fail-open ---
O="$(printf 'not json' | bash "$SH" 2>/dev/null)"; RC=$?; { [ $RC -eq 0 ] && ! deny "$O"; } && pass "failopen" || fail "failopen (rc=$RC $O)"

[ $FAIL -eq 0 ] && echo "PASS: test-codex-guard-pretool" || { echo "FAIL: test-codex-guard-pretool"; exit 1; }
