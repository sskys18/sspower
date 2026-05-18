#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
git -C "$WORK" init -q
git -C "$WORK" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
node - "$ROOT" "$WORK" <<'EOF'
const [,, ROOT, WORK] = process.argv;
const m = await import(`${ROOT}/scripts/codex-bridge.mjs`);
// cond 4: missing session id → loop returns input _lsp unchanged, 0 rounds.
const inp = { status:"errors", decision:"would-block", checked_files:["x"], total_errors:1, errors:[{file:"x",text:"err"}], repair_rounds:0 };
const out = await m.__test_runLspRepairLoop(WORK, null, null, inp, false);
if (out.repair_rounds !== 0 || out.status !== "errors") { console.log(`FAIL cond4: ${JSON.stringify(out)}`); process.exit(1); }
console.log("PASS: cond4 missing-session terminates with 0 rounds");
// _extractSid: production sid source must prefer result.sessionId (set by
// _spawnAndCapture, available at the gate) over _meta.session_id (stamped
// later in output()). Guards against the plan-defect regression.
const a = m._extractSid({ sessionId: "abc", structured: {} });
if (a !== "abc") { console.log(`FAIL extractSid-primary: ${JSON.stringify(a)}`); process.exit(1); }
const b = m._extractSid({ structured: { _meta: { session_id: "def" } } });
if (b !== "def") { console.log(`FAIL extractSid-fallback: ${JSON.stringify(b)}`); process.exit(1); }
const c = m._extractSid({ structured: {} });
if (c !== null) { console.log(`FAIL extractSid-null: ${JSON.stringify(c)}`); process.exit(1); }
console.log("PASS: _extractSid prefers result.sessionId, falls back to _meta, else null");
// lspDiffHash must capture untracked files (gate checks them via
// lspChangedFiles ls-files --others) — else cond-2 false-fires when a
// repair only edits an untracked file.
const { writeFileSync } = await import("node:fs");
const h1 = m.__test_lspDiffHash(WORK);
writeFileSync(`${WORK}/new.ts`, "const x: number = 1;\n");
const h2 = m.__test_lspDiffHash(WORK);
if (!h1 || h1 === h2) { console.log(`FAIL lspDiffHash-untracked: h1=${h1} h2=${h2}`); process.exit(1); }
console.log("PASS: lspDiffHash captures untracked");
EOF
echo "PASS: test-lsp-repair-termination"
