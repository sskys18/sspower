import multiprocessing as mp
import os
import pathlib
import time

import pytest

from sspower_mem.lock import acquire_lock


def _hold_lock(lock_path: str, hold_seconds: float, started_event, finished_event):
    with acquire_lock(pathlib.Path(lock_path)):
        started_event.set()
        time.sleep(hold_seconds)
        finished_event.set()


def test_acquire_lock_blocks_concurrent_writer(tmp_path):
    lock_path = tmp_path / ".lock"
    started = mp.Event()
    finished = mp.Event()
    p = mp.Process(target=_hold_lock, args=(str(lock_path), 0.5, started, finished))
    p.start()
    assert started.wait(timeout=2.0), "holder process did not start"

    t0 = time.monotonic()
    with acquire_lock(lock_path):
        elapsed = time.monotonic() - t0
        # We waited until the other process released the lock.
        assert finished.is_set(), "second acquire returned before holder finished"
        assert elapsed >= 0.4, f"second acquire returned too fast ({elapsed:.2f}s)"
    p.join(timeout=2.0)
    assert p.exitcode == 0


def test_acquire_lock_refuses_symlinked_final_file(tmp_path):
    lock_dir = tmp_path / "idx"
    lock_dir.mkdir()
    target = tmp_path / "outside.lock"
    target.write_text("", encoding="utf-8")
    lock_path = lock_dir / ".lock"
    os.symlink(target, lock_path)

    with pytest.raises(OSError):
        with acquire_lock(lock_path, parent_anchor=tmp_path):
            pass

    assert target.read_text(encoding="utf-8") == ""


def test_acquire_lock_refuses_symlinked_parent(tmp_path):
    target_dir = tmp_path / "target"
    target_dir.mkdir()
    lock_dir = tmp_path / "idx"
    os.symlink(target_dir, lock_dir)

    with pytest.raises(OSError):
        with acquire_lock(lock_dir / ".lock", parent_anchor=tmp_path):
            pass

    assert not (target_dir / ".lock").exists()


def test_acquire_lock_refuses_hardlink_to_outside_file(tmp_path):
    """A lock file hard-linked to an outside file (st_nlink > 1) is rejected.

    Also asserts the outside file's mode is unchanged: the lock open does
    os.fchmod(fd, 0o600) AFTER _assert_regular_private_file, so a wrong
    ordering could chmod the hard-linked outside file before raising.
    Capturing the mode before/after locks in rejection-BEFORE-chmod.
    """
    import os
    import stat

    lock_dir = tmp_path / "idx"
    lock_dir.mkdir()
    outside = tmp_path / "outside.lock"
    outside.write_text("attacker-controlled", encoding="utf-8")
    lock_path = lock_dir / ".lock"
    os.link(outside, lock_path)
    mode_before = stat.S_IMODE(outside.stat().st_mode)

    with pytest.raises(OSError):
        with acquire_lock(lock_path, parent_anchor=tmp_path):
            pass

    assert outside.read_text(encoding="utf-8") == "attacker-controlled"
    assert stat.S_IMODE(outside.stat().st_mode) == mode_before, (
        "outside file mode changed - fchmod ran before the hardlink rejection"
    )


def test_acquire_lock_file_created_at_0600(tmp_path):
    """A freshly created lock file ends up at mode 0600."""
    import stat

    lock_dir = tmp_path / "idx"
    lock_dir.mkdir()
    lock_path = lock_dir / ".lock"

    with acquire_lock(lock_path, parent_anchor=tmp_path):
        pass

    assert lock_path.exists()
    assert stat.S_IMODE(lock_path.stat().st_mode) == 0o600
