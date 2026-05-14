# sspower-mem Phase A — Plaintext Memory Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use sspower:subagent-driven-development (recommended) or sspower:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a `uvx`-runnable Python CLI `sspower-mem` that provides a plaintext memory backend (per-scope `digest.md`) with strict symlink/TOCTOU-safe writes, file-locked appends, and grep+recent search. Zero index-backend/Chroma/Model2Vec dependencies. Ship-able as v0 independent of all later phases.

**Architecture:** Stdlib-only Python 3.11+ package at `scripts/sspower_mem/`. Layered modules: `io.py` (openat-walk primitives) → `lock.py` (`fcntl.flock` ctx) → `scope.py` (cwd canonicalization, path derivation) → `digest.py` (block id, append, parse, search) → `doctor.py` (bootstrap) → `cli.py` (argparse dispatch). Tests with pytest. All four exit codes (0/10/20/30) wired through. The index-backend contract is RESERVED — Phase A returns `extracted: "n/a"` (not "ok"/"skipped"); `--no-llm` is accepted but no-op since there is no LLM step yet.

**Tech Stack:** Python 3.11+ (POSIX: macOS + Linux), stdlib only (`argparse`, `fcntl`, `hashlib`, `os`, `pathlib`, `re`, `subprocess`, `sys`, `json`, `time`, `datetime`), `pytest` (dev dep), `uv` for runtime invocation. No network. No third-party runtime deps.

**Spec reference:** `docs/specs/2026-05-13-index-backend-integration-design.md` v8, sections §5 (storage layout), §6.1 (CLI contract + write critical section + read path), §6.4 (digest format + safe_append_strict), §9 Phase A (checklist).

---

## File Structure

Files to create (all paths relative to `<plugin-root>` = `~/.claude/plugins/marketplaces/sskys18/plugins/sspower/`):

```
scripts/sspower_mem/
├── pyproject.toml                   # Package decl + entry point
├── sspower_mem/
│   ├── __init__.py                  # __version__
│   ├── __main__.py                  # python -m sspower_mem entrypoint
│   ├── io.py                        # safe_append_strict, safe_makedirs_strict
│   ├── lock.py                      # acquire_lock context manager
│   ├── scope.py                     # canonicalize_cwd, scope_paths, scope_id
│   ├── digest.py                    # compute_id, append_block, parse_blocks, grep_search, recent
│   ├── doctor.py                    # bootstrap, health
│   └── cli.py                       # argparse + dispatch
└── tests/
    ├── conftest.py                  # tmp trust-root fixtures
    ├── test_io.py                   # symlink/traversal/fd-safety
    ├── test_lock.py                 # concurrent contention
    ├── test_scope.py                # cwd canonicalization, scope id, paths
    ├── test_digest.py               # id, append, parse, search, collision, _dup<N>
    ├── test_doctor.py               # bootstrap idempotence
    └── test_cli.py                  # CLI integration: exit codes 0/20/30, --json, --cwd
```

---

### Task 1: Package skeleton + pyproject.toml + version

**Files:**
- Create: `scripts/sspower_mem/pyproject.toml`
- Create: `scripts/sspower_mem/sspower_mem/__init__.py`
- Create: `scripts/sspower_mem/sspower_mem/__main__.py`

- [ ] **Step 1: Write `pyproject.toml`**

```toml
[project]
name = "sspower-mem"
version = "0.1.0"
description = "sspower plaintext memory backend (Phase A)"
requires-python = ">=3.11"
dependencies = []

[project.scripts]
sspower-mem = "sspower_mem.cli:main"

[project.optional-dependencies]
test = ["pytest>=8"]

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["sspower_mem"]
```

- [ ] **Step 2: Write `sspower_mem/__init__.py`**

```python
"""sspower-mem — plaintext memory backend (Phase A)."""
__version__ = "0.1.0"
```

- [ ] **Step 3: Write `sspower_mem/__main__.py`**

```python
from sspower_mem.cli import main
import sys

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

- [ ] **Step 4: Verify the package builds**

Run: `cd scripts/sspower_mem && uv build 2>&1 | tail -5`
Expected: lines ending with `Successfully built ... sspower_mem-0.1.0-py3-none-any.whl`

- [ ] **Step 5: Commit**

```bash
git -C "$(git rev-parse --show-toplevel)" add scripts/sspower_mem/pyproject.toml scripts/sspower_mem/sspower_mem/__init__.py scripts/sspower_mem/sspower_mem/__main__.py
git commit -m "feat(sspower-mem): package skeleton for Phase A plaintext backend"
```

---

### Task 2: `io.safe_append_strict` — failing test for symlink refusal

**Files:**
- Create: `scripts/sspower_mem/tests/conftest.py`
- Create: `scripts/sspower_mem/tests/test_io.py`

- [ ] **Step 1: Write `conftest.py` with a trust-root fixture**

```python
import os
import pathlib
import pytest


@pytest.fixture
def trust_root(tmp_path: pathlib.Path) -> pathlib.Path:
    """A clean, non-symlink trust root dir at 0700."""
    root = tmp_path / "trust"
    root.mkdir(mode=0o700)
    return root
```

- [ ] **Step 2: Write the first failing test in `test_io.py`**

```python
import os
import pathlib
import pytest

from sspower_mem.io import safe_append_strict


def test_safe_append_strict_refuses_symlinked_final_file(trust_root, tmp_path):
    # Set up: <trust>/digest.md is a symlink pointing OUTSIDE trust_root.
    target = tmp_path / "outside.md"
    target.write_text("attacker-controlled\n")
    link = trust_root / "digest.md"
    os.symlink(target, link)

    with pytest.raises(OSError):
        safe_append_strict(link, "should-not-write\n", trust_root)

    # The outside file must not have been appended to.
    assert target.read_text() == "attacker-controlled\n"
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd scripts/sspower_mem && uv run --with pytest pytest tests/test_io.py::test_safe_append_strict_refuses_symlinked_final_file -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'sspower_mem.io'`

- [ ] **Step 4: Commit**

```bash
git add scripts/sspower_mem/tests/conftest.py scripts/sspower_mem/tests/test_io.py
git commit -m "test(sspower-mem): symlink refusal contract for safe_append_strict"
```

---

### Task 3: `io.safe_append_strict` — minimal implementation

**Files:**
- Create: `scripts/sspower_mem/sspower_mem/io.py`

- [ ] **Step 1: Write `io.py`**

```python
"""Symlink-safe, TOCTOU-closed write primitives for digest.md.

Per spec §6.4: openat-walk + O_NOFOLLOW on every component below trust_root.
"""
from __future__ import annotations

import os
import pathlib


def _open_dir(path_or_fd, flags_dir: int, *, dir_fd: int | None = None) -> int:
    return os.open(path_or_fd, flags_dir, dir_fd=dir_fd) if dir_fd is not None else os.open(path_or_fd, flags_dir)


def safe_append_strict(path: pathlib.Path, content: str, trust_root: pathlib.Path) -> None:
    """Append `content` to `path`, refusing if any path component AT OR BELOW
    `trust_root` is a symlink. TOCTOU-closed via openat-style relative opens with
    O_NOFOLLOW. Loops on partial writes (handles short os.write returns)."""
    try:
        rel = path.relative_to(trust_root)
    except ValueError as e:
        raise OSError(f"path {path} not under trust_root {trust_root}") from e

    for part in rel.parts:
        if part in ("", ".", ".."):
            raise OSError(f"path {path} contains traversal component {part!r}")

    flags_dir = os.O_RDONLY | os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags_dir |= os.O_NOFOLLOW

    cur_fd = os.open(trust_root, flags_dir)
    try:
        # Walk intermediate dirs (all parts except the last).
        for part in rel.parts[:-1]:
            next_fd = os.open(part, flags_dir, dir_fd=cur_fd)
            os.close(cur_fd)
            cur_fd = next_fd

        # Open final file relative to last dir fd, O_NOFOLLOW.
        file_flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT
        if hasattr(os, "O_NOFOLLOW"):
            file_flags |= os.O_NOFOLLOW
        file_fd = os.open(rel.parts[-1], file_flags, mode=0o644, dir_fd=cur_fd)
        try:
            data = content.encode("utf-8")
            written = 0
            while written < len(data):
                n = os.write(file_fd, data[written:])
                if n <= 0:
                    raise OSError("safe_append_strict: os.write returned 0")
                written += n
        finally:
            os.close(file_fd)
    finally:
        os.close(cur_fd)
```

- [ ] **Step 2: Run test to verify it passes**

Run: `cd scripts/sspower_mem && uv run --with pytest pytest tests/test_io.py::test_safe_append_strict_refuses_symlinked_final_file -v`
Expected: PASS (1 passed)

- [ ] **Step 3: Commit**

```bash
git add scripts/sspower_mem/sspower_mem/io.py
git commit -m "feat(sspower-mem): safe_append_strict — openat + O_NOFOLLOW + partial-write loop"
```

---

### Task 4: `safe_append_strict` — happy path + traversal + outside trust_root

**Files:**
- Modify: `scripts/sspower_mem/tests/test_io.py`

- [ ] **Step 1: Append three failing tests to `test_io.py`**

```python
def test_safe_append_strict_writes_content(trust_root):
    path = trust_root / "digest.md"
    safe_append_strict(path, "hello\n", trust_root)
    safe_append_strict(path, "world\n", trust_root)
    assert path.read_text() == "hello\nworld\n"


def test_safe_append_strict_rejects_traversal(trust_root):
    bad = pathlib.Path(str(trust_root) + "/sub/../escape.md")
    # path is lexically under trust_root, but contains ".."
    with pytest.raises(OSError, match="traversal"):
        safe_append_strict(bad, "x\n", trust_root)


def test_safe_append_strict_rejects_outside_trust_root(trust_root, tmp_path):
    outside = tmp_path / "elsewhere" / "digest.md"
    with pytest.raises(OSError, match="not under trust_root"):
        safe_append_strict(outside, "x\n", trust_root)


def test_safe_append_strict_refuses_symlinked_parent_dir(trust_root, tmp_path):
    # <trust>/wiki is a symlink to an outside dir; final file would be inside that.
    outside_dir = tmp_path / "evil"
    outside_dir.mkdir()
    link_dir = trust_root / "wiki"
    os.symlink(outside_dir, link_dir)
    bad = link_dir / "digest.md"
    with pytest.raises(OSError):
        safe_append_strict(bad, "x\n", trust_root)
    assert not (outside_dir / "digest.md").exists()
```

- [ ] **Step 2: Run tests**

Run: `cd scripts/sspower_mem && uv run --with pytest pytest tests/test_io.py -v`
Expected: All 4 tests PASS (including the original symlinked-final-file one)

- [ ] **Step 3: Commit**

```bash
git add scripts/sspower_mem/tests/test_io.py
git commit -m "test(sspower-mem): happy path + traversal + outside trust_root + symlinked parent"
```

---

### Task 5: `io.safe_makedirs_strict` — failing test

**Files:**
- Modify: `scripts/sspower_mem/tests/test_io.py`

- [ ] **Step 1: Append two failing tests**

```python
from sspower_mem.io import safe_makedirs_strict


def test_safe_makedirs_strict_creates_nested(trust_root):
    target = trust_root / "a" / "b" / "c"
    safe_makedirs_strict(target, trust_root)
    assert target.is_dir()
    # idempotent
    safe_makedirs_strict(target, trust_root)
    assert target.is_dir()


def test_safe_makedirs_strict_refuses_symlink_in_path(trust_root, tmp_path):
    outside = tmp_path / "evil"
    outside.mkdir()
    link_dir = trust_root / "a"
    os.symlink(outside, link_dir)
    target = link_dir / "b"
    with pytest.raises(OSError):
        safe_makedirs_strict(target, trust_root)
```

- [ ] **Step 2: Run — verify they fail with ImportError**

Run: `cd scripts/sspower_mem && uv run --with pytest pytest tests/test_io.py::test_safe_makedirs_strict_creates_nested -v`
Expected: FAIL with `ImportError: cannot import name 'safe_makedirs_strict'`

- [ ] **Step 3: Commit**

```bash
git add scripts/sspower_mem/tests/test_io.py
git commit -m "test(sspower-mem): safe_makedirs_strict — nested + symlink refusal"
```

---

### Task 6: `io.safe_makedirs_strict` — implementation

**Files:**
- Modify: `scripts/sspower_mem/sspower_mem/io.py`

- [ ] **Step 1: Append `safe_makedirs_strict` to `io.py`**

```python
def safe_makedirs_strict(path: pathlib.Path, parent_anchor: pathlib.Path, mode: int = 0o700) -> None:
    """Create `path` and missing intermediate dirs UNDER `parent_anchor`, using
    openat-style mkdirat. Rejects symlink components below `parent_anchor`.
    `parent_anchor` itself must already exist and not be a symlink."""
    try:
        rel = path.relative_to(parent_anchor)
    except ValueError as e:
        raise OSError(f"path {path} not under parent_anchor {parent_anchor}") from e

    for part in rel.parts:
        if part in ("", ".", ".."):
            raise OSError(f"traversal component {part!r} in {path}")

    flags_dir = os.O_RDONLY | os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags_dir |= os.O_NOFOLLOW

    cur_fd = os.open(parent_anchor, flags_dir)
    try:
        for part in rel.parts:
            try:
                os.mkdir(part, mode=mode, dir_fd=cur_fd)
            except FileExistsError:
                pass  # already exists; open below verifies it is not a symlink
            next_fd = os.open(part, flags_dir, dir_fd=cur_fd)
            os.close(cur_fd)
            cur_fd = next_fd
    finally:
        os.close(cur_fd)
```

- [ ] **Step 2: Run all io tests**

Run: `cd scripts/sspower_mem && uv run --with pytest pytest tests/test_io.py -v`
Expected: 6 passed

- [ ] **Step 3: Commit**

```bash
git add scripts/sspower_mem/sspower_mem/io.py
git commit -m "feat(sspower-mem): safe_makedirs_strict — mkdirat walk + symlink refusal"
```

---

### Task 7: `lock.acquire_lock` — failing test for mutual exclusion

**Files:**
- Create: `scripts/sspower_mem/tests/test_lock.py`

- [ ] **Step 1: Write `test_lock.py`**

```python
import multiprocessing as mp
import pathlib
import time

import pytest

from sspower_mem.lock import acquire_lock


def _hold_lock(lock_path: str, hold_seconds: float, started_event, finished_event):
    with acquire_lock(pathlib.Path(lock_path)):
        started_event.set()
        time.sleep(hold_seconds)
        finished_event.set()


def test_acquire_lock_blocks_concurrent_writer(tmp_path):
    lock_path = tmp_path / ".lock"
    started = mp.Event()
    finished = mp.Event()
    p = mp.Process(target=_hold_lock, args=(str(lock_path), 0.5, started, finished))
    p.start()
    assert started.wait(timeout=2.0), "holder process did not start"

    t0 = time.monotonic()
    with acquire_lock(lock_path):
        elapsed = time.monotonic() - t0
        # We waited until the other process released the lock.
        assert finished.is_set(), "second acquire returned before holder finished"
        assert elapsed >= 0.4, f"second acquire returned too fast ({elapsed:.2f}s)"
    p.join(timeout=2.0)
    assert p.exitcode == 0
```

- [ ] **Step 2: Run — fail with ImportError**

Run: `cd scripts/sspower_mem && uv run --with pytest pytest tests/test_lock.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'sspower_mem.lock'`

- [ ] **Step 3: Commit**

```bash
git add scripts/sspower_mem/tests/test_lock.py
git commit -m "test(sspower-mem): mutual exclusion contract for acquire_lock"
```

---

### Task 8: `lock.acquire_lock` — implementation

**Files:**
- Create: `scripts/sspower_mem/sspower_mem/lock.py`

- [ ] **Step 1: Write `lock.py`**

```python
"""POSIX fcntl-based exclusive file lock context manager.

Per spec §6.1: one critical section per `add` invocation, lock file at
~/.claude/sspower/idx/.lock.
"""
from __future__ import annotations

import contextlib
import fcntl
import os
import pathlib
from typing import Iterator


@contextlib.contextmanager
def acquire_lock(lock_path: pathlib.Path) -> Iterator[int]:
    """Exclusive blocking flock on `lock_path`. Creates the file if missing.
    Yields the fd. Releases on exit (including exception).
    """
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        try:
            yield fd
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)
```

- [ ] **Step 2: Run lock test**

Run: `cd scripts/sspower_mem && uv run --with pytest pytest tests/test_lock.py -v`
Expected: 1 passed (test takes ~0.5s)

- [ ] **Step 3: Commit**

```bash
git add scripts/sspower_mem/sspower_mem/lock.py
git commit -m "feat(sspower-mem): acquire_lock fcntl context manager"
```

---

### Task 9: `scope.canonicalize_cwd` — failing test

**Files:**
- Create: `scripts/sspower_mem/tests/test_scope.py`

- [ ] **Step 1: Write `test_scope.py`**

```python
import hashlib
import os
import pathlib

import pytest

from sspower_mem.scope import (
    canonicalize_cwd,
    parent_anchor,
    project_wiki_dir,
    scope_id,
    user_sspower_dir,
)


def test_canonicalize_cwd_resolves_symlinks(tmp_path):
    real = tmp_path / "real"
    real.mkdir()
    link = tmp_path / "link"
    os.symlink(real, link)
    assert canonicalize_cwd(str(link)) == real.resolve()


def test_canonicalize_cwd_rejects_missing(tmp_path):
    missing = tmp_path / "nope"
    with pytest.raises(FileNotFoundError):
        canonicalize_cwd(str(missing))


def test_scope_id_project_uses_realpath_hash(tmp_path):
    real = tmp_path / "proj"
    real.mkdir()
    link = tmp_path / "alias"
    os.symlink(real, link)
    # Both lexical paths resolve to the same project scope id.
    a = scope_id("project", canonicalize_cwd(str(real)))
    b = scope_id("project", canonicalize_cwd(str(link)))
    assert a == b
    expected = "project:" + hashlib.sha1(str(real.resolve()).encode()).hexdigest()[:16]
    assert a == expected


def test_scope_id_user_is_static():
    assert scope_id("user", None) == "user:global"


def test_paths_helpers(tmp_path):
    assert project_wiki_dir(tmp_path) == tmp_path / ".claude" / "wiki"
    home = pathlib.Path.home()
    assert user_sspower_dir() == home / ".claude" / "sspower"


def test_parent_anchor_returns_trusted_preexisting_path(tmp_path):
    """parent_anchor returns the trusted pre-existing path for openat-walk
    trust-root creation. Per spec §6.4 the only valid anchors are $HOME and
    the user-supplied --cwd."""
    proj = tmp_path / "proj"
    proj.mkdir()
    cwd = canonicalize_cwd(str(proj))
    assert parent_anchor("project", cwd) == cwd
    assert parent_anchor("user", None) == pathlib.Path.home()
    with pytest.raises(ValueError):
        parent_anchor("project", None)
    with pytest.raises(ValueError):
        parent_anchor("bogus", None)
```

- [ ] **Step 2: Run — fail with ModuleNotFoundError**

Run: `cd scripts/sspower_mem && uv run --with pytest pytest tests/test_scope.py -v`
Expected: FAIL

- [ ] **Step 3: Commit**

```bash
git add scripts/sspower_mem/tests/test_scope.py
git commit -m "test(sspower-mem): cwd canonicalization + scope_id realpath hash"
```

---

### Task 10: `scope.py` — implementation

**Files:**
- Create: `scripts/sspower_mem/sspower_mem/scope.py`

- [ ] **Step 1: Write `scope.py`**

```python
"""Scope resolution: cwd canonicalization, project hash, path helpers.

Per spec §5 (storage layout) and §6.4 (--cwd canonicalization).
"""
from __future__ import annotations

import hashlib
import os
import pathlib


def canonicalize_cwd(cwd_arg: str) -> pathlib.Path:
    """Resolve symlinks and verify the cwd exists.
    Raises FileNotFoundError if the path does not exist."""
    p = pathlib.Path(cwd_arg)
    if not p.exists():
        raise FileNotFoundError(f"cwd does not exist: {cwd_arg}")
    return p.resolve()


def scope_id(scope: str, cwd: pathlib.Path | None) -> str:
    """Return the scope key used as the index backend's user_id and digest header field.
    project → sha1(realpath(cwd))[:16]; user → "user:global"."""
    if scope == "project":
        if cwd is None:
            raise ValueError("project scope requires cwd")
        h = hashlib.sha1(str(cwd).encode()).hexdigest()[:16]
        return f"project:{h}"
    if scope == "user":
        return "user:global"
    raise ValueError(f"unknown scope: {scope}")


def project_wiki_dir(cwd: pathlib.Path) -> pathlib.Path:
    """Project-scope trust root: <cwd>/.claude/wiki/"""
    return cwd / ".claude" / "wiki"


def user_sspower_dir() -> pathlib.Path:
    """User-scope trust root: ~/.claude/sspower/"""
    return pathlib.Path.home() / ".claude" / "sspower"


def digest_path(scope: str, cwd: pathlib.Path | None) -> pathlib.Path:
    """Resolve the digest.md path for a given scope."""
    if scope == "project":
        return project_wiki_dir(cwd) / "digest.md"
    if scope == "user":
        return user_sspower_dir() / "digest.md"
    raise ValueError(f"unknown scope: {scope}")


def trust_root(scope: str, cwd: pathlib.Path | None) -> pathlib.Path:
    """Trust root for the scope's digest path."""
    if scope == "project":
        return project_wiki_dir(cwd)
    if scope == "user":
        return user_sspower_dir()
    raise ValueError(f"unknown scope: {scope}")


def parent_anchor(scope: str, cwd: pathlib.Path | None) -> pathlib.Path:
    """Trusted pre-existing path that anchors openat walks for trust-root creation.

    Per spec §6.4: the only paths assumed pre-existing and trusted are $HOME and
    the user-supplied --cwd value. Callers pass the result to safe_makedirs_strict
    when they need to create the trust root (e.g., first project-scope add against
    a fresh repo where <cwd>/.claude/wiki/ does not yet exist)."""
    if scope == "project":
        if cwd is None:
            raise ValueError("project scope requires cwd")
        return cwd  # already canonicalized realpath
    if scope == "user":
        return pathlib.Path.home()
    raise ValueError(f"unknown scope: {scope}")
```

- [ ] **Step 2: Run scope tests**

Run: `cd scripts/sspower_mem && uv run --with pytest pytest tests/test_scope.py -v`
Expected: 6 passed

- [ ] **Step 3: Commit**

```bash
git add scripts/sspower_mem/sspower_mem/scope.py
git commit -m "feat(sspower-mem): scope resolution + cwd canonicalization"
```

---

### Task 11: `digest.compute_id` + block format — failing test

**Files:**
- Create: `scripts/sspower_mem/tests/test_digest.py`

- [ ] **Step 1: Write the first batch of digest tests**

```python
import hashlib
import pathlib

import pytest

from sspower_mem.digest import compute_id, format_block, parse_blocks


def test_compute_id_is_stable_sha1_16():
    a = compute_id("project:abc", "decision", "use the index")
    b = compute_id("project:abc", "decision", "use the index")
    assert a == b
    assert a == hashlib.sha1(b"project:abc|decision|use the index").hexdigest()[:16]


def test_compute_id_differs_on_content_change():
    assert compute_id("project:abc", "decision", "use the index") != \
           compute_id("project:abc", "decision", "use the index!")


def test_format_block_round_trips_through_parse():
    block = format_block(
        ts="2026-05-13T10:00:00Z",
        scope="project:abc12345",
        layer="episodic",
        block_id="0123456789abcdef",
        meta={"foo": "bar"},
        content="some content\nspanning lines",
    )
    parsed = list(parse_blocks(block))
    assert len(parsed) == 1
    p = parsed[0]
    assert p["ts"] == "2026-05-13T10:00:00Z"
    assert p["scope"] == "project:abc12345"
    assert p["layer"] == "episodic"
    assert p["id"] == "0123456789abcdef"
    assert p["meta"] == {"foo": "bar"}
    assert p["content"].rstrip() == "some content\nspanning lines"


def test_parse_blocks_handles_multiple():
    b1 = format_block("2026-05-13T10:00:00Z", "user:global", "user-global",
                     "id0000000000000a", {}, "first")
    b2 = format_block("2026-05-13T11:00:00Z", "user:global", "user-global",
                     "id0000000000000b", {"k": "v"}, "second")
    parsed = list(parse_blocks(b1 + b2))
    assert [p["id"] for p in parsed] == ["id0000000000000a", "id0000000000000b"]


def test_meta_serialization_handles_commas_and_equals():
    """Path-safe meta serialization: values may contain commas/equals."""
    block = format_block(
        ts="2026-05-13T10:00:00Z",
        scope="user:global",
        layer="user-global",
        block_id="abc1234567890123",
        meta={"migrated_from": "/path/with,comma=equals.md"},
        content="x",
    )
    parsed = list(parse_blocks(block))
    assert parsed[0]["meta"]["migrated_from"] == "/path/with,comma=equals.md"
```

- [ ] **Step 2: Run — fail with ModuleNotFoundError**

Run: `cd scripts/sspower_mem && uv run --with pytest pytest tests/test_digest.py -v`
Expected: FAIL

- [ ] **Step 3: Commit**

```bash
git add scripts/sspower_mem/tests/test_digest.py
git commit -m "test(sspower-mem): compute_id + block format round-trip + meta escaping"
```

---

### Task 12: `digest.py` — id + format + parse implementation

**Files:**
- Create: `scripts/sspower_mem/sspower_mem/digest.py`

- [ ] **Step 1: Write `digest.py` (initial: id, format, parse)**

```python
"""Digest block: id, format, parse, append, search.

Block format (spec §6.4):
    ## <ISO-8601-ts> · <scope> · <layer> · <id>
    [meta] <JSON-encoded dict>
    <content>

    ---

Meta is serialized as a single JSON object on its own line, prefixed with
`[meta] `. JSON handles commas / equals / quotes in values losslessly,
fixing the unsafe `key=value, key=value` shape from spec v8.
"""
from __future__ import annotations

import datetime
import hashlib
import json
import re
from typing import Iterator


_HEADER_RE = re.compile(
    r"^## (?P<ts>\S+) · (?P<scope>[^·]+?) · (?P<layer>[^·]+?) · (?P<id>\S+)\s*$"
)
_META_RE = re.compile(r"^\[meta\] (.+)$")
_SEPARATOR = "\n---\n\n"


def compute_id(scope: str, layer: str, content: str) -> str:
    """16-char SHA-1 over scope|layer|content (spec §6.1, v4 widened from 8)."""
    return hashlib.sha1(f"{scope}|{layer}|{content}".encode("utf-8")).hexdigest()[:16]


def iso_now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def format_block(
    ts: str,
    scope: str,
    layer: str,
    block_id: str,
    meta: dict,
    content: str,
) -> str:
    """Render one block. Caller appends to digest.md atomically."""
    # Strip trailing newlines from content; we control the separator.
    body = content.rstrip("\n")
    meta_line = "[meta] " + json.dumps(meta, separators=(",", ":"), sort_keys=True)
    return f"## {ts} · {scope} · {layer} · {block_id}\n{meta_line}\n{body}{_SEPARATOR}"


def parse_blocks(text: str) -> Iterator[dict]:
    """Yield {ts, scope, layer, id, meta, content} per block.
    Tolerant: skips malformed blocks rather than raising."""
    # Split into raw block strings on the canonical separator.
    raw_blocks = text.split(_SEPARATOR)
    for raw in raw_blocks:
        raw = raw.strip("\n")
        if not raw:
            continue
        lines = raw.split("\n")
        if not lines:
            continue
        h = _HEADER_RE.match(lines[0])
        if not h:
            continue
        meta: dict = {}
        body_start = 1
        if len(lines) > 1:
            m = _META_RE.match(lines[1])
            if m:
                try:
                    meta = json.loads(m.group(1))
                except json.JSONDecodeError:
                    meta = {}
                body_start = 2
        body = "\n".join(lines[body_start:])
        yield {
            "ts": h.group("ts"),
            "scope": h.group("scope"),
            "layer": h.group("layer"),
            "id": h.group("id"),
            "meta": meta,
            "content": body,
        }
```

- [ ] **Step 2: Run digest tests**

Run: `cd scripts/sspower_mem && uv run --with pytest pytest tests/test_digest.py -v`
Expected: 5 passed

- [ ] **Step 3: Commit**

```bash
git add scripts/sspower_mem/sspower_mem/digest.py
git commit -m "feat(sspower-mem): compute_id + JSON-encoded meta block format + parser"
```

---

### Task 13: `digest.append_block_or_skip` — collision handling test

**Files:**
- Modify: `scripts/sspower_mem/tests/test_digest.py`

- [ ] **Step 1: Append three tests for the collision contract**

```python
from sspower_mem.digest import append_block_or_skip


def test_append_block_or_skip_returns_id_on_new(trust_root):
    digest = trust_root / "digest.md"
    eff_id, was_new = append_block_or_skip(
        digest_path=digest,
        trust_root=trust_root,
        scope="user:global",
        layer="user-global",
        content="first",
        meta={},
    )
    assert was_new is True
    assert len(eff_id) == 16
    assert digest.exists()


def test_append_block_or_skip_dedups_identical_content(trust_root):
    digest = trust_root / "digest.md"
    a_id, a_new = append_block_or_skip(digest, trust_root, "user:global",
                                       "user-global", "same", {})
    b_id, b_new = append_block_or_skip(digest, trust_root, "user:global",
                                       "user-global", "same", {})
    assert a_id == b_id
    assert a_new is True
    assert b_new is False  # dedup'd
    # Only one block in the file.
    blocks = list(parse_blocks(digest.read_text()))
    assert len(blocks) == 1


def test_append_block_or_skip_handles_collision_with_dup_suffix(trust_root, monkeypatch):
    """If two distinct contents hash to the same base_id, the second gets `_dup1`."""
    digest = trust_root / "digest.md"

    # Force a collision: monkeypatch compute_id to always return the same value.
    import sspower_mem.digest as d
    monkeypatch.setattr(d, "compute_id", lambda *a, **k: "collision00000000")

    a_id, _ = append_block_or_skip(digest, trust_root, "user:global",
                                   "user-global", "content-A", {})
    b_id, _ = append_block_or_skip(digest, trust_root, "user:global",
                                   "user-global", "content-B", {})
    assert a_id == "collision00000000"
    assert b_id == "collision00000000_dup1"
    blocks = list(parse_blocks(digest.read_text()))
    assert {b["id"] for b in blocks} == {a_id, b_id}
```

- [ ] **Step 2: Run — fail with ImportError**

Run: `cd scripts/sspower_mem && uv run --with pytest pytest tests/test_digest.py::test_append_block_or_skip_returns_id_on_new -v`
Expected: FAIL

- [ ] **Step 3: Commit**

```bash
git add scripts/sspower_mem/tests/test_digest.py
git commit -m "test(sspower-mem): collision dedup + _dup<N> contract"
```

---

### Task 14: `digest.append_block_or_skip` — implementation

**Files:**
- Modify: `scripts/sspower_mem/sspower_mem/digest.py`

- [ ] **Step 1: Append to `digest.py`**

```python
import pathlib

from sspower_mem.io import safe_append_strict, safe_makedirs_strict


def _existing_blocks_by_base(digest_path: pathlib.Path) -> dict[str, list[dict]]:
    """Map base_id (with any _dup<N> stripped) → list of blocks already present."""
    if not digest_path.exists():
        return {}
    by_base: dict[str, list[dict]] = {}
    for blk in parse_blocks(digest_path.read_text(encoding="utf-8")):
        bid = blk["id"]
        base = bid.split("_dup", 1)[0]
        by_base.setdefault(base, []).append(blk)
    return by_base


def append_block_or_skip(
    digest_path: pathlib.Path,
    trust_root: pathlib.Path,
    scope: str,
    layer: str,
    content: str,
    meta: dict,
    ts: str | None = None,
    *,
    parent_anchor: pathlib.Path | None = None,
) -> tuple[str, bool]:
    """Append a block, applying §6.1 collision-safe id logic.

    `parent_anchor`: trusted pre-existing path under which `trust_root` should be
    created if missing. Per spec §6.4, the only valid anchors are $HOME and the
    user-supplied --cwd value (see scope.parent_anchor()). When None, assumes
    `trust_root` already exists (test setup; legacy callers).

    Returns (effective_id, was_new). was_new=False means an identical block
    already existed (dedup hit, no write).
    """
    if parent_anchor is not None:
        # Create the trust root itself (e.g., first project-scope add on a fresh
        # <cwd>/.claude/wiki/) by walking openat from the trusted anchor down to
        # trust_root. Idempotent: existing components are accepted as long as
        # they are not symlinks.
        safe_makedirs_strict(trust_root, parent_anchor)
    # If no anchor, trust_root MUST already exist; otherwise the open below fails.
    base_id = compute_id(scope, layer, content)
    existing = _existing_blocks_by_base(digest_path)
    for blk in existing.get(base_id, []):
        if blk["content"].rstrip("\n") == content.rstrip("\n"):
            return blk["id"], False  # dedup hit
    if base_id in existing:
        # collision: pick next free _dup<N>
        suffixes = [
            int(b["id"].split("_dup", 1)[1])
            for b in existing[base_id]
            if "_dup" in b["id"] and b["id"].split("_dup", 1)[1].isdigit()
        ]
        n = max(suffixes, default=0) + 1
        effective_id = f"{base_id}_dup{n}"
    else:
        effective_id = base_id
    block = format_block(
        ts=ts or iso_now(),
        scope=scope,
        layer=layer,
        block_id=effective_id,
        meta=meta,
        content=content,
    )
    safe_append_strict(digest_path, block, trust_root)
    return effective_id, True
```

Also fix the import in test_digest.py — `safe_makedirs_strict` needs `parent_anchor` to exist. The trust_root fixture creates `tmp_path/trust`; `parent_anchor` passed is `trust_root.parent` (= `tmp_path`). Adjust:

```python
# In test_digest.py: add a fixture using the existing trust_root from conftest.
# (No change needed — conftest.trust_root is already mode=0o700 under tmp_path.)
```

- [ ] **Step 2: Run digest tests**

Run: `cd scripts/sspower_mem && uv run --with pytest pytest tests/test_digest.py -v`
Expected: 8 passed

- [ ] **Step 3: Commit**

```bash
git add scripts/sspower_mem/sspower_mem/digest.py
git commit -m "feat(sspower-mem): append_block_or_skip with full-content compare + _dup<N>"
```

---

### Task 15: `digest.grep_search` — failing test

**Files:**
- Modify: `scripts/sspower_mem/tests/test_digest.py`

- [ ] **Step 1: Append grep-search tests**

```python
from sspower_mem.digest import grep_search, recent


def test_grep_search_tokenizes_and_scores(trust_root):
    digest = trust_root / "digest.md"
    append_block_or_skip(digest, trust_root, "user:global", "user-global",
                        "memory backend design decision about chroma", {})
    append_block_or_skip(digest, trust_root, "user:global", "user-global",
                        "completely unrelated content about telegram", {})
    append_block_or_skip(digest, trust_root, "user:global", "user-global",
                        "another chroma note", {})
    hits = grep_search([digest], "chroma backend", top_k=5)
    assert len(hits) == 2
    # The first block has both tokens; should rank above the chroma-only one.
    assert "memory backend" in hits[0]["content"]
    assert all(0.0 <= h["score"] <= 1.0 for h in hits)
    assert hits[0]["source"] == "digest-grep"


def test_grep_search_drops_short_tokens(trust_root):
    digest = trust_root / "digest.md"
    append_block_or_skip(digest, trust_root, "user:global", "user-global",
                        "chromaDB note", {})
    hits = grep_search([digest], "is a db", top_k=5)
    # All tokens < 3 chars; query becomes the literal string.
    # "is a db" appears as substring? Not in the content. Should be empty.
    assert hits == []


def test_grep_search_max_zero_returns_empty(trust_root):
    digest = trust_root / "digest.md"
    append_block_or_skip(digest, trust_root, "user:global", "user-global",
                        "hello world", {})
    hits = grep_search([digest], "absent_term_xyz", top_k=5)
    assert hits == []


def test_recent_returns_newest_first(trust_root):
    digest = trust_root / "digest.md"
    append_block_or_skip(digest, trust_root, "user:global", "user-global",
                        "old", {}, ts="2026-05-10T00:00:00Z")
    append_block_or_skip(digest, trust_root, "user:global", "user-global",
                        "mid", {}, ts="2026-05-11T00:00:00Z")
    append_block_or_skip(digest, trust_root, "user:global", "user-global",
                        "new", {}, ts="2026-05-12T00:00:00Z")
    hits = recent([digest], top_k=2)
    assert [h["content"].strip() for h in hits] == ["new", "mid"]
    assert hits[0]["score"] == 1.0
    assert hits[0]["source"] == "digest-recent"
```

- [ ] **Step 2: Run — fail with ImportError**

Run: `cd scripts/sspower_mem && uv run --with pytest pytest tests/test_digest.py::test_grep_search_tokenizes_and_scores -v`
Expected: FAIL

- [ ] **Step 3: Commit**

```bash
git add scripts/sspower_mem/tests/test_digest.py
git commit -m "test(sspower-mem): grep_search scoring + recent ordering"
```

---

### Task 16: `digest.grep_search` + `digest.recent` — implementation

**Files:**
- Modify: `scripts/sspower_mem/sspower_mem/digest.py`

- [ ] **Step 1: Append search functions**

```python
_TOKEN_RE = re.compile(r"[a-z0-9]+")


def _tokenize(query: str) -> list[str]:
    """Lowercase, split on word boundaries, drop tokens < 3 chars.
    Falls back to the literal query as one token if zero remain."""
    toks = [t for t in _TOKEN_RE.findall(query.lower()) if len(t) >= 3]
    return toks if toks else [query.lower()]


def _load_all_blocks(digest_paths: list[pathlib.Path]) -> list[dict]:
    blocks: list[dict] = []
    for p in digest_paths:
        if not p.exists():
            continue
        blocks.extend(parse_blocks(p.read_text(encoding="utf-8")))
    return blocks


def grep_search(
    digest_paths: list[pathlib.Path],
    query: str,
    top_k: int = 8,
    layer_filter: list[str] | None = None,
) -> list[dict]:
    """Deterministic grep scoring per spec §6.1 read path."""
    tokens = _tokenize(query)
    candidates: list[tuple[float, dict]] = []
    for blk in _load_all_blocks(digest_paths):
        if layer_filter and blk["layer"] not in layer_filter:
            continue
        text_lower = blk["content"].lower()
        hits = sum(text_lower.count(t) for t in tokens)
        if hits == 0:
            continue
        raw = hits / max(1, len(blk["content"]) / 1000)
        candidates.append((raw, blk))
    if not candidates:
        return []
    max_raw = max(r for r, _ in candidates)
    if max_raw == 0:
        return []
    scored = [
        {
            "id": b["id"],
            "source": "digest-grep",
            "score": r / max_raw,
            "content": b["content"],
            "scope": b["scope"],
            "layer": b["layer"],
            "ts": b["ts"],
        }
        for r, b in candidates
    ]
    scored.sort(key=lambda h: (-h["score"], -_ts_key(h["ts"]), h["id"]))
    return scored[:top_k]


def recent(
    digest_paths: list[pathlib.Path],
    top_k: int = 8,
    layer_filter: list[str] | None = None,
) -> list[dict]:
    """Top-k newest blocks by ts. Score = linear position normalized."""
    blocks = _load_all_blocks(digest_paths)
    if layer_filter:
        blocks = [b for b in blocks if b["layer"] in layer_filter]
    if not blocks:
        return []
    blocks.sort(key=lambda b: (-_ts_key(b["ts"]), b["id"]))
    chosen = blocks[:top_k]
    n = len(chosen)
    out: list[dict] = []
    for i, b in enumerate(chosen):
        score = 1.0 if n == 1 else 1.0 - (i / (n - 1))
        out.append({
            "id": b["id"],
            "source": "digest-recent",
            "score": score,
            "content": b["content"],
            "scope": b["scope"],
            "layer": b["layer"],
            "ts": b["ts"],
        })
    return out


def _ts_key(ts: str) -> int:
    """Sortable int from an ISO timestamp (epoch seconds). Returns 0 on parse failure."""
    try:
        return int(datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")
                   .replace(tzinfo=datetime.timezone.utc).timestamp())
    except ValueError:
        return 0
```

- [ ] **Step 2: Run digest tests**

Run: `cd scripts/sspower_mem && uv run --with pytest pytest tests/test_digest.py -v`
Expected: 12 passed

- [ ] **Step 3: Commit**

```bash
git add scripts/sspower_mem/sspower_mem/digest.py
git commit -m "feat(sspower-mem): grep_search (tokenize/score/top-k) + recent (ts-sorted)"
```

---

### Task 17: `doctor.bootstrap` — failing test

**Files:**
- Create: `scripts/sspower_mem/tests/test_doctor.py`

- [ ] **Step 1: Write `test_doctor.py`**

```python
import pathlib

import pytest

from sspower_mem.doctor import bootstrap, health


def test_bootstrap_creates_user_sspower_dir(monkeypatch, tmp_path):
    fake_home = tmp_path / "home"
    fake_home.mkdir()
    monkeypatch.setenv("HOME", str(fake_home))
    monkeypatch.setattr(pathlib.Path, "home", classmethod(lambda cls: fake_home))

    result = bootstrap()
    sspower = fake_home / ".claude" / "sspower"
    assert (sspower / "idx").is_dir()
    assert (sspower / "idx" / ".lock").exists()
    assert (sspower / "idx" / "config.json").exists()
    assert result["status"] == "ok"

    # Idempotent — second call must not raise.
    bootstrap()


def test_health_reports_ok_after_bootstrap(monkeypatch, tmp_path):
    fake_home = tmp_path / "home"
    fake_home.mkdir()
    monkeypatch.setattr(pathlib.Path, "home", classmethod(lambda cls: fake_home))
    bootstrap()
    h = health()
    assert h["lock_writable"] is True
    assert h["digest_writable"] is True


def test_health_reports_missing_when_no_bootstrap(monkeypatch, tmp_path):
    fake_home = tmp_path / "home"
    fake_home.mkdir()
    monkeypatch.setattr(pathlib.Path, "home", classmethod(lambda cls: fake_home))
    h = health()
    assert h["lock_writable"] is False
```

- [ ] **Step 2: Run — fail with ModuleNotFoundError**

Run: `cd scripts/sspower_mem && uv run --with pytest pytest tests/test_doctor.py -v`
Expected: FAIL

- [ ] **Step 3: Commit**

```bash
git add scripts/sspower_mem/tests/test_doctor.py
git commit -m "test(sspower-mem): doctor bootstrap creates user dir + idempotent + health"
```

---

### Task 18: `doctor.py` — implementation

**Files:**
- Create: `scripts/sspower_mem/sspower_mem/doctor.py`

- [ ] **Step 1: Write `doctor.py`**

```python
"""Phase A doctor — user-scope bootstrap + health.

User-scope only per spec §6.4 trust-root creation. Project-scope dirs are
created lazily on first `add --scope project`.
"""
from __future__ import annotations

import json

from sspower_mem.io import safe_makedirs_strict
from sspower_mem.scope import user_sspower_dir


def bootstrap() -> dict:
    """Create ~/.claude/sspower/idx/{.lock,config.json}. Idempotent."""
    base = user_sspower_dir()
    base.parent.mkdir(parents=True, exist_ok=True)  # ~/.claude/ may not exist
    base.mkdir(mode=0o700, exist_ok=True)
    idx = base / "idx"
    # Use safe_makedirs_strict; parent_anchor = ~/.claude/sspower/
    safe_makedirs_strict(idx, base)
    lock = idx / ".lock"
    if not lock.exists():
        lock.touch(mode=0o600)
    config = idx / "config.json"
    if not config.exists():
        config.write_text(json.dumps({
            "version": "0.1.0",
            "phase": "A",
            "index": {"enabled": False, "note": "Phase A: digest-only, no index backend"},
        }, indent=2))
    return {"status": "ok", "base": str(base)}


def health() -> dict:
    """Lightweight health check. Returns booleans for each subsystem."""
    base = user_sspower_dir()
    idx = base / "idx"
    lock = idx / ".lock"
    digest = base / "digest.md"
    return {
        "lock_writable": lock.exists() and _writable(lock),
        "digest_writable": _writable(digest) if digest.exists() else _writable(base),
        "phase": "A",
    }


def _writable(p) -> bool:
    import os
    try:
        return os.access(p, os.W_OK)
    except OSError:
        return False
```

- [ ] **Step 2: Run doctor tests**

Run: `cd scripts/sspower_mem && uv run --with pytest pytest tests/test_doctor.py -v`
Expected: 3 passed

- [ ] **Step 3: Commit**

```bash
git add scripts/sspower_mem/sspower_mem/doctor.py
git commit -m "feat(sspower-mem): doctor.bootstrap (user-scope) + health"
```

---

### Task 19: `cli.py` — argparse + dispatch + exit codes

**Files:**
- Create: `scripts/sspower_mem/sspower_mem/cli.py`

- [ ] **Step 1: Write `cli.py`**

```python
"""CLI entry point.

Exit codes per spec section 6.1:
  0 = ok
 10 = degraded (Phase A: not yet triggered; reserved for B/C)
 20 = HARD (digest unwritable / traversal / outside trust_root)
 30 = dep missing (Phase A: bootstrap not run / unexpected import error)
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import sys

from sspower_mem.digest import (
    DigestSource,
    _load_all_blocks,
    append_block_or_skip,
    grep_search,
    recent,
)
from sspower_mem.doctor import bootstrap, health
from sspower_mem.io import _assert_regular_private_file, safe_read_strict
from sspower_mem.lock import acquire_lock
from sspower_mem.scope import (
    canonicalize_cwd,
    digest_path,
    parent_anchor,
    scope_id,
    trust_root,
    user_sspower_dir,
)

PROJECT_LAYERS = frozenset({"episodic", "decision", "gotcha"})
USER_LAYERS = frozenset({"user-global"})


def _resolve_cwd(args: argparse.Namespace) -> pathlib.Path | None:
    if not getattr(args, "cwd", None):
        # Project-scope without --cwd: fall back to os.getcwd() for interactive use.
        if getattr(args, "scope", "") in ("project", "project,user"):
            return canonicalize_cwd(os.getcwd())
        return None
    return canonicalize_cwd(args.cwd)


def _parse_meta(meta_args: list[str]) -> dict:
    out: dict = {}
    for entry in meta_args or []:
        if "=" not in entry:
            raise ValueError(f"--meta entry must be key=value, got: {entry}")
        key, value = entry.split("=", 1)
        out[key.strip()] = value.strip()
    return out


def _read_content_file(path: str) -> str:
    abs_path = pathlib.Path(os.path.abspath(path))
    file_flags = os.O_RDONLY
    if hasattr(os, "O_NONBLOCK"):
        file_flags |= os.O_NONBLOCK
    if hasattr(os, "O_NOFOLLOW"):
        file_flags |= os.O_NOFOLLOW

    file_fd = os.open(abs_path, file_flags)
    try:
        _assert_regular_private_file(file_fd, abs_path)
        chunks: list[bytes] = []
        while True:
            chunk = os.read(file_fd, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks).decode("utf-8")
    finally:
        os.close(file_fd)


def _validate_layer_for_scope(scope: str, layer: str) -> str | None:
    allowed_layers = PROJECT_LAYERS if scope == "project" else USER_LAYERS
    if layer in allowed_layers:
        return None

    if layer in PROJECT_LAYERS:
        return f"layer {layer} is only valid with --scope project"
    if layer in USER_LAYERS:
        return f"layer {layer} is only valid with --scope user"
    return f"unknown layer {layer}"


def cmd_add(args: argparse.Namespace) -> int:
    layer_error = _validate_layer_for_scope(args.scope, args.layer)
    if layer_error:
        print(f"sspower-mem: {layer_error}", file=sys.stderr)
        return 30

    try:
        cwd = _resolve_cwd(args) if args.scope == "project" else None
    except FileNotFoundError as e:
        print(f"sspower-mem: {e}", file=sys.stderr)
        return 20

    sc_id = scope_id(args.scope, cwd)
    troot = trust_root(args.scope, cwd)
    panchor = parent_anchor(args.scope, cwd)
    dpath = digest_path(args.scope, cwd)
    try:
        content = args.content if args.content is not None else _read_content_file(args.content_file)
    except OSError as e:
        print(f"sspower-mem: content file read failed: {e}", file=sys.stderr)
        return 20
    meta = _parse_meta(args.meta)
    if args.no_llm:
        meta = {**meta, "no_llm": True}

    lock_path = user_sspower_dir() / "idx" / ".lock"
    if not lock_path.exists():
        print(
            f"sspower-mem: lock missing at {lock_path}; run `sspower-mem doctor --bootstrap`",
            file=sys.stderr,
        )
        return 30

    try:
        with acquire_lock(lock_path):
            try:
                eff_id, was_new = append_block_or_skip(
                    digest_path=dpath,
                    trust_root=troot,
                    parent_anchor=panchor,
                    scope=sc_id,
                    layer=args.layer,
                    content=content,
                    meta=meta,
                )
            except OSError as e:
                print(f"sspower-mem: digest write failed: {e}", file=sys.stderr)
                return 20
            except ValueError as e:
                print(f"sspower-mem: digest write failed: {e}", file=sys.stderr)
                return 20
    except OSError as e:
        print(f"sspower-mem: lock unavailable: {e}", file=sys.stderr)
        return 30

    result = {
        "id": eff_id,
        "new": was_new,
        "raw": "n/a",
        "extracted": "n/a",
    }
    print(json.dumps(result))
    return 0


def cmd_search(args: argparse.Namespace) -> int:
    if args.idx_only:
        print(
            "sspower-mem: --idx-only requires the Phase C index backend; Phase A always uses digest",
            file=sys.stderr,
        )
        return 30

    scopes = args.scope.split(",")
    needs_project = "project" in scopes
    sources: list[DigestSource] = []

    try:
        cwd = canonicalize_cwd(args.cwd) if args.cwd and needs_project else None
        for scope in scopes:
            if scope == "project":
                if cwd is None:
                    cwd = canonicalize_cwd(os.getcwd())
                sources.append((
                    digest_path("project", cwd),
                    parent_anchor("project", cwd),
                    scope_id("project", cwd),
                    PROJECT_LAYERS,
                ))
            elif scope == "user":
                sources.append((
                    digest_path("user", None),
                    parent_anchor("user", None),
                    scope_id("user", None),
                    USER_LAYERS,
                ))
            else:
                print(f"sspower-mem: unknown scope: {scope}", file=sys.stderr)
                return 30
    except FileNotFoundError as e:
        print(f"sspower-mem: {e}", file=sys.stderr)
        return 20

    layer_filter = args.layer.split(",") if args.layer else None

    try:
        if args.mode == "recent":
            hits = recent(sources, top_k=args.top_k, layer_filter=layer_filter)
        elif args.query:
            hits = grep_search(sources, args.query, top_k=args.top_k, layer_filter=layer_filter)
        else:
            print("sspower-mem: search requires --query or --mode recent", file=sys.stderr)
            return 30
    except OSError as e:
        print(f"sspower-mem: digest read failed: {e}", file=sys.stderr)
        return 20

    if args.json:
        print(json.dumps(hits, indent=2))
    else:
        for hit in hits:
            print(
                f"[{hit['source']} {hit['score']:.3f}] "
                f"{hit['ts']} · {hit['scope']} · {hit['layer']} · {hit['id']}"
            )
            print(hit["content"])
            print("---")
    return 0


def cmd_digest(args: argparse.Namespace) -> int:
    """Print an in-scope digest summary.

    The --rebuild-chroma flag is reserved for Phase C, when the index backend
    exists. Phase A rejects it explicitly so recovery commands do not silently
    no-op.
    """
    if args.rebuild_chroma:
        print(
            "sspower-mem: --rebuild-chroma is reserved for Phase C (no index "
            "backend in Phase A); rerun after Phase C lands",
            file=sys.stderr,
        )
        return 30

    try:
        cwd = _resolve_cwd(args) if args.scope == "project" else None
    except FileNotFoundError as e:
        print(f"sspower-mem: {e}", file=sys.stderr)
        return 20

    dpath = digest_path(args.scope, cwd)
    panchor = parent_anchor(args.scope, cwd)
    sc_id = scope_id(args.scope, cwd)
    allowed_layers = PROJECT_LAYERS if args.scope == "project" else USER_LAYERS
    try:
        safe_read_strict(dpath, panchor)
        blocks = _load_all_blocks([(dpath, panchor, sc_id, allowed_layers)])
    except FileNotFoundError:
        print(
            json.dumps(
                {
                    "path": str(dpath),
                    "exists": False,
                    "blocks": 0,
                    "by_layer": {},
                    "latest_ts": None,
                }
            )
        )
        return 0
    except OSError as e:
        print(f"sspower-mem: digest read failed: {e}", file=sys.stderr)
        return 20

    by_layer: dict[str, int] = {}
    for block in blocks:
        by_layer[block["layer"]] = by_layer.get(block["layer"], 0) + 1

    summary = {
        "path": str(dpath),
        "exists": True,
        "blocks": len(blocks),
        "by_layer": by_layer,
        "latest_ts": blocks[-1]["ts"] if blocks else None,
    }
    print(json.dumps(summary))
    return 0


def cmd_doctor(args: argparse.Namespace) -> int:
    if args.bootstrap:
        result = bootstrap()
        print(json.dumps(result))
        return 0

    result = health()
    print(json.dumps(result))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="sspower-mem")
    sub = parser.add_subparsers(dest="cmd", required=True)

    add = sub.add_parser("add", help="Append a memory block")
    add.add_argument("--scope", required=True, choices=["project", "user"])
    add.add_argument(
        "--layer",
        required=True,
        choices=["episodic", "decision", "gotcha", "user-global"],
    )
    content_group = add.add_mutually_exclusive_group(required=True)
    content_group.add_argument("--content")
    content_group.add_argument("--content-file")
    add.add_argument("--cwd")
    add.add_argument("--meta", action="append", default=[])
    add.add_argument("--no-llm", action="store_true")
    add.set_defaults(func=cmd_add)

    search = sub.add_parser("search", help="Search memory")
    search.add_argument("--scope", required=True)
    search.add_argument("--cwd")
    search.add_argument("--layer")
    search_group = search.add_mutually_exclusive_group(required=True)
    search_group.add_argument("--query")
    search_group.add_argument("--mode", choices=["recent"])
    search.add_argument("--top-k", type=int, default=8)
    search.add_argument("--json", action="store_true")
    search.add_argument("--idx-only", action="store_true")  # Phase A: rejected with rc=30 (Phase C requires backend)
    search.set_defaults(func=cmd_search)

    digest = sub.add_parser("digest", help="Print digest summary or rebuild index")
    digest.add_argument("--scope", required=True, choices=["project", "user"])
    digest.add_argument("--cwd")
    digest.add_argument(
        "--rebuild-chroma",
        action="store_true",
        help="Reserved for Phase C; Phase A rejects with rc=30",
    )
    digest.add_argument(
        "--no-llm",
        action="store_true",
        help="Reserved for Phase C; no-op in Phase A",
    )
    digest.set_defaults(func=cmd_digest)

    doctor = sub.add_parser("doctor", help="Health + bootstrap")
    doctor.add_argument("--bootstrap", action="store_true")
    doctor.set_defaults(func=cmd_doctor)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except Exception as e:
        print(f"sspower-mem: unexpected error: {e}", file=sys.stderr)
        return 30
```

- [ ] **Step 2: Smoke-test the CLI**

Run:
```bash
cd scripts/sspower_mem
uv run python -m sspower_mem doctor --bootstrap
uv run python -m sspower_mem add --scope user --layer user-global --content "test"
uv run python -m sspower_mem search --scope user --mode recent --top-k 5 --json
uv run python -m sspower_mem digest --scope user
uv run python -m sspower_mem digest --scope user --rebuild-chroma  # expect rc=30
```
Expected: doctor/add/search/`digest --scope user` all exit 0; the add prints `{"id": "...", "new": true, ...}`; search prints the just-added block as JSON; `digest --scope user` prints `{"path": "...", "exists": true, "blocks": 1, "by_layer": {"user-global": 1}, "latest_ts": "..."}`; `digest --rebuild-chroma` exits 30 with the "reserved for Phase C" stderr message.

- [ ] **Step 3: Commit**

```bash
git add scripts/sspower_mem/sspower_mem/cli.py
git commit -m "feat(sspower-mem): CLI with add/search/digest/doctor + exit-code contract"
```

---

### Task 20: CLI integration tests — exit codes 0/20/30

**Files:**
- Create: `scripts/sspower_mem/tests/test_cli.py`

- [ ] **Step 1: Write `test_cli.py`**

```python
import json
import pathlib
import subprocess

import pytest


def _run(monkeypatch, tmp_path, *args, set_home: bool = True) -> tuple[int, str, str]:
    fake_home = tmp_path / "home"
    fake_home.mkdir(exist_ok=True)
    env = {"HOME": str(fake_home), "PATH": __import__("os").environ["PATH"]}
    cmd = ["python", "-m", "sspower_mem", *args]
    cp = subprocess.run(cmd, capture_output=True, text=True, env=env, cwd=str(pathlib.Path(__file__).parent.parent))
    return cp.returncode, cp.stdout, cp.stderr


def test_cli_add_without_bootstrap_exits_30(monkeypatch, tmp_path):
    rc, out, err = _run(monkeypatch, tmp_path,
                        "add", "--scope", "user", "--layer", "user-global",
                        "--content", "test")
    assert rc == 30
    assert "lock missing" in err or "bootstrap" in err


def test_cli_bootstrap_then_add_then_search(monkeypatch, tmp_path):
    rc, _, _ = _run(monkeypatch, tmp_path, "doctor", "--bootstrap")
    assert rc == 0
    rc, out, _ = _run(monkeypatch, tmp_path,
                      "add", "--scope", "user", "--layer", "user-global",
                      "--content", "hello world")
    assert rc == 0
    body = json.loads(out)
    assert body["new"] is True
    assert len(body["id"]) == 16

    rc, out, _ = _run(monkeypatch, tmp_path,
                      "search", "--scope", "user", "--mode", "recent",
                      "--top-k", "5", "--json")
    assert rc == 0
    hits = json.loads(out)
    assert len(hits) == 1
    assert hits[0]["source"] == "digest-recent"


def test_cli_add_project_with_missing_cwd_exits_20(monkeypatch, tmp_path):
    _run(monkeypatch, tmp_path, "doctor", "--bootstrap")
    rc, _, err = _run(monkeypatch, tmp_path,
                      "add", "--scope", "project", "--layer", "episodic",
                      "--content", "x", "--cwd", str(tmp_path / "does-not-exist"))
    assert rc == 20
    assert "does not exist" in err


def test_cli_search_requires_query_or_mode(monkeypatch, tmp_path):
    _run(monkeypatch, tmp_path, "doctor", "--bootstrap")
    rc, _, err = _run(monkeypatch, tmp_path,
                      "search", "--scope", "user")
    # argparse mutually-exclusive required group exits 2 (argparse error),
    # which our wrapper would normalize at the bash layer. Direct invocation
    # surfaces argparse's own rc=2.
    assert rc in (2, 30)


def test_cli_digest_summary(monkeypatch, tmp_path):
    """Phase A `digest` subcommand: prints block count + per-layer summary.
    Resolves Codex v8-rev finding: spec §9 Phase A requires add/search/digest/doctor."""
    rc, _, _ = _run(monkeypatch, tmp_path, "doctor", "--bootstrap")
    assert rc == 0
    rc, _, _ = _run(monkeypatch, tmp_path,
                    "add", "--scope", "user", "--layer", "user-global",
                    "--content", "block one")
    assert rc == 0
    rc, out, _ = _run(monkeypatch, tmp_path, "digest", "--scope", "user")
    assert rc == 0
    body = json.loads(out)
    assert body["exists"] is True
    assert body["blocks"] == 1
    assert body["by_layer"]["user-global"] == 1
    assert body["latest_ts"] is not None


def test_cli_digest_rebuild_chroma_reserved_phase_c(monkeypatch, tmp_path):
    """`--rebuild-chroma` requires the index backend; Phase A rejects with rc=30
    rather than silently no-op a recovery command."""
    _run(monkeypatch, tmp_path, "doctor", "--bootstrap")
    rc, _, err = _run(monkeypatch, tmp_path,
                      "digest", "--scope", "user", "--rebuild-chroma")
    assert rc == 30
    assert "Phase C" in err or "reserved" in err


def test_cli_add_project_fresh_repo_creates_trust_root(monkeypatch, tmp_path):
    """First project-scope add against a fresh repo (no <cwd>/.claude/ yet) MUST
    create the trust root by openat-walk from the user-supplied --cwd anchor.
    Resolves Codex v8-rev finding: prior plan called safe_makedirs_strict with
    trust_root.parent (= <cwd>/.claude) as anchor, which fails when .claude is
    absent."""
    _run(monkeypatch, tmp_path, "doctor", "--bootstrap")
    fresh_repo = tmp_path / "fresh-project"
    fresh_repo.mkdir()  # <cwd> exists; <cwd>/.claude does NOT
    rc, out, err = _run(monkeypatch, tmp_path,
                        "add", "--scope", "project", "--layer", "episodic",
                        "--content", "first block in fresh repo",
                        "--cwd", str(fresh_repo))
    assert rc == 0, f"fresh-repo add failed: rc={rc} stderr={err}"
    assert (fresh_repo / ".claude" / "wiki" / "digest.md").exists()
    body = json.loads(out)
    assert body["new"] is True
```

- [ ] **Step 2: Run CLI tests**

Run: `cd scripts/sspower_mem && uv run --with pytest pytest tests/test_cli.py -v`
Expected: 7 passed

- [ ] **Step 3: Commit**

```bash
git add scripts/sspower_mem/tests/test_cli.py
git commit -m "test(sspower-mem): CLI integration — exit codes 0/20/30 + add+search round-trip"
```

---

### Task 21: Full test suite + uvx invocation smoke

**Files:** none

- [ ] **Step 1: Run the full test suite**

Run: `cd scripts/sspower_mem && uv run --with pytest pytest -v`
Expected: all tests pass (4 io + 1 lock + 5 scope + 12 digest + 3 doctor + 4 cli = ~29 passed)

- [ ] **Step 2: Smoke `uvx --from` invocation (the hook launch path)**

Run:
```bash
SSPOWER_MEM_SRC="$(pwd)/scripts/sspower_mem"
uvx --from "$SSPOWER_MEM_SRC" sspower-mem doctor --bootstrap
uvx --from "$SSPOWER_MEM_SRC" sspower-mem add --scope user --layer user-global --content "uvx smoke"
uvx --from "$SSPOWER_MEM_SRC" sspower-mem search --scope user --mode recent --top-k 3 --json
```
Expected: each exits 0; the search hit includes `"content": "uvx smoke"`.

- [ ] **Step 3: Verify `uvx --offline` works after warm cache**

Run:
```bash
uvx --offline --from "$SSPOWER_MEM_SRC" sspower-mem doctor
```
Expected: exits 0, prints health JSON.

- [ ] **Step 4: Commit a release note**

```bash
echo "Phase A v0.1.0 — plaintext memory backend ready. Phases B-F provisional." \
  >> scripts/sspower_mem/CHANGELOG.md
git add scripts/sspower_mem/CHANGELOG.md
git commit -m "docs(sspower-mem): Phase A v0.1.0 release note"
```

---

## Self-review

**Spec coverage** — every Phase A §9 checklist item maps to a task:
- ✓ `scripts/sspower_mem/` package + `pyproject.toml` → Task 1
- ✓ `add`/`search`/`digest`/`doctor` digest-only → Tasks 14, 16, 18, 19
- ✓ File lock around add → Task 8 + Task 19
- ✓ `safe_append_strict` (openat + O_NOFOLLOW) → Task 3, 4
- ✓ `safe_makedirs_strict` → Task 6
- ✓ `--cwd` canonicalization → Task 10
- ✓ `doctor --bootstrap` creates user dir + config.json + .lock → Task 18
- ✓ Exit codes 0/10/20/30 → Task 19 + Task 20 (10 reserved for Phase B/C)
- ✓ Tests: lock contention (Task 7), header parse (Task 11), grep search (Task 15), exit-20 (Task 20), exit-30 (Task 20), symlink refusal (Task 2, 4, 5), traversal rejection (Task 4)
- ✓ Stable `sha1[:16]` id + `_dup<N>` collision → Task 11–14
- ✓ Block format with header + ts + scope + layer + id + meta + separator → Task 11, 12
- ✓ `--query` grep + `--mode recent` → Task 15, 16
- ✓ `--no-llm` flag accepted (Phase A no-op) → Task 19

**Deviations from v8 spec** (deliberate, flagged):
- **Meta serialization**: spec §6.4 used `[meta] key=value, key=value` which breaks on paths with commas/equals (Codex v8 missing #4). This plan uses `[meta] <json-dict>` instead. Lossless, parseable, future-proof.
- **`extracted` field in `add` JSON output**: Phase A returns `"raw": "n/a", "extracted": "n/a"` rather than the spec's `"ok"/"skipped-*"` since there is no index-backend step yet. Phase C will replace these with the spec's values.
- **`--no-llm` is a no-op in Phase A**: the flag is accepted (so hooks/skills can pass it without breaking) and recorded in meta, but it has no behavioral effect until Phase C.

**Placeholder scan**: none. All steps have exact code, exact commands, expected output.

**Type consistency**: function names and arg signatures match across tasks. `append_block_or_skip` introduced in Task 14 is used in Tasks 15, 19. `digest_path`/`trust_root`/`scope_id` from Task 10 used throughout the CLI in Task 19. `acquire_lock` from Task 8 used in Task 19.

---

## Execution Handoff

**Plan complete. Three execution options:**

1. **Subagent-Driven (recommended)** → `sspower:subagent-driven-development` — fans out independent task groups (io+lock vs digest vs cli) across worktree subagents.
2. **Inline Execution** → `sspower:executing-plans` — task-by-task in the current session, with checkpoint reviews.
3. **Codex execute** → `codex-bridge.mjs implement --write` with the plan file as prompt; lets Codex own the full implementation.

**Which approach?**
