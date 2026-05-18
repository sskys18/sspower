#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
chmod +x "$ROOT/.codex/codex-lsp-posttool.sh"
# Default (no gate env): even if codex-lsp emits block, wrapper must return approve.
OUT=$(cd "$ROOT" && SSPOWER_LSP_SELFREPAIR_BLOCK= bash .codex/codex-lsp-posttool.sh </dev/null 2>/dev/null || true)
echo "$OUT" | grep -q '"decision":"approve"' && echo "PASS: advisory default = approve" || { echo "FAIL: $OUT"; exit 1; }

# --- Branch: gate passthrough (D-B6 promotion path) ---
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
FAKE="$TMPD/fake-cli.js"
cat > "$FAKE" <<'EOF'
// Fake codex-lsp cli: accept `hook post-tool-use` argv, ignore stdin, emit block.
process.stdin.resume();
process.stdin.on('data', () => {});
process.stdout.write('{"decision":"block","reason":"seeded"}');
process.exit(0);
EOF

# Gate flipped → block must pass through.
OUT=$(cd "$ROOT" && SSPOWER_CODEX_LSP_CLI="$FAKE" SSPOWER_LSP_SELFREPAIR_BLOCK=1 bash .codex/codex-lsp-posttool.sh </dev/null 2>/dev/null || true)
echo "$OUT" | grep -q '"decision":"block"' && echo "PASS: gate=1 passes block through" || { echo "FAIL: $OUT"; exit 1; }

# Same fake cli, gate NOT set → block stripped to approve.
OUT=$(cd "$ROOT" && SSPOWER_CODEX_LSP_CLI="$FAKE" SSPOWER_LSP_SELFREPAIR_BLOCK= bash .codex/codex-lsp-posttool.sh </dev/null 2>/dev/null || true)
echo "$OUT" | grep -q '"decision":"approve"' && echo "PASS: gate unset strips block to approve" || { echo "FAIL: $OUT"; exit 1; }

# --- Branch: D-B7 infra-missing downgrade even in block mode ---
INFRA="$TMPD/infra-cli.js"
cat > "$INFRA" <<'EOF'
// Fake codex-lsp cli: emit a BLOCK whose reason carries an infra-missing signature.
// Use JSON.stringify so the wire bytes are valid JSON (matches real codex-hook.js).
process.stdin.resume();
process.stdin.on('data', () => {});
process.stdout.write(JSON.stringify({decision:"block",reason:"LSP diagnostics after editing foo.ts:\nLSP server 'typescript' is configured but NOT INSTALLED.",hookSpecificOutput:{x:1}}));
process.exit(0);
EOF
set +e
OUT=$(cd "$ROOT" && SSPOWER_CODEX_LSP_CLI="$INFRA" SSPOWER_LSP_SELFREPAIR_BLOCK=1 bash .codex/codex-lsp-posttool.sh </dev/null 2>/dev/null)
RC=$?
set -e
[ "$RC" -eq 0 ] && echo "$OUT" | grep -q '"decision":"approve"' && echo "PASS: block mode + infra-missing → downgraded to approve" || { echo "FAIL: rc=$RC out=$OUT"; exit 1; }
echo "$OUT" | grep -q '"decision":"block"' && { echo "FAIL: infra block leaked through: $OUT"; exit 1; } || true

# --- Branch: D-B6 real code-error block still blocks in block mode ---
REAL="$TMPD/real-cli.js"
cat > "$REAL" <<'EOF'
// Fake codex-lsp cli: emit a BLOCK with a genuine code diagnostic, no infra signature.
process.stdin.resume();
process.stdin.on('data', () => {});
process.stdout.write(JSON.stringify({decision:"block",reason:"LSP diagnostics after editing foo.ts:\nfoo.ts:3:7 error TS2322: Type 'string' is not assignable to type 'number'."}));
process.exit(0);
EOF
set +e
OUT=$(cd "$ROOT" && SSPOWER_CODEX_LSP_CLI="$REAL" SSPOWER_LSP_SELFREPAIR_BLOCK=1 bash .codex/codex-lsp-posttool.sh </dev/null 2>/dev/null)
RC=$?
set -e
[ "$RC" -eq 0 ] && echo "$OUT" | grep -q '"decision":"block"' && echo "PASS: block mode + real code error → still blocks (passthrough)" || { echo "FAIL: rc=$RC out=$OUT"; exit 1; }
echo "$OUT" | grep -q 'TS2322' && echo "PASS: real code-error block preserved verbatim" || { echo "FAIL: diagnostic stripped: $OUT"; exit 1; }

# --- Branch: bogus override fail-open (exit 0 + valid approve JSON) ---
set +e
OUT=$(cd "$ROOT" && SSPOWER_CODEX_LSP_CLI=/definitely/nonexistent/xyz SSPOWER_LSP_SELFREPAIR_BLOCK= bash .codex/codex-lsp-posttool.sh </dev/null 2>/dev/null)
RC=$?
set -e
[ "$RC" -eq 0 ] && echo "$OUT" | grep -q '"decision":"approve"' && echo "PASS: bogus override fail-open (exit 0, approve)" || { echo "FAIL: rc=$RC out=$OUT"; exit 1; }

echo "PASS: test-lsp-selfrepair-advisory"
