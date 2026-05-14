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
