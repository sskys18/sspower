"""Scope resolution: cwd canonicalization, project hash, path helpers.

Per spec §5 (storage layout) and §6.4 (--cwd canonicalization).
"""
from __future__ import annotations

import hashlib
import pathlib


def canonicalize_cwd(cwd_arg: str) -> pathlib.Path:
    """Resolve symlinks and verify the cwd exists.

    Raises FileNotFoundError if the path does not exist.
    """
    p = pathlib.Path(cwd_arg)
    if not p.exists():
        raise FileNotFoundError(f"cwd does not exist: {cwd_arg}")
    return p.resolve()


def scope_id(scope: str, cwd: pathlib.Path | None) -> str:
    """Return the scope key used as the index backend's user_id and digest header field.

    project -> sha1(realpath(cwd))[:16]; user -> "user:global".
    """
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
        if cwd is None:
            raise ValueError("project scope requires cwd")
        return project_wiki_dir(cwd) / "digest.md"
    if scope == "user":
        return user_sspower_dir() / "digest.md"
    raise ValueError(f"unknown scope: {scope}")


def trust_root(scope: str, cwd: pathlib.Path | None) -> pathlib.Path:
    """Trust root for the scope's digest path."""
    if scope == "project":
        if cwd is None:
            raise ValueError("project scope requires cwd")
        return project_wiki_dir(cwd)
    if scope == "user":
        return user_sspower_dir()
    raise ValueError(f"unknown scope: {scope}")


def parent_anchor(scope: str, cwd: pathlib.Path | None) -> pathlib.Path:
    """Trusted pre-existing path that anchors openat walks for trust-root creation.

    Per spec §6.4: the only paths assumed pre-existing and trusted are $HOME and
    the user-supplied --cwd value. Callers pass the result to safe_makedirs_strict
    when they need to create the trust root, for example first project-scope add
    against a fresh repo where <cwd>/.claude/wiki/ does not yet exist.
    """
    if scope == "project":
        if cwd is None:
            raise ValueError("project scope requires cwd")
        return cwd
    if scope == "user":
        return pathlib.Path.home()
    raise ValueError(f"unknown scope: {scope}")
