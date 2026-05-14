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
