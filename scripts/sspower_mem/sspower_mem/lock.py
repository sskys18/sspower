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


@contextlib.contextmanager
def acquire_lock(lock_path: pathlib.Path) -> Iterator[int]:
    """Exclusive blocking flock on lock_path.

    Creates the lock file if missing, yields its file descriptor, and releases
    the lock on exit including exceptional exits.
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
