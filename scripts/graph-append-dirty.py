#!/usr/bin/env python3
# pyright: reportMissingImports=false
"""Append a single JSONL record to <graph-dir>/dirty under exclusive lock."""
import argparse
import json
import os
import pathlib
import sys


PLUGIN_ROOT = pathlib.Path(os.environ["CLAUDE_PLUGIN_ROOT"]).resolve()
sys.path.insert(0, str(PLUGIN_ROOT / "scripts" / "sspower_mem"))
from sspower_mem.io import safe_append_strict, safe_makedirs_strict  # noqa: E402
from sspower_mem.lock import acquire_lock  # noqa: E402


ap = argparse.ArgumentParser()
ap.add_argument("--graph-dir", required=True)
ap.add_argument("--op", required=True, choices=["upsert", "delete"])
ap.add_argument("--path", required=True)
args = ap.parse_args()

graph_dir = pathlib.Path(args.graph_dir).resolve()
trust_root = graph_dir.parent.parent
safe_makedirs_strict(graph_dir, trust_root, mode=0o700)

lock_path = graph_dir / ".lock"
dirty_path = graph_dir / "dirty"
record = json.dumps({"op": args.op, "path": args.path}) + "\n"

with acquire_lock(lock_path, parent_anchor=trust_root):
    safe_append_strict(dirty_path, record, trust_root=trust_root)
