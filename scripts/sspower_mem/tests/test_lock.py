import multiprocessing as mp
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
