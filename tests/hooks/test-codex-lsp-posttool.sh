#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
H="$ROOT/hooks/codex-lsp-posttool.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: test-codex-lsp-posttool (no jq - harness dep)"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "SKIP: test-codex-lsp-posttool (no node - harness dep)"; exit 0; }
FAIL=0; ok(){ echo "PASS: $1"; }; bad(){ echo "FAIL: $1 :: $2"; FAIL=1; }

# Stubs are COMMITTED fixtures (created as plan deliverables via normal file
# authoring - Step 6.4a), NOT written here with `cat >`/`echo >`. This avoids
# shell-redirection file creation at test runtime (Codex-worker rule / D-B4
# guard) and needs no temp files or cleanup at all.
FX="$ROOT/tests/hooks/fixtures"
STUB="$FX/codex-lsp-stub-block.cjs"   # emits a codex-lsp-style decision:block
EMPTY="$FX/codex-lsp-stub-empty.cjs"  # consumes stdin, emits nothing (clean)
FAILS="$FX/codex-lsp-stub-fail.cjs"   # consumes stdin, exits non-zero
for f in "$STUB" "$EMPTY" "$FAILS"; do
  [[ -f "$f" ]] || { echo "FAIL: missing fixture $f (Step 6.4a not done)"; exit 1; }
done

IN='{"tool_name":"Edit","tool_input":{"file_path":"x.ts"},"tool_response":{}}'

# 1. De-fang: output must NOT contain decision:block, MUST carry the diag text.
O="$(printf '%s' "$IN" | SSPOWER_CODEX_LSP_CLI="$STUB" "$H")"
echo "$O" | jq -e '(has("decision")|not) and (.hookSpecificOutput.additionalContext|test("DIAG: x.ts"))' >/dev/null \
  && ok "de-fang block->advisory" || bad "de-fang" "$O"
echo "$O" | grep -q '"decision"' && bad "decision leaked" "$O" || ok "no decision key"

# 2. Clean (stub emits nothing) -> silent pass
O="$(printf '%s' "$IN" | SSPOWER_CODEX_LSP_CLI="$EMPTY" "$H")"
[[ -z "$O" ]] && ok "clean -> silent" || bad "clean silent" "$O"

# 3. Fail-open on non-zero codex-lsp exit (the realistic infra-failure path -
#    proves the hook never blocks even when codex-lsp itself errors).
O="$(printf '%s' "$IN" | SSPOWER_CODEX_LSP_CLI="$FAILS" "$H")"
[[ -z "$O" ]] && ok "fail-open on lsp non-zero exit" || bad "lsp-nonzero fail-open" "$O"

# 4. Fail-open: resolver returns null when override points at a missing file
#    AND no vendored copy is found is structurally guaranteed by
#    resolveCodexLspCli (existsSync gate). We assert the operator disable here;
#    the null path is exercised by unit coverage of codex-lsp-path.mjs.
O="$(printf '%s' "$IN" | SSPOWER_CODEX_LSP_POSTTOOL=0 "$H")"
[[ -z "$O" ]] && ok "disable env" || bad "disable env" "$O"

[[ $FAIL -eq 0 ]] && echo "PASS: test-codex-lsp-posttool" || { echo "FAIL: test-codex-lsp-posttool"; exit 1; }
