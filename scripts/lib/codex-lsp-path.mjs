// Single source of truth for locating the vendored codex-lsp CLI.
// Order: SSPOWER_CODEX_LSP_CLI override → vendored tools/codex-lsp → null (fail-open).
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const PLUGIN_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");

export function resolveCodexLspCli() {
  const override = process.env.SSPOWER_CODEX_LSP_CLI;
  if (override && fs.existsSync(override)) return override;
  const vendored = path.join(PLUGIN_ROOT, "tools", "codex-lsp", "dist", "cli.js");
  if (fs.existsSync(vendored)) return vendored;
  return null; // caller must fail-open (skip + log), never crash
}
