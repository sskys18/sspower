# Vendored: @code-yeongyu/codex-lsp

- **Upstream:** https://github.com/code-yeongyu/codex-lsp
- **Pinned commit:** `05e8f07` ("fix(lsp): make config-loader test platform-aware")
- **Version:** 0.1.0
- **License:** MIT — see [`./LICENSE`](./LICENSE) (Copyright (c) 2026 Yeongyu Kim)
- **What is vendored:** the compiled `dist/` only. codex-lsp has **0 runtime
  dependencies** (`package.json` `dependencies` = `{}`; verified self-contained
  by running `dist/cli.js` in isolation with no `node_modules`). Sourcemaps
  (`*.map`) stripped to shrink the tree (~272K).
- **Why vendor (not submodule / not env-only):** 0-dep static compiled bundle
  → committing it is reproducible, needs no setup build, no runtime network.
  A submodule would add `git submodule` + `bun build` ceremony for zero gain.

## Runtime contract

- Entry: `node tools/codex-lsp/dist/cli.js <mcp | hook post-tool-use>`
  - **no args / `mcp`** → starts the MCP-over-stdio server (waits on stdin —
    *not* a help/usage path; do NOT "verify" with a bare no-arg run).
  - `hook post-tool-use` → PostToolUse diagnostics hook.
  - any other arg (e.g. `--help`) → prints `Usage: codex-lsp [mcp | hook post-tool-use]` to stderr, exit 0.
- Requires the language servers on `PATH` (e.g. `typescript-language-server`).
- Resolver: `scripts/lib/codex-lsp-path.mjs` (`SSPOWER_CODEX_LSP_CLI` env
  overrides this vendored path; null → callers must fail-open).

## Rebuild / update

```bash
git clone https://github.com/code-yeongyu/codex-lsp /tmp/codex-lsp
git -C /tmp/codex-lsp checkout 05e8f07     # or a newer pinned SHA
cd /tmp/codex-lsp && bun install && bun run build
cp -R /tmp/codex-lsp/dist <repo>/tools/codex-lsp/dist
find <repo>/tools/codex-lsp/dist -name '*.map' -delete
cp /tmp/codex-lsp/LICENSE <repo>/tools/codex-lsp/LICENSE
# bump the pinned commit + version above
```
