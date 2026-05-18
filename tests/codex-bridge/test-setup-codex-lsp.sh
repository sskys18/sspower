#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/setup-codex-lsp.mjs"

# --- Case 1: fresh HOME → file has codex-lsp-loadable .lsp shape ---
H1="$(mktemp -d)"
trap 'rm -rf "$H1" "$H2" "$H3"' EXIT
HOME="$H1" node "$SCRIPT" >/dev/null
CFG1="$H1/.codex/lsp-client.json"
[ -f "$CFG1" ] || { echo "FAIL: $CFG1 not written"; exit 1; }
node - "$CFG1" <<'EOF'
const c = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
if (!c.lsp || typeof c.lsp !== "object") { console.log("FAIL: no top-level .lsp"); process.exit(1); }
const ts = c.lsp.typescript;
if (!ts) { console.log("FAIL: no .lsp.typescript"); process.exit(1); }
if (!Array.isArray(ts.command)) { console.log("FAIL: .lsp.typescript.command not an array"); process.exit(1); }
if (JSON.stringify(ts.command) !== JSON.stringify(["typescript-language-server","--stdio"])) {
  console.log("FAIL: unexpected command " + JSON.stringify(ts.command)); process.exit(1); }
if (!Array.isArray(ts.extensions) || !ts.extensions.includes(".ts")) {
  console.log("FAIL: .lsp.typescript.extensions missing/invalid"); process.exit(1); }
console.log("PASS: fresh HOME emits codex-lsp-loadable .lsp shape");
EOF

# --- Case 2: pre-existing user file → merge, not clobber + idempotent ---
H2="$(mktemp -d)"
mkdir -p "$H2/.codex"
cat > "$H2/.codex/lsp-client.json" <<'EOF'
{"someTopKey":1,"lsp":{"typescript":{"command":["custom"],"extensions":[".ts"]},"mylang":{"command":["mylang-ls"],"extensions":[".ml"]}}}
EOF
HOME="$H2" node "$SCRIPT" >/dev/null
node - "$H2/.codex/lsp-client.json" <<'EOF'
const c = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
if (JSON.stringify(c.lsp.typescript.command) !== JSON.stringify(["custom"])) {
  console.log("FAIL: user typescript entry was overwritten"); process.exit(1); }
if (!c.lsp.mylang || JSON.stringify(c.lsp.mylang.command) !== JSON.stringify(["mylang-ls"])) {
  console.log("FAIL: user mylang entry not preserved"); process.exit(1); }
if (c.someTopKey !== 1) { console.log("FAIL: other top-level key dropped"); process.exit(1); }
console.log("PASS: pre-existing user entries preserved (merge, not clobber)");
EOF
# 2nd run must report up-to-date (idempotency)
OUT="$(HOME="$H2" node "$SCRIPT")"
case "$OUT" in
  *up-to-date*) echo "PASS: idempotent (up-to-date on 2nd run)";;
  *) echo "FAIL: 2nd run not idempotent: $OUT"; exit 1;;
esac

# --- Case 3: pre-existing UNPARSEABLE user file → untouched + exit 0 + warning ---
H3="$(mktemp -d)"
mkdir -p "$H3/.codex"
BADCFG="$H3/.codex/lsp-client.json"
printf 'not json {{{' > "$BADCFG"
SHA_BEFORE="$(shasum "$BADCFG" | awk '{print $1}')"
set +e
ERR3="$(HOME="$H3" node "$SCRIPT" 2>&1 >/dev/null)"
RC3=$?
set -e
[ "$RC3" -eq 0 ] || { echo "FAIL: unparseable file did not exit 0 (rc=$RC3)"; exit 1; }
case "$ERR3" in
  *WARNING*not\ valid\ JSON*leaving\ it\ untouched*) echo "PASS: unparseable file → stderr WARNING printed";;
  *) echo "FAIL: expected untouched WARNING on stderr, got: $ERR3"; exit 1;;
esac
SHA_AFTER="$(shasum "$BADCFG" | awk '{print $1}')"
[ "$SHA_BEFORE" = "$SHA_AFTER" ] || { echo "FAIL: unparseable user file was overwritten ($SHA_BEFORE != $SHA_AFTER)"; exit 1; }
echo "PASS: unparseable user file left byte-identical (no clobber)"

echo "PASS: test-setup-codex-lsp"
