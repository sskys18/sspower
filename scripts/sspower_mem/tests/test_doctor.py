import os
import pathlib

import pytest

from sspower_mem.doctor import bootstrap, health


def test_bootstrap_creates_user_sspower_dir(monkeypatch, tmp_path):
    fake_home = tmp_path / "home"
    fake_home.mkdir()
    monkeypatch.setenv("HOME", str(fake_home))
    monkeypatch.setattr(pathlib.Path, "home", classmethod(lambda cls: fake_home))

    result = bootstrap()
    sspower = fake_home / ".claude" / "sspower"
    assert (sspower / "idx").is_dir()
    assert (sspower / "idx" / ".lock").exists()
    assert (sspower / "idx" / "config.json").exists()
    # status is "ok" if both probes pass; "degraded" if bridge unreachable (test env).
    assert result["status"] in ("ok", "degraded")
    assert "probe" in result

    # Idempotent -- second call must not raise.
    bootstrap()


def test_bootstrap_refuses_symlinked_user_sspower_dir(monkeypatch, tmp_path):
    fake_home = tmp_path / "home"
    fake_home.mkdir()
    monkeypatch.setenv("HOME", str(fake_home))
    monkeypatch.setattr(pathlib.Path, "home", classmethod(lambda cls: fake_home))

    claude = fake_home / ".claude"
    claude.mkdir()
    target = tmp_path / "target"
    target.mkdir()
    os.symlink(target, claude / "sspower")

    with pytest.raises(OSError):
        bootstrap()

    assert not (target / "idx").exists()
    assert not (target / "idx" / ".lock").exists()
    assert not (target / "idx" / "config.json").exists()


def test_health_reports_ok_after_bootstrap(monkeypatch, tmp_path):
    fake_home = tmp_path / "home"
    fake_home.mkdir()
    monkeypatch.setattr(pathlib.Path, "home", classmethod(lambda cls: fake_home))
    bootstrap()
    h = health()
    assert h["lock_writable"] is True
    assert h["digest_writable"] is True


def test_health_reports_missing_when_no_bootstrap(monkeypatch, tmp_path):
    fake_home = tmp_path / "home"
    fake_home.mkdir()
    monkeypatch.setattr(pathlib.Path, "home", classmethod(lambda cls: fake_home))
    h = health()
    assert h["lock_writable"] is False


_FAKE_BRIDGE = pathlib.Path(__file__).resolve().parent / "fixtures" / "fake_bridge.sh"
_EMPTY_FACTS_ENVELOPE = (
    '{"id":"x","object":"chat.completion","choices":[{"index":0,'
    '"message":{"role":"assistant","content":"{\\"facts\\":[]}"}}],'
    '"usage":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0}}'
)


def test_bootstrap_phase_c_reports_status_ok_with_healthy_bridge(monkeypatch, tmp_path):
    fake_home = tmp_path / "home"
    fake_home.mkdir()
    monkeypatch.setattr(pathlib.Path, "home", classmethod(lambda cls: fake_home))
    monkeypatch.setenv("SSPOWER_BRIDGE_PATH", str(_FAKE_BRIDGE))
    monkeypatch.setenv("SSPOWER_FAKE_BRIDGE_RESPONSE", _EMPTY_FACTS_ENVELOPE)
    monkeypatch.setenv("SSPOWER_FAKE_BRIDGE_EXIT", "0")

    result = bootstrap()
    assert result["status"] == "ok"
    assert result["probe"]["index"]["ok"] is True
    assert result["probe"]["bridge"]["ok"] is True


def test_bootstrap_phase_c_reports_degraded_on_bridge_failure(monkeypatch, tmp_path):
    fake_home = tmp_path / "home"
    fake_home.mkdir()
    monkeypatch.setattr(pathlib.Path, "home", classmethod(lambda cls: fake_home))
    monkeypatch.setenv("SSPOWER_BRIDGE_PATH", str(_FAKE_BRIDGE))
    monkeypatch.setenv("SSPOWER_FAKE_BRIDGE_EXIT", "1")
    monkeypatch.setenv("SSPOWER_FAKE_BRIDGE_STDERR",
                       '{"error":{"type":"x","message":"bridge unavailable"}}')

    result = bootstrap()
    assert result["status"] == "degraded"
    assert result["probe"]["bridge"]["ok"] is False
    # Filesystem init still proceeds.
    sspower = fake_home / ".claude" / "sspower"
    assert (sspower / "idx" / "chroma").exists()


def test_health_phase_c_canaries_entity_store(monkeypatch, tmp_path):
    fake_home = tmp_path / "home"
    fake_home.mkdir()
    monkeypatch.setattr(pathlib.Path, "home", classmethod(lambda cls: fake_home))
    monkeypatch.setenv("SSPOWER_BRIDGE_PATH", str(_FAKE_BRIDGE))
    monkeypatch.setenv("SSPOWER_FAKE_BRIDGE_RESPONSE", _EMPTY_FACTS_ENVELOPE)
    monkeypatch.setenv("SSPOWER_FAKE_BRIDGE_EXIT", "0")

    bootstrap()
    h = health()
    assert h["phase"] == "C"
    assert h["chroma_reachable"] is True
    assert h["entity_store_present"] is False
