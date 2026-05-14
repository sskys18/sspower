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
    assert result["status"] == "ok"

    # Idempotent -- second call must not raise.
    bootstrap()


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
