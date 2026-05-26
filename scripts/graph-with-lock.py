#!/usr/bin/env python3
# pyright: reportMissingImports=false
"""Hold <graph-dir>/.lock for the duration of a child process."""
import argparse
import os
import pathlib
import subprocess
import sys


PLUGIN_ROOT = pathlib.Path(os.environ["CLAUDE_PLUGIN_ROOT"]).resolve()
sys.path.insert(0, str(PLUGIN_ROOT / "scripts" / "sspower_mem"))
from sspower_mem.io import safe_makedirs_strict  # noqa: E402
from sspower_mem.lock import acquire_lock  # noqa: E402


ap = argparse.ArgumentParser()
ap.add_argument("--graph-dir", required=True)
ap.add_argument("cmd", nargs=argparse.REMAINDER)
args = ap.parse_args()

graph_dir = pathlib.Path(args.graph_dir).resolve()
trust_root = graph_dir.parent.parent
safe_makedirs_strict(graph_dir, trust_root, mode=0o700)
lock_path = graph_dir / ".lock"

cmd = args.cmd[1:] if args.cmd and args.cmd[0] == "--" else args.cmd
if not cmd:
    print("error: no command after --", file=sys.stderr)
    sys.exit(2)

with acquire_lock(lock_path, parent_anchor=trust_root):
    completed = subprocess.run(cmd, env=os.environ)
    sys.exit(completed.returncode)
