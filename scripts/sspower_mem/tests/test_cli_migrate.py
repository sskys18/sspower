"""Integration tests for `sspower-mem migrate` via subprocess."""
from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys


_PACKAGE_ROOT = pathlib.Path(__file__).resolve().parent.parent
_FAKE_BRIDGE = _PACKAGE_ROOT / "tests" / "fixtures" / "fake_bridge.sh"
_EMPTY_FACTS_ENVELOPE = (
    '{"id":"x","object":"chat.completion","choices":[{"index":0,'
    '"message":{"role":"assistant","content":"{\\"facts\\":[]}"}}],'
    '"usage":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0}}'
)


def _run(monkeypatch, tmp_path, *args) -> tuple[int, str, str]:
    fake_home = tmp_path / "home"
    fake_home.mkdir(exist_ok=True)
    monkeypatch.setenv("HOME", str(fake_home))
    env = os.environ.copy()
    env["HOME"] = str(fake_home)
    env.setdefault("SSPOWER_BRIDGE_PATH", str(_FAKE_BRIDGE))
    env.setdefault("SSPOWER_FAKE_BRIDGE_RESPONSE", _EMPTY_FACTS_ENVELOPE)
    env.setdefault("SSPOWER_FAKE_BRIDGE_EXIT", "0")
    cmd = [sys.executable, "-m", "sspower_mem", *args]
    cp = subprocess.run(
        cmd, capture_output=True, text=True, env=env, cwd=str(_PACKAGE_ROOT),
    )
    return cp.returncode, cp.stdout, cp.stderr


def _seed_repo(tmp_path: pathlib.Path) -> pathlib.Path:
    cwd = tmp_path / "repo"
    sessions = cwd / ".claude" / "wiki" / "sessions"
    sessions.mkdir(parents=True)
    (sessions / "260512_21-22.md").write_text(
        "# 260512 session\n\nFiles touched: handoff.md\n", encoding="utf-8"
    )
    (cwd / ".claude" / "wiki" / "decisions.md").write_text(
        "# Decisions\n## D1\nFirst\n## D2\nSecond\n", encoding="utf-8"
    )
    (cwd / ".claude" / "wiki" / "gotchas.md").write_text(
        "# Gotchas\nStub only.\n", encoding="utf-8"
    )
    return cwd


def test_cli_migrate_dry_run_no_bootstrap_required(monkeypatch, tmp_path):
    """Dry-run does NOT touch lock or digest — works without doctor --bootstrap."""
    cwd = _seed_repo(tmp_path)
    rc, out, err = _run(
        monkeypatch, tmp_path, "migrate", "--cwd", str(cwd), "--dry-run"
    )
    assert rc == 0, f"stderr={err!r}"
    payload = json.loads(out)
    assert payload["totals"]["project_episodic"] == 1
    assert payload["totals"]["project_decision"] == 2
    assert payload["totals"]["project_gotcha"] == 0
    assert payload["totals"]["user_global"] == 0
    # No digest, no sspower dir.
    assert not (cwd / ".claude" / "wiki" / "digest.md").exists()
    sspower_dir = tmp_path / "home" / ".claude" / "sspower"
    # bootstrap NOT required for dry-run; sspower dir should not exist.
    assert not sspower_dir.exists()


def test_cli_migrate_live_first_run_writes_blocks(monkeypatch, tmp_path):
    cwd = _seed_repo(tmp_path)
    # Bootstrap (creates lock + chroma + history.db).
    rc, _, err = _run(monkeypatch, tmp_path, "doctor", "--bootstrap")
    assert rc == 0, f"bootstrap stderr={err!r}"

    # First migrate.
    rc, out, err = _run(monkeypatch, tmp_path, "migrate", "--cwd", str(cwd))
    assert rc in (0, 10), f"rc={rc} stderr={err!r}"
    # Final JSON is the run_migrate summary.
    lines = [ln for ln in out.splitlines() if ln.strip().startswith("{")]
    summary = json.loads(lines[-1])
    assert summary["totals"]["project_episodic"] == 1
    assert summary["totals"]["project_decision"] == 2
    # Every result was new on first run.
    assert all(r["new"] for r in summary["results"])

    # Project digest now exists with 3 blocks (1 episodic + 2 decision).
    pdigest = cwd / ".claude" / "wiki" / "digest.md"
    assert pdigest.exists()
    text = pdigest.read_text(encoding="utf-8")
    assert text.count("\n## ") >= 3  # at least 3 block headers


def test_cli_migrate_idempotent_second_run_no_writes(monkeypatch, tmp_path):
    cwd = _seed_repo(tmp_path)
    rc, _, _ = _run(monkeypatch, tmp_path, "doctor", "--bootstrap")
    assert rc == 0

    # First migrate.
    rc1, out1, _ = _run(monkeypatch, tmp_path, "migrate", "--cwd", str(cwd))
    assert rc1 in (0, 10)
    pdigest = cwd / ".claude" / "wiki" / "digest.md"
    bytes1 = pdigest.read_bytes()

    # Second migrate — should yield identical digest (every block was_new=False).
    rc2, out2, _ = _run(monkeypatch, tmp_path, "migrate", "--cwd", str(cwd))
    assert rc2 in (0, 10)
    bytes2 = pdigest.read_bytes()
    assert bytes1 == bytes2, "digest.md mutated on second migrate — not idempotent"

    lines = [ln for ln in out2.splitlines() if ln.strip().startswith("{")]
    summary2 = json.loads(lines[-1])
    assert all(not r["new"] for r in summary2["results"]), (
        "Some blocks reported new=True on second run — dedup broken"
    )
