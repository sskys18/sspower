import os
import pathlib
import pytest
import stat

from sspower_mem.io import safe_append_strict
from sspower_mem.io import safe_makedirs_strict
from sspower_mem.io import safe_read_strict


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


def test_safe_append_strict_writes_content(trust_root):
    path = trust_root / "digest.md"
    safe_append_strict(path, "hello\n", trust_root)
    safe_append_strict(path, "world\n", trust_root)
    assert path.read_text() == "hello\nworld\n"


def test_safe_append_strict_creates_file_at_0600(trust_root):
    path = trust_root / "digest.md"
    safe_append_strict(path, "secret\n", trust_root)

    assert stat.S_IMODE(path.stat().st_mode) == 0o600


def test_safe_read_strict_refuses_symlinked_final_file(trust_root, tmp_path):
    path = trust_root / "digest.md"
    safe_append_strict(path, "trusted\n", trust_root)
    path.unlink()
    outside = tmp_path / "outside.md"
    outside.write_text("attacker-controlled\n")
    os.symlink(outside, path)

    with pytest.raises(OSError):
        safe_read_strict(path, trust_root)


def test_safe_read_strict_round_trip(trust_root):
    path = trust_root / "digest.md"
    safe_append_strict(path, "hello\n", trust_root)
    safe_append_strict(path, "world\n", trust_root)

    assert safe_read_strict(path, trust_root) == "hello\nworld\n"


def test_safe_append_strict_rejects_traversal(trust_root):
    bad = pathlib.Path(str(trust_root) + "/sub/../escape.md")
    # path is lexically under trust_root, but contains ".."
    with pytest.raises(OSError, match="traversal"):
        safe_append_strict(bad, "x\n", trust_root)


def test_safe_append_strict_rejects_outside_trust_root(trust_root, tmp_path):
    outside = tmp_path / "elsewhere" / "digest.md"
    with pytest.raises(OSError, match="not under trust_root"):
        safe_append_strict(outside, "x\n", trust_root)


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
