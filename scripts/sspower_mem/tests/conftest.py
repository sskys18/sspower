import os
import pathlib
import pytest


@pytest.fixture
def trust_root(tmp_path: pathlib.Path) -> pathlib.Path:
    """A clean, non-symlink trust root dir at 0700."""
    root = tmp_path / "trust"
    root.mkdir(mode=0o700)
    return root
