#!/usr/bin/env node
// Idempotently writes ~/.codex/lsp-client.json mapping languages to the
// language servers already on PATH. Out-of-repo (user-global), like config.toml.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";

function onPath(bin) {
  try { execFileSync("command", ["-v", bin], { shell: "/bin/bash", stdio: "ignore" }); return true; }
  catch { return false; }
}
// codex-lsp's getMergedServers() reads config.lsp; each entry needs BOTH
// command (spawn argv ARRAY) AND extensions or it is silently skipped.
// Extension sets mirror codex-lsp BUILTIN_SERVERS.
const ourEntries = {};
for (const [id, bin, command, extensions] of [
  ["typescript", "typescript-language-server",
    ["typescript-language-server", "--stdio"],
    [".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts"]],
  ["python", "pyright-langserver",
    ["pyright-langserver", "--stdio"], [".py", ".pyi"]],
  ["rust", "rust-analyzer", ["rust-analyzer"], [".rs"]],
  ["go", "gopls", ["gopls"], [".go"]],
]) if (onPath(bin)) ourEntries[id] = { command, extensions };

const dst = path.join(os.homedir(), ".codex", "lsp-client.json");
fs.mkdirSync(path.dirname(dst), { recursive: true });

// Never clobber a user file: parse existing, merge with user entries
// winning (existing.lsp spread LAST). Preserve other top-level keys.
let existing = {};
if (fs.existsSync(dst)) {
  try { existing = JSON.parse(fs.readFileSync(dst, "utf8")) || {}; }
  catch { existing = {}; } // unparseable / our own old shape → safe to rewrite
}
const mergedLsp = { ...ourEntries, ...(existing.lsp || {}) };
const next = { ...existing, lsp: mergedLsp };

const prev = JSON.stringify(existing);
if (prev === JSON.stringify(next)) {
  console.log("[setup-codex-lsp] up-to-date");
  process.exit(0);
}
fs.writeFileSync(dst, JSON.stringify(next, null, 2) + "\n");
console.log(`[setup-codex-lsp] wrote ${dst} (${Object.keys(mergedLsp).join(",") || "none"})`);
