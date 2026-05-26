#!/usr/bin/env python3
"""Smoke tests for graph-append-dirty.py and graph-with-lock.py."""
import os
import pathlib
import subprocess
import tempfile
import time


PLUGIN_ROOT = pathlib.Path(__file__).resolve().parents[2]
ENV = {**os.environ, "CLAUDE_PLUGIN_ROOT": str(PLUGIN_ROOT)}


def test_append_writes_jsonl():
    with tempfile.TemporaryDirectory() as cwd:
        graph_dir = pathlib.Path(cwd) / ".claude" / "graph"
        subprocess.run(
            [
                "python3",
                str(PLUGIN_ROOT / "scripts" / "graph-append-dirty.py"),
                "--graph-dir",
                str(graph_dir),
                "--op",
                "upsert",
                "--path",
                "/abs/path/foo.ts",
            ],
            env=ENV,
            check=True,
            capture_output=True,
            text=True,
        )
        dirty = (graph_dir / "dirty").read_text()
        assert dirty.strip() == '{"op": "upsert", "path": "/abs/path/foo.ts"}', dirty
        print("OK append_writes_jsonl")


def test_with_lock_runs_child():
    with tempfile.TemporaryDirectory() as cwd:
        graph_dir = pathlib.Path(cwd) / ".claude" / "graph"
        graph_dir.mkdir(parents=True)
        marker = pathlib.Path(cwd) / "ran.txt"
        subprocess.run(
            [
                "python3",
                str(PLUGIN_ROOT / "scripts" / "graph-with-lock.py"),
                "--graph-dir",
                str(graph_dir),
                "--",
                "sh",
                "-c",
                f"echo locked > {marker}",
            ],
            env=ENV,
            check=True,
            capture_output=True,
            text=True,
        )
        assert marker.read_text().strip() == "locked"
        print("OK with_lock_runs_child")


def test_with_lock_blocks_concurrent():
    """Second invocation must wait for first to release."""
    with tempfile.TemporaryDirectory() as cwd:
        graph_dir = pathlib.Path(cwd) / ".claude" / "graph"
        graph_dir.mkdir(parents=True)
        marker = pathlib.Path(cwd) / "log.txt"
        p1 = subprocess.Popen(
            [
                "python3",
                str(PLUGIN_ROOT / "scripts" / "graph-with-lock.py"),
                "--graph-dir",
                str(graph_dir),
                "--",
                "sh",
                "-c",
                f"sleep 1 && echo A >> {marker}",
            ],
            env=ENV,
        )
        time.sleep(0.2)
        p2 = subprocess.Popen(
            [
                "python3",
                str(PLUGIN_ROOT / "scripts" / "graph-with-lock.py"),
                "--graph-dir",
                str(graph_dir),
                "--",
                "sh",
                "-c",
                f"echo B >> {marker}",
            ],
            env=ENV,
        )
        p1.wait()
        p2.wait()
        log = marker.read_text().split()
        assert log == ["A", "B"], f"got {log}"
        print("OK with_lock_blocks_concurrent")


if __name__ == "__main__":
    test_append_writes_jsonl()
    test_with_lock_runs_child()
    test_with_lock_blocks_concurrent()
    print("ALL PASS")
