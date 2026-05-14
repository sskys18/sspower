"""Phase A doctor: user-scope bootstrap and health checks."""
from __future__ import annotations

import json
import os
import pathlib

from sspower_mem.io import safe_append_strict, safe_makedirs_strict, safe_write_strict
from sspower_mem.scope import user_sspower_dir


def bootstrap() -> dict:
    """Create ~/.claude/sspower/idx/{.lock,config.json}. Idempotent."""
    home = pathlib.Path.home()
    base = user_sspower_dir()
    idx = base / "idx"
    safe_makedirs_strict(idx, home)

    lock = idx / ".lock"
    safe_append_strict(lock, "", base, home)

    config = idx / "config.json"
    safe_write_strict(
        config,
        json.dumps(
            {
                "version": "0.1.0",
                "phase": "A",
                "index": {
                    "enabled": False,
                    "note": "Phase A: digest-only, no index backend",
                },
            },
            indent=2,
        ),
        base,
        home,
    )

    return {"status": "ok", "base": str(base)}


def health() -> dict:
    """Return lightweight booleans for doctor-managed user-scope files."""
    base = user_sspower_dir()
    idx = base / "idx"
    lock = idx / ".lock"
    digest = base / "digest.md"

    return {
        "lock_writable": lock.exists() and _writable(lock),
        "digest_writable": _writable(digest) if digest.exists() else _writable(base),
        "phase": "A",
    }


def _writable(path: pathlib.Path) -> bool:
    try:
        return os.access(path, os.W_OK)
    except OSError:
        return False
