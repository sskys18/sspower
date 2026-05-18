# Plan: sspower config/state consolidation

> Spec: `docs/specs/2026-05-18-sspower-config-consolidation-design.md` (REV2, Codex-reviewed)
> Branch: `refactor/sspower-config-consolidation` (off `main`, already created)
> Date: 2026-05-18

## Outcome

`~/.claude/` root: 4 scattered files (`sspower-codex-failures.jsonl`, `sspower-codex.log`, `.sspower-diet`, `sspower-codex-patches.md`) → one dir `~/.claude/sspower/` with one config file `config.json` (`{diet, log_rotate_lines}`). Logs/doc are separate files inside that dir. All runtime + cross-repo consumers updated. Manual migration script. No data loss.

## Critical design notes (read before any task)

- **Diet on/off signal changes representation.** Today: flag file *present* = on; `fs.unlinkSync` = off. After: `config.json` always exists (also holds `log_rotate_lines`), so off = `diet:"off"` or `diet` absent. `readActiveDiet()` MUST return `null` for `"off"`/absent so downstream truthiness (`diet-track.js:68 if (activeMode)`) is byte-identical to today. Never `unlink` config.json to disable diet.
- **Security parity is mandatory.** `_diet-config.js:13-15,59-116` hardens flag I/O (O_NOFOLLOW, size cap, symlink refusal at file+parent) because the path is predictable (local-attacker redirect to secrets). `config.json` is equally predictable → the new read/write MUST carry the same hardening. Reuse the existing `safeWriteFlag`/`readFlag` mechanics, do not weaken them.
- **`getDefaultMode()` chain is OUT OF SCOPE** (spec non-goal). Do not touch `_diet-config.js:26-57` (env / XDG `diet.json` / `defaultMode`). Only the *active* flag relocates.
- **`_log.sh` rotation knobs stay env** (spec carve-out). Only its default *path* changes.
- **`log_rotate_lines` is read-only to code.** Only `codex-bridge.mjs` reads it. Nothing writes it.

## File map

Created:
- `hooks/_config.js` — config module (paths, readConfig, atomic writeConfigKey, diet helpers)
- `scripts/sspower-migrate.sh` — manual one-shot migration
- `tests/config/test_config.sh` — _config.js unit tests

Modified (plugin repo):
- `hooks/_diet-config.js` `hooks/diet-activate.js` `hooks/diet-track.js`
- `scripts/codex-bridge.mjs` `hooks/prompt-submit` `hooks/_log.sh`
- `skills/codex-diagnostics/SKILL.md` `README.md` `docs/ARCHITECTURE.md` `CLAUDE.md`

Modified (config repo `~/.claude`, separate git repo — Task 9):
- `bin/codex-failures` `skills/codex-health/SKILL.md`

---

## Task 1 — Create `hooks/_config.js`

Create `hooks/_config.js` with exactly this content:

```javascript
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
```

Verify: `node -e "const c=require('$PWD/hooks/_config.js'); console.log(c.configPath(), c.readActiveDiet())"` from plugin root → prints a path ending `/.claude/sspower/config.json` and `null` (no config yet). Expected, no throw.

Commit: `feat(config): add hooks/_config.js single-file config accessor`

---

## Task 2 — Unit tests for `_config.js`

Create `tests/config/test_config.sh` with exactly this content:

```bash
#!/usr/bin/env bash
# Unit tests for hooks/_config.js — run with: bash tests/config/test_config.sh
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_CONFIG_DIR="$TMP"
C="$PLUGIN_ROOT/hooks/_config.js"
pass=0; fail=0
ok(){ if [ "$1" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $3 (got '$1' want '$2')"; fi; }

# 1. defaults when absent
ok "$(node -e "console.log(require('$C').readActiveDiet())")" "null" "absent->null"
ok "$(node -e "console.log(require('$C').readConfig().log_rotate_lines)")" "1000" "absent->default rotate"

# 2. write + read diet
node -e "require('$C').writeActiveDiet('full')"
ok "$(node -e "console.log(require('$C').readActiveDiet())")" "full" "write full"
ok "$(node -e "const fs=require('fs');console.log(fs.existsSync(require('$C').configPath()))")" "true" "config.json created"

# 3. off -> null, file still present (NOT unlinked), other keys preserved
node -e "require('$C').writeConfigKey('log_rotate_lines',2000)"
node -e "require('$C').clearActiveDiet()"
ok "$(node -e "console.log(require('$C').readActiveDiet())")" "null" "off->null"
ok "$(node -e "const fs=require('fs');console.log(fs.existsSync(require('$C').configPath()))")" "true" "config kept on off"
ok "$(node -e "console.log(require('$C').readConfig().log_rotate_lines)")" "2000" "other key preserved"

# 4. invalid mode -> treated as null
node -e "require('$C').writeConfigKey('diet','bogus')"
ok "$(node -e "console.log(require('$C').readActiveDiet())")" "null" "invalid->null"

# 5. corrupt JSON -> defaults, no throw
printf 'not json{' > "$TMP/sspower/config.json"
ok "$(node -e "console.log(require('$C').readActiveDiet())")" "null" "corrupt->null"
ok "$(node -e "console.log(require('$C').readConfig().log_rotate_lines)")" "1000" "corrupt->default"

# 6. symlink at config path refused (write returns false, no follow)
rm -f "$TMP/sspower/config.json"; ln -s /etc/hosts "$TMP/sspower/config.json"
ok "$(node -e "console.log(require('$C').writeConfigKey('diet','full'))")" "false" "symlink write refused"
ok "$(node -e "console.log(require('$C').readActiveDiet())")" "null" "symlink read refused"

echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
```

`chmod +x tests/config/test_config.sh`. Run: `bash tests/config/test_config.sh` → last line `PASS=12 FAIL=0`, exit 0.

Commit: `test(config): _config.js unit tests (defaults, off-semantics, security)`

---

## Task 3 — Rewire `_diet-config.js` flag I/O to `_config.js`

In `hooks/_diet-config.js`, **do not touch** lines 1-57 (`getConfigDir`/`getConfigPath`/`getDefaultMode` — the default-mode chain is out of scope).

Replace the flag I/O block (lines 59-118, from the `// Symlink-safe flag write` comment through `module.exports`) with:

```javascript
// Active-flag I/O now delegates to the single config file (~/.claude/sspower/
// config.json) via _config.js. The legacy ~/.claude/.sspower-diet flag is
// retired (see scripts/sspower-migrate.sh). flagPath args are accepted but
// ignored for backward call-signature compatibility.
const _cfg = require('./_config');

function safeWriteFlag(_flagPath, content) {
  const m = String(content == null ? '' : content).trim().toLowerCase();
  return _cfg.writeActiveDiet(m);
}

function readFlag(_flagPath) {
  return _cfg.readActiveDiet();
}

module.exports = { getDefaultMode, getConfigDir, getConfigPath, VALID_MODES, safeWriteFlag, readFlag };
```

Rationale: `safeWriteFlag`/`readFlag` keep their signatures so `diet-activate.js`/`diet-track.js` callers compile unchanged this task; the `flagPath` argument is now inert. `readFlag` returns `null` for off/absent exactly as before (file-absent previously → `null`).

Verify: `bash tests/config/test_config.sh` still `FAIL=0`. Then:
`node -e "const d=require('./hooks/_diet-config.js'); d.safeWriteFlag(null,'lite'); console.log(d.readFlag(null))"` → `lite`.
`node -e "const d=require('./hooks/_diet-config.js'); d.safeWriteFlag(null,'off'); console.log(d.readFlag(null))"` → `null`.

Commit: `refactor(diet): route _diet-config flag I/O through _config.js`

---

## Task 4 — Update `diet-activate.js`

In `hooks/diet-activate.js`:

Replace lines 14-23:

```javascript
const claudeDir = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
const flagPath = path.join(claudeDir, '.sspower-diet');

const mode = getDefaultMode();

if (mode === 'off') {
  try { fs.unlinkSync(flagPath); } catch (e) {}
  process.exit(0);
}

safeWriteFlag(flagPath, mode);
```

with:

```javascript
const mode = getDefaultMode();

if (mode === 'off') {
  clearActiveDiet();          // sets config.json diet:"off"; never unlinks config
  process.exit(0);
}

writeActiveDiet(mode);
```

Update the require on line 13 from:
`const { getDefaultMode, safeWriteFlag } = require('./_diet-config');`
to:
`const { getDefaultMode } = require('./_diet-config');`
`const { writeActiveDiet, clearActiveDiet } = require('./_config');`

Update the header comment line 5 from:
`//   1. Writes flag file at $CLAUDE_CONFIG_DIR/.sspower-diet (for tracker/statusline)`
to:
`//   1. Writes active diet level into ~/.claude/sspower/config.json (read by diet-track)`

`fs`/`path`/`os` are still used elsewhere in the file (SKILL.md read) — leave those requires. Verify: `grep -c 'os\.' hooks/diet-activate.js` → if 0 after edit, delete the `const os = require('os');` line to avoid lint noise; if >0 leave it. Same check for `path` (`grep -c 'path\.' hooks/diet-activate.js`).

Verify: `echo '{}' | SSPOWER_DIET_DEFAULT=full node hooks/diet-activate.js | head -1` → `DIET MODE ACTIVE — level: full`. Then `node -e "console.log(require('./hooks/_config.js').readActiveDiet())"` → `full`.

Commit: `refactor(diet): diet-activate writes config.json, no flag unlink`

---

## Task 5 — Update `diet-track.js`

In `hooks/diet-track.js`:

Replace line 11:
`const { getDefaultMode, safeWriteFlag, readFlag } = require('./_diet-config');`
with:
`const { getDefaultMode } = require('./_diet-config');`
`const { writeActiveDiet, clearActiveDiet, readActiveDiet } = require('./_config');`

Delete lines 13-14:
```javascript
const claudeDir = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
const flagPath = path.join(claudeDir, '.sspower-diet');
```

Apply these in-body replacements (semantics preserved exactly):
- Line 29 `if (mode !== 'off') safeWriteFlag(flagPath, mode);` → `if (mode !== 'off') writeActiveDiet(mode);`
- Lines 52-55:
  ```javascript
  if (mode && mode !== 'off') {
    safeWriteFlag(flagPath, mode);
  } else if (mode === 'off') {
    try { fs.unlinkSync(flagPath); } catch (e) {}
  }
  ```
  →
  ```javascript
  if (mode && mode !== 'off') {
    writeActiveDiet(mode);
  } else if (mode === 'off') {
    clearActiveDiet();
  }
  ```
- Line 63 `try { fs.unlinkSync(flagPath); } catch (e) {}` → `clearActiveDiet();`
- Line 67 `const activeMode = readFlag(flagPath);` → `const activeMode = readActiveDiet();`

After edits, `fs`/`path`/`os` may be unused. Check each: `for s in fs path os; do echo -n "$s: "; grep -c "\\b$s\\." hooks/diet-track.js; done`. For any with count 0, delete its `const X = require('X');` line (lines 8-10). `readActiveDiet()` returns `null` for off → `if (activeMode)` on line 68 behaves identically to the old `readFlag` (which returned `null` when the flag file was absent).

Verify (off-state must NOT emit reinforcement, identical to today):
```
printf '{"prompt":"/diet full"}' | node hooks/diet-track.js >/dev/null
node -e "console.log(require('./hooks/_config.js').readActiveDiet())"   # -> full
printf '{"prompt":"hello"}' | node hooks/diet-track.js | grep -c 'DIET MODE ACTIVE'  # -> 1
printf '{"prompt":"normal mode"}' | node hooks/diet-track.js >/dev/null
printf '{"prompt":"hello"}' | node hooks/diet-track.js | wc -c  # -> 0  (no reinforcement when off)
```

Commit: `refactor(diet): diet-track uses config.json active-diet helpers`

---

## Task 6 — Update `codex-bridge.mjs` paths + config-driven rotation

In `scripts/codex-bridge.mjs`:

Line 53: `const FAILURE_LOG = path.join(os.homedir(), ".claude", "sspower-codex-failures.jsonl");`
→ `const FAILURE_LOG = path.join(os.homedir(), ".claude", "sspower", "failures.jsonl");`

Line 61: `const LOG_FILE = path.join(os.homedir(), ".claude", "sspower-codex.log");`
→ `const LOG_FILE = path.join(os.homedir(), ".claude", "sspower", "codex.log");`

Line 62: `const LOG_MAX_LINES = 1000;`
→
```javascript
const LOG_MAX_LINES = (() => {
  try {
    const v = require('../hooks/_config').readConfig().log_rotate_lines;
    return Number.isInteger(v) && v > 0 ? v : 1000;
  } catch { return 1000; }
})();
```

Update comment lines 57-59 to reference `~/.claude/sspower/codex.log` and `~/.claude/sspower/failures.jsonl`.

Add a `mkdir` guard so first write on a fresh machine doesn't fail. Immediately after the new `LOG_MAX_LINES` block, add:
```javascript
try { fs.mkdirSync(path.join(os.homedir(), ".claude", "sspower"), { recursive: true }); } catch { /* best effort */ }
```
(`fs`, `path`, `os` are already imported at top of file — confirm with `grep -nE "require\\(.(fs|path|os).\\)" scripts/codex-bridge.mjs`.)

Verify: `node --check scripts/codex-bridge.mjs` exits 0 (no syntax error). `node -e "require('./hooks/_config.js')"` exits 0. `node scripts/codex-bridge.mjs --help | head -1` prints the usage banner (no require/throw).

Commit: `refactor(bridge): codex-bridge logs → ~/.claude/sspower/, rotate from config`

---

## Task 7 — Update `prompt-submit` + `_log.sh` (path only; rotation carve-out)

`hooks/prompt-submit` line 21:
`DIAG_LOG="${HOME}/.claude/sspower-codex.log"`
→ `DIAG_LOG="${HOME}/.claude/sspower/codex.log"`
(The existing `mkdir -p "$(dirname "$DIAG_LOG")"` on the next lines already creates `~/.claude/sspower/` — confirm with `grep -n 'mkdir -p' hooks/prompt-submit`.)

`hooks/_log.sh` line 10:
`SSPOWER_LOG_FILE="${SSPOWER_LOG_FILE:-$HOME/.claude/sspower-codex.log}"`
→ `SSPOWER_LOG_FILE="${SSPOWER_LOG_FILE:-$HOME/.claude/sspower/codex.log}"`

Leave `_log.sh` lines 11-12 (`SSPOWER_LOG_MAX_LINES`, `SSPOWER_LOG_KEEP_TAIL`) **unchanged** — spec carve-out. Update the comment block lines 14-17 to add a line: `# Path moved to ~/.claude/sspower/codex.log; rotation knobs intentionally stay env (no jq dep in hook hot path) — see docs/specs/2026-05-18-sspower-config-consolidation-design.md carve-out.` Ensure the writer creates the dir before first append: `grep -n 'mkdir' hooks/_log.sh`; if no `mkdir` covering `$SSPOWER_LOG_FILE`'s dir exists, add `mkdir -p "$(dirname "$SSPOWER_LOG_FILE")" 2>/dev/null || true` immediately after line 12.

Verify: `bash -n hooks/_log.sh` exit 0. `bash -n hooks/prompt-submit` exit 0.

Commit: `refactor(hooks): prompt-submit/_log.sh log path → ~/.claude/sspower/`

---

## Task 8 — Update plugin docs + skill

- `skills/codex-diagnostics/SKILL.md`: replace every `~/.claude/sspower-codex.log` with `~/.claude/sspower/codex.log` (line 3 description, line 10 body, line 32 `LOG=` assignment). Confirm zero remaining: `grep -n 'sspower-codex' skills/codex-diagnostics/SKILL.md` → empty.
- `README.md:256`: `~/.claude/sspower-codex.log` → `~/.claude/sspower/codex.log`.
- `docs/ARCHITECTURE.md:76` and `:325`: `~/.claude/sspower-codex.log` → `~/.claude/sspower/codex.log`.
- `CLAUDE.md` (plugin): `grep -n 'sspower-codex\|\.sspower-diet' CLAUDE.md`; for each hit update `~/.claude/sspower-codex-failures.jsonl`→`~/.claude/sspower/failures.jsonl`, `~/.claude/sspower-codex.log`→`~/.claude/sspower/codex.log`, `.sspower-diet`→`~/.claude/sspower/config.json (diet field)`. The line mentioning `~/.claude/state/sspower/codex/...` is a DIFFERENT path (session tracking state) — **do not change it**.

Verify whole-plugin sweep finds no stale runtime/doc path (excluding spec/plan/handoff/wiki history which intentionally cite old paths):
```
grep -rn 'sspower-codex-failures\|sspower-codex\.log\|\.sspower-diet' \
  --include='*.js' --include='*.mjs' --include='*.sh' --include='*.md' . \
  | grep -vE '/docs/specs/|/docs/plans/|/docs/.*handoff|/\.git/|/\.claude/wiki/'
```
Expected: empty. Any printed line is an unhandled consumer — fix it in this task before commit.

Commit: `docs(sspower): update skill/README/ARCHITECTURE/CLAUDE paths to sspower/`

---

## Task 9 — Cross-repo: config repo (`~/.claude`, separate git repo)

This repo is `~/.claude` (git repo created earlier; NOT this plugin). Use `git -C "$HOME/.claude"`.

- `~/.claude/bin/codex-failures`:
  - line 3 comment: `# Source: ~/.claude/sspower-codex-failures.jsonl ...` → `# Source: ~/.claude/sspower/failures.jsonl ...`
  - line 7: `LOG="$HOME/.claude/sspower-codex-failures.jsonl"` → `LOG="$HOME/.claude/sspower/failures.jsonl"`
- `~/.claude/skills/codex-health/SKILL.md`:
  - line 9: `$HOME/.claude/sspower-codex.log` → `$HOME/.claude/sspower/codex.log`
  - line 10: `$HOME/.claude/sspower-codex-failures.jsonl` → `$HOME/.claude/sspower/failures.jsonl`
  - line 19: `"$HOME/.claude/sspower-codex.log"` → `"$HOME/.claude/sspower/codex.log"`

Verify no stale path remains in config-repo runtime consumers:
```
grep -rn 'sspower-codex-failures\|sspower-codex\.log\|\.sspower-diet' \
  "$HOME/.claude/bin" "$HOME/.claude/skills/codex-health" 2>/dev/null
```
Expected: empty.

Commit (in `~/.claude` repo, standalone chokepoints):
`git -C "$HOME/.claude" add bin/codex-failures skills/codex-health/SKILL.md`
then `git -C "$HOME/.claude" commit -m "refactor: codex log/failures paths → ~/.claude/sspower/ (plugin consolidation)"`

---

## Task 10 — Create `scripts/sspower-migrate.sh`

Create `scripts/sspower-migrate.sh` with exactly this content:

```bash
#!/usr/bin/env bash
# One-shot, idempotent migration: legacy ~/.claude/sspower-* root files
# -> ~/.claude/sspower/. Run ONCE after upgrading the plugin. Safe to re-run.
#
# Sequencing: the legacy .sspower-diet flag may be live in a running
# session. Running this mid-session moves diet state into config.json;
# until reloaded hooks pick it up, one diet re-init may occur. Prefer
# running at a session boundary.
set -euo pipefail

BASE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
DIR="$BASE/sspower"
mkdir -p "$DIR"

moved=0
mv_if() {  # $1=src $2=dst
  if [ -e "$1" ] && [ ! -e "$2" ]; then mv "$1" "$2"; echo "moved: $1 -> $2"; moved=$((moved+1));
  elif [ -e "$1" ] && [ -e "$2" ]; then echo "skip (dest exists): $1"; fi
}

mv_if "$BASE/sspower-codex-failures.jsonl" "$DIR/failures.jsonl"
mv_if "$BASE/sspower-codex.log"            "$DIR/codex.log"
mv_if "$BASE/sspower-codex-patches.md"     "$DIR/patches.md"

# Diet flag -> config.json .diet (then remove legacy flag).
CONFIG="$DIR/config.json"
diet="off"
if [ -f "$BASE/.sspower-diet" ]; then
  raw="$(tr -d '[:space:]' < "$BASE/.sspower-diet" | tr '[:upper:]' '[:lower:]')"
  case "$raw" in lite|full|ultra) diet="$raw" ;; *) diet="off" ;; esac
  rm -f "$BASE/.sspower-diet"
  echo "migrated diet flag: $diet"
fi

# Use the hardened node writer so we never hand-roll JSON.
NODE_CFG="$(cd "$(dirname "$0")/.." && pwd)/hooks/_config.js"
if [ ! -f "$CONFIG" ]; then
  CLAUDE_CONFIG_DIR="$BASE" node -e "require('$NODE_CFG').writeConfigKey('log_rotate_lines',1000)"
fi
CLAUDE_CONFIG_DIR="$BASE" node -e "require('$NODE_CFG').writeConfigKey('diet','$diet')"

echo "done. moved=$moved config=$CONFIG"
ls -la "$DIR"
```

`chmod +x scripts/sspower-migrate.sh`.

Verify in a sandbox (does NOT touch real `~/.claude`):
```
T=$(mktemp -d); export CLAUDE_CONFIG_DIR="$T"
printf 'x\n' > "$T/sspower-codex.log"; echo full > "$T/.sspower-diet"
echo '[]' > "$T/sspower-codex-failures.jsonl"
bash scripts/sspower-migrate.sh
test -f "$T/sspower/codex.log" && test -f "$T/sspower/failures.jsonl" && test ! -e "$T/.sspower-diet"
node -e "process.env.CLAUDE_CONFIG_DIR='$T'; console.log(require('./hooks/_config.js').readActiveDiet())"  # -> full
bash scripts/sspower-migrate.sh   # re-run: idempotent, no error, moved=0
rm -rf "$T"; unset CLAUDE_CONFIG_DIR
```
All assertions pass; second run prints `moved=0`.

Commit: `feat(migrate): one-shot idempotent sspower-migrate.sh`

---

## Task 11 — Full verification (no commit)

From plugin root, on branch `refactor/sspower-config-consolidation`:

1. `bash tests/config/test_config.sh` → `PASS=12 FAIL=0`, exit 0.
2. Plugin-wide stale-path sweep (Task 8 command) → empty.
3. Config-repo sweep (Task 9 command) → empty.
4. Diet round-trip end to end:
   ```
   T=$(mktemp -d); export CLAUDE_CONFIG_DIR="$T"
   SSPOWER_DIET_DEFAULT=full node hooks/diet-activate.js </dev/null | head -1   # DIET MODE ACTIVE — level: full
   node -e "console.log(require('./hooks/_config.js').readActiveDiet())"          # full
   printf '{"prompt":"normal mode"}' | node hooks/diet-track.js >/dev/null
   printf '{"prompt":"hi"}' | node hooks/diet-track.js | wc -c                    # 0
   test -f "$T/sspower/config.json"                                               # exists (not unlinked)
   rm -rf "$T"; unset CLAUDE_CONFIG_DIR
   ```
5. `node --check scripts/codex-bridge.mjs` exit 0; `node scripts/codex-bridge.mjs --help | head -1` prints usage.
6. Existing suites unaffected: run any present `tests/hooks/*.sh` — no new failures vs `main`.

If all green, implementation is complete. Migration is a **manual user step** (run `scripts/sspower-migrate.sh` at a session boundary) — do NOT auto-run it during implementation; it would move this live session's diet state.

---

## Acceptance criteria

- [ ] After the user runs migration, `~/.claude/sspower/` is the only sspower entry at `~/.claude` root (4 legacy files moved in, none left).
- [ ] One config file `~/.claude/sspower/config.json` holds `diet` + `log_rotate_lines`; no `.sspower-diet`.
- [ ] Diet on/off/level behavior byte-identical to pre-change (off emits no reinforcement; config.json never unlinked).
- [ ] `codex-bridge.mjs`, `prompt-submit`, `_log.sh` write under `~/.claude/sspower/`; `_log.sh` rotation knobs still env (carve-out honored).
- [ ] `codex-diagnostics` skill + `bin/codex-failures` + `codex-health` skill read new paths.
- [ ] Security hardening (O_NOFOLLOW, size cap, symlink refusal, O_EXCL temp+rename) preserved in `_config.js` — proven by test 6.
- [ ] `getDefaultMode()` env/XDG/`defaultMode` chain untouched.
- [ ] Stale-path sweeps (plugin + config repo) empty.
- [ ] All Task 11 checks green.

## Execution notes

- Tasks 1-8, 10 = plugin repo (branch `refactor/sspower-config-consolidation`). Task 9 = config repo `~/.claude` (its own commit).
- One commit per task (messages specified). Git chokepoints standalone (auto-review hook).
- Migration script is delivered but **run by the user**, not during execution.
```
