#!/usr/bin/env node

/**
 * codex-bridge.mjs — sspower's direct bridge to the Codex CLI.
 *
 * Calls `codex exec` with structured output schemas so SDD can treat
 * Codex as a first-class subagent with the same contract as Claude.
 *
 * Session management: `implement` and `rescue --write` runs persist sessions
 * (no --ephemeral) so they can be resumed for fix loops. The session ID is
 * printed to stderr as `[codex:session] <id>` and can be passed to `resume`
 * via --session-id to target the correct thread.
 *
 * Usage:
 *   node codex-bridge.mjs setup
 *   node codex-bridge.mjs implement  --prompt <text|@file> [--write] [--model <m>] [--effort <e>] [--cd <dir>]
 *   node codex-bridge.mjs spec-review --prompt <text|@file> [--model <m>] [--cd <dir>]
 *   node codex-bridge.mjs plan-review --prompt <text|@file> [--profile <p>] [--model <m>] [--cd <dir>]
 *   node codex-bridge.mjs review     --prompt <text|@file> [--model <m>] [--cd <dir>]
 *   node codex-bridge.mjs rescue     [DISABLED — see spec D-A3; use plan-review/review/implement]
 *   node codex-bridge.mjs resume     --prompt <text|@file> [--session-id <id>] [--model <m>] [--cd <dir>]
 */

import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const _sspowerCfg = require("../hooks/_config.js");
import * as registry from "./codex-registry.mjs";
import { resolveCodexLspCli } from "./lib/codex-lsp-path.mjs";
import { McpLspClient, isCleanDiagnosticsText } from "./mcp-lsp-client.mjs";

const BRIDGE_DIR = path.dirname(fileURLToPath(import.meta.url));
const PLUGIN_ROOT = path.resolve(BRIDGE_DIR, "..");
const SCHEMAS_DIR = path.join(PLUGIN_ROOT, "schemas");

const VALID_EFFORTS = new Set(["none", "minimal", "low", "medium", "high", "xhigh"]);
// Model/effort defaults removed (spec P1, 2026-05-18): tier/model/effort are
// governed by ~/.codex/config.toml profiles via COMMAND_PROFILE + -p. The
// bridge no longer force-resolves a default model/effort (that killed profiles).

// Per-command default profile (single source of truth = ~/.codex/config.toml).
// Bridge passes `-p <profile>` unless the user gave an explicit --profile.
// `resume` is intentionally absent: `codex exec resume` has NO --profile;
// it inherits root config.toml (root service_tier=flex is load-bearing).
const COMMAND_PROFILE = {
  complete: "quick",
  enrich: "quick",
  implement: "normal",
  review: "normal",
  "spec-review": "normal",
  "plan-review": "normal",
  rescue: "normal",
};

// Failure log (structured JSONL, ring-buffered)
const FAILURE_LOG = _sspowerCfg.failuresLogPath();
const FAILURE_LOG_MAX = 2000;
const FAILURE_LOG_KEEP = 1000;

// ── Diagnostics log ──────────────────────────────────────────────────
// Single append-only file at ~/.claude/sspower/codex.log, rotated at
// log_rotate_lines (default 1000). Failures at ~/.claude/sspower/failures.jsonl.
// Captures errors + warnings for post-mortem via `codex-diagnostics` skill.

const LOG_FILE = _sspowerCfg.codexLogPath();
const LOG_MAX_LINES = (() => {
  try {
    const v = _sspowerCfg.readConfig().log_rotate_lines;
    return Number.isInteger(v) && v > 0 ? v : 1000;
  } catch { return 1000; }
})();
try { fs.mkdirSync(_sspowerCfg.sspowerDir(), { recursive: true }); } catch { /* best effort */ }
const LOG_KEEP_TAIL = 500;

let _logRotated = false;
function rotateLogOnce() {
  if (_logRotated) return;
  _logRotated = true;
  try {
    if (!fs.existsSync(LOG_FILE)) return;
    const content = fs.readFileSync(LOG_FILE, "utf8");
    const lines = content.split("\n");
    if (lines.length > LOG_MAX_LINES) {
      const kept = lines.slice(-LOG_KEEP_TAIL).join("\n");
      fs.writeFileSync(LOG_FILE, kept, { mode: 0o600 });
    }
  } catch { /* best effort */ }
}

function logEvent(kind /* "error" | "warn" | "info" */, source /* e.g. "bridge.enrich" */, fields = {}) {
  rotateLogOnce();
  const ts = new Date().toISOString();
  const parts = Object.entries(fields)
    .filter(([, v]) => v !== undefined && v !== null && v !== "")
    .map(([k, v]) => `${k}=${JSON.stringify(typeof v === "string" ? v.slice(0, 500) : v)}`)
    .join(" ");
  const line = `${ts} [${kind}] ${source}${parts ? " " + parts : ""}\n`;
  try {
    fs.mkdirSync(path.dirname(LOG_FILE), { recursive: true });
    fs.appendFileSync(LOG_FILE, line, { mode: 0o600 });
  } catch { /* fail open */ }
}

// ── Secure temp files ────────────────────────────────────────────────

let _tmpDir = null;

function secureTmpDir() {
  if (!_tmpDir) {
    _tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "sspower-codex-"));
    fs.chmodSync(_tmpDir, 0o700);
  }
  return _tmpDir;
}

function secureTmpFile(prefix, content) {
  const filePath = path.join(secureTmpDir(), `${prefix}-${Date.now()}`);
  fs.writeFileSync(filePath, content, { mode: 0o600 });
  return filePath;
}

function cleanupTmpDir() {
  if (_tmpDir) {
    try { fs.rmSync(_tmpDir, { recursive: true, force: true }); } catch { /* ok */ }
  }
}

// ── Helpers ──────────────────────────────────────────────────────────

function die(msg) {
  cleanupTmpDir();
  logEvent("error", "bridge.die", { msg, subcommand: process.argv[2] });
  console.error(`codex-bridge: ${msg}`);
  process.exit(1);
}

function classifyError(stderr = "", exitCode, durationMs) {
  const s = stderr.toLowerCase();
  if (s.includes("timed out") || durationMs > 540000) return "timeout";
  if (s.includes("trusted directory") || s.includes("sandbox")) return "sandbox";
  if (s.includes("rate limit") || /\b(429|503|502|504)\b/.test(s)) return "api";
  if (s.includes("prompt file not found")) return "prompt_missing";
  if (s.includes("returned no output")) return "no_output";
  if (s.includes("no rollout found")) return "stale_session";
  if (s.includes("network") || s.includes("dns")) return "network";
  if (exitCode === 124 || exitCode === 137) return "timeout";
  return "unknown";
}

function appendFailure(entry) {
  try {
    fs.mkdirSync(path.dirname(FAILURE_LOG), { recursive: true });
    fs.appendFileSync(FAILURE_LOG, JSON.stringify(entry) + "\n");
    // Ring-buffer rotation
    const lines = fs.readFileSync(FAILURE_LOG, "utf8").trim().split("\n");
    if (lines.length > FAILURE_LOG_MAX) {
      const kept = lines.slice(-FAILURE_LOG_KEEP).join("\n") + "\n";
      fs.writeFileSync(FAILURE_LOG, kept);
    }
  } catch { /* best-effort, never crash */ }
}

function redactSecrets(text = "") {
  return String(text)
    .replace(/(sk-[A-Za-z0-9_-]{20,})/g, "sk-***REDACTED***")
    .replace(/(gh[ps]_[A-Za-z0-9]{20,})/g, "gh*_***REDACTED***")
    .replace(/(password|passwd|secret|api[_-]?key|token)\s*[:=]\s*\S+/gi, "$1=***REDACTED***");
}

function resolvePrompt(raw) {
  if (!raw) die("--prompt is required");
  if (raw.startsWith("@")) {
    const filePath = raw.slice(1);
    if (!fs.existsSync(filePath)) die(`prompt file not found: ${filePath}`);
    return fs.readFileSync(filePath, "utf8");
  }
  return raw;
}

function schemaPath(name) {
  const p = path.join(SCHEMAS_DIR, `${name}.json`);
  if (!fs.existsSync(p)) die(`schema not found: ${p}`);
  return p;
}

function codexBin() {
  try {
    return execFileSync("which", ["codex"], { encoding: "utf8" }).trim();
  } catch {
    die("codex CLI not found. Install with: npm install -g @openai/codex");
  }
}

function cleanStderr(stderr) {
  return stderr
    .split(/\r?\n/)
    .map((l) => l.trimEnd())
    .filter((l) => l && !l.startsWith("WARNING: proceeding"))
    .join("\n");
}

/**
 * Extract session ID from codex JSONL output.
 * The session ID appears in the startup banner or JSONL events.
 */
function extractSessionId(stdout) {
  // Try JSONL events first
  for (const line of stdout.split("\n")) {
    try {
      const event = JSON.parse(line);
      if (event.session_id) return event.session_id;
      if (event.conversation?.id) return event.conversation.id;
      if (event.thread_id) return event.thread_id;
    } catch { /* not JSON */ }
  }
  // Try banner format: "session id: <uuid>"
  const bannerMatch = stdout.match(/session id:\s*([0-9a-f-]{36})/i);
  if (bannerMatch) return bannerMatch[1];
  return null;
}

// ── Worktree & auto-commit ───────────────────────────────────────────

/**
 * Create a git worktree for isolated Codex work.
 * Returns { worktreePath, branch } or null if --worktree not requested.
 */
function createWorktree(repoDir, branch) {
  const worktreeBase = path.join(repoDir, ".worktrees");
  const worktreePath = path.join(worktreeBase, branch);

  // Create .worktrees dir if needed
  if (!fs.existsSync(worktreeBase)) {
    fs.mkdirSync(worktreeBase, { recursive: true });
  }

  // Remove stale worktree at this path if it exists
  try {
    execFileSync("git", ["-C", repoDir, "worktree", "remove", worktreePath, "--force"], {
      stdio: "ignore",
    });
  } catch { /* didn't exist, fine */ }

  // Create worktree with new branch
  try {
    execFileSync("git", ["-C", repoDir, "worktree", "add", "-b", branch, worktreePath], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
  } catch (e) {
    // Branch may already exist — try without -b
    try {
      execFileSync("git", ["-C", repoDir, "worktree", "add", worktreePath, branch], {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (e2) {
      die(`Failed to create worktree: ${e2.message}`);
    }
  }

  return { worktreePath, branch };
}

/**
 * Auto-commit all changes in a directory after successful Codex work.
 * Returns the commit SHA or null if nothing to commit.
 */
function autoCommit(dir, message, opts = {}) {
  try {
    const { baseHead = null } = opts;

    // If a pre-codex HEAD snapshot was supplied, refuse to commit when it
    // changed: codex (running with workspace-write + writable_roots on the
    // worktree-private gitdir) could have rewritten HEAD/ORIG_HEAD to point
    // at an attacker-controlled commit. A subsequent host-side commit would
    // then attach to that tainted parent. Force human review instead.
    if (baseHead) {
      const currHead = execFileSync("git", ["-C", dir, "rev-parse", "HEAD"], {
        encoding: "utf8",
      }).trim();
      if (currHead !== baseHead) {
        logEvent("warn", "bridge.auto_commit", {
          kind: "head_changed", dir, baseHead, currHead,
        });
        process.stderr.write(`[codex:auto-commit] Refused: HEAD changed during codex run (${baseHead.slice(0,8)} -> ${currHead.slice(0,8)}). Inspect manually.\n`);
        return null;
      }

      // Reject planted commit-state files. Codex with writable_roots on the
      // worktree-private gitdir could create MERGE_HEAD / CHERRY_PICK_HEAD
      // / REVERT_HEAD / REBASE_HEAD pointing at an attacker-controlled
      // commit; the next `git commit` would attach as a merge/cherry-pick
      // with that tainted parent. None of these should exist for a clean
      // single-parent autoCommit.
      for (const ref of ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD"]) {
        try {
          execFileSync("git", ["-C", dir, "rev-parse", "--verify", "-q", ref], {
            stdio: ["ignore", "ignore", "ignore"],
          });
          // Did not throw → file exists → abort.
          logEvent("warn", "bridge.auto_commit", {
            kind: "state_file_planted", dir, ref,
          });
          process.stderr.write(`[codex:auto-commit] Refused: ${ref} present (would create unintended merge/cherry-pick parent). Inspect manually.\n`);
          return null;
        } catch {
          // Throws when ref doesn't exist — desired state.
        }
      }
    }

    // Stage all changes
    execFileSync("git", ["-C", dir, "add", "-A"], { stdio: "ignore" });

    // Check if there's anything to commit
    const status = execFileSync("git", ["-C", dir, "status", "--porcelain"], {
      encoding: "utf8",
    }).trim();

    if (!status) return null;

    // Commit
    execFileSync("git", ["-C", dir, "commit", "-m", message], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });

    // Return SHA
    const sha = execFileSync("git", ["-C", dir, "rev-parse", "HEAD"], {
      encoding: "utf8",
    }).trim();

    return sha;
  } catch (e) {
    logEvent("warn", "bridge.auto_commit", { kind: "commit_failed", msg: e.message, dir });
    process.stderr.write(`[codex:auto-commit] Failed: ${e.message}\n`);
    return null;
  }
}

// ── Core executors ───────────────────────────────────────────────────

// Per-run advisory LSP MCP registration (Track B P2). Returns the -c
// override argv pairs registering the vendored codex-lsp as `mcp_servers.lsp`,
// or [] (fail-open) if codex-lsp is unresolved. No file is written — Codex
// 0.130.0 only merges ~/.codex/config.toml + -c overrides, never a project
// .codex/config.toml, so -c is the clobber-free mechanism. Advisory: the
// server is registered as callable but never required (P2; required=true is P3).
function lspMcpOverrideArgs() {
  const cli = resolveCodexLspCli();
  if (!cli) {
    logEvent("info", "bridge.lsp", { kind: "codex_lsp_unresolved_skip" });
    return [];
  }
  const j = (v) => JSON.stringify(v); // TOML basic strings == JSON strings for these values
  return [
    "-c", `mcp_servers.lsp.command=${j("node")}`,
    "-c", `mcp_servers.lsp.args=${j([cli, "mcp"])}`,
    "-c", `mcp_servers.lsp.env.PATH=${j(process.env.PATH || "")}`,
    "-c", `mcp_servers.lsp.env.HOME=${j(os.homedir())}`,
  ];
}

/**
 * Run `codex exec` for fresh tasks (implement, review, rescue).
 * Supports --output-schema, --sandbox, -C, --full-auto.
 */
function runCodexExec(prompt, options = {}) {
  const {
    schema = null,
    sandbox = "read-only",
    profile = null,
    model = null,
    effort = null,
    cd = null,
    ephemeral = true,
    hardenWrite = false,
    lspMcp = false,
  } = options;

  const bin = codexBin();
  const resultFile = secureTmpFile("result", "");

  const args = ["exec"];
  args.push("--json");
  if (ephemeral) args.push("--ephemeral");
  args.push("--sandbox", sandbox);
  // D-B5: hardened write profile. approval_policy=never (no interactive
  // approvals in non-interactive exec) + network_access=false (model-spawned
  // shell gets no network; Codex's own LLM channel is unaffected -- D-5).
  // Scoped to the implement --write path only (D-4); reviews stay read-only.
  if (hardenWrite) {
    args.push("-c", 'approval_policy="never"');
    args.push("-c", "sandbox_workspace_write.network_access=false");
  }
  args.push("-o", resultFile);

  if (schema) args.push("--output-schema", schema);
  if (profile) args.push("-p", profile);
  if (model) args.push("-m", model);
  if (effort) args.push("-c", `model_reasoning_effort="${effort}"`);
  const _lspArgs = lspMcp ? lspMcpOverrideArgs() : [];
  for (const a of _lspArgs) args.push(a);
  // Normalize --cd to absolute path. Otherwise -C and spawnOpts.cwd both
  // apply, resolving as "<cd>/<cd>" when the caller passes a relative path.
  const cdAbs = cd ? path.resolve(cd) : null;
  if (cdAbs) args.push("-C", cdAbs);


  const promptFile = secureTmpFile("prompt", prompt);
  args.push("-");

  if (options.printArgs) {
    process.stdout.write(JSON.stringify({ bin: codexBin(), args, mcpLsp: _lspArgs.length > 0 }) + "\n");
    process.exit(0);
  }

  // Pass cd through so registry records the actual Codex working dir,
  // not bridge process cwd. Codex itself uses -C flag set above.
  return _spawnAndCapture(bin, args, promptFile, resultFile, schema, cdAbs);
}

/**
 * Run `codex exec resume` for fix loops.
 * Only supports flags that `codex exec resume` accepts:
 * SESSION_ID, --last, --full-auto, -m, -o, --json
 * Does NOT support --sandbox, -C, --output-schema, --ephemeral.
 *
 * Since --output-schema is unavailable for resume, we wrap the prompt
 * with an explicit JSON instruction when a schema name is provided.
 * The bridge then parses the JSON from the response text.
 */
function runCodexResume(prompt, options = {}) {
  const {
    sessionId = null,
    model = null,
    effort = null,
    schemaName = null,
    cd = null,
    hardenWrite = false,
    lspMcp = false,
  } = options;

  const bin = codexBin();
  const resultFile = secureTmpFile("result", "");

  const args = ["exec", "resume"];

  if (sessionId) {
    args.push(sessionId);
  } else {
    args.push("--last");
  }

  args.push("--json");
  args.push("-o", resultFile);
  if (model) args.push("-m", model);
  if (effort) args.push("-c", `model_reasoning_effort="${effort}"`);
  // D-4a: codex exec resume does NOT inherit the originating session's
  // sandbox/approval/network config (Task 0 spike: resume ran network-ON).
  // It DOES accept these -c overrides (verified: network blocked with them).
  // Re-apply the same hardening as runCodexExec so repair-loop resumes are
  // not a network-ON hole during gate-triggered edits.
  if (hardenWrite) {
    args.push("-c", 'approval_policy="never"');
    args.push("-c", "sandbox_workspace_write.network_access=false");
  }
  const _lspArgs = lspMcp ? lspMcpOverrideArgs() : [];
  for (const a of _lspArgs) args.push(a);

  // Wrap prompt with structured output instruction when schema requested
  let finalPrompt = prompt;
  if (schemaName) {
    const schema = JSON.parse(fs.readFileSync(schemaPath(schemaName), "utf8"));
    const fields = Object.keys(schema.properties || {}).join(", ");
    finalPrompt = `${prompt}\n\nIMPORTANT: After completing the work above, respond with ONLY a JSON object matching this exact structure (fields: ${fields}). No markdown fences, no commentary — just the raw JSON object.\n\nSchema:\n${JSON.stringify(schema, null, 2)}`;
  }

  const promptFile = secureTmpFile("prompt", finalPrompt);
  args.push("-");

  if (options.printArgs) {
    process.stdout.write(JSON.stringify({ bin: codexBin(), args, mcpLsp: _lspArgs.length > 0 }) + "\n");
    process.exit(0);
  }

  // Codex `exec resume` doesn't accept -C, so spawn cwd is the only
  // mechanism. Normalize to absolute path for the same reason runCodexExec does.
  const cdAbs = cd ? path.resolve(cd) : null;
  // Pass schemaName so parser knows to attempt structured extraction
  return _spawnAndCapture(bin, args, promptFile, resultFile, schemaName ? schemaPath(schemaName) : null, cdAbs);
}

/**
 * Render a Codex JSONL event as a tagged stderr line.
 * Covers the event types we care about; unknown types get a generic tag.
 * Returns the event "kind" for heartbeat/trace tracking.
 */
function renderEvent(event) {
  const trunc = (s, n = 120) => {
    if (!s) return "";
    const one = String(s).replace(/\s+/g, " ").trim();
    return one.length > n ? one.slice(0, n) + "…" : one;
  };

  const t = event.type || event.kind || "";

  // v0.124+ shape: thread.started carries thread_id (session identifier)
  if (t === "thread.started" && event.thread_id) {
    return { kind: "session", line: `[codex:session] ${event.thread_id}` };
  }

  if (event.session_id || event.conversation?.id) {
    const id = event.session_id || event.conversation.id;
    return { kind: "session", line: `[codex:session] ${id}` };
  }

  // v0.124+ shape: item.started / item.completed wrap the real payload in event.item
  if ((t === "item.started" || t === "item.completed") && event.item) {
    const it = event.item;
    const itype = it.type || "";
    if (itype === "agent_message") {
      if (t === "item.completed" && it.text) {
        return { kind: "agent", line: `[codex:agent] ${trunc(it.text)}` };
      }
      return { kind: "agent", line: null };
    }
    if (itype === "reasoning") {
      const text = it.text || it.content || "";
      if (text && t === "item.completed") {
        return { kind: "think", line: `[codex:think] ${trunc(text)}` };
      }
      return { kind: "think", line: null };
    }
    if (itype === "command_execution") {
      if (t === "item.started") {
        return { kind: "exec", line: `[codex:exec] ${trunc(it.command, 100)}` };
      }
      const code = it.exit_code ?? "?";
      const out = trunc(it.aggregated_output || "", 80);
      return { kind: "result", line: `[codex:result] exit=${code} ${out}` };
    }
    if (itype === "file_change" || itype === "patch_apply" || itype === "edit") {
      const p = it.path || it.file || "?";
      return { kind: "edit", line: `[codex:edit] ${p}` };
    }
    if (itype === "error") {
      return { kind: "error", line: `[codex:error] ${trunc(it.message || JSON.stringify(it), 200)}` };
    }
    return { kind: itype, line: `[codex:event] item.${itype}` };
  }

  // v0.124+ shape: turn.completed carries usage at top level
  if (t === "turn.completed" && event.usage) {
    const u = event.usage;
    const inTok = u.input_tokens ?? u.input ?? u.prompt_tokens;
    const outTok = u.output_tokens ?? u.output ?? u.completion_tokens;
    const cached = u.cached_input_tokens;
    const total = (inTok != null && outTok != null) ? inTok + outTok : (u.total ?? u.total_tokens);
    return {
      kind: "token",
      line: `[codex:token] in=${inTok ?? "?"} out=${outTok ?? "?"} total=${total ?? "?"}${cached != null ? ` cached=${cached}` : ""}`,
    };
  }

  if (t === "turn.started") return { kind: "turn", line: null };
  if (t === "turn.completed") return { kind: "done", line: null };
  if (t === "turn_aborted") {
    return { kind: "error", line: `[codex:error] turn aborted${event.reason ? `: ${event.reason}` : ""}` };
  }
  if (t === "stream_error") {
    return { kind: "error", line: `[codex:error] stream_error ${trunc(event.message || event.error || JSON.stringify(event), 200)}` };
  }

  // v0.124 top-level command_execution events (not always wrapped in item.*)
  if (t === "exec_command_begin") {
    return { kind: "exec", line: `[codex:exec] ${trunc(event.command || event.cmd || "", 100)}` };
  }
  // Output deltas stream many times per command — classify but emit nothing
  if (t === "exec_command_output_delta") return { kind: "stream", line: null };
  if (t === "exec_command_end") {
    const code = event.exit_code ?? "?";
    return { kind: "result", line: `[codex:result] exit=${code} ${trunc(event.aggregated_output || event.output || "", 80)}` };
  }

  // v0.124 top-level patch_apply events. Render each lifecycle phase for
  // visibility, but only count patch_apply_end (or patch_apply_updated) as a
  // finished edit so trace.edits reflects applied changes, not events.
  if (t === "patch_apply_begin" || t === "patch_apply_updated" || t === "patch_apply_end") {
    const extractPaths = (ev) => {
      if (ev.path || ev.file) return ev.path || ev.file;
      if (!Array.isArray(ev.changes)) return null;
      const joined = ev.changes.map(c => c.path || c.file).filter(Boolean).join(",");
      return joined || null;
    };
    const p = extractPaths(event) || "?";
    const failed = event.success === false || event.status === "failed" || event.error != null;
    const suffix = t === "patch_apply_end"
      ? (failed ? " (failed)" : " (done)")
      : (t === "patch_apply_begin" ? " (begin)" : "");
    const line = `[codex:edit] ${p}${suffix}`;
    // Only count a successful _end as an applied edit; failures and interim
    // phases render for visibility but don't inflate trace.edits.
    if (t === "patch_apply_end" && !failed) return { kind: "edit", line };
    return { kind: "patch_phase", line };
  }

  // v0.124 top-level MCP tool events
  if (t === "mcp_tool_call_begin") {
    const name = event.name || event.tool || "?";
    const argsPreview = trunc(JSON.stringify(event.arguments || event.args || {}), 80);
    return { kind: "tool", line: `[codex:tool] ${name}(${argsPreview})` };
  }
  if (t === "mcp_tool_call_end") {
    return { kind: "result", line: `[codex:result] ${trunc(event.result || event.output || "", 80)}` };
  }

  if (t === "agent" && event.agent?.content) {
    return { kind: "agent", line: `[codex:agent] ${trunc(event.agent.content)}` };
  }
  if (t === "reasoning" || t === "reasoning.delta" || event.reasoning) {
    const text = event.reasoning?.content || event.delta || event.text || "";
    if (text) return { kind: "think", line: `[codex:think] ${trunc(text)}` };
    return { kind: "think", line: null };
  }
  if (t === "tool_call" || t === "tool.call" || event.tool_call) {
    const tc = event.tool_call || event;
    const name = tc.name || tc.tool || "?";
    const argsPreview = trunc(JSON.stringify(tc.arguments || tc.args || {}), 80);
    return { kind: "tool", line: `[codex:tool] ${name}(${argsPreview})` };
  }
  if (t === "tool_result" || t === "tool.result") {
    const r = event.result || event.output || "";
    return { kind: "result", line: `[codex:result] ${trunc(r, 80)}` };
  }
  if (t === "file_change" || t === "patch" || event.file_change) {
    const fc = event.file_change || event;
    const p = fc.path || fc.file || "?";
    const add = fc.added ?? fc.additions ?? "";
    const del = fc.removed ?? fc.deletions ?? "";
    return { kind: "edit", line: `[codex:edit] ${p} +${add} -${del}` };
  }
  if (t === "exec" || t === "shell" || event.command) {
    const cmd = event.command || event.cmd || "";
    return { kind: "exec", line: `[codex:exec] ${trunc(cmd, 100)}` };
  }
  if (t === "token_count" || t === "usage" || event.usage || event.tokens) {
    const u = event.usage || event.tokens || {};
    return {
      kind: "token",
      line: `[codex:token] in=${u.input ?? u.prompt_tokens ?? "?"} out=${u.output ?? u.completion_tokens ?? "?"} total=${u.total ?? u.total_tokens ?? "?"}`,
    };
  }
  if (t === "error" || event.error) {
    const msg = event.error?.message || event.message || JSON.stringify(event.error || {});
    return { kind: "error", line: `[codex:error] ${trunc(msg, 200)}` };
  }
  if (t === "turn_complete" || t === "done") {
    return { kind: "done", line: null };
  }
  // Unknown event — surface compact so schema drift is visible
  if (t) {
    return { kind: t, line: `[codex:event] ${t}` };
  }
  return { kind: "unknown", line: null };
}

/**
 * Shared spawn logic for both exec and resume paths.
 * Streams Codex JSONL to stderr as tagged events and tracks a trace summary.
 */
function _spawnAndCapture(bin, args, promptFile, resultFile, schema, cwd = null) {
  return new Promise((resolve, reject) => {
    let stderr = "";
    const startedAt = Date.now();
    let sessionIdEmitted = null;
    const trace = {
      tool_calls: 0,
      edits: 0,
      execs: 0,
      errors: 0,
      tokens: { input: null, output: null, total: null },
    };

    const promptStream = fs.createReadStream(promptFile);
    // Re-entry guard: tag the child process so the auto-review /
    // auto-spec-gate hooks short-circuit if codex itself runs git
    // push / commit during the review. Depth counter is the backstop
    // when SSPOWER_REVIEW_IN_FLIGHT is unset (e.g. wrapper that
    // strips env vars).
    const childEnv = { ...process.env };
    childEnv.SSPOWER_REVIEW_IN_FLIGHT = "1";
    childEnv.SSPOWER_REVIEW_DEPTH = String(
      parseInt(process.env.SSPOWER_REVIEW_DEPTH || "0", 10) + 1
    );
    const spawnOpts = {
      stdio: ["pipe", "pipe", "pipe"],
      env: childEnv,
    };
    if (cwd) spawnOpts.cwd = cwd;
    const child = spawn(bin, args, spawnOpts);

    promptStream.pipe(child.stdin);

    // Heartbeat: surface liveness if no event for >30s of silence
    let lastEventAt = Date.now();
    let lastEventKind = "start";
    const heartbeat = setInterval(() => {
      const silent = Date.now() - lastEventAt;
      if (silent >= 30_000) {
        const elapsed = ((Date.now() - startedAt) / 1000).toFixed(0);
        process.stderr.write(`[codex:alive] ${elapsed}s elapsed, silent ${(silent / 1000).toFixed(0)}s, last: ${lastEventKind}\n`);
      }
    }, 30_000);

    // Registry: write initial state when session ID first emitted.
    // Registry is observability — failures must NEVER crash the bridge.
    let stateRecord = null;
    let registryDisabled = false;
    const safeRegistryCall = (fn, kind) => {
      if (registryDisabled) return;
      try { fn(); } catch (e) {
        registryDisabled = true; // disable further attempts this run
        logEvent("warn", `registry.${kind}`, { msg: e.message?.slice(0, 200) });
        process.stderr.write(`[codex:registry] disabled after ${kind} error: ${e.message}\n`);
      }
    };
    const initState = (sessionId) => {
      if (stateRecord || registryDisabled) return;
      stateRecord = {
        session_id: sessionId,
        pid: child.pid,
        bridge_pid: process.pid,
        subcommand: process.argv[2],
        cwd: cwd || process.cwd(),
        started_at: new Date(startedAt).toISOString(),
        updated_at: new Date().toISOString(),
        status: "running",
        phase: "start",
        last_kind: "start",
        last_event: null,
        trace: { ...trace },
        duration_ms: 0,
        exit_code: null,
      };
      safeRegistryCall(() => registry.writeState(stateRecord), "init");
    };

    const updateState = (kind, line, event) => {
      if (!stateRecord || registryDisabled) return;
      stateRecord.updated_at = new Date().toISOString();
      stateRecord.phase = kind;
      stateRecord.last_kind = kind;
      if (line) stateRecord.last_event = line;
      stateRecord.trace = { ...trace };
      stateRecord.duration_ms = Date.now() - startedAt;
      safeRegistryCall(() => {
        registry.writeState(stateRecord);
        registry.appendEvent(stateRecord.session_id, event);
      }, "update");
    };

    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });

    const stdoutChunks = [];
    let lineBuf = "";
    child.stdout.on("data", (chunk) => {
      stdoutChunks.push(chunk);
      lineBuf += chunk.toString();
      const lines = lineBuf.split("\n");
      lineBuf = lines.pop() ?? "";
      for (const line of lines) {
        if (!line) continue;
        let event;
        try { event = JSON.parse(line); } catch { continue; }

        // Emit session id at first sight, not at end
        const id = event.session_id || event.conversation?.id || event.thread_id;
        if (id && !sessionIdEmitted) {
          sessionIdEmitted = id;
          initState(id);
        }

        const { kind, line: renderedLine } = renderEvent(event);
        if (renderedLine) process.stderr.write(renderedLine + "\n");
        lastEventAt = Date.now();
        lastEventKind = kind;
        if (kind === "tool") trace.tool_calls++;
        else if (kind === "edit") trace.edits++;
        else if (kind === "exec") trace.execs++;
        else if (kind === "error") trace.errors++;
        else if (kind === "token") {
          const u = event.usage || event.tokens || {};
          const inTok = u.input_tokens ?? u.input ?? u.prompt_tokens;
          const outTok = u.output_tokens ?? u.output ?? u.completion_tokens;
          if (inTok != null) trace.tokens.input = inTok;
          if (outTok != null) trace.tokens.output = outTok;
          const total = u.total ?? u.total_tokens ?? ((inTok != null && outTok != null) ? inTok + outTok : null);
          if (total != null) trace.tokens.total = total;
        }

        if (sessionIdEmitted) updateState(kind, renderedLine, event);
      }
    });

    child.on("close", (code) => {
      clearInterval(heartbeat);
      let lastMessage = "";
      try {
        lastMessage = fs.readFileSync(resultFile, "utf8").trim();
      } catch { /* no output file */ }

      try { fs.unlinkSync(resultFile); } catch { /* ok */ }
      try { fs.unlinkSync(promptFile); } catch { /* ok */ }

      const stdout = Buffer.concat(stdoutChunks).toString();

      // Try to parse structured output
      let structured = null;
      if (schema && lastMessage) {
        structured = parseStructuredOutput(lastMessage);
      }

      // Fallback to post-hoc extraction if streaming missed it
      const sessionId = sessionIdEmitted || extractSessionId(stderr + "\n" + stdout);

      const duration_ms = Date.now() - startedAt;
      process.stderr.write(`[codex:done] exit=${code} dur=${(duration_ms / 1000).toFixed(1)}s tools=${trace.tool_calls} edits=${trace.edits} errors=${trace.errors}\n`);

      if (stateRecord) {
        // Race guard: if another process (steer) re-initialized this session,
        // or already marked it killed, do not clobber.
        // Wrap in safeRegistryCall — disk failures here must not crash close handler.
        safeRegistryCall(() => {
          const current = registry.readState(stateRecord.session_id);
          const safeToWrite = !current || (current.pid === stateRecord.pid && current.status !== "killed");
          if (safeToWrite) {
            stateRecord.status = code === 0 ? "done" : "error";
            stateRecord.exit_code = code;
            stateRecord.updated_at = new Date().toISOString();
            stateRecord.duration_ms = Date.now() - startedAt;
            registry.writeState(stateRecord);
          }
          registry.sweep();
        }, "close");
      }

      // Persist failure to JSONL log (best-effort)
      if (code !== 0) {
        appendFailure({
          ts: new Date().toISOString(),
          command: process.argv[2] || "unknown",
          exit_code: code,
          duration_ms,
          model: args.includes("-m") ? args[args.indexOf("-m") + 1] : null,
          effort: (() => {
            const idx = args.indexOf("-c");
            return idx >= 0 ? (args[idx + 1].match(/effort="([^"]+)"/)?.[1] || null) : null;
          })(),
          cwd: cwd || process.cwd(),
          session_id: sessionId,
          error_kind: classifyError(stderr, code, duration_ms),
          stderr_snippet: redactSecrets(cleanStderr(stderr).slice(-500)),
        });
      }

      resolve({
        exitCode: code,
        lastMessage,
        structured,
        sessionId,
        stderr: cleanStderr(stderr),
        stdout,
        trace: { ...trace, duration_ms },
      });
    });

    child.on("error", (err) => {
      clearInterval(heartbeat);
      reject(new Error(`Failed to spawn codex: ${err.message}`));
    });
  });
}

/**
 * Parse structured JSON from Codex output with fallbacks.
 */
function parseStructuredOutput(text) {
  // Direct parse
  try { return JSON.parse(text); } catch { /* continue */ }

  // Fenced code block
  const fenced = text.match(/```(?:json)?\s*\n?([\s\S]*?)\n?```/);
  if (fenced) {
    try { return JSON.parse(fenced[1]); } catch { /* continue */ }
  }

  // First { ... } in prose
  const braceMatch = text.match(/\{[\s\S]*\}/);
  if (braceMatch) {
    try { return JSON.parse(braceMatch[0]); } catch { /* give up */ }
  }

  return null;
}

// ── complete: single-turn OpenAI-shape extractor ─────────────────────
//
// Thin wrapper over `codex exec` for non-agentic chat completions.
// Tool-disable contract (spec §6.2 — achievable-contract baseline):
//   1. --sandbox read-only            (no file writes, no spawns beyond read-only shell)
//   2. Hard system directive prepended (single-turn extractor; do NOT call tools)
//   3. model_reasoning_effort=minimal (lowers chance of tool-use during reasoning)
//   4. Wall-clock cap (default 60s)   (on timeout exit nonzero so caller degrades)
//
// Output (stdout, exit 0):  OpenAI chat.completion JSON
// Output (stderr, exit !=0): {"error":{"type":"...","message":"..."}}
//
// Intentionally NOT wired through _spawnAndCapture: that path carries
// registry writes, heartbeat, structured-output parsing, JSONL event
// rendering — all overhead the index-extract step doesn't want.

const COMPLETE_HARD_DIRECTIVE =
  "You are a single-turn extractor. Do NOT call any tool. Respond with " +
  "the answer directly. If you start to call a tool, stop and answer in text.";

const COMPLETE_DEFAULT_TIMEOUT_MS = 60_000;

function _emitCompleteError(type, message) {
  // Spec error shape (stderr JSON). Distinct from existing output() shape.
  process.stderr.write(
    JSON.stringify({ error: { type, message } }) + "\n",
  );
}

function _buildCompletePrompt(userPrompt, systemMessage) {
  const parts = [COMPLETE_HARD_DIRECTIVE];
  if (systemMessage && systemMessage.trim()) {
    parts.push("", systemMessage.trim());
  }
  parts.push("", userPrompt);
  return parts.join("\n");
}

/**
 * Run `codex exec` for the single-turn complete path.
 * Resolves with { exitCode, stdout, stderr, lastMessage, tokens, sessionId, durationMs, timedOut }.
 * Wall-clock kill enforced: SIGTERM at deadline, SIGKILL 2s later. exitCode 124 on timeout.
 */
function _runCodexComplete(prompt, options) {
  const { profile, model, effort, timeoutMs, printArgs } = options;
  const bin = codexBin();
  const resultFile = secureTmpFile("complete-result", "");
  const promptFile = secureTmpFile("complete-prompt", prompt);

  const args = [
    "exec",
    "--json",
    "--ephemeral",
    "--sandbox", "read-only",
    "-o", resultFile,
    "-",
  ];

  const _stdinIdx = args.lastIndexOf("-");
  const _flags = [];
  if (profile) _flags.push("-p", profile);
  if (model) _flags.push("-m", model);
  if (effort) _flags.push("-c", `model_reasoning_effort="${effort}"`);
  args.splice(_stdinIdx, 0, ..._flags);

  if (printArgs) {
    process.stdout.write(JSON.stringify({ bin: codexBin(), args }) + "\n");
    process.exit(0);
  }

  return new Promise((resolve, reject) => {
    const startedAt = Date.now();
    let stderr = "";
    let stdoutBuf = "";
    let tokens = { input: null, output: null, total: null };
    let sessionId = null;
    let timedOut = false;
    let killed = false;

    const promptStream = fs.createReadStream(promptFile);
    // Inherit re-entry env guards so any nested git chokepoint short-circuits.
    const childEnv = { ...process.env };
    childEnv.SSPOWER_REVIEW_IN_FLIGHT = "1";
    childEnv.SSPOWER_REVIEW_DEPTH = String(
      parseInt(process.env.SSPOWER_REVIEW_DEPTH || "0", 10) + 1,
    );

    // detached:true puts the child in its own process group so a wall-clock
    // kill can take down any grandchildren (e.g. nested sleep, codex spawning
    // shell helpers) by signalling the negative PGID. Without this, a child
    // that has spawned its own subprocesses can keep stdout pipes open after
    // we kill the immediate child, and the bridge would never see 'close'.
    const child = spawn(bin, args, {
      stdio: ["pipe", "pipe", "pipe"],
      env: childEnv,
      detached: true,
    });

    promptStream.pipe(child.stdin);

    child.stderr.on("data", (c) => { stderr += c.toString(); });

    // Parse JSONL stdout incrementally to capture session_id + usage.
    let lineBuf = "";
    child.stdout.on("data", (chunk) => {
      stdoutBuf += chunk.toString();
      lineBuf += chunk.toString();
      const lines = lineBuf.split("\n");
      lineBuf = lines.pop() ?? "";
      for (const line of lines) {
        if (!line) continue;
        let ev;
        try { ev = JSON.parse(line); } catch { continue; }
        const id = ev.session_id || ev.conversation?.id || ev.thread_id;
        if (id && !sessionId) sessionId = id;
        if ((ev.type === "turn.completed" || ev.kind === "turn.completed") && ev.usage) {
          const u = ev.usage;
          const inTok = u.input_tokens ?? u.input ?? u.prompt_tokens;
          const outTok = u.output_tokens ?? u.output ?? u.completion_tokens;
          if (inTok != null) tokens.input = inTok;
          if (outTok != null) tokens.output = outTok;
          const total = u.total ?? u.total_tokens ?? (
            inTok != null && outTok != null ? inTok + outTok : null
          );
          if (total != null) tokens.total = total;
        }
      }
    });

    // Wall-clock kill: SIGTERM the whole process group at deadline,
    // SIGKILL the group 2s after if still alive. Killing by negative
    // PGID ensures any grandchildren (shell helpers, sleeps) die too so
    // stdout pipes close and 'close' fires.
    const killGroup = (sig) => {
      try { process.kill(-child.pid, sig); }
      catch {
        // PGID kill failed (race or unsupported); fall back to direct child kill.
        try { child.kill(sig); } catch { /* gone */ }
      }
    };
    const killTimer = setTimeout(() => {
      timedOut = true;
      killed = true;
      killGroup("SIGTERM");
      setTimeout(() => killGroup("SIGKILL"), 2_000);
    }, timeoutMs);

    child.on("close", (code, signal) => {
      clearTimeout(killTimer);
      let lastMessage = "";
      try {
        lastMessage = fs.readFileSync(resultFile, "utf8").trim();
      } catch { /* ok */ }
      try { fs.unlinkSync(resultFile); } catch { /* ok */ }
      try { fs.unlinkSync(promptFile); } catch { /* ok */ }

      const durationMs = Date.now() - startedAt;
      // Synthesize a nonzero exit code on timeout for stable downstream classification.
      const exitCode = timedOut ? 124 : (code ?? (signal ? 1 : 0));
      resolve({
        exitCode,
        stdout: stdoutBuf,
        stderr: cleanStderr(stderr),
        lastMessage,
        tokens,
        sessionId,
        durationMs,
        timedOut,
        killed,
      });
    });

    child.on("error", (err) => {
      clearTimeout(killTimer);
      try { fs.unlinkSync(resultFile); } catch { /* ok */ }
      try { fs.unlinkSync(promptFile); } catch { /* ok */ }
      reject(err);
    });
  });
}

async function cmdComplete(argv) {
  const opts = parseOpts(argv);
  if (!opts.prompt) {
    _emitCompleteError("invalid_request", "--prompt is required");
    cleanupTmpDir();
    process.exit(1);
  }
  const userPrompt = resolvePrompt(opts.prompt);
  const finalPrompt = _buildCompletePrompt(userPrompt, opts.system);

  const profile = opts.profile || COMMAND_PROFILE.complete;
  const model = opts.model || null;
  const effort = opts.effort || null;
  const timeoutMs = Number.isFinite(opts.timeoutMs) && opts.timeoutMs > 0
    ? opts.timeoutMs
    : COMPLETE_DEFAULT_TIMEOUT_MS;

  let result;
  try {
    result = await _runCodexComplete(finalPrompt, { profile, model, effort, timeoutMs, printArgs: opts.printArgs });
  } catch (err) {
    logEvent("error", "bridge.complete", {
      kind: "spawn_error",
      msg: err.message?.slice(0, 300),
    });
    _emitCompleteError("spawn_error", err.message || String(err));
    cleanupTmpDir();
    process.exit(1);
  }

  if (result.exitCode !== 0) {
    const errorKind = result.timedOut
      ? "timeout"
      : classifyError(result.stderr, result.exitCode, result.durationMs);
    const msg = result.timedOut
      ? `codex complete timed out after ${timeoutMs}ms`
      : (result.stderr || result.lastMessage || `codex exited with code ${result.exitCode}`);
    appendFailure({
      ts: new Date().toISOString(),
      command: "complete",
      exit_code: result.exitCode,
      duration_ms: result.durationMs,
      model,
      effort,
      cwd: process.cwd(),
      session_id: result.sessionId,
      error_kind: errorKind,
      stderr_snippet: redactSecrets(result.stderr.slice(-500)),
    });
    logEvent("error", "bridge.complete", {
      kind: errorKind,
      exitCode: result.exitCode,
      session: result.sessionId,
      duration_ms: result.durationMs,
    });
    _emitCompleteError(errorKind, msg.slice(0, 1000));
    cleanupTmpDir();
    process.exit(1);
  }

  // C9 guard: exit 0 but no model output → structured error, not empty content.
  // _runCodexComplete trims lastMessage (line ~1047), so falsy ⇒ truly empty.
  if (!result.lastMessage) {
    logEvent("error", "bridge.complete", {
      kind: "empty_response",
      session: result.sessionId,
      duration_ms: result.durationMs,
    });
    _emitCompleteError("empty_response", "codex complete produced no output");
    cleanupTmpDir();
    process.exit(1);
  }

  // Build OpenAI chat.completion shape.
  // - id: prefer Codex session_id (consistent with bridge session identity);
  //       fall back to a synthesized chatcmpl-* id if Codex never emitted one.
  // - usage: spec example always shows numbers; if stream cut short and token
  //       fields are null, emit zeros + stderr warning rather than dropping the field.
  const id = result.sessionId
    ? `chatcmpl-${result.sessionId}`
    : `chatcmpl-${Date.now().toString(36)}${Math.random().toString(36).slice(2, 8)}`;

  let prompt_tokens = result.tokens.input;
  let completion_tokens = result.tokens.output;
  let total_tokens = result.tokens.total;
  if (prompt_tokens == null || completion_tokens == null || total_tokens == null) {
    process.stderr.write(
      `[codex:complete] usage tokens missing (in=${prompt_tokens} out=${completion_tokens} total=${total_tokens}); emitting zeros\n`,
    );
    prompt_tokens = prompt_tokens ?? 0;
    completion_tokens = completion_tokens ?? 0;
    total_tokens = total_tokens ?? (prompt_tokens + completion_tokens);
  }

  const payload = {
    id,
    object: "chat.completion",
    // Profile-routed (spec P1): when no explicit --model, the model is
    // governed by the ~/.codex/config.toml profile, not pinned by the bridge.
    // Report a non-null sentinel so the OpenAI shape stays well-formed.
    model: model || `profile:${profile || "default"}`,
    choices: [{
      index: 0,
      message: { role: "assistant", content: result.lastMessage || "" },
      finish_reason: "stop",
    }],
    usage: { prompt_tokens, completion_tokens, total_tokens },
  };
  console.log(JSON.stringify(payload));
  cleanupTmpDir();
}

// ── Output formatting ────────────────────────────────────────────────

function output(result, options = {}) {
  const { expectStructured = false } = options;

  // Check exit code — non-zero means Codex failed
  if (result.exitCode !== 0) {
    const msg = result.stderr || result.lastMessage || "unknown error";
    logEvent("error", `bridge.${process.argv[2]}`, {
      exitCode: result.exitCode,
      session: result.sessionId,
      duration_ms: result.trace?.duration_ms,
      msg: msg.slice(0, 300),
    });
    console.error(JSON.stringify({
      error: true,
      exitCode: result.exitCode,
      message: msg,
    }, null, 2));
    cleanupTmpDir();
    process.exit(1);
  }

  // Session ID already emitted inline at first-sight; only emit here
  // as a fallback if the stream never surfaced it.
  if (result.sessionId && !result.stderr.includes(`[codex:session] ${result.sessionId}`)) {
    process.stderr.write(`[codex:session] ${result.sessionId}\n`);
  }

  if (result.structured) {
    // Attach _meta envelope (duration, tool counts, tokens, session id).
    // Preserves any fields callers already stamped (_commit, _branch, _worktree).
    const existingMeta = result.structured._meta || {};
    result.structured._meta = {
      session_id: result.sessionId ?? null,
      duration_ms: result.trace?.duration_ms ?? null,
      tool_calls: result.trace?.tool_calls ?? 0,
      edits: result.trace?.edits ?? 0,
      execs: result.trace?.execs ?? 0,
      errors: result.trace?.errors ?? 0,
      tokens: result.trace?.tokens ?? null,
      ...existingMeta,
    };
    console.log(JSON.stringify(result.structured, null, 2));
  } else if (expectStructured) {
    // Schema was set but we couldn't parse — report as error
    logEvent("error", `bridge.${process.argv[2]}`, {
      kind: "schema_parse_fail",
      session: result.sessionId,
      raw_preview: result.lastMessage?.slice(0, 120) || "",
    });
    console.error(JSON.stringify({
      error: true,
      exitCode: 0,
      message: "Failed to parse structured output from Codex",
      raw: result.lastMessage?.slice(0, 2000) || "",
    }, null, 2));
    cleanupTmpDir();
    process.exit(1);
  } else if (result.lastMessage) {
    console.log(result.lastMessage);
  } else {
    die("Codex returned no output");
  }

  cleanupTmpDir();
}

// ── Subcommands ──────────────────────────────────────────────────────

async function cmdSetup() {
  const bin = codexBin();
  console.log(`Codex CLI: ${bin}`);

  try {
    const version = execFileSync(bin, ["--version"], { encoding: "utf8" }).trim();
    console.log(`Version: ${version}`);
  } catch {
    console.log("Version: unknown");
  }

  try {
    execFileSync(bin, ["login", "status"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 10000,
    });
    console.log("Auth: authenticated");
  } catch {
    console.log("Auth: not authenticated (run 'codex login')");
  }

  const schemas = ["implementation-output", "spec-review-output", "quality-review-output"];
  for (const s of schemas) {
    const exists = fs.existsSync(path.join(SCHEMAS_DIR, `${s}.json`));
    console.log(`Schema ${s}: ${exists ? "OK" : "MISSING"}`);
  }

  try {
    execFileSync(process.execPath, [path.join(BRIDGE_DIR, "setup-codex-lsp.mjs")], { stdio: "inherit" });
  } catch {
    console.log("LSP client config: setup failed (see above)");
  }

  console.log("\nReady for SDD integration.");
}

// Source extensions codex-lsp can serve (subset; safe superset is fine —
// files with no server return "No LSP server configured" → treated clean).
const LSP_SOURCE_EXT = new Set([
  ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts",
  ".py", ".pyi", ".rs", ".go", ".rb", ".swift", ".c", ".cpp", ".cc",
  ".cxx", ".h", ".hpp", ".sh", ".bash",
]);

// Changed source files (post-run, pre-commit): committed-since-baseHead
// ∪ unstaged ∪ staged ∪ untracked, filtered to LSP-serviceable extensions.
function lspChangedFiles(cwd, baseHead) {
  const run = (args) => {
    try {
      return execFileSync("git", ["-C", cwd, ...args], {
        encoding: "utf8", stdio: ["ignore", "pipe", "ignore"],
      }).split("\n").map((s) => s.trim()).filter(Boolean);
    } catch { return []; }
  };
  const set = new Set();
  if (baseHead) for (const f of run(["diff", "--name-only", baseHead, "HEAD"])) set.add(f);
  for (const f of run(["diff", "--name-only"])) set.add(f);
  for (const f of run(["diff", "--name-only", "--cached"])) set.add(f);
  for (const f of run(["ls-files", "--others", "--exclude-standard"])) set.add(f);
  const out = [];
  for (const rel of set) {
    const dot = rel.lastIndexOf(".");
    if (dot < 0) continue;
    if (!LSP_SOURCE_EXT.has(rel.slice(dot).toLowerCase())) continue;
    // Skip deleted/stale paths: a removed source file would be sent to
    // diagnostics() on a nonexistent path → false would-block, or an
    // unrepairable block-mode loop (Issue 4).
    if (!fs.existsSync(path.resolve(cwd, rel))) continue;
    out.push(path.resolve(cwd, rel));
  }
  return out;
}

// Post-run bridge LSP gate. Returns the _lsp object (always — fail-open).
// blockMode = SSPOWER_LSP_GATE_BLOCK==="1".
async function runLspGate(cwd, baseHead, blockMode) {
  const base = {
    status: "skipped", decision: "clean",
    checked_files: [], total_errors: 0, errors: [], repair_rounds: 0,
  };
  const cli = resolveCodexLspCli();
  if (!cli) {
    logEvent("info", "bridge.lsp", { kind: "gate_skipped_unresolved" });
    return base;
  }
  const files = lspChangedFiles(cwd, baseHead);
  if (files.length === 0) {
    logEvent("info", "bridge.lsp", { kind: "gate_no_source_files" });
    return { ...base, status: "clean", decision: "clean" };
  }
  const client = new McpLspClient(cli, cwd);
  const gateDeadline = Date.now() + 120000; // §5.7a whole-gate 120s cap
  const started = await client.start();
  if (!started) {
    await client.stop();
    logEvent("warn", "bridge.lsp", { kind: "gate_unavailable_init" });
    return { ...base, status: "unavailable" };
  }
  const errors = [];
  const checked = [];
  try {
    for (const f of files) {
      if (Date.now() > gateDeadline) {
        logEvent("warn", "bridge.lsp", { kind: "gate_timeout_cap", checked: checked.length });
        await client.stop();
        return { ...base, status: "unavailable", checked_files: checked };
      }
      const remaining = Math.max(1000, gateDeadline - Date.now());
      const { ok, text } = await client.diagnostics(f, Math.min(30000, remaining));
      checked.push(f);
      if (!ok) {
        await client.stop();
        logEvent("warn", "bridge.lsp", { kind: "gate_unavailable_call", file: f });
        return { ...base, status: "unavailable", checked_files: checked };
      }
      if (!isCleanDiagnosticsText(text)) errors.push({ file: f, text });
    }
  } finally {
    await client.stop();
  }
  if (errors.length === 0) {
    logEvent("info", "bridge.lsp", { kind: "gate_clean", files: checked.length });
    return { ...base, status: "clean", decision: "clean", checked_files: checked };
  }
  const decision = blockMode ? "block" : "would-block";
  logEvent("info", "bridge.lsp", {
    kind: "gate_errors", decision, files: checked.length, errs: errors.length,
  });
  return {
    status: "errors", decision,
    checked_files: checked, total_errors: errors.length, errors, repair_rounds: 0,
  };
}

// Bounded LSP repair loop (§5.7b / D-B7). ≤2 resume rounds. Terminates on
// ANY of the 7 spec conditions. Returns the final _lsp (decision updated).
// Fail-open: any infra error ends the loop with the current _lsp.
async function runLspRepairLoop(cwd, baseHead, sessionId, _lsp, blockMode) {
  if (!sessionId) return _lsp;                         // cond 4: missing session
  let prevErrHash = "";
  for (let round = 1; round <= 2; round++) {           // cond 1: ≤2 rounds
    // cond 6: pre-resume registry concurrency check
    let rec = null;
    try { rec = registry.readState(sessionId); } catch { rec = null; }
    if (rec && ["running", "killed", "stale"].includes(rec.status)) {
      logEvent("warn", "bridge.lsp", { kind: "repair_abort_registry", status: rec.status, round });
      return { ..._lsp, repair_rounds: round - 1 };
    }
    // cond 7: HEAD drift
    let headBefore = null;
    try {
      headBefore = execFileSync("git", ["-C", cwd, "rev-parse", "HEAD"], {
        encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
    } catch { headBefore = null; }
    if (baseHead && headBefore && headBefore !== baseHead && round === 1) {
      logEvent("warn", "bridge.lsp", { kind: "repair_abort_head_drift", baseHead, headBefore });
      return { ..._lsp, repair_rounds: 0 };
    }
    const diffBefore = lspDiffHash(cwd);
    const errHash = lspErrHash(_lsp.errors);
    if (errHash && errHash === prevErrHash) {           // cond 3: same diagnostics
      logEvent("info", "bridge.lsp", { kind: "repair_stop_same_diag", round });
      return { ..._lsp, repair_rounds: round - 1 };
    }
    prevErrHash = errHash;
    const fileList = _lsp.errors.map((e) => e.file).join(", ");
    const repairPrompt =
      `LSP reports error-severity diagnostics after your edits. Fix ONLY these so the language server is clean. Do not change unrelated code. Files: ${fileList}\n\n` +
      _lsp.errors.map((e) => `--- ${e.file} ---\n${e.text}`).join("\n\n");
    let rr;
    try {
      rr = await runCodexResume(repairPrompt, {
        sessionId, effort: "high", schemaName: "implementation-output", cd: cwd, hardenWrite: true, lspMcp: true,
      });
    } catch {
      logEvent("warn", "bridge.lsp", { kind: "repair_resume_threw", round });
      return { ..._lsp, repair_rounds: round };          // fail-open
    }
    if (!rr || rr.exitCode !== 0) {                       // cond 5: nonzero resume
      logEvent("warn", "bridge.lsp", { kind: "repair_resume_nonzero", round, code: rr && rr.exitCode });
      return { ..._lsp, repair_rounds: round };
    }
    if (lspDiffHash(cwd) === diffBefore) {                // cond 2: no progress
      logEvent("info", "bridge.lsp", { kind: "repair_stop_no_progress", round });
      return { ..._lsp, repair_rounds: round };
    }
    let re;
    try { re = await runLspGate(cwd, baseHead, blockMode); }
    catch { logEvent("warn", "bridge.lsp", { kind: "repair_gate_threw", round }); return { ..._lsp, repair_rounds: round }; }
    re.repair_rounds = round;
    if (re.status === "clean") {
      logEvent("info", "bridge.lsp", { kind: "repair_converged", round });
      return re;                                          // decision=clean
    }
    _lsp = re;                                            // loop with new errors
  }
  logEvent("info", "bridge.lsp", { kind: "repair_exhausted" });
  return { ..._lsp, repair_rounds: 2 };
}

function lspDiffHash(cwd) {
  try {
    const h = require("node:crypto").createHash("sha1");
    h.update(execFileSync("git", ["-C", cwd, "diff", "HEAD"], {
      encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }));
    // git diff HEAD ignores untracked files, but the gate checks them
    // (lspChangedFiles unions ls-files --others). Hash untracked contents
    // too, else a repair that only edits an untracked file looks like
    // "no progress" (cond-2 false-positive → premature loop abort).
    const others = execFileSync("git", ["-C", cwd, "ls-files", "--others", "--exclude-standard"], {
      encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] })
      .split("\n").map((s) => s.trim()).filter(Boolean).sort();
    for (const rel of others) {
      h.update("\0" + rel + "\0");
      try { h.update(fs.readFileSync(path.join(cwd, rel))); } catch { /* gone/binbig: name only */ }
    }
    return h.digest("hex");
  } catch { return ""; }
}
function lspErrHash(errs) {
  try {
    const key = (errs || []).map((e) => e.file + "|" + (e.text || "")).sort().join("\n");
    return require("node:crypto").createHash("sha1").update(key).digest("hex");
  } catch { return ""; }
}
// Session id source of truth for the repair loop. result.sessionId is set by
// _spawnAndCapture (available immediately); _meta.session_id is stamped later
// in output(), AFTER the gate block, so it is undefined here — defensive only.
function _extractSid(result) {
  return result.sessionId || result.structured?._meta?.session_id || null;
}

async function cmdImplement(argv) {
  const opts = parseOpts(argv);
  const prompt = resolvePrompt(opts.prompt);

  // Set up worktree if requested
  let worktree = null;
  let workDir = opts.cd;
  if (opts.worktree && opts.cd) {
    worktree = createWorktree(opts.cd, opts.worktree);
    workDir = worktree.worktreePath;
    process.stderr.write(`[codex:worktree] Created ${worktree.worktreePath} on branch ${worktree.branch}\n`);
  }

  // Snapshot HEAD before codex runs. autoCommit refuses if HEAD changed
  // during the run, blocking taint via writable_roots → worktree gitdir.
  let baseHead = null;
  try {
    baseHead = execFileSync("git", ["-C", workDir || ".", "rev-parse", "HEAD"], {
      encoding: "utf8", stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    // not a git repo or no commits yet — skip snapshot, autoCommit acts as before
  }

  const result = await runCodexExec(prompt, {
    schema: schemaPath("implementation-output"),
    sandbox: opts.write ? "workspace-write" : "read-only",
    hardenWrite: !!opts.write,
    profile: opts.profile || COMMAND_PROFILE["implement"],
    model: opts.model || null,
    effort: opts.effort || null,
    printArgs: opts.printArgs,
    cd: workDir,
    ephemeral: false, // persist session for resume-based fix loops
    lspMcp: true,
  });

  // Bridge-side LSP gate (D-B1: bridge-computed _lsp overrides Codex
  // self-report). Advisory by default (D-B6); fail-open (D-B7).
  if (result.structured) {
    // cwd basis MUST mirror baseHead's `workDir || "."` so the gate diffs
    // the same tree the HEAD snapshot was taken against (Issue 1).
    const cwdAbs = path.resolve(workDir || opts.cd || ".");
    const blockMode = process.env.SSPOWER_LSP_GATE_BLOCK === "1";
    let _lsp = await runLspGate(cwdAbs, baseHead, blockMode);
    if (_lsp.status === "errors") {
      const sid = _extractSid(result);
      _lsp = await runLspRepairLoop(cwdAbs, baseHead, sid, _lsp, blockMode);
    }
    result.structured._lsp = _lsp;
    if (blockMode && _lsp.decision === "block") {
      result.structured.status = "BLOCKED";
      result.structured.blocked_reason =
        `LSP gate: ${_lsp.total_errors} error(s) after ${_lsp.repair_rounds} repair round(s)`;
    }
  }

  // Auto-commit after successful implementation
  if (result.exitCode === 0 && result.structured?.status === "DONE" && opts.autoCommit) {
    const commitMsg = opts.autoCommit === true
      ? `codex: ${result.structured?.summary?.slice(0, 72) || "implement task"}`
      : opts.autoCommit;
    const sha = autoCommit(workDir || ".", commitMsg, { baseHead });
    if (sha) {
      process.stderr.write(`[codex:auto-commit] ${sha.slice(0, 8)} ${commitMsg}\n`);
      if (result.structured) {
        // Dual-write: top-level for existing consumers, _meta for new
        result.structured._commit = sha;
        result.structured._meta = { ...(result.structured._meta || {}), commit: sha };
      }
    }
  }

  // Report worktree path in output (dual-write for back-compat)
  if (worktree && result.structured) {
    result.structured._worktree = worktree.worktreePath;
    result.structured._branch = worktree.branch;
    result.structured._meta = {
      ...(result.structured._meta || {}),
      worktree: worktree.worktreePath,
      branch: worktree.branch,
    };
  }

  output(result, { expectStructured: true });
}

// B5 backend: in-session Stop-gate diagnostics. Reuses the shipped
// bridge-direct runLspGate (NEVER model-issued MCP -- Codex-0.130 gates
// model MCP behind an un-bypassable per-call approval; see gotchas).
// Always exits 0 and prints one JSON line (fail-open / D-B7).
async function cmdLspCheck(argv) {
  const out = { status: "skipped", decision: "clean", total_errors: 0, errors: [] };
  try {
    const opts = parseOpts(argv);
    const cwd = path.resolve(opts.cd || ".");
    if (!fs.existsSync(cwd)) { process.stdout.write(JSON.stringify(out) + "\n"); return; }
    // baseHead=null -> lspChangedFiles diffs working tree vs HEAD (the
    // uncommitted edits Codex just made this session).
    const g = await runLspGate(cwd, null, false);
    out.status = g.status;
    out.decision = g.status === "errors" ? "would-block" : "clean";
    out.total_errors = g.total_errors || 0;
    out.errors = (g.errors || []).map((e) => ({ file: e.file, text: e.text }));
  } catch (e) {
    logEvent("warn", "bridge.lsp", { kind: "lsp_check_threw", msg: String(e && e.message) });
  }
  process.stdout.write(JSON.stringify(out) + "\n");
}

async function cmdSpecReview(argv) {
  const opts = parseOpts(argv);
  const prompt = resolvePrompt(opts.prompt);
  const result = await runCodexExec(prompt, {
    schema: schemaPath("spec-review-output"),
    sandbox: "read-only",
    profile: opts.profile || COMMAND_PROFILE["spec-review"],
    model: opts.model || null,
    effort: opts.effort || null,
    printArgs: opts.printArgs,
    cd: opts.cd,
    ephemeral: true, // reviews don't need resume
  });
  output(result, { expectStructured: true });
}

async function cmdPlanReview(argv) {
  const opts = parseOpts(argv);
  const prompt = resolvePrompt(opts.prompt);
  const result = await runCodexExec(prompt, {
    schema: schemaPath("plan-review-output"),
    sandbox: "read-only",
    profile: opts.profile || COMMAND_PROFILE["plan-review"],
    model: opts.model || null,
    effort: opts.effort || null,
    printArgs: opts.printArgs,
    cd: opts.cd,
    ephemeral: true,
  });
  output(result, { expectStructured: true });
}

async function cmdReview(argv) {
  const opts = parseOpts(argv);
  const prompt = resolvePrompt(opts.prompt);
  const result = await runCodexExec(prompt, {
    schema: schemaPath("quality-review-output"),
    sandbox: "read-only",
    profile: opts.profile || COMMAND_PROFILE["review"],
    model: opts.model || null,
    effort: opts.effort || null,
    printArgs: opts.printArgs,
    cd: opts.cd,
    ephemeral: true, // reviews don't need resume
  });
  output(result, { expectStructured: true });
}

async function cmdRescue(argv) {
  parseOpts(argv); // tolerate args for back-compat
  process.stderr.write(
    "[codex:rescue] disabled (spec D-A3). Use `plan-review` for design/plan review, " +
    "`review` for code review, or `implement --write` for worker delegation.\n"
  );
  logEvent("info", "bridge.rescue", { kind: "disabled" });
  process.exit(2);
}

async function cmdEnrich(argv) {
  const opts = parseOpts(argv);
  const rawPrompt = resolvePrompt(opts.prompt);
  process.stderr.write("[codex:enrich] disabled (spec D-A2) — passing raw prompt through\n");
  logEvent("info", "bridge.enrich", { kind: "disabled_passthrough" });
  process.stdout.write(rawPrompt);
  cleanupTmpDir();
  process.exit(0);
}

async function cmdResume(argv) {
  const opts = parseOpts(argv);
  const prompt = resolvePrompt(opts.prompt);
  // Default to implementation-output schema for SDD fix loops.
  // Use --no-schema for free-form resume (rescue continuations).
  const schemaName = opts.noSchema ? null : (opts.schema || "implementation-output");
  const result = await runCodexResume(prompt, {
    sessionId: opts.sessionId,
    model: opts.model || null,
    effort: opts.effort || null,
    printArgs: opts.printArgs,
    schemaName,
    cd: opts.cd,
    hardenWrite: true,
    lspMcp: true,
  });
  output(result, { expectStructured: !!schemaName });
}

async function cmdPs() {
  const sessions = registry.listSessions();
  console.log(JSON.stringify(sessions, null, 2));
}

async function cmdStatus(argv) {
  const sessionId = argv[0];
  if (!sessionId) die("status requires <session_id>");
  const record = registry.readState(sessionId);
  if (!record) {
    console.error(JSON.stringify({ error: true, message: `no record for ${sessionId}` }));
    process.exit(1);
  }
  console.log(JSON.stringify(registry.markStale(record), null, 2));
}

/**
 * Validate that a record represents a still-live, running session before
 * we send signals based on its pid. Defends against PID reuse on stale records.
 *
 * Three cases by record completeness:
 *   A. bridge_pid recorded + alive: trust child pid liveness directly.
 *      Bridge wrapper supervises Codex; while wrapper is alive, the
 *      recorded child pid is still ours (no OS reuse possible because
 *      the parent hasn't released it). Long silent sessions (no events
 *      for >5min) are correctly identified as live.
 *   B. bridge_pid recorded + dead: refuse. Codex child is orphaned or
 *      its pid was reused.
 *   C. bridge_pid not recorded (legacy records pre-bridge_pid): fall
 *      back to age window + pid liveness. Less strict but best we can
 *      do without supervision metadata.
 */
function isLiveRunning(record) {
  if (!record || record.status !== "running") return false;
  if (!Number.isInteger(record.pid) || record.pid <= 1) return false;

  if (Number.isInteger(record.bridge_pid) && record.bridge_pid > 1) {
    // Case A/B: supervised record. Wrapper liveness is authoritative.
    if (!registry.pidAlive(record.bridge_pid)) return false;
    return registry.pidAlive(record.pid);
  }

  // Case C: legacy unsupervised record. Use age window as proxy for
  // pid-reuse defense, then check pid liveness.
  const STALE_WINDOW_MS = 5 * 60 * 1000;
  const ageMs = Date.now() - new Date(record.updated_at).getTime();
  if (ageMs > STALE_WINDOW_MS) return false;
  return registry.pidAlive(record.pid);
}

/**
 * SIGTERM pid then poll for exit up to timeoutMs. Returns true if exited cleanly.
 */
async function waitForExit(pid, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (!registry.pidAlive(pid)) return true;
    await new Promise((r) => setTimeout(r, 100));
  }
  return false;
}

async function cmdKill(argv) {
  const sessionId = argv[0];
  if (!sessionId) die("kill requires <session_id>");
  const record = registry.readState(sessionId);
  if (!record) {
    console.error(JSON.stringify({ error: true, message: `no record for ${sessionId}` }));
    process.exit(1);
  }
  if (!isLiveRunning(record)) {
    // Don't signal stale/done/error/killed records — pid may belong to an unrelated process now.
    const fresh = registry.markStale(record);
    console.log(JSON.stringify({
      killed: false,
      reason: `record is ${fresh.status}, not running — refusing to signal pid ${record.pid}`,
      pid: record.pid,
      session_id: sessionId,
      status: fresh.status,
    }, null, 2));
    return;
  }
  let signaled = false;
  try {
    process.kill(record.pid, "SIGTERM");
    signaled = true;
  } catch {
    /* race: died between liveness check and signal */
  }
  // Verify exit before reporting success. Escalate to SIGKILL if SIGTERM ignored.
  let exited = signaled ? await waitForExit(record.pid, 5_000) : true;
  if (!exited) {
    process.stderr.write(`[codex:kill] pid=${record.pid} ignored SIGTERM, escalating to SIGKILL\n`);
    try { process.kill(record.pid, "SIGKILL"); } catch { /* ok */ }
    exited = await waitForExit(record.pid, 3_000);
  }
  if (exited) {
    record.status = "killed";
    record.updated_at = new Date().toISOString();
    registry.writeState(record);
  }
  console.log(JSON.stringify({
    killed: exited,
    signaled,
    pid: record.pid,
    session_id: sessionId,
    ...(exited ? {} : { error: "process survived SIGTERM+SIGKILL within 8s" }),
  }, null, 2));
  if (!exited) process.exit(2);
}

async function cmdSteer(argv) {
  const opts = parseOpts(argv);
  if (!opts.sessionId) die("steer requires --session-id");
  const prompt = resolvePrompt(opts.prompt);
  const record = registry.readState(opts.sessionId);

  // Refuse to resume a record that claims running but fails liveness checks.
  // Without verified termination, a parallel resume could collide with the
  // surviving original process or signal a reused PID.
  if (record && record.status === "running" && !isLiveRunning(record)) {
    die(`steer aborted: record session=${opts.sessionId} status=running but liveness check failed (bridge_pid or child pid unreachable). PID may be reused or wrapper crashed. Run "kill <id>" to clear, then retry.`);
  }

  if (record && isLiveRunning(record)) {
    process.stderr.write(`[codex:steer] killing pid=${record.pid} before resume\n`);
    // Mark killed BEFORE signal so the dying bridge's close handler skips its own write (race guard)
    record.status = "killed";
    record.updated_at = new Date().toISOString();
    registry.writeState(record);
    try { process.kill(record.pid, "SIGTERM"); } catch { /* already dead */ }
    // Bounded poll instead of fixed sleep — abort if process won't exit
    let exited = await waitForExit(record.pid, 10_000);
    if (!exited) {
      process.stderr.write(`[codex:steer] pid=${record.pid} did not exit after 10s, escalating to SIGKILL\n`);
      try { process.kill(record.pid, "SIGKILL"); } catch { /* ok */ }
      exited = await waitForExit(record.pid, 3_000);
    }
    if (!exited) {
      // Refuse to start resume — the old bridge may still be writing state
      // or holding the codex session, and starting a parallel resume would
      // collide with whatever the surviving process is doing.
      die(`steer aborted: pid=${record.pid} survived SIGTERM+SIGKILL within 13s. Investigate manually.`);
    }
  } else if (record && record.status !== "running") {
    process.stderr.write(`[codex:steer] record is ${record.status}, resuming directly without kill\n`);
  }

  // Inherit cwd from the original session record so resume runs in the same
  // working directory context. Caller can override with --cd.
  const resumeCwd = opts.cd || record?.cwd || null;
  const result = await runCodexResume(prompt, {
    sessionId: opts.sessionId,
    model: opts.model || null,
    effort: opts.effort || null,
    printArgs: opts.printArgs,
    schemaName: null,
    cd: resumeCwd,
    hardenWrite: true,
    lspMcp: true,
  });
  output(result);
}

async function cmdTail(argv) {
  const sessionId = argv[0];
  if (!sessionId) die("tail requires <session_id>");
  const eventsFile = registry.eventsPath(sessionId);
  if (!fs.existsSync(eventsFile)) die(`no events for ${sessionId}`);
  const tail = spawn("tail", ["-f", "-n", "+1", eventsFile], { stdio: "inherit" });
  process.on("SIGINT", () => tail.kill("SIGTERM"));
  // Wait for tail to exit (only happens on SIGINT or file deletion)
  await new Promise((resolve) => tail.on("close", resolve));
}

// ── Argument parsing ─────────────────────────────────────────────────

function parseOpts(argv) {
  const opts = {
    prompt: null,
    write: false,
    model: null,
    profile: null,
    printArgs: false,
    effort: null,
    cd: null,
    sessionId: null,
    schema: null,
    noSchema: false,
    worktree: null,
    autoCommit: false,
    system: null,
    timeoutMs: null,
  };

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    switch (arg) {
      case "--prompt":
        opts.prompt = argv[++i];
        break;
      case "--write":
        opts.write = true;
        break;
      case "--model":
        opts.model = argv[++i];
        break;
      case "--profile":
        opts.profile = argv[++i];
        break;
      case "--print-args":
        opts.printArgs = true;
        break;
      case "--effort":
        opts.effort = argv[++i];
        if (!VALID_EFFORTS.has(opts.effort)) {
          die(`invalid effort: ${opts.effort}. Valid: ${[...VALID_EFFORTS].join(", ")}`);
        }
        break;
      case "--cd":
        opts.cd = argv[++i];
        break;
      case "--session-id":
        opts.sessionId = argv[++i];
        break;
      case "--schema":
        opts.schema = argv[++i];
        break;
      case "--no-schema":
        opts.noSchema = true;
        break;
      case "--worktree":
        opts.worktree = argv[++i];
        break;
      case "--auto-commit":
        // Can be bare flag (true) or take a message
        if (argv[i + 1] && !argv[i + 1].startsWith("--")) {
          opts.autoCommit = argv[++i];
        } else {
          opts.autoCommit = true;
        }
        break;
      case "--system":
        opts.system = argv[++i];
        break;
      case "--timeout":
        {
          const v = parseInt(argv[++i], 10);
          if (!Number.isFinite(v) || v <= 0) {
            die(`invalid --timeout: must be positive integer ms`);
          }
          opts.timeoutMs = v;
        }
        break;
      case "--json":
        // Accepted as a no-op marker for the `complete` subcommand; the
        // OpenAI-shape JSON output is the only output mode for `complete`,
        // but accepting --json keeps the documented invocation explicit.
        opts.json = true;
        break;
      default:
        if (!opts.prompt) opts.prompt = arg;
        break;
    }
  }

  return opts;
}

// ── Main ─────────────────────────────────────────────────────────────

async function main() {
  const [subcommand, ...argv] = process.argv.slice(2);

  if (!subcommand || subcommand === "--help" || subcommand === "-h") {
    console.log([
      "sspower codex-bridge — direct Codex CLI integration for SDD",
      "",
      "Usage:",
      "  codex-bridge.mjs setup",
      "  codex-bridge.mjs implement  --prompt <text|@file> [--write] [--model <m>] [--effort <e>] [--cd <dir>] [--worktree <branch>] [--auto-commit [msg]]",
      "  codex-bridge.mjs spec-review --prompt <text|@file> [--model <m>] [--cd <dir>]",
      "  codex-bridge.mjs plan-review --prompt <text|@file> [--profile <p>] [--model <m>] [--cd <dir>]",
      "  codex-bridge.mjs review     --prompt <text|@file> [--profile <p>] [--model <m>] [--cd <dir>]",
      "  codex-bridge.mjs rescue     [DISABLED — spec D-A3; use plan-review/review/implement]",
      "  codex-bridge.mjs resume     --prompt <text|@file> [--session-id <id>] [--model <m>] [--no-schema]",
      "  codex-bridge.mjs enrich     --prompt <text|@file> [--model <m>] [--effort <e>] [--cd <dir>]",
      "  codex-bridge.mjs complete   --json --prompt <text|@file> [--system <text>] [--model <m>] [--effort <e>] [--timeout <ms>]",
      "  codex-bridge.mjs ps",
      "  codex-bridge.mjs status     <session_id>",
      "  codex-bridge.mjs kill       <session_id>",
      "  codex-bridge.mjs steer      --session-id <id> --prompt <text|@file>",
      "  codex-bridge.mjs tail       <session_id>",
      "",
      "Prompt: literal text or @/path/to/file.md to read from file",
      "",
      "Session management:",
      "  implement and rescue --write persist sessions for fix-loop resume.",
      "  The session ID is printed to stderr as [codex:session] <id>.",
      "  Pass it to resume via --session-id to target the correct thread.",
      "  If --session-id is omitted, resume uses --last (most recent session).",
      "",
      "Worktree + auto-commit (implement only):",
      "  --worktree <branch>     Create git worktree, Codex works in isolation",
      "  --auto-commit [msg]     Auto-commit after successful DONE status",
      "",
      "Session tracking:",
      "  ps                      List active and recent bridge sessions (JSON)",
      "  status <session_id>     Inspect one session's state record",
      "  kill <session_id>       SIGTERM the bridge process; marks status=killed",
      "  steer --session-id <id> --prompt <p>   SIGTERM running bridge, resume with new prompt",
      "  tail <session_id>                       Stream JSONL events live (Ctrl-C to stop)",
      "  State at: ~/.claude/state/sspower/codex/",
    ].join("\n"));
    process.exit(0);
  }

  switch (subcommand) {
    case "setup":
      await cmdSetup();
      break;
    case "implement":
      await cmdImplement(argv);
      break;
    case "lsp-check":
      await cmdLspCheck(argv);
      break;
    case "spec-review":
      await cmdSpecReview(argv);
      break;
    case "plan-review":
      await cmdPlanReview(argv);
      break;
    case "review":
      await cmdReview(argv);
      break;
    case "rescue":
      await cmdRescue(argv);
      break;
    case "resume":
      await cmdResume(argv);
      break;
    case "enrich":
      await cmdEnrich(argv);
      break;
    case "complete":
      await cmdComplete(argv);
      break;
    case "ps":
      await cmdPs();
      break;
    case "status":
      await cmdStatus(argv);
      break;
    case "kill":
      await cmdKill(argv);
      break;
    case "steer":
      await cmdSteer(argv);
      break;
    case "tail":
      await cmdTail(argv);
      break;
    default:
      die(`unknown subcommand: ${subcommand}. Run with --help for usage.`);
  }
}

// Import-safe CLI guard: only dispatch when run directly, not when imported
// (e.g. tests importing __test_runLspGate). Canonicalize BOTH sides:
// ESM import.meta.url resolves symlinks but process.argv[1] does not, so a
// raw compare breaks under any symlinked path component (macOS /tmp →
// /private/tmp, npm-link, marketplace cache) and main() silently never runs.
let _isCli = false;
try {
  _isCli = !!process.argv[1] &&
    fileURLToPath(import.meta.url) === fs.realpathSync(process.argv[1]);
} catch { _isCli = false; }
if (_isCli) {
  main().catch((err) => {
    cleanupTmpDir();
    console.error(`codex-bridge: ${err.message}`);
    process.exit(1);
  });
}

export { runLspGate as __test_runLspGate };
export { runLspRepairLoop as __test_runLspRepairLoop };
export { _extractSid };
export { lspDiffHash as __test_lspDiffHash };
