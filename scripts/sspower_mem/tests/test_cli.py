import json
import os
import pathlib
import subprocess
import sys


_PACKAGE_ROOT = pathlib.Path(__file__).resolve().parent.parent


def _run(monkeypatch, tmp_path, *args) -> tuple[int, str, str]:
    fake_home = tmp_path / "home"
    fake_home.mkdir(exist_ok=True)
    monkeypatch.setenv("HOME", str(fake_home))
    env = os.environ.copy()
    cmd = [sys.executable, "-m", "sspower_mem", *args]
    cp = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        env=env,
        cwd=str(_PACKAGE_ROOT),
    )
    return cp.returncode, cp.stdout, cp.stderr


def test_cli_add_without_bootstrap_exits_30(monkeypatch, tmp_path):
    rc, out, err = _run(
        monkeypatch,
        tmp_path,
        "add",
        "--scope",
        "user",
        "--layer",
        "user-global",
        "--content",
        "test",
    )
    assert rc == 30
    assert out == ""
    assert "lock missing" in err or "bootstrap" in err


def test_cli_bootstrap_then_add_then_search(monkeypatch, tmp_path):
    rc, _, _ = _run(monkeypatch, tmp_path, "doctor", "--bootstrap")
    assert rc == 0

    rc, out, _ = _run(
        monkeypatch,
        tmp_path,
        "add",
        "--scope",
        "user",
        "--layer",
        "user-global",
        "--content",
        "hello world",
    )
    assert rc == 0
    body = json.loads(out)
    assert body["new"] is True
    assert len(body["id"]) == 16

    rc, out, _ = _run(
        monkeypatch,
        tmp_path,
        "search",
        "--scope",
        "user",
        "--mode",
        "recent",
        "--top-k",
        "5",
        "--json",
    )
    assert rc == 0
    hits = json.loads(out)
    assert len(hits) == 1
    assert hits[0]["source"] == "digest-recent"


def test_cli_add_project_with_missing_cwd_exits_20(monkeypatch, tmp_path):
    _run(monkeypatch, tmp_path, "doctor", "--bootstrap")
    rc, _, err = _run(
        monkeypatch,
        tmp_path,
        "add",
        "--scope",
        "project",
        "--layer",
        "episodic",
        "--content",
        "x",
        "--cwd",
        str(tmp_path / "does-not-exist"),
    )
    assert rc == 20
    assert "does not exist" in err


def test_cli_search_requires_query_or_mode(monkeypatch, tmp_path):
    _run(monkeypatch, tmp_path, "doctor", "--bootstrap")
    rc, _, err = _run(monkeypatch, tmp_path, "search", "--scope", "user")
    assert rc in (2, 30)
    assert "required" in err or "requires --query or --mode recent" in err


def test_cli_digest_summary(monkeypatch, tmp_path):
    rc, _, _ = _run(monkeypatch, tmp_path, "doctor", "--bootstrap")
    assert rc == 0
    rc, _, _ = _run(
        monkeypatch,
        tmp_path,
        "add",
        "--scope",
        "user",
        "--layer",
        "user-global",
        "--content",
        "block one",
    )
    assert rc == 0

    rc, out, _ = _run(monkeypatch, tmp_path, "digest", "--scope", "user")
    assert rc == 0
    body = json.loads(out)
    assert body["exists"] is True
    assert body["blocks"] == 1
    assert body["by_layer"]["user-global"] == 1
    assert body["latest_ts"] is not None


def test_cli_digest_rebuild_chroma_reserved_phase_c(monkeypatch, tmp_path):
    _run(monkeypatch, tmp_path, "doctor", "--bootstrap")
    rc, _, err = _run(
        monkeypatch,
        tmp_path,
        "digest",
        "--scope",
        "user",
        "--rebuild-chroma",
    )
    assert rc == 30
    assert "Phase C" in err or "reserved" in err


def test_cli_add_project_fresh_repo_creates_trust_root(monkeypatch, tmp_path):
    _run(monkeypatch, tmp_path, "doctor", "--bootstrap")
    fresh_repo = tmp_path / "fresh-project"
    fresh_repo.mkdir()

    rc, out, err = _run(
        monkeypatch,
        tmp_path,
        "add",
        "--scope",
        "project",
        "--layer",
        "episodic",
        "--content",
        "first block in fresh repo",
        "--cwd",
        str(fresh_repo),
    )
    assert rc == 0, f"fresh-repo add failed: rc={rc} stderr={err}"
    assert (fresh_repo / ".claude" / "wiki" / "digest.md").exists()
    body = json.loads(out)
    assert body["new"] is True
