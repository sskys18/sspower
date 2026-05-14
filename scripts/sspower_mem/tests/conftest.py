import pathlib
import pytest


@pytest.fixture
def parent_anchor(tmp_path: pathlib.Path) -> pathlib.Path:
    """Trusted pre-existing parent for test trust roots."""
    return tmp_path


@pytest.fixture
def trust_root(parent_anchor: pathlib.Path) -> pathlib.Path:
    """A clean, non-symlink trust root dir at 0700."""
    root = parent_anchor / "trust"
    root.mkdir(mode=0o700)
    return root
