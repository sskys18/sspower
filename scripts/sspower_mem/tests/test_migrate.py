"""Phase D migrate tests."""
from __future__ import annotations

import hashlib
import json
import pathlib

import pytest


def test_project_scope_hash_matches_spec(tmp_path):
    """scope_id('project', realpath(cwd)) must = f'project:{sha1[:16]}'."""
    from sspower_mem.scope import canonicalize_cwd, scope_id

    real = canonicalize_cwd(str(tmp_path))
    sid = scope_id("project", real)
    expected_hash = hashlib.sha1(str(real).encode()).hexdigest()[:16]
    assert sid == f"project:{expected_hash}"


def test_user_scope_is_global():
    from sspower_mem.scope import scope_id

    assert scope_id("user", None) == "user:global"
