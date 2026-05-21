# sspower Unified Error Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use sspower:subagent-driven-development (recommended) or sspower:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture errors from all sspower/Claude Code surfaces into one unified log (`~/.claude/sspower/errors.jsonl`) and broaden the codex-only investigator skill into a full error investigator.

**Architecture:** Two tiers. Tier 1 (capture) — sspower shell hooks get an `EXIT` trap that logs uncaught crashes live. Tier 2 (scrape) — a Python scraper reads every log surface Claude Code already writes, classifies plugin-vs-external, dedups, and appends to `errors.jsonl`. The `error-health` skill (renamed from `codex-health`) and `/daily` consume the unified log.

**Tech Stack:** Bash (hooks, `_log.sh`), Python 3 stdlib (scraper), Markdown (skills).

**Spec:** `docs/specs/2026-05-21-sspower-error-capture-design.md`

**Execution note:** Commit steps below assume Claude/subagent execution. If
executed via `codex implement --write`, the Codex worker must NOT run
`git commit`/`push`/`merge` — it implements + verifies, leaves changes
uncommitted, and the supervisor commits at the task boundaries shown.

**Repos:** This plan spans two git repos.
- **plugin repo** = `/Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower` (branch `phase-e`) — Tasks 1, 2, 6.
- **claude repo** = `/Users/sskys/.claude` — Tasks 3, 4, 5.
Commit in the repo that owns each file. Never stage files from one repo into the other.

---

### Task 1: `_log.sh` error helpers

**Files:**
- Modify: `hooks/_log.sh` (plugin repo) — append two functions after `log_event`
- Test: `tests/test_log_helpers.sh` (plugin repo) — new

- [ ] **Step 1: Write the failing test**

Create `tests/test_log_helpers.sh`:

```bash
#!/usr/bin/env bash
# Test _sspower_exit_guard / _sspower_err_jsonl in hooks/_log.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export SSPOWER_LOG_FILE="$TMP/codex.log"
export SSPOWER_ERRORS_FILE="$TMP/errors.jsonl"
source "$HERE/../hooks/_log.sh"

fail() { echo "FAIL: $1"; exit 1; }

# 1. Expected code -> no row, no log
_sspower_exit_guard 0 "0" hook.test
[ -f "$SSPOWER_ERRORS_FILE" ] && fail "exit 0 wrote a row"

# 2. Expected code 20 (session-start) -> no row
_sspower_exit_guard 20 "0 20" hook.session-start
[ -f "$SSPOWER_ERRORS_FILE" ] && fail "exit 20 in allow-set wrote a row"

# 3. Unexpected code -> one row + one [error] log line
_sspower_exit_guard 1 "0" hook.test
[ -f "$SSPOWER_ERRORS_FILE" ] || fail "exit 1 wrote no row"
rows=$(wc -l < "$SSPOWER_ERRORS_FILE" | tr -d ' ')
[ "$rows" = "1" ] || fail "expected 1 row, got $rows"
grep -q '"category":"hook"' "$SSPOWER_ERRORS_FILE" || fail "category missing"
grep -q '"origin":"plugin"' "$SSPOWER_ERRORS_FILE" || fail "origin missing"
grep -q '"message":"exit 1"' "$SSPOWER_ERRORS_FILE" || fail "message missing"
grep -q '\[error\] hook.test kind=crash exit="1"' "$SSPOWER_LOG_FILE" || fail "codex.log line missing"

# 4. JSON is valid
python3 -c "import json,sys; [json.loads(l) for l in open('$SSPOWER_ERRORS_FILE')]" \
  || fail "errors.jsonl line is not valid JSON"

# 5. Message with quotes/backslashes is escaped
_sspower_err_jsonl hook plugin hook.test error 'has "quote" and \back'
python3 -c "import json; [json.loads(l) for l in open('$SSPOWER_ERRORS_FILE')]" \
  || fail "escaping produced invalid JSON"

# 6. errors.jsonl is mode 0600
perms=$(stat -f '%Lp' "$SSPOWER_ERRORS_FILE" 2>/dev/null || stat -c '%a' "$SSPOWER_ERRORS_FILE")
[ "$perms" = "600" ] || fail "errors.jsonl perms = $perms, expected 600"

echo "PASS test_log_helpers.sh"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_log_helpers.sh`
Expected: FAIL — `_sspower_exit_guard: command not found` (functions not yet defined).

- [ ] **Step 3: Add the two helpers to `_log.sh`**

Append to `hooks/_log.sh` (after the closing `}` of `log_event`):

```bash

# --- error capture (errors.jsonl) ----------------------------------------
SSPOWER_ERRORS_FILE="${SSPOWER_ERRORS_FILE:-$HOME/.claude/sspower/errors.jsonl}"

# Append one structured row to errors.jsonl. Best-effort, never errors out.
# Usage: _sspower_err_jsonl <category> <origin> <source> <level> <message>
_sspower_err_jsonl() {
  local cat="$1" org="$2" src="$3" lvl="$4" msg="$5"
  local ts esc existed=0
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || return 0
  esc="${msg//\\/\\\\}"; esc="${esc//\"/\\\"}"; esc="${esc//$'\n'/\\n}"
  [ -f "$SSPOWER_ERRORS_FILE" ] && existed=1
  (
    umask 077
    mkdir -p "$(dirname "$SSPOWER_ERRORS_FILE")" 2>/dev/null || exit 0
    printf '{"ts":"%s","category":"%s","origin":"%s","source":"%s","level":"%s","message":"%s","raw":"","session":null}\n' \
      "$ts" "$cat" "$org" "$src" "$lvl" "$esc" >> "$SSPOWER_ERRORS_FILE"
  ) 2>/dev/null || true
  if [ "$existed" = "0" ] && [ -f "$SSPOWER_ERRORS_FILE" ]; then
    chmod 600 "$SSPOWER_ERRORS_FILE" 2>/dev/null || true
  fi
}

# EXIT trap helper: log a crash only when the exit code is NOT expected.
# Usage: trap '_sspower_exit_guard $? "0" hook.NAME' EXIT
_sspower_exit_guard() {
  local rc="$1" ok="$2" src="$3"
  case " $ok " in *" $rc "*) return 0 ;; esac
  log_event error "$src" kind=crash exit="$rc"
  _sspower_err_jsonl hook plugin "$src" error "exit $rc"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_log_helpers.sh`
Expected: `PASS test_log_helpers.sh`

- [ ] **Step 5: Commit (plugin repo)**

```bash
git -C /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower add hooks/_log.sh tests/test_log_helpers.sh
```
Then, as a standalone invocation:
```bash
git -C /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower commit -m "feat(hooks): _log.sh error-capture helpers for errors.jsonl"
```

---

### Task 2: Install exit-trap in 9 shell hooks

**Files (all plugin repo):**
- Modify: `hooks/auto-review.sh`, `hooks/auto-spec-gate.sh` — `trap` line only (already source `_log.sh`)
- Modify: `hooks/session-start`, `hooks/prompt-submit`, `hooks/semble-session.sh`, `hooks/semble-context.sh`, `hooks/semble-rewrite.sh`, `hooks/cmd-rewrite.sh`, `hooks/codex-lsp-posttool.sh` — `source` + `trap` lines

`wiki-archive.sh` is **excluded** (ends with `exec`, EXIT trap never fires).

- [ ] **Step 1: Re-verify exit codes per hook**

Run:
```bash
cd /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower
for h in session-start prompt-submit semble-session.sh semble-context.sh \
         semble-rewrite.sh cmd-rewrite.sh auto-review.sh auto-spec-gate.sh \
         codex-lsp-posttool.sh; do
  printf '%-22s ' "$h"; grep -oE 'exit [0-9]+' "hooks/$h" | sort -u | tr '\n' ' '; echo
done
```
Expected: every hook shows only `exit 0` **except** `session-start` which shows `exit 0 exit 20`. If any hook shows a different code, set that hook's allow-set accordingly in Step 3 and note it.

- [ ] **Step 2: Add `source _log.sh` + trap to the 7 hooks that don't source it**

For each of `session-start`, `prompt-submit`, `semble-session.sh`, `semble-context.sh`, `semble-rewrite.sh`, `cmd-rewrite.sh`, `codex-lsp-posttool.sh`:

Insert these two lines immediately **after** the hook's `set -...` line (or after the shebang if there is no `set` line). Use the hook's basename for `NAME`, and allow-set `"0"` for all except `session-start` which uses `"0 20"`:

```bash
source "$(dirname "${BASH_SOURCE[0]}")/_log.sh" 2>/dev/null || true
trap '_sspower_exit_guard $? "0" hook.NAME' EXIT
```

`session-start` trap line specifically:
```bash
trap '_sspower_exit_guard $? "0 20" hook.session-start' EXIT
```

Concrete `NAME` per hook: `session-start`, `prompt-submit`, `semble-session`, `semble-context`, `semble-rewrite`, `cmd-rewrite`, `codex-lsp-posttool`.

Caveat for `set -e` hooks: place the two lines AFTER `set -e`/`set -u` so a sourcing failure under `set -e` cannot abort the hook — the `|| true` guards it. `_log.sh` only defines functions on source (no side effects), so it is safe under `set -u`.

- [ ] **Step 3: Add trap-only line to the 2 hooks that already source `_log.sh`**

`auto-review.sh` and `auto-spec-gate.sh` already `source .../_log.sh`. Add only the trap line, immediately after their existing `source` of `_log.sh`:

```bash
trap '_sspower_exit_guard $? "0" hook.auto-review' EXIT
```
```bash
trap '_sspower_exit_guard $? "0" hook.auto-spec-gate' EXIT
```

- [ ] **Step 4: Smoke-test each hook still runs and exits clean**

For each modified hook, run it with empty stdin and confirm exit 0 and no spurious error row:

```bash
cd /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower
export SSPOWER_ERRORS_FILE="$(mktemp -d)/errors.jsonl"
for h in semble-session.sh semble-context.sh semble-rewrite.sh cmd-rewrite.sh \
         codex-lsp-posttool.sh prompt-submit; do
  echo '{}' | bash "hooks/$h" >/dev/null 2>&1
  echo "$h exit=$?"
done
test ! -f "$SSPOWER_ERRORS_FILE" && echo "OK: no spurious error rows" \
  || { echo "FAIL: rows written by clean run:"; cat "$SSPOWER_ERRORS_FILE"; }
```
Expected: each hook `exit=0` (a hook may exit non-zero only if its real dependency is missing — note such cases), and `OK: no spurious error rows`. `session-start` and `auto-review.sh`/`auto-spec-gate.sh` need real harness JSON on stdin; skip them here and rely on Step 5.

- [ ] **Step 5: Force-crash test on one hook**

Verify the trap fires on a real crash. Temporarily inject a failing command:

```bash
cd /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower
export SSPOWER_ERRORS_FILE="$(mktemp -d)/errors.jsonl"
export SSPOWER_LOG_FILE="$(mktemp -d)/codex.log"
# run cmd-rewrite with a deliberately broken PATH entry to force a non-zero exit
bash -c 'source hooks/_log.sh; trap "_sspower_exit_guard \$? \"0\" hook.test" EXIT; false'
grep -q '"source":"hook.test"' "$SSPOWER_ERRORS_FILE" && echo "OK: crash captured" \
  || echo "FAIL: crash not captured"
```
Expected: `OK: crash captured`.

- [ ] **Step 6: Commit (plugin repo)**

```bash
git -C /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower add hooks/session-start hooks/prompt-submit hooks/semble-session.sh hooks/semble-context.sh hooks/semble-rewrite.sh hooks/cmd-rewrite.sh hooks/auto-review.sh hooks/auto-spec-gate.sh hooks/codex-lsp-posttool.sh
```
Standalone:
```bash
git -C /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower commit -m "feat(hooks): EXIT-trap crash capture in 9 shell hooks"
```

---

### Task 3: `scan_errors.py` scraper

**Files (claude repo):**
- Create: `skills/daily/scripts/scan_errors.py`
- Test: `skills/daily/scripts/test_scan_errors.py`

- [ ] **Step 1: Write the failing test**

Create `/Users/sskys/.claude/skills/daily/scripts/test_scan_errors.py`:

```python
#!/usr/bin/env python3
"""Tests for scan_errors.py — stdlib unittest, no external deps."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).parent
SCRIPT = HERE / "scan_errors.py"


def run(env):
    """Run scan_errors.py with env overrides; return (rc, summary_dict)."""
    full = dict(os.environ)
    full.update(env)
    p = subprocess.run(
        [sys.executable, str(SCRIPT), "--since", "7d", "--json"],
        capture_output=True, text=True, env=full,
    )
    summary = json.loads(p.stdout) if p.stdout.strip() else {}
    return p.returncode, summary


class TestScanErrors(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.errors = Path(self.tmp) / "errors.jsonl"
        self.codex_log = Path(self.tmp) / "codex.log"
        self.failures = Path(self.tmp) / "failures.jsonl"
        self.env = {
            "SSPOWER_ERRORS_FILE": str(self.errors),
            "SSPOWER_SCAN_CODEX_LOG": str(self.codex_log),
            "SSPOWER_SCAN_FAILURES": str(self.failures),
            "SSPOWER_SCAN_DEBUG_DIR": str(Path(self.tmp) / "nodir"),
            "SSPOWER_SCAN_MCP_ROOT": str(Path(self.tmp) / "nomcp"),
        }

    def test_codex_log_error_classified_as_codex(self):
        self.codex_log.write_text(
            '2026-05-21T04:00:00Z [error] bridge.complete kind=spawn_error msg="boom"\n'
        )
        rc, summary = run(self.env)
        self.assertEqual(rc, 0)
        rows = [json.loads(l) for l in self.errors.read_text().splitlines()]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["category"], "codex")
        self.assertEqual(rows[0]["origin"], "plugin")

    def test_hook_warn_classified_as_hook(self):
        self.codex_log.write_text(
            '2026-05-21T04:00:00Z [warn] hook.auto-review kind="deny_predecessor"\n'
        )
        rc, summary = run(self.env)
        rows = [json.loads(l) for l in self.errors.read_text().splitlines()]
        self.assertEqual(rows[0]["category"], "hook")
        self.assertEqual(rows[0]["origin"], "plugin")

    def test_info_lines_ignored(self):
        self.codex_log.write_text(
            '2026-05-21T04:00:00Z [info] hook.semble-context kind=inject\n'
        )
        rc, summary = run(self.env)
        self.assertFalse(self.errors.exists() and self.errors.read_text().strip())

    def test_failures_jsonl_ingested(self):
        self.failures.write_text(json.dumps({
            "ts": "2026-05-21T04:00:00Z", "command": "review",
            "error_kind": "timeout", "stderr_snippet": "timed out",
        }) + "\n")
        rc, summary = run(self.env)
        rows = [json.loads(l) for l in self.errors.read_text().splitlines()]
        self.assertEqual(rows[0]["category"], "codex")

    def test_dedup_on_rerun(self):
        self.codex_log.write_text(
            '2026-05-21T04:00:00Z [error] bridge.complete kind=spawn_error msg="boom"\n'
        )
        run(self.env)
        run(self.env)  # second run must add nothing
        rows = self.errors.read_text().splitlines()
        self.assertEqual(len(rows), 1)

    def test_secret_redaction(self):
        self.codex_log.write_text(
            '2026-05-21T04:00:00Z [error] bridge.complete msg="token=sk-abcdefghijklmnopqrstuvwx"\n'
        )
        run(self.env)
        text = self.errors.read_text()
        self.assertNotIn("sk-abcdefghijklmnopqrstuvwx", text)
        self.assertIn("REDACTED", text)

    def test_summary_shape(self):
        self.codex_log.write_text(
            '2026-05-21T04:00:00Z [error] bridge.complete kind=spawn_error msg="x"\n'
        )
        rc, summary = run(self.env)
        self.assertIn("counts", summary)
        self.assertIn("total", summary)
        self.assertEqual(summary["total"], 1)
        self.assertEqual(summary["counts"]["codex"]["plugin"], 1)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 /Users/sskys/.claude/skills/daily/scripts/test_scan_errors.py`
Expected: FAIL — all tests error because `scan_errors.py` does not exist.

- [ ] **Step 3: Write `scan_errors.py`**

Create `/Users/sskys/.claude/skills/daily/scripts/scan_errors.py`:

```python
#!/usr/bin/env python3
"""Scan Claude Code / sspower log surfaces, classify errors, append to errors.jsonl.

Mirrors extract_github.py: stdlib only, JSON summary to stdout, non-zero exit
only on a hard failure (a source being missing is NOT a hard failure).

Sources:
  ~/.claude/sspower/codex.log     [error]/[warn] lines  -> hook | codex
  ~/.claude/sspower/failures.jsonl                      -> codex
  ~/.claude/debug/*                                     -> plugin-load | cc-core
  ~/Library/Caches/claude-cli-nodejs/*/mcp-logs-*/*     -> mcp

errors.jsonl is a derived aggregate: re-running is idempotent (dedup by
sha1(category|source|message|day-bucket)).
"""
import argparse
import glob
import hashlib
import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

HOME = Path.home()


def _env_path(var, default):
    v = os.environ.get(var)
    return Path(v) if v else default


ERRORS_FILE = _env_path("SSPOWER_ERRORS_FILE", HOME / ".claude/sspower/errors.jsonl")
CODEX_LOG = _env_path("SSPOWER_SCAN_CODEX_LOG", HOME / ".claude/sspower/codex.log")
FAILURES = _env_path("SSPOWER_SCAN_FAILURES", HOME / ".claude/sspower/failures.jsonl")
DEBUG_DIR = _env_path("SSPOWER_SCAN_DEBUG_DIR", HOME / ".claude/debug")
MCP_ROOT = _env_path("SSPOWER_SCAN_MCP_ROOT", HOME / "Library/Caches/claude-cli-nodejs")

MAX_LINES = int(os.environ.get("SSPOWER_ERRORS_MAX", "2000"))
KEEP_LINES = int(os.environ.get("SSPOWER_ERRORS_KEEP", "1000"))

SECRET_PATTERNS = [
    (re.compile(r"sk-[A-Za-z0-9_-]{20,}"), "sk-***REDACTED***"),
    (re.compile(r"gh[ps]_[A-Za-z0-9]{20,}"), "gh*_***REDACTED***"),
    (re.compile(r"(password|passwd|secret|api[_-]?key|token)\s*[:=]\s*\S+", re.I),
     r"\1=***REDACTED***"),
]
ISO_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})")
# codex.log line:  TS [level] source key="value" ...
LOGLINE_RE = re.compile(r"^(\S+)\s+\[(\w+)\]\s+(\S+)\s*(.*)$")


def redact(text):
    for pat, repl in SECRET_PATTERNS:
        text = pat.sub(repl, text)
    return text


def parse_ts(s):
    """Parse an ISO-ish timestamp; return aware datetime or None."""
    m = ISO_RE.match(s or "")
    if not m:
        return None
    try:
        return datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S").replace(
            tzinfo=timezone.utc)
    except ValueError:
        return None


def since_cutoff(spec):
    now = datetime.now(timezone.utc)
    if spec.endswith("h"):
        return now - timedelta(hours=int(spec[:-1]))
    if spec.endswith("d"):
        return now - timedelta(days=int(spec[:-1]))
    dt = parse_ts(spec)
    return dt or (now - timedelta(hours=24))


def mkrow(ts, category, origin, source, level, message, raw):
    msg = redact(message)[:300]
    return {
        "ts": ts,
        "category": category,
        "origin": origin,
        "source": source,
        "level": level,
        "message": msg,
        "raw": redact(raw)[:500],
        "session": None,
    }


def dedup_key(row):
    day = (row["ts"] or "")[:10]
    h = hashlib.sha1()
    h.update("|".join([row["category"], row["source"],
                        row["message"], day]).encode("utf-8", "replace"))
    return h.hexdigest()


def scan_codex_log(cutoff):
    """codex.log [error]/[warn] lines -> hook or codex rows."""
    rows = []
    if not CODEX_LOG.exists():
        return rows
    for line in CODEX_LOG.read_text(errors="replace").splitlines():
        m = LOGLINE_RE.match(line)
        if not m:
            continue
        ts_s, level, source, rest = m.groups()
        if level not in ("error", "warn"):
            continue
        ts = parse_ts(ts_s)
        if ts and ts < cutoff:
            continue
        category = "codex" if source.startswith("bridge.") else "hook"
        origin = "plugin"
        rows.append(mkrow(ts_s, category, origin, source, level,
                           rest.strip(), line))
    return rows


def scan_failures(cutoff):
    """failures.jsonl -> codex rows."""
    rows = []
    if not FAILURES.exists():
        return rows
    for line in FAILURES.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        ts_s = d.get("ts", "")
        ts = parse_ts(ts_s)
        if ts and ts < cutoff:
            continue
        msg = "%s: %s" % (d.get("error_kind", "unknown"),
                          d.get("stderr_snippet", ""))
        rows.append(mkrow(ts_s, "codex", "plugin",
                           "bridge." + d.get("command", "?"),
                           "error", msg, line))
    return rows


def scan_dir_errorlines(root, category_fn, source_prefix):
    """Generic: scan text files under root for lines that look like errors.

    Best-effort heuristic. Uses file mtime for the --since window because the
    debug/MCP files are not reliably line-timestamped.
    """
    rows = []
    if not root or not Path(root).exists():
        return rows
    err_re = re.compile(r"\b(error|exception|failed|traceback)\b", re.I)
    for path in sorted(glob.glob(str(Path(root) / "**" / "*"), recursive=True)):
        p = Path(path)
        if not p.is_file():
            continue
        try:
            text = p.read_text(errors="replace")
        except OSError:
            continue
        for line in text.splitlines():
            if not err_re.search(line):
                continue
            category, origin = category_fn(p, line)
            rows.append(mkrow(
                datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                category, origin, source_prefix + p.name, "error",
                line.strip(), line))
    return rows


def classify_debug(path, line):
    """CC debug files: plugin-load vs cc-core."""
    low = line.lower()
    if "plugin" in low or "skill" in low or "agent" in low:
        origin = "plugin" if "sspower" in low else "external"
        return "plugin-load", origin
    return "cc-core", "external"


def classify_mcp(path, line):
    return "mcp", "external"


def load_existing_keys():
    keys = set()
    if not ERRORS_FILE.exists():
        return keys
    for line in ERRORS_FILE.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            keys.add(dedup_key(json.loads(line)))
        except (json.JSONDecodeError, KeyError):
            continue
    return keys


def append_rows(rows):
    """Append new rows; rotate ring-buffer; chmod 0600. Returns count added."""
    existed = ERRORS_FILE.exists()
    ERRORS_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(ERRORS_FILE, "a", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    if not existed:
        try:
            os.chmod(ERRORS_FILE, 0o600)
        except OSError:
            pass
    lines = ERRORS_FILE.read_text(errors="replace").splitlines()
    if len(lines) > MAX_LINES:
        kept = "\n".join(lines[-KEEP_LINES:]) + "\n"
        ERRORS_FILE.write_text(kept, encoding="utf-8")
    return len(rows)


def build_summary(new_rows, window):
    counts = {}
    seen = {}
    for r in new_rows:
        c = counts.setdefault(r["category"], {"plugin": 0, "external": 0})
        c[r["origin"]] += 1
        k = (r["source"], r["message"])
        seen[k] = seen.get(k, 0) + 1
    recurring = [{"source": s, "message": m, "count": n}
                 for (s, m), n in sorted(seen.items(), key=lambda x: -x[1])
                 if n >= 3]
    return {
        "window": window,
        "total": len(new_rows),
        "counts": counts,
        "recurring": recurring,
    }


def main():
    ap = argparse.ArgumentParser(description="Scan log surfaces into errors.jsonl")
    ap.add_argument("--since", default="24h", help="1h | 24h | 7d | ISO-8601")
    ap.add_argument("--json", action="store_true", help="emit summary JSON")
    args = ap.parse_args()

    cutoff = since_cutoff(args.since)
    candidates = []
    candidates += scan_codex_log(cutoff)
    candidates += scan_failures(cutoff)
    candidates += scan_dir_errorlines(DEBUG_DIR, classify_debug, "cc.")
    candidates += scan_dir_errorlines(MCP_ROOT, classify_mcp, "mcp.")

    existing = load_existing_keys()
    fresh = []
    batch_keys = set()
    for r in candidates:
        k = dedup_key(r)
        if k in existing or k in batch_keys:
            continue
        batch_keys.add(k)
        fresh.append(r)

    append_rows(fresh)
    summary = build_summary(fresh, args.since)
    if args.json:
        print(json.dumps(summary, ensure_ascii=False))
    else:
        print("scan_errors: %d new rows (%s)" % (summary["total"], args.since))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # hard failure only
        print(json.dumps({"status": "error", "error": str(exc)}))
        sys.exit(1)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 /Users/sskys/.claude/skills/daily/scripts/test_scan_errors.py`
Expected: `OK` — all 7 tests pass.

- [ ] **Step 5: Smoke-test against real logs**

Run: `python3 /Users/sskys/.claude/skills/daily/scripts/scan_errors.py --since 24h --json`
Expected: valid JSON summary printed; `~/.claude/sspower/errors.jsonl` created or appended; a second run prints `"total": 0` (dedup holds).

- [ ] **Step 6: Commit (claude repo)**

```bash
git -C /Users/sskys/.claude add skills/daily/scripts/scan_errors.py skills/daily/scripts/test_scan_errors.py
```
Standalone:
```bash
git -C /Users/sskys/.claude commit -m "feat(daily): scan_errors.py unified error scraper"
```

---

### Task 4: Rename `codex-health` → `error-health`, broaden SKILL.md

**Files (claude repo):**
- Rename: `skills/codex-health/` → `skills/error-health/`
- Rewrite: `skills/error-health/SKILL.md`

- [ ] **Step 1: Rename the directory with git**

```bash
git -C /Users/sskys/.claude mv skills/codex-health skills/error-health
```

- [ ] **Step 2: Rewrite `skills/error-health/SKILL.md`**

Overwrite `/Users/sskys/.claude/skills/error-health/SKILL.md` with:

```markdown
---
description: Investigate all Claude Code / sspower errors — hooks, plugin load, codex bridge, CC core, MCP. Trigger 'error health' / 'errors' / 'investigate errors' / 'codex health' / called by /daily skill.
allowed-tools: Read, Bash, Glob, Grep, Write, Edit
---

Run after a busy day or when errors pile up. Read-only triage + state cleanup — does NOT modify the bridge or hooks.

## Inputs
- `$HOME/.claude/sspower/errors.jsonl` — unified error log (built by `scan_errors.py`)
- `$HOME/.claude/sspower/codex.log` — raw text log
- `$HOME/.claude/sspower/failures.jsonl` — structured codex bridge failures
- Per-repo `.git/sspower-review-rounds-<branch>` — round counters
- `$HOME/.cache/sspower/verdicts/*.json` — review verdict cache

## 1. Error inventory (last 24h)

Refresh the unified log, then read it:
```bash
python3 "$HOME/.claude/skills/daily/scripts/scan_errors.py" --since 24h --json
```
Report a table from the summary: `category | origin | count`.

## 2. Plugin vs external split

Headline: total errors, how many `origin=plugin` (sspower's fault) vs
`origin=external` (Claude Code core / other plugins / MCP). This is the
first thing to surface.

## 3. Recurring errors

From the summary `recurring` array (same `source`+`message` seen 3+ times),
list each with its count. Recurring plugin errors are the priority fixes.

## 4. Hook crashes

Filter `errors.jsonl` for `category:hook`:
```bash
grep '"category":"hook"' "$HOME/.claude/sspower/errors.jsonl" | tail -20
```
Report which hook crashed and the exit code. A crashing hook is a real bug.

## 5. Codex section (stuck branches + verdict cache)

Find branches at or near the round cap:
```bash
find ~ -maxdepth 6 -path "*/.git/sspower-review-rounds-*" -type f 2>/dev/null \
  | while read f; do
      n=$(cat "$f")
      repo=$(dirname "$f" | xargs dirname)
      branch=$(basename "$f" | sed 's/sspower-review-rounds-//')
      echo "$n  $branch  $repo"
    done | sort -rn
```
Report branches with rounds >=2.

Clean stale verdict cache:
```bash
find ~/.cache/sspower/verdicts -name "*.json" -mtime +7 -delete -print
```
Print count cleaned.

## 6. Recommendations

| category / kind | action |
|-----------------|--------|
| hook crash | real bug — open the named hook, find the failing command |
| codex spawn_error | codex CLI not found / not authenticated — `codex login` |
| codex timeout | check OpenAI quota; consider `quick` profile |
| codex no_output | content-policy or quota; retry |
| plugin-load (sspower) | malformed skill/agent frontmatter — fix the YAML |
| plugin-load (external) | not sspower's bug — report upstream |
| cc-core | Claude Code bug — report to Anthropic; not user-fixable |
| mcp | the named MCP server is failing — check its config |
| review_cap | branch needs manual review — list exact `rm` commands |

## 7. Auto-actions (with confirmation)

Ask the user before:
- Removing rounds files (unblocks branches)
- Clearing verdict cache fully (`rm -rf ~/.cache/sspower/verdicts/*.json`)
- Disabling auto-review for a stuck repo (`.sspower-skip-auto-review` marker)

## 8. Output

Telegram-style summary:
```
Error health 24h
- 14 total: 9 plugin, 5 external
- By category: hook 2, codex 7, plugin-load 1, cc-core 3, mcp 1
- Recurring: hook.auto-review "exit 1" x4
- Hook crashes: cmd-rewrite (exit 1)
- Stuck branches: feat/x (3/3)
- Cleaned: 6 stale verdict cache files
```
Print to stdout. Do NOT auto-send Telegram (the /daily skill aggregates).
```

- [ ] **Step 3: Verify no stale `codex-health` references remain in the claude repo**

Run:
```bash
grep -rn "codex-health" /Users/sskys/.claude/skills /Users/sskys/.claude/bin 2>/dev/null
```
Expected: only matches are in `skills/daily/SKILL.md` (fixed in Task 5). If any other file references `codex-health`, update it to `error-health`.

- [ ] **Step 4: Commit (claude repo)**

```bash
git -C /Users/sskys/.claude add -A skills/error-health skills/codex-health
```
Standalone:
```bash
git -C /Users/sskys/.claude commit -m "feat(skills): rename codex-health to error-health, broaden to all error categories"
```

---

### Task 5: `/daily` integration

**Files (claude repo):**
- Modify: `skills/daily/SKILL.md` — subagent 3 reference + new `## Errors` section

- [ ] **Step 1: Update subagent 3 in step 1**

In `/Users/sskys/.claude/skills/daily/SKILL.md`, find the `**Subagent 3 — Codex health**` block. Replace it with:

```markdown
**Subagent 3 — Error health**: Read `$HOME/.claude/skills/error-health/SKILL.md` and execute steps 1-6 (error inventory, plugin/external split, recurring, hook crashes, codex stuck branches, stale verdict cache) for the last 24h. Report: total errors with plugin/external split, count by category, recurring errors, hook crashes, stuck branches w/ unblock commands, cleaned cache count. Do NOT auto-clear rounds files — list them for human action.
```

- [ ] **Step 2: Add the `## Errors` section spec to step 2c**

In `skills/daily/SKILL.md`, in the step 2c section list (after `## GitHub`, before the next section), add:

```markdown
**N. ## Errors**

Run `python3 $HOME/.claude/skills/daily/scripts/scan_errors.py --since 24h --json`. Capture the summary JSON.

If `total` == 0:
  Write: `## Errors — clean`
Else:
  Write `## Errors — N plugin, M external` header (N = sum of all `counts.*.plugin`, M = sum of all `counts.*.external`), then:
  - one line per category: `- {category}: {plugin} plugin, {external} external`
  - if `recurring` non-empty, a `**Recurring:**` line listing each `{source} "{message}" x{count}`

Idempotency: if `## Errors` header exists WITHOUT `⚠️` -> skip. WITH `⚠️` -> replace. If `scan_errors.py` fails (non-zero exit), write `## Errors — ⚠️ scan failed`.
```

Renumber subsequent sections in step 2c accordingly.

- [ ] **Step 3: Verify the daily skill has no remaining `codex-health` / `## Codex Health` references**

Run:
```bash
grep -n "codex-health\|Codex Health" /Users/sskys/.claude/skills/daily/SKILL.md
```
Expected: no output. If `## Codex Health` is still referenced as a section, replace it — codex health is now folded into subagent 3's report and the `## Errors` section.

- [ ] **Step 4: Commit (claude repo)**

```bash
git -C /Users/sskys/.claude add skills/daily/SKILL.md
```
Standalone:
```bash
git -C /Users/sskys/.claude commit -m "feat(daily): error-health subagent + ## Errors section"
```

---

### Task 6: Update plugin `CLAUDE.md`

**Files (plugin repo):**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add an error-capture bullet to Key Rules**

In `/Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower/CLAUDE.md`, in the `## Key Rules` list, add a bullet near the codex-tracking bullets:

```markdown
- Error capture: sspower shell hooks install an `EXIT` trap (`_sspower_exit_guard` in `hooks/_log.sh`) that logs uncaught crashes to `~/.claude/sspower/errors.jsonl` — a unified, deduped error log covering hook crashes, codex bridge errors, plugin-load, CC-core, and MCP. `errors.jsonl` is a derived aggregate: the live writer is the hook trap; everything else is scraped by `skills/daily/scripts/scan_errors.py` (in the `~/.claude` repo). Investigate via the `error-health` skill (renamed from `codex-health`) or `/daily`. `wiki-archive.sh` is excluded from the trap (it `exec`s; an EXIT trap never fires)
```

- [ ] **Step 2: Verify no stale `codex-health` reference in plugin CLAUDE.md**

Run:
```bash
grep -n "codex-health" /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower/CLAUDE.md
```
Expected: no output (the plugin CLAUDE.md does not currently reference `codex-health`; if it does, update to `error-health`).

- [ ] **Step 3: Commit (plugin repo)**

```bash
git -C /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower add CLAUDE.md
```
Standalone:
```bash
git -C /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower commit -m "docs(claude-md): document unified error capture + error-health"
```

---

## Verification (whole plan)

- [ ] `bash tests/test_log_helpers.sh` → `PASS` (plugin repo)
- [ ] `python3 ~/.claude/skills/daily/scripts/test_scan_errors.py` → `OK` (7 tests)
- [ ] Each of the 9 trapped hooks runs clean (no spurious error rows) — Task 2 Step 4
- [ ] Forced crash produces an `errors.jsonl` row — Task 2 Step 5
- [ ] `scan_errors.py --since 24h` is idempotent — second run `total: 0`
- [ ] `grep -rn codex-health ~/.claude/skills` → no matches
- [ ] `error-health` skill eval-tested (plugin rule: all skill changes eval-tested before commit) — run via `skill-creator` eval or a manual dry-run of the SKILL.md steps
- [ ] Both repos: `git status` clean after the 6 commits

## Notes / known limitations

- Debug-dir and MCP-log parsing in `scan_errors.py` is heuristic (regex on
  "error/exception/failed/traceback"). Format of `~/.claude/debug/*` is not
  a documented contract — expect to tune `classify_debug` after seeing real
  data. This is acceptable per spec §12 (scrape is best-effort).
- `scan_errors.py` uses file mtime for the `--since` window on debug/MCP
  files because those are not reliably line-timestamped; codex.log and
  failures.jsonl use real line/record timestamps.
- The codex `spawn_error` → `failures.jsonl` source-level fix is NOT in this
  plan (spec §3.4, deferred). The scraper covers it from `codex.log`.
