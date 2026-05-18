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
const servers = {};
if (onPath("typescript-language-server"))
  servers.typescript = { command: "typescript-language-server", args: ["--stdio"] };
// python/rust/go/c_cpp added only if their servers are present (no hard dep).
for (const [lang, bin, args] of [
  ["python", "pyright-langserver", ["--stdio"]],
  ["rust", "rust-analyzer", []],
  ["go", "gopls", []],
]) if (onPath(bin)) servers[lang] = { command: bin, args };

const dst = path.join(os.homedir(), ".codex", "lsp-client.json");
fs.mkdirSync(path.dirname(dst), { recursive: true });
const next = JSON.stringify({ servers }, null, 2) + "\n";
const prev = fs.existsSync(dst) ? fs.readFileSync(dst, "utf8") : "";
if (prev === next) { console.log("[setup-codex-lsp] up-to-date"); process.exit(0); }
fs.writeFileSync(dst, next);
console.log(`[setup-codex-lsp] wrote ${dst} (${Object.keys(servers).join(",") || "none"})`);
