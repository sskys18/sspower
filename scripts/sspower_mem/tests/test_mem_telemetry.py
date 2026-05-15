"""Phase C telemetry shield: env var + defensive module patch.

The shield runs at `import sspower_mem.mem`. Asserts:
  1. MEM0_TELEMETRY=False set in environment.
  2. mem0.memory.telemetry.capture_event is a no-op.
  3. mem0.memory.telemetry.MEM0_TELEMETRY is False at the patched module.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import textwrap


def test_telemetry_env_and_patch_in_fresh_subprocess():
    """Clean Python subprocess that imports sspower_mem.mem first, then mem0."""
    script = textwrap.dedent(
        """
        import os, json
        os.environ.pop("MEM0_TELEMETRY", None)
        import sspower_mem.mem  # noqa: F401  — shield runs here
        import mem0.memory.telemetry as t
        result = {
            "env": os.environ.get("MEM0_TELEMETRY"),
            "patched_flag": t.MEM0_TELEMETRY,
            "capture_event_noop": t.capture_event("x") is None,
            "capture_client_event_noop": t.capture_client_event("x") is None,
            "sample_rate_env": os.environ.get("MEM0_TELEMETRY_SAMPLE_RATE"),
        }
        print(json.dumps(result))
        """
    )
    out = subprocess.check_output([sys.executable, "-c", script], text=True)
    result = json.loads(out.strip().splitlines()[-1])
    assert result["env"] == "False"
    assert result["sample_rate_env"] == "0"
    assert result["patched_flag"] is False
    assert result["capture_event_noop"] is True
    assert result["capture_client_event_noop"] is True


def test_mem0_import_does_not_leak_outside_MEM0_DIR(tmp_path):
    """Phase 0 open issue #5: mem0 setup must not write outside MEM0_DIR."""
    mem0_dir = tmp_path / "mem0_probe"
    mem0_dir.mkdir()
    home = tmp_path / "fake_home"
    home.mkdir()
    env = os.environ.copy()
    env["MEM0_DIR"] = str(mem0_dir)
    env["HOME"] = str(home)
    env["MEM0_TELEMETRY"] = "False"
    subprocess.check_call(
        [sys.executable, "-c", "import sspower_mem.mem; import mem0"],
        env=env,
    )
    leaked = list((home / ".mem0").rglob("*")) if (home / ".mem0").exists() else []
    assert leaked == [], f"mem0 leaked into HOME despite MEM0_DIR override: {leaked}"
