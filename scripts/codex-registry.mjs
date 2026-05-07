// scripts/codex-registry.mjs
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export const REGISTRY_DIR = path.join(os.homedir(), ".claude", "state", "sspower", "codex");
const MAX_RECORDS = 50;
const STALE_AFTER_MS = 5 * 60 * 1000;
const SWEEP_AFTER_MS = 24 * 60 * 60 * 1000;

// Codex session IDs are UUIDs (e.g. 019e0066-6508-7fe0-89e8-e6bf6eb84b4f).
// Allow conservative subset to defeat path traversal: alphanumeric + dash, 8-128 chars.
const SESSION_ID_RE = /^[A-Za-z0-9-]{8,128}$/;

export function validateSessionId(id) {
  if (typeof id !== "string" || !SESSION_ID_RE.test(id)) {
    throw new Error(`invalid session id: ${JSON.stringify(id)}`);
  }
  return id;
}

export function ensureDir() {
  fs.mkdirSync(REGISTRY_DIR, { recursive: true, mode: 0o700 });
}

export function statePath(sessionId) {
  validateSessionId(sessionId);
  return path.join(REGISTRY_DIR, `${sessionId}.json`);
}

export function eventsPath(sessionId) {
  validateSessionId(sessionId);
  return path.join(REGISTRY_DIR, `${sessionId}.events.jsonl`);
}

export function writeState(record) {
  ensureDir();
  const target = statePath(record.session_id);
  const tmp = `${target}.tmp.${process.pid}`;
  fs.writeFileSync(tmp, JSON.stringify(record, null, 2), { mode: 0o600 });
  fs.renameSync(tmp, target);
}

export function readState(sessionId) {
  try {
    return JSON.parse(fs.readFileSync(statePath(sessionId), "utf8"));
  } catch {
    return null;
  }
}

export function appendEvent(sessionId, event) {
  ensureDir();
  fs.appendFileSync(eventsPath(sessionId), JSON.stringify(event) + "\n", { mode: 0o600 });
}

export function listSessions() {
  ensureDir();
  const entries = fs.readdirSync(REGISTRY_DIR)
    .filter((f) => f.endsWith(".json") && !f.includes(".tmp."));
  const records = [];
  for (const f of entries) {
    try {
      const r = JSON.parse(fs.readFileSync(path.join(REGISTRY_DIR, f), "utf8"));
      records.push(markStale(r));
    } catch { /* skip corrupt */ }
  }
  records.sort((a, b) => new Date(b.started_at) - new Date(a.started_at));
  return records;
}

export function markStale(record) {
  if (record.status !== "running") return record;
  const last = new Date(record.updated_at).getTime();
  if (Date.now() - last > STALE_AFTER_MS && !pidAlive(record.pid)) {
    return { ...record, status: "stale" };
  }
  return record;
}

export function pidAlive(pid) {
  try { process.kill(pid, 0); return true; } catch { return false; }
}

export function sweep() {
  ensureDir();
  const entries = fs.readdirSync(REGISTRY_DIR);
  const now = Date.now();
  for (const f of entries) {
    const full = path.join(REGISTRY_DIR, f);
    try {
      const stat = fs.statSync(full);
      if (now - stat.mtimeMs > SWEEP_AFTER_MS) fs.unlinkSync(full);
    } catch { /* ok */ }
  }
  // Cap at MAX_RECORDS
  const sorted = listSessions();
  if (sorted.length > MAX_RECORDS) {
    for (const r of sorted.slice(MAX_RECORDS)) {
      try { fs.unlinkSync(statePath(r.session_id)); } catch { /* ok */ }
      try { fs.unlinkSync(eventsPath(r.session_id)); } catch { /* ok */ }
    }
  }
}
