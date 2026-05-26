// Minimal JSON-RPC-2.0-over-stdio MCP client for the vendored codex-lsp
// `mcp` server. Newline-delimited framing (measured: codex-lsp emits NO
// Content-Length headers). Single-purpose: spawn → initialize → call
// `diagnostics` per file → shutdown. Fail-OPEN: every error path resolves
// to a structured {status} object, never throws to the caller.
import { spawn } from "node:child_process";

const PROTOCOL_VERSION = "2024-11-05";

export class McpLspClient {
  constructor(cliPath, cwd) {
    this.cliPath = cliPath;
    this.cwd = cwd;
    this.child = null;
    this._buf = "";
    this._nextId = 1;
    this._pending = new Map(); // id -> {resolve, timer}
    this._stderrBuf = "";       // capped stderr for diagnostic surfacing
    this.lastReason = "";       // populated on ok=false (D-B8)
  }

  // Spawn `node <cli> mcp` and run the initialize handshake.
  // Returns true on success, false on any failure (fail-open).
  async start(initTimeoutMs = 15000) {
    try {
      this.child = spawn("node", [this.cliPath, "mcp"], {
        cwd: this.cwd,
        stdio: ["pipe", "pipe", "pipe"],
        env: { ...process.env },
      });
    } catch {
      return false;
    }
    this.child.on("error", () => this._failAll());
    this.child.stdout.setEncoding("utf8");
    this.child.stdout.on("data", (d) => this._onData(d));
    if (this.child.stderr) {
      this.child.stderr.setEncoding("utf8");
      this.child.stderr.on("data", (d) => {
        // Cap at 2 KiB — first error line is what matters for diagnostics.
        if (this._stderrBuf.length < 2048) {
          this._stderrBuf += String(d).slice(0, 2048 - this._stderrBuf.length);
        }
      });
    }
    try {
      const res = await this._request("initialize", {
        protocolVersion: PROTOCOL_VERSION,
        capabilities: {},
        clientInfo: { name: "sspower-bridge", version: "1" },
      }, initTimeoutMs);
      if (!res || !res.result) { await this.stop(); return false; }
      this._notify("notifications/initialized", {});
      return true;
    } catch {
      await this.stop();
      return false;
    }
  }

  // Call the codex-lsp `diagnostics` tool for one absolute file path.
  // severity defaults to "error". Returns { ok, text } — ok=false on
  // timeout/error (fail-open; caller treats as unavailable).
  async diagnostics(filePath, perCallTimeoutMs = 30000, severity = "error") {
    this.lastReason = "";
    const _stderr = () => (this._stderrBuf.split("\n").find((l) => l.trim()) || "").slice(0, 200);
    try {
      const res = await this._request("tools/call", {
        name: "diagnostics",
        arguments: { filePath, severity },
      }, perCallTimeoutMs);
      if (!res) { this.lastReason = `timeout_or_no_response${_stderr() ? `: ${_stderr()}` : ""}`; return { ok: false, text: "" }; }
      if (res.error) { this.lastReason = `jsonrpc_error: ${(res.error.message || JSON.stringify(res.error)).slice(0, 160)}`; return { ok: false, text: "" }; }
      if (!res.result) { this.lastReason = "no_result_field"; return { ok: false, text: "" }; }
      // MCP tool-level failure (server crash/timeout/dep-missing) comes back
      // as a SUCCESSFUL JSON-RPC response with result.isError===true. Capture
      // first text block as the reason so callers can surface actionable info.
      if (res.result.isError) {
        const errText = (res.result.content || [])
          .filter((b) => b && b.type === "text")
          .map((b) => b.text)
          .join(" | ")
          .slice(0, 200);
        this.lastReason = `tool_error: ${errText || _stderr() || "unknown"}`;
        return { ok: false, text: "" };
      }
      // codex-lsp signals infra absence (missing language server, no source
      // files) as a SUCCESSFUL response with isError:false but a non-diagnostic
      // details.errorKind. Treat these as fail-open unavailable (D-B7), NOT as
      // code diagnostics — else a machine merely lacking a server false-blocks.
      const ek = res.result.details && res.result.details.errorKind;
      if (ek === "missing_dependency" || ek === "no_files") {
        this.lastReason = `infra: ${ek}`;
        return { ok: false, text: "" };
      }
      const text = (res.result.content || [])
        .filter((b) => b && b.type === "text")
        .map((b) => b.text)
        .join("\n");
      return { ok: true, text };
    } catch (e) {
      this.lastReason = `throw: ${(e && e.message || String(e)).slice(0, 160)}`;
      return { ok: false, text: "" };
    }
  }

  // Explicit shutdown + process kill. Idempotent, never throws.
  async stop() {
    try { this._notify("notifications/cancelled", {}); } catch { /* ignore */ }
    try { this.child && this.child.kill("SIGTERM"); } catch { /* ignore */ }
    this._failAll();
  }

  _onData(chunk) {
    this._buf += chunk;
    let nl;
    while ((nl = this._buf.indexOf("\n")) >= 0) {
      const line = this._buf.slice(0, nl).trim();
      this._buf = this._buf.slice(nl + 1);
      if (!line) continue;
      let msg;
      try { msg = JSON.parse(line); } catch { continue; }
      if (msg.id != null && this._pending.has(msg.id)) {
        const { resolve, timer } = this._pending.get(msg.id);
        clearTimeout(timer);
        this._pending.delete(msg.id);
        resolve(msg);
      }
    }
  }

  _request(method, params, timeoutMs) {
    return new Promise((resolve) => {
      const id = this._nextId++;
      const timer = setTimeout(() => {
        if (this._pending.has(id)) {
          this._pending.delete(id);
          resolve(null); // fail-open: timeout → null, caller degrades
        }
      }, timeoutMs);
      this._pending.set(id, { resolve, timer });
      const ok = this._write({ jsonrpc: "2.0", id, method, params });
      if (!ok) {
        clearTimeout(timer);
        this._pending.delete(id);
        resolve(null);
      }
    });
  }

  _notify(method, params) {
    this._write({ jsonrpc: "2.0", method, params });
  }

  _write(obj) {
    try {
      if (!this.child || this.child.killed || !this.child.stdin.writable) return false;
      return this.child.stdin.write(JSON.stringify(obj) + "\n");
    } catch {
      return false;
    }
  }

  _failAll() {
    for (const { resolve, timer } of this._pending.values()) {
      clearTimeout(timer);
      resolve(null);
    }
    this._pending.clear();
  }
}

// Clean-diagnostics detection mirrors codex-lsp's own codex-hook.js:
// clean === empty, "No diagnostics found", or "No LSP server configured…".
export function isCleanDiagnosticsText(text) {
  const t = (text || "").trim();
  return (
    t.length === 0 ||
    t === "No diagnostics found" ||
    t.startsWith("No LSP server configured for extension:") ||
    t.includes("is configured but NOT INSTALLED")
  );
}
