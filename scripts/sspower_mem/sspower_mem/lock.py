"""POSIX fcntl-based exclusive file lock context manager.

Per spec Section 6.1: one critical section per add invocation, lock file at
~/.claude/sspower/idx/.lock.
"""
from __future__ import annotations

import contextlib
import fcntl
import os
import pathlib
from collections.abc import Iterator

from sspower_mem.io import _assert_regular_private_file, safe_makedirs_strict


def _checked_relative(path: pathlib.Path, parent_anchor: pathlib.Path) -> pathlib.PurePath:
    try:
        rel = path.relative_to(parent_anchor)
    except ValueError as e:
        raise OSError(f"lock path {path} not under parent_anchor {parent_anchor}") from e

    if not rel.parts:
        raise OSError(f"lock path {path} must name a file below parent_anchor {parent_anchor}")

    for part in rel.parts:
        if part in ("", ".", ".."):
            raise OSError(f"lock path {path} contains traversal component {part!r}")

    return rel


def _open_lock_file(lock_path: pathlib.Path, parent_anchor: pathlib.Path) -> int:
    rel = _checked_relative(lock_path, parent_anchor)
    safe_makedirs_strict(lock_path.parent, parent_anchor)

    flags_dir = os.O_RDONLY | os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags_dir |= os.O_NOFOLLOW

    cur_fd = os.open(parent_anchor, flags_dir)
    try:
        for part in rel.parts[:-1]:
            next_fd = os.open(part, flags_dir, dir_fd=cur_fd)
            os.close(cur_fd)
            cur_fd = next_fd

        file_flags = os.O_RDWR | os.O_CREAT
        if hasattr(os, "O_NONBLOCK"):
            file_flags |= os.O_NONBLOCK
        if hasattr(os, "O_NOFOLLOW"):
            file_flags |= os.O_NOFOLLOW
        file_fd = os.open(rel.parts[-1], file_flags, mode=0o600, dir_fd=cur_fd)
        try:
            _assert_regular_private_file(file_fd, lock_path)
            os.fchmod(file_fd, 0o600)
            return file_fd
        except Exception:
            os.close(file_fd)
            raise
    finally:
        os.close(cur_fd)


@contextlib.contextmanager
def acquire_lock(lock_path: pathlib.Path, parent_anchor: pathlib.Path | None = None) -> Iterator[int]:
    """Exclusive blocking flock on lock_path.

    Creates the lock file if missing, yields its file descriptor, and releases
    the lock on exit including exceptional exits.
    """
    if parent_anchor is None:
        parent_anchor = lock_path.parent.parent

    fd = _open_lock_file(lock_path, parent_anchor)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        try:
            yield fd
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)
