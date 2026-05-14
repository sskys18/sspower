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
