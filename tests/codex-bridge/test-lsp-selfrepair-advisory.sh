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

# --- Branch: bogus override fail-open (exit 0 + valid approve JSON) ---
set +e
OUT=$(cd "$ROOT" && SSPOWER_CODEX_LSP_CLI=/definitely/nonexistent/xyz SSPOWER_LSP_SELFREPAIR_BLOCK= bash .codex/codex-lsp-posttool.sh </dev/null 2>/dev/null)
RC=$?
set -e
[ "$RC" -eq 0 ] && echo "$OUT" | grep -q '"decision":"approve"' && echo "PASS: bogus override fail-open (exit 0, approve)" || { echo "FAIL: rc=$RC out=$OUT"; exit 1; }

echo "PASS: test-lsp-selfrepair-advisory"
