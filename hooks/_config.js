#!/usr/bin/env node
// sspower — single config/state file accessor.
//
// One file: ~/.claude/sspower/config.json
//   { "diet": "off|lite|full|ultra", "log_rotate_lines": <int> }
//
// Security: config.json path is predictable, so a local attacker could
// pre-create it as a symlink to redirect reads/writes (e.g. ~/.ssh/id_rsa).
// Read/write below refuse symlinks at file + parent dir, use O_NOFOLLOW,
// cap read size, and write via O_EXCL temp + atomic rename — identical
// hardening to the prior _diet-config.js flag I/O.

const fs = require('fs');
const path = require('path');
const os = require('os');

const VALID_MODES = ['off', 'lite', 'full', 'ultra'];
const DEFAULTS = { diet: 'off', log_rotate_lines: 1000 };
const MAX_CONFIG_BYTES = 4096;

function sspowerDir() {
  const base = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
  return path.join(base, 'sspower');
}
function configPath() { return path.join(sspowerDir(), 'config.json'); }
function failuresLogPath() { return path.join(sspowerDir(), 'failures.jsonl'); }
function codexLogPath() { return path.join(sspowerDir(), 'codex.log'); }

// Symlink-safe, size-capped read. Returns parsed object merged over
// DEFAULTS; on any error/missing/corrupt → DEFAULTS clone. Never throws.
function readConfig() {
  const p = configPath();
  try {
    // Parent-dir symlink refusal (security parity with _diet-config.js,
    // which lstat-checks flagDir). If ~/.claude/sspower is a symlink or
    // not a real dir, refuse — return defaults.
    try {
      const dst = fs.lstatSync(sspowerDir());
      if (dst.isSymbolicLink() || !dst.isDirectory()) return { ...DEFAULTS };
    } catch (e) { return { ...DEFAULTS }; }

    let st;
    try { st = fs.lstatSync(p); } catch (e) { return { ...DEFAULTS }; }
    if (st.isSymbolicLink() || !st.isFile()) return { ...DEFAULTS };
    if (st.size > MAX_CONFIG_BYTES) return { ...DEFAULTS };

    const O_NOFOLLOW = typeof fs.constants.O_NOFOLLOW === 'number' ? fs.constants.O_NOFOLLOW : 0;
    let fd, out;
    try {
      fd = fs.openSync(p, fs.constants.O_RDONLY | O_NOFOLLOW);
      const buf = Buffer.alloc(MAX_CONFIG_BYTES);
      const n = fs.readSync(fd, buf, 0, MAX_CONFIG_BYTES, 0);
      out = buf.slice(0, n).toString('utf8');
    } finally {
      if (fd !== undefined) fs.closeSync(fd);
    }
    const parsed = JSON.parse(out);
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      return { ...DEFAULTS };
    }
    return { ...DEFAULTS, ...parsed };
  } catch (e) {
    return { ...DEFAULTS };
  }
}

// Shallow-merge {key:value} into config and write atomically.
// Symlink-safe at parent dir + target. O_EXCL temp + rename. Silent-fails.
// NOTE: only the diet path calls this at runtime (single code writer key),
// so read-merge-rename is sufficient — see spec Concurrency contract.
function writeConfigKey(key, value) {
  try {
    const dir = sspowerDir();
    fs.mkdirSync(dir, { recursive: true });
    try {
      if (fs.lstatSync(dir).isSymbolicLink()) return false;
    } catch (e) { return false; }

    const p = configPath();
    try {
      if (fs.lstatSync(p).isSymbolicLink()) return false;
    } catch (e) {
      if (e.code !== 'ENOENT') return false;
    }

    const current = readConfig();
    current[key] = value;
    const body = JSON.stringify(current, null, 2) + '\n';

    const tempPath = path.join(dir, `.config.json.${process.pid}.${Date.now()}`);
    const O_NOFOLLOW = typeof fs.constants.O_NOFOLLOW === 'number' ? fs.constants.O_NOFOLLOW : 0;
    const flags = fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | O_NOFOLLOW;
    let fd;
    try {
      fd = fs.openSync(tempPath, flags, 0o600);
      fs.writeSync(fd, body);
      try { fs.fchmodSync(fd, 0o600); } catch (e) { /* windows */ }
    } finally {
      if (fd !== undefined) fs.closeSync(fd);
    }
    fs.renameSync(tempPath, p);
    return true;
  } catch (e) {
    return false;
  }
}

// Active diet: returns 'lite'|'full'|'ultra', or null when off/absent/invalid.
// Returning null for 'off' preserves exact prior truthiness of readFlag().
function readActiveDiet() {
  const d = readConfig().diet;
  if (typeof d !== 'string') return null;
  const m = d.trim().toLowerCase();
  if (m === 'off' || !VALID_MODES.includes(m)) return null;
  return m;
}
function writeActiveDiet(mode) {
  if (!VALID_MODES.includes(mode) || mode === 'off') return clearActiveDiet();
  return writeConfigKey('diet', mode);
}
function clearActiveDiet() { return writeConfigKey('diet', 'off'); }

module.exports = {
  VALID_MODES, DEFAULTS,
  sspowerDir, configPath, failuresLogPath, codexLogPath,
  readConfig, writeConfigKey,
  readActiveDiet, writeActiveDiet, clearActiveDiet,
};
