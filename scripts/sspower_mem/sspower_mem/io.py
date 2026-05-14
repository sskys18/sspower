"""Symlink-safe, TOCTOU-closed write primitives for digest.md.

Per spec §6.4: openat-walk + O_NOFOLLOW on every component below trust_root.
"""
from __future__ import annotations

import os
import pathlib
import stat


def _open_dir(path_or_fd, flags_dir: int, *, dir_fd: int | None = None) -> int:
    return os.open(path_or_fd, flags_dir, dir_fd=dir_fd) if dir_fd is not None else os.open(path_or_fd, flags_dir)


def _assert_regular_private_file(fd: int, path: pathlib.Path) -> None:
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode):
        raise OSError(f"path {path} is not a regular file")
    if st.st_nlink != 1:
        raise OSError(f"path {path} has multiple hard links")


def _checked_relative(
    path: pathlib.Path,
    root: pathlib.Path,
    root_name: str,
    *,
    require_child: bool,
) -> pathlib.PurePath:
    try:
        rel = path.relative_to(root)
    except ValueError as e:
        raise OSError(f"path {path} not under {root_name} {root}") from e

    if require_child and not rel.parts:
        raise OSError(f"path {path} must name a file below {root_name} {root}")

    for part in rel.parts:
        if part in ("", ".", ".."):
            raise OSError(f"path {path} contains traversal component {part!r}")

    return rel


def _write_strict(
    path: pathlib.Path,
    content: str,
    trust_root: pathlib.Path,
    *,
    file_write_flag: int,
    helper_name: str,
    parent_anchor: pathlib.Path | None = None,
) -> None:
    _checked_relative(path, trust_root, "trust_root", require_child=True)
    open_root = trust_root
    if parent_anchor is not None:
        _checked_relative(trust_root, parent_anchor, "parent_anchor", require_child=False)
        open_root = parent_anchor
    rel = _checked_relative(path, open_root, "open_root", require_child=True)

    flags_dir = os.O_RDONLY | os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags_dir |= os.O_NOFOLLOW

    cur_fd = os.open(open_root, flags_dir)
    try:
        # Walk intermediate dirs (all parts except the last).
        for part in rel.parts[:-1]:
            next_fd = os.open(part, flags_dir, dir_fd=cur_fd)
            os.close(cur_fd)
            cur_fd = next_fd

        # Open final file relative to last dir fd, O_NOFOLLOW. For truncating
        # writes, defer ftruncate until after fstat has rejected hard links.
        file_flags = os.O_WRONLY | os.O_CREAT
        if file_write_flag == os.O_APPEND:
            file_flags |= os.O_APPEND
        if hasattr(os, "O_NONBLOCK"):
            file_flags |= os.O_NONBLOCK
        if hasattr(os, "O_NOFOLLOW"):
            file_flags |= os.O_NOFOLLOW
        file_fd = os.open(rel.parts[-1], file_flags, mode=0o600, dir_fd=cur_fd)
        try:
            _assert_regular_private_file(file_fd, path)
            os.fchmod(file_fd, 0o600)
            if file_write_flag == os.O_TRUNC:
                os.ftruncate(file_fd, 0)
            data = content.encode("utf-8")
            written = 0
            while written < len(data):
                n = os.write(file_fd, data[written:])
                if n <= 0:
                    raise OSError(f"{helper_name}: os.write returned 0")
                written += n
        finally:
            os.close(file_fd)
    finally:
        os.close(cur_fd)


def safe_append_strict(
    path: pathlib.Path,
    content: str,
    trust_root: pathlib.Path,
    parent_anchor: pathlib.Path | None = None,
) -> None:
    """Append `content` to `path`, refusing if any path component AT OR BELOW
    `trust_root` is a symlink. When `parent_anchor` is supplied, the openat walk
    starts there after confirming `trust_root` is below it, protecting trust-root
    creation paths such as $HOME/.claude/sspower. TOCTOU-closed via relative
    opens with O_NOFOLLOW. Loops on partial writes."""
    _write_strict(
        path,
        content,
        trust_root,
        file_write_flag=os.O_APPEND,
        helper_name="safe_append_strict",
        parent_anchor=parent_anchor,
    )


def safe_write_strict(
    path: pathlib.Path,
    content: str,
    trust_root: pathlib.Path,
    parent_anchor: pathlib.Path | None = None,
) -> None:
    """Create or replace `path` with `content`, using the same symlink-refusing
    openat walk as `safe_append_strict`, but with O_TRUNC instead of O_APPEND."""
    _write_strict(
        path,
        content,
        trust_root,
        file_write_flag=os.O_TRUNC,
        helper_name="safe_write_strict",
        parent_anchor=parent_anchor,
    )


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


def safe_read_strict(path: pathlib.Path, trust_root: pathlib.Path) -> str:
    """Read `path`, refusing if any path component AT OR BELOW `trust_root`
    is a symlink. TOCTOU-closed via openat-style relative opens with
    O_NOFOLLOW."""
    try:
        rel = path.relative_to(trust_root)
    except ValueError as e:
        raise OSError(f"path {path} not under trust_root {trust_root}") from e
    if not rel.parts:
        raise OSError(f"path {path} must name a file below trust_root")
    for part in rel.parts:
        if part in ("", ".", ".."):
            raise OSError(f"path {path} contains traversal component {part!r}")

    flags_dir = os.O_RDONLY | os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags_dir |= os.O_NOFOLLOW

    cur_fd = os.open(trust_root, flags_dir)
    try:
        for part in rel.parts[:-1]:
            next_fd = os.open(part, flags_dir, dir_fd=cur_fd)
            os.close(cur_fd)
            cur_fd = next_fd

        file_flags = os.O_RDONLY
        if hasattr(os, "O_NONBLOCK"):
            file_flags |= os.O_NONBLOCK
        if hasattr(os, "O_NOFOLLOW"):
            file_flags |= os.O_NOFOLLOW
        file_fd = os.open(rel.parts[-1], file_flags, dir_fd=cur_fd)
        try:
            _assert_regular_private_file(file_fd, path)
            chunks: list[bytes] = []
            while True:
                chunk = os.read(file_fd, 1024 * 1024)
                if not chunk:
                    break
                chunks.append(chunk)
            return b"".join(chunks).decode("utf-8")
        finally:
            os.close(file_fd)
    finally:
        os.close(cur_fd)
