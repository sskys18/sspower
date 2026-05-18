# Plan: sspower config/state consolidation

> Spec: `docs/specs/2026-05-18-sspower-config-consolidation-design.md` (REV2, Codex-reviewed)
> Branch: `refactor/sspower-config-consolidation` (off `main`, already created)
> Date: 2026-05-18

## Codex plan-review resolution (v1 `needs-attention` → REV2)

Review JSON: `docs/reviews/2026-05-18-sspower-config-consolidation-plan-review.json`.

| Sev | Finding | Fix |
|---|---|---|
| blocking | `codex-bridge.mjs` is ESM — bare `require` undefined → config rotation silently never read | Task 6: `createRequire(import.meta.url)` + verifier that proves `1234` is read (not 1000 fallback) |
| blocking | Migration not idempotent — rerun resets migrated diet to `off` | Task 10: write diet only if legacy flag existed; brand-new seeds via DEFAULTS merge; existing config untouched on rerun; verifier re-asserts `full` after 2nd run |
| blocking | `readConfig()` missing parent-dir symlink refusal (security parity) | Task 1: `lstatSync(sspowerDir())` symlink/dir check; Task 2 tests parent-symlink read+write (PASS 12→16) |
| advisory | Task 3/4/5 verifiers touch real `~/.claude` | All wrapped in temp `CLAUDE_CONFIG_DIR` |
| advisory | No forced-failure append proof (spec rollout step 4) | Task 11 step 6 sandbox verifier |
| advisory | Spec impl-step-1 pre-edit fail-closed sweep absent | New Task 0 (gate) |
| advisory | Migration verifier ignored `patches.md` | Task 10 verifier adds fixture + asserts moved |

**Re-review v2** (`needs-attention`, 3 new blocking from REV2's own changes — all fixed in REV3):

| Sev | Finding | Fix |
|---|---|---|
| blocking | Task 6 verifier used `./hooks/_config.js` (resolves to `scripts/hooks/...` → MODULE_NOT_FOUND) | Verifier now `../hooks/_config.js`, mirroring the bridge's real require |
| blocking | Task 6 hardcoded `os.homedir()` → inconsistent with `_config.js`, untestable under sandbox | Task 6 now derives `FAILURE_LOG`/`LOG_FILE`/`sspowerDir` from `_config.js` helpers (single path source, honors `CLAUDE_CONFIG_DIR`) |
| blocking | `mv_if` skipped on dst-exists → legacy root file orphaned (violates acceptance criterion) | `mv_if` archives legacy → `<dst>.pre-migrate-<ts>` and clears root; verifier asserts no orphan + content kept |

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

## Task 0 — Pre-edit fail-closed consumer sweep (spec impl-step 1)

Before any edit, enumerate every consumer of the legacy paths and assert it matches the known set. Run from plugin root:

```
grep -rn 'sspower-codex-failures\|sspower-codex\.log\|\.sspower-diet' \
  --include='*.js' --include='*.mjs' --include='*.sh' --include='*.md' . \
  | grep -vE '/docs/specs/|/docs/plans/|/docs/reviews/|/docs/.*handoff|/\.git/|/\.claude/wiki/' \
  | sort > /tmp/sspower_consumers_plugin.txt
grep -rn 'sspower-codex-failures\|sspower-codex\.log\|\.sspower-diet' \
  "$HOME/.claude/bin" "$HOME/.claude/skills/codex-health" 2>/dev/null | sort \
  > /tmp/sspower_consumers_cfg.txt
cat /tmp/sspower_consumers_plugin.txt /tmp/sspower_consumers_cfg.txt
```

Expected consumer set (every printed line must map to one of these; any extra line BLOCKS implementation until added to the plan):

- Plugin: `scripts/codex-bridge.mjs` (FAILURE_LOG, LOG_FILE, comments) · `hooks/prompt-submit` (DIAG_LOG) · `hooks/_log.sh` (SSPOWER_LOG_FILE) · `hooks/_diet-config.js` (.sspower-diet flag I/O) · `hooks/diet-activate.js` (flagPath) · `hooks/diet-track.js` (flagPath) · `skills/codex-diagnostics/SKILL.md` · `README.md` · `docs/ARCHITECTURE.md` · `CLAUDE.md`
- Config repo: `bin/codex-failures` · `skills/codex-health/SKILL.md`

If a line falls outside this set, STOP — extend the plan with a task for it before proceeding. No edits this task; it is a gate.

Commit: none (verification gate only).

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

# 7. parent-dir symlink refused on BOTH read and write (security parity)
rm -rf "$TMP/sspower"
mkdir -p "$TMP/real_target"
ln -s "$TMP/real_target" "$TMP/sspower"
ok "$(node -e "console.log(require('$C').readActiveDiet())")" "null" "parent-symlink read refused"
ok "$(node -e "console.log(require('$C').readConfig().log_rotate_lines)")" "1000" "parent-symlink read->defaults"
ok "$(node -e "console.log(require('$C').writeConfigKey('diet','full'))")" "false" "parent-symlink write refused"
ok "$(node -e "const fs=require('fs');console.log(fs.existsSync('$TMP/real_target/config.json'))")" "false" "parent-symlink not followed on write"

echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
```

`chmod +x tests/config/test_config.sh`. Run: `bash tests/config/test_config.sh` → last line `PASS=16 FAIL=0`, exit 0.

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

Verify (sandboxed — must NOT write real `~/.claude/sspower/`):
```
bash tests/config/test_config.sh                              # FAIL=0
T=$(mktemp -d); export CLAUDE_CONFIG_DIR="$T"
node -e "const d=require('./hooks/_diet-config.js'); d.safeWriteFlag(null,'lite'); console.log(d.readFlag(null))"  # lite
node -e "const d=require('./hooks/_diet-config.js'); d.safeWriteFlag(null,'off'); console.log(d.readFlag(null))"   # null
rm -rf "$T"; unset CLAUDE_CONFIG_DIR
```

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

Verify (sandboxed):
```
T=$(mktemp -d); export CLAUDE_CONFIG_DIR="$T"
echo '{}' | SSPOWER_DIET_DEFAULT=full node hooks/diet-activate.js | head -1   # DIET MODE ACTIVE — level: full
node -e "console.log(require('./hooks/_config.js').readActiveDiet())"          # full
rm -rf "$T"; unset CLAUDE_CONFIG_DIR
```

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

Verify (sandboxed; off-state must NOT emit reinforcement, identical to today):
```
T=$(mktemp -d); export CLAUDE_CONFIG_DIR="$T"
printf '{"prompt":"/diet full"}' | node hooks/diet-track.js >/dev/null
node -e "console.log(require('./hooks/_config.js').readActiveDiet())"   # -> full
printf '{"prompt":"hello"}' | node hooks/diet-track.js | grep -c 'DIET MODE ACTIVE'  # -> 1
printf '{"prompt":"normal mode"}' | node hooks/diet-track.js >/dev/null
printf '{"prompt":"hello"}' | node hooks/diet-track.js | wc -c  # -> 0  (no reinforcement when off)
rm -rf "$T"; unset CLAUDE_CONFIG_DIR
```

Commit: `refactor(diet): diet-track uses config.json active-diet helpers`

---

## Task 6 — Update `codex-bridge.mjs` paths + config-driven rotation

In `scripts/codex-bridge.mjs`. **Single source of path truth**: the bridge must derive its paths from `_config.js` helpers (which honor `CLAUDE_CONFIG_DIR || os.homedir()`), NOT re-hardcode `os.homedir()`. Re-review v2 blocking #2: hardcoding `os.homedir()` made paths inconsistent with `_config.js` and untestable under a sandboxed `CLAUDE_CONFIG_DIR`.

**`codex-bridge.mjs` is pure ESM** (`import ... from "node:..."`). `require` is undefined in `.mjs`. Add to the import block (after the existing `import { fileURLToPath } from "node:url";`, line ~17):
```javascript
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const _sspowerCfg = require("../hooks/_config.js");
```
`createRequire(import.meta.url)` roots resolution at the bridge file (`scripts/`), so `"../hooks/_config.js"` correctly resolves to `hooks/_config.js`. `_config.js` is CommonJS (`hooks/package.json` is `{"type":"commonjs"}`) — `createRequire` loads it cleanly. Explicit `.js` extension required.

Line 53: `const FAILURE_LOG = path.join(os.homedir(), ".claude", "sspower-codex-failures.jsonl");`
→ `const FAILURE_LOG = _sspowerCfg.failuresLogPath();`

Line 61: `const LOG_FILE = path.join(os.homedir(), ".claude", "sspower-codex.log");`
→ `const LOG_FILE = _sspowerCfg.codexLogPath();`

Line 62: `const LOG_MAX_LINES = 1000;`
→
```javascript
const LOG_MAX_LINES = (() => {
  try {
    const v = _sspowerCfg.readConfig().log_rotate_lines;
    return Number.isInteger(v) && v > 0 ? v : 1000;
  } catch { return 1000; }
})();
```

Update comment lines 57-59 to reference `~/.claude/sspower/codex.log` and `~/.claude/sspower/failures.jsonl`.

`mkdir` guard so first write on a fresh machine doesn't fail. Immediately after the `LOG_MAX_LINES` block, add:
```javascript
try { fs.mkdirSync(_sspowerCfg.sspowerDir(), { recursive: true }); } catch { /* best effort */ }
```
(`fs` already imported at top — confirm `grep -nE "^import fs " scripts/codex-bridge.mjs`. `os`/`path` may now be unused by the removed lines but are used elsewhere in the file; do NOT remove their imports without `grep -c '\bos\.\|\bpath\.' scripts/codex-bridge.mjs` confirming 0.)

Verify (proves: config IS read, AND paths honor the sandbox — never touches real `~/.claude`):
```
node --check scripts/codex-bridge.mjs                       # syntax ok, exit 0
T=$(mktemp -d); export CLAUDE_CONFIG_DIR="$T"
node -e "require('./hooks/_config.js').writeConfigKey('log_rotate_lines',1234)"
node --input-type=module -e '
  import { createRequire } from "node:module";
  const r = createRequire(process.cwd()+"/scripts/codex-bridge.mjs");
  const c = r("../hooks/_config.js");
  console.log(c.readConfig().log_rotate_lines, c.failuresLogPath());
'   # -> 1234  /tmp/.../sspower/failures.jsonl   (config read + path sandboxed)
node scripts/codex-bridge.mjs --help | head -1              # usage banner, no throw
rm -rf "$T"; unset CLAUDE_CONFIG_DIR
```
The `../hooks/_config.js` path mirrors the bridge's actual require exactly (re-review v2 #1: `./hooks/...` would be `MODULE_NOT_FOUND`). The printed path must start with `$T/` — proving the bridge no longer hardcodes `os.homedir()` (re-review v2 #2).

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
ts="$(date -u +%Y%m%dT%H%M%SZ)"
mv_if() {  # $1=src $2=dst
  [ -e "$1" ] || return 0
  if [ ! -e "$2" ]; then
    mv "$1" "$2"; echo "moved: $1 -> $2"; moved=$((moved+1))
  else
    # Conflict: new code already created $2 (post-upgrade, pre-migrate).
    # NEVER leave the legacy root file orphaned (acceptance criterion) and
    # NEVER silently drop its data. Archive the legacy source beside the
    # destination with a timestamp, then remove it from root.
    local bak="$2.pre-migrate-$ts"
    mv "$1" "$bak"
    echo "conflict: $2 existed; legacy archived -> $bak (root cleared)"
    moved=$((moved+1))
  fi
}

mv_if "$BASE/sspower-codex-failures.jsonl" "$DIR/failures.jsonl"
mv_if "$BASE/sspower-codex.log"            "$DIR/codex.log"
mv_if "$BASE/sspower-codex-patches.md"     "$DIR/patches.md"

# Diet flag -> config.json .diet. IDEMPOTENT: only write diet when there is
# a legacy flag to migrate, OR when config.json has no diet yet. A re-run
# after the flag is gone must NOT clobber an already-migrated value.
CONFIG="$DIR/config.json"
NODE_CFG="$(cd "$(dirname "$0")/.." && pwd)/hooks/_config.js"

migrated_diet=""
if [ -f "$BASE/.sspower-diet" ]; then
  raw="$(tr -d '[:space:]' < "$BASE/.sspower-diet" | tr '[:upper:]' '[:lower:]')"
  case "$raw" in lite|full|ultra) migrated_diet="$raw" ;; *) migrated_diet="off" ;; esac
  rm -f "$BASE/.sspower-diet"
  echo "migrated diet flag: $migrated_diet"
fi

if [ -n "$migrated_diet" ]; then
  # Legacy flag existed THIS run -> authoritative. writeConfigKey merges
  # DEFAULTS, so log_rotate_lines is set on a brand-new file in the same call.
  CLAUDE_CONFIG_DIR="$BASE" node -e "require('$NODE_CFG').writeConfigKey('diet','$migrated_diet')"
elif [ ! -f "$CONFIG" ]; then
  # Brand-new config, no legacy flag: one write seeds the file. writeConfigKey
  # read-merges DEFAULTS, so the file lands as {"diet":"off","log_rotate_lines":1000}.
  CLAUDE_CONFIG_DIR="$BASE" node -e "require('$NODE_CFG').writeConfigKey('log_rotate_lines',1000)"
else
  # Config already exists, no legacy flag this run: touch NOTHING.
  # Re-run safety — never overwrite a previously migrated diet value.
  echo "config exists, no legacy flag: diet untouched (idempotent)"
fi

echo "done. moved=$moved config=$CONFIG"
ls -la "$DIR"
```

`chmod +x scripts/sspower-migrate.sh`.

Verify in a sandbox (does NOT touch real `~/.claude`):
```
T=$(mktemp -d); export CLAUDE_CONFIG_DIR="$T"
printf 'x\n' > "$T/sspower-codex.log"; echo full > "$T/.sspower-diet"
echo '[]' > "$T/sspower-codex-failures.jsonl"
printf '# patches\n' > "$T/sspower-codex-patches.md"
bash scripts/sspower-migrate.sh
# all 4 legacy files migrated, none left at root
test -f "$T/sspower/codex.log"
test -f "$T/sspower/failures.jsonl"
test -f "$T/sspower/patches.md"          # patches.md preserved (spec no-data-loss)
test ! -e "$T/.sspower-diet"
test ! -e "$T/sspower-codex-patches.md"
node -e "console.log(require('./hooks/_config.js').readActiveDiet())"  # -> full
# RE-RUN must be idempotent AND must NOT clobber migrated diet back to off
bash scripts/sspower-migrate.sh
node -e "console.log(require('./hooks/_config.js').readActiveDiet())"  # -> full  (still!)
rm -rf "$T"; unset CLAUDE_CONFIG_DIR

# Conflict path: dst already exists + legacy root file also exists.
# Legacy must be archived (no data loss) AND removed from root (no orphan).
T2=$(mktemp -d); export CLAUDE_CONFIG_DIR="$T2"
mkdir -p "$T2/sspower"; printf 'NEW\n' > "$T2/sspower/codex.log"
printf 'OLD\n' > "$T2/sspower-codex.log"
bash scripts/sspower-migrate.sh
test ! -e "$T2/sspower-codex.log"                              # root cleared (no orphan)
ls "$T2/sspower/"codex.log.pre-migrate-* >/dev/null            # legacy archived (data kept)
grep -q OLD "$T2/sspower/"codex.log.pre-migrate-*              # archived content intact
grep -q NEW "$T2/sspower/codex.log"                            # new file untouched
rm -rf "$T2"; unset CLAUDE_CONFIG_DIR
```
Every `test` passes; both `readActiveDiet()` prints are `full` (second run does NOT reset diet — the idempotency bug fix); second run reports `moved=0` and "diet untouched".

Commit: `feat(migrate): one-shot idempotent sspower-migrate.sh`

---

## Task 11 — Full verification (no commit)

From plugin root, on branch `refactor/sspower-config-consolidation`:

1. `bash tests/config/test_config.sh` → `PASS=16 FAIL=0`, exit 0.
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
5. `node --check scripts/codex-bridge.mjs` exit 0; config-driven rotation proven via the Task 6 createRequire verifier (prints `1234`, not `1000`).
6. Forced-failure append uses the new path (spec rollout step 4). Sandbox:
   ```
   T=$(mktemp -d); export CLAUDE_CONFIG_DIR="$T"
   # invoke the bridge so a guaranteed-nonzero codex run records a failure
   node scripts/codex-bridge.mjs rescue --prompt "noop" --model nonexistent-model-xyz >/dev/null 2>&1 || true
   test -f "$T/sspower/failures.jsonl" && test ! -e "$T/sspower-codex-failures.jsonl"
   echo "failure log at new path: OK"
   rm -rf "$T"; unset CLAUDE_CONFIG_DIR
   ```
   `failures.jsonl` exists under `$T/sspower/`, never at the legacy root path. (If the bridge no-ops without writing on this error class, assert instead that `FAILURE_LOG` resolves to `$T/sspower/failures.jsonl` via the Task 6 createRequire pattern — never the legacy path.)
7. Existing suites unaffected: run any present `tests/hooks/*.sh` and `tests/codex-bridge/*` — no new failures vs `main`.

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
