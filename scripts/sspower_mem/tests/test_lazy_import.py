"""Lazy-import policy: cli.py module load must NOT pull mem0/chromadb/model2vec.

Phase A regression guard. If a future edit imports sspower_mem.mem at cli.py
module top-level, the digest write would be bypassed when deps are broken.
"""
from __future__ import annotations

import subprocess
import sys
import textwrap


def test_cli_module_load_does_not_import_mem0():
    code = textwrap.dedent(
        """
        import sys
        import sspower_mem.cli  # noqa: F401
        bad = [
            m for m in sys.modules
            if m == "sspower_mem.mem"
            or m.startswith(("mem0", "chromadb", "model2vec"))
        ]
        print(",".join(sorted(bad)))
        """
    )
    out = subprocess.check_output([sys.executable, "-c", code], text=True).strip()
    assert out == "", f"cli.py module load leaked imports: {out}"
