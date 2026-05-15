"""Phase C cmd_add chain: digest → raw upsert → extract → fact writes.

Uses fake_bridge.sh fixture to control extraction output, real Chroma persist
dir under tmp_path. ~/.claude is monkeypatched so user-scope writes land there.
"""
from __future__ import annotations

import hashlib
import json
import pathlib

import pytest

FIX = pathlib.Path(__file__).parent / "fixtures"
FAKE_BRIDGE = FIX / "fake_bridge.sh"


@pytest.fixture
def env(monkeypatch, tmp_path):
    home = tmp_path / "home"
    home.mkdir()
    (home / ".claude").mkdir()
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("SSPOWER_BRIDGE_PATH", str(FAKE_BRIDGE))
    monkeypatch.setenv("MEM0_TELEMETRY", "False")
    from sspower_mem.doctor import bootstrap
    bootstrap()
    return {"home": home, "tmp": tmp_path, "monkeypatch": monkeypatch}


def _ok_envelope(facts):
    return json.dumps({
        "id": "x", "object": "chat.completion",
        "choices": [{"index": 0, "message": {"role": "assistant",
                                              "content": json.dumps({"facts": facts})}}],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
    })


def _set_bridge_resp(env, response, exit_code=0):
    env["monkeypatch"].setenv("SSPOWER_FAKE_BRIDGE_RESPONSE", response)
    env["monkeypatch"].setenv("SSPOWER_FAKE_BRIDGE_EXIT", str(exit_code))
    env["monkeypatch"].setenv("SSPOWER_FAKE_BRIDGE_STDERR", "")


def test_add_step2_writes_raw_record(env, capsys):
    """Happy path: digest + raw upsert + empty facts list = rc 0, extracted=ok."""
    from sspower_mem.cli import main
    _set_bridge_resp(env, _ok_envelope([]))
    rc = main(["add", "--scope", "user", "--layer", "user-global",
               "--content", "memory body one"])
    assert rc == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["raw"] == "ok"
    assert payload["extracted"] == "ok"


def test_add_step2_failure_returns_rc10(env, capsys, monkeypatch):
    """Step 2 raises → rc=10, digest still written."""
    from sspower_mem.cli import main

    def boom(*a, **kw):
        raise RuntimeError("simulated chroma failure")

    monkeypatch.setattr("sspower_mem.mem.idx.raw_upsert", boom)
    _set_bridge_resp(env, _ok_envelope([]))
    rc = main(["add", "--scope", "user", "--layer", "user-global",
               "--content", "memory body two"])
    assert rc == 10
    payload = json.loads(capsys.readouterr().out)
    assert payload["raw"] == "skipped"
    assert payload["extracted"] in ("skipped-failed", "skipped-partial")


def test_add_full_happy_with_facts(env, capsys):
    from sspower_mem.cli import main
    _set_bridge_resp(env, _ok_envelope(["fact a", "fact b"]))
    rc = main(["add", "--scope", "user", "--layer", "user-global",
               "--content", "narrative content here"])
    assert rc == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["raw"] == "ok"
    assert payload["extracted"] == "ok"


def test_add_bridge_failure_returns_skipped_failed(env, capsys):
    from sspower_mem.cli import main
    _set_bridge_resp(env, "", exit_code=1)
    rc = main(["add", "--scope", "user", "--layer", "user-global",
               "--content", "x" * 10])
    assert rc == 10
    payload = json.loads(capsys.readouterr().out)
    assert payload["raw"] == "ok"
    assert payload["extracted"] == "skipped-failed"


def test_add_step3b_partial_failure(env, capsys, monkeypatch):
    """Mid-write failure → skipped-partial, rc=10."""
    from sspower_mem.cli import main
    from sspower_mem.mem import idx as idx_module

    real_upsert = idx_module.extracted_upsert

    def flaky(mem, text, meta, *, user_id):
        if meta.get("fact_index") == 1:
            raise RuntimeError("chroma full")
        return real_upsert(mem, text, meta, user_id=user_id)

    monkeypatch.setattr("sspower_mem.mem.idx.extracted_upsert", flaky)
    _set_bridge_resp(env, _ok_envelope(["one", "two", "three"]))
    rc = main(["add", "--scope", "user", "--layer", "user-global",
               "--content", "content for partial"])
    assert rc == 10
    payload = json.loads(capsys.readouterr().out)
    assert payload["extracted"] == "skipped-partial"


def test_add_no_llm_step2_ok_returns_rc0_and_skips_bridge(env, capsys, tmp_path):
    """--no-llm must NOT invoke the bridge."""
    from sspower_mem.cli import main

    sentinel = tmp_path / "bridge_called_sentinel"
    env["monkeypatch"].setenv("SSPOWER_FAKE_BRIDGE_SENTINEL", str(sentinel))
    _set_bridge_resp(env, _ok_envelope([]))
    rc = main(["add", "--scope", "user", "--layer", "user-global",
               "--content", "no-llm body", "--no-llm"])
    assert rc == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["raw"] == "ok"
    assert payload["extracted"] == "skipped-intentional"
    assert not sentinel.exists(), "bridge was invoked under --no-llm"


def test_add_no_llm_step2_failed_still_rc10(env, capsys, monkeypatch):
    """--no-llm does not mask step 2 failures."""
    from sspower_mem.cli import main

    def boom(*a, **kw):
        raise RuntimeError("chroma corrupt")

    monkeypatch.setattr("sspower_mem.mem.idx.raw_upsert", boom)
    _set_bridge_resp(env, _ok_envelope([]))
    rc = main(["add", "--scope", "user", "--layer", "user-global",
               "--content", "body", "--no-llm"])
    assert rc == 10
    payload = json.loads(capsys.readouterr().out)
    assert payload["raw"] == "skipped"
    assert payload["extracted"] == "skipped-intentional"


def test_search_index_hit_after_add(env, capsys):
    """Add a block with extracted facts; search by query returns index hits."""
    from sspower_mem.cli import main
    _set_bridge_resp(env, _ok_envelope(["alpha apples are fruit"]))
    main(["add", "--scope", "user", "--layer", "user-global",
          "--content", "alpha apples are nutritious fruit"])
    capsys.readouterr()
    rc = main(["search", "--scope", "user", "--query", "apples", "--json"])
    assert rc == 0
    out = json.loads(capsys.readouterr().out)
    assert out, "expected at least one hit"
    assert any(h["source"] == "index" for h in out)


def test_search_idx_only_empty_returns_empty_rc0(env, capsys):
    """--idx-only with empty index returns rc=0 and []."""
    from sspower_mem.cli import main
    rc = main(["search", "--scope", "user", "--query", "nothing", "--idx-only", "--json"])
    assert rc == 0
    assert json.loads(capsys.readouterr().out) == []


def test_search_dedups_raw_and_extracted_for_same_block(env, capsys):
    """Spec §6.1 read path: when raw + extracted hits share correlation key,
    keep only the extracted hit."""
    from sspower_mem.cli import main
    # Add a block whose content AND fact share the word "elephant".
    _set_bridge_resp(env, _ok_envelope(["elephants live in africa"]))
    main(["add", "--scope", "user", "--layer", "user-global",
          "--content", "elephants are large animals living in africa"])
    capsys.readouterr()
    rc = main(["search", "--scope", "user", "--query", "elephant", "--json"])
    assert rc == 0
    out = json.loads(capsys.readouterr().out)
    # raw record (block_id=X) + extracted (raw_id=X) → dedup collapses to one.
    block_ids = [h["id"] for h in out]
    assert len(block_ids) == len(set(block_ids)), f"duplicate ids in result: {block_ids}"


def test_add_mem0_import_failure_keeps_digest_durable(env, capsys, monkeypatch):
    """Spec §6.1/§8 lazy-import policy: broken Mem0 import inside cmd_add
    MUST NOT bypass the digest write. Step 1 completes, Step 2 import fails,
    rc=10, digest block exists with the effective id.
    """
    import builtins
    from sspower_mem.cli import main
    from sspower_mem.io import safe_read_strict
    from sspower_mem.scope import digest_path, parent_anchor

    real_import = builtins.__import__

    def broken_import(name, *args, **kwargs):
        if name in ("sspower_mem.mem.factory", "sspower_mem.mem.idx"):
            raise ImportError(f"simulated dep failure for {name}")
        return real_import(name, *args, **kwargs)

    monkeypatch.setattr(builtins, "__import__", broken_import)
    _set_bridge_resp(env, _ok_envelope([]))

    rc = main(["add", "--scope", "user", "--layer", "user-global",
               "--content", "durable digest body"])
    assert rc == 10
    payload = json.loads(capsys.readouterr().out)
    assert payload["raw"] == "skipped"

    digest_text = safe_read_strict(digest_path("user", None), parent_anchor("user", None))
    assert payload["id"] in digest_text
    assert "durable digest body" in digest_text
