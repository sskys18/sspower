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
