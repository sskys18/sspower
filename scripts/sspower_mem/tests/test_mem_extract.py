"""bridge_extract_facts: D14 error classification matrix.

Contract per docs/specs/2026-05-13-index-backend-integration-design.md §6.1.5:
  - choices[0].message.content parses as JSON object {"facts": [str, ...]}
  - empty success = {"facts": []} → returns []
  - any malformed step → ExtractFailed
  - facts truncated to first 32; each fact to 512 chars
"""
from __future__ import annotations

import json
import pathlib

import pytest

FIXTURES = pathlib.Path(__file__).parent / "fixtures"
FAKE_BRIDGE = FIXTURES / "fake_bridge.sh"


def _envelope(content_obj):
    return json.dumps({
        "id": "test-1",
        "object": "chat.completion",
        "choices": [{"index": 0, "message": {"role": "assistant", "content": json.dumps(content_obj)}}],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
    })


def _set_bridge(monkeypatch, response, exit_code=0, stderr=""):
    monkeypatch.setenv("SSPOWER_BRIDGE_PATH", str(FAKE_BRIDGE))
    monkeypatch.setenv("SSPOWER_FAKE_BRIDGE_RESPONSE", response)
    monkeypatch.setenv("SSPOWER_FAKE_BRIDGE_EXIT", str(exit_code))
    monkeypatch.setenv("SSPOWER_FAKE_BRIDGE_STDERR", stderr)


def test_empty_facts_returns_empty_list(monkeypatch):
    from sspower_mem.mem.extract import bridge_extract_facts
    _set_bridge(monkeypatch, _envelope({"facts": []}))
    assert bridge_extract_facts("hello") == []


def test_two_facts_returned_in_order(monkeypatch):
    from sspower_mem.mem.extract import bridge_extract_facts
    _set_bridge(monkeypatch, _envelope({"facts": ["alpha", "beta"]}))
    assert bridge_extract_facts("hello") == ["alpha", "beta"]


def test_bridge_nonzero_exit_raises(monkeypatch):
    from sspower_mem.mem.extract import ExtractFailed, bridge_extract_facts
    _set_bridge(monkeypatch, "", exit_code=1, stderr='{"error":{"type":"x","message":"y"}}')
    with pytest.raises(ExtractFailed):
        bridge_extract_facts("hello")


def test_invalid_envelope_json_raises(monkeypatch):
    from sspower_mem.mem.extract import ExtractFailed, bridge_extract_facts
    _set_bridge(monkeypatch, "not json")
    with pytest.raises(ExtractFailed):
        bridge_extract_facts("hello")


def test_bridge_error_field_raises(monkeypatch):
    from sspower_mem.mem.extract import ExtractFailed, bridge_extract_facts
    _set_bridge(monkeypatch, json.dumps({"error": {"type": "timeout", "message": "x"}}))
    with pytest.raises(ExtractFailed):
        bridge_extract_facts("hello")


def test_missing_choices_raises(monkeypatch):
    from sspower_mem.mem.extract import ExtractFailed, bridge_extract_facts
    _set_bridge(monkeypatch, json.dumps({"id": "x", "object": "chat.completion", "choices": []}))
    with pytest.raises(ExtractFailed):
        bridge_extract_facts("hello")


def test_content_not_json_raises(monkeypatch):
    from sspower_mem.mem.extract import ExtractFailed, bridge_extract_facts
    raw = json.dumps({"id": "x", "object": "chat.completion",
                      "choices": [{"index": 0, "message": {"role": "assistant", "content": "not-json"}}]})
    _set_bridge(monkeypatch, raw)
    with pytest.raises(ExtractFailed):
        bridge_extract_facts("hello")


def test_missing_facts_key_raises(monkeypatch):
    from sspower_mem.mem.extract import ExtractFailed, bridge_extract_facts
    _set_bridge(monkeypatch, _envelope({"items": ["a"]}))
    with pytest.raises(ExtractFailed):
        bridge_extract_facts("hello")


def test_facts_not_list_raises(monkeypatch):
    from sspower_mem.mem.extract import ExtractFailed, bridge_extract_facts
    _set_bridge(monkeypatch, _envelope({"facts": "alpha"}))
    with pytest.raises(ExtractFailed):
        bridge_extract_facts("hello")


def test_non_string_element_raises(monkeypatch):
    from sspower_mem.mem.extract import ExtractFailed, bridge_extract_facts
    _set_bridge(monkeypatch, _envelope({"facts": ["alpha", 42]}))
    with pytest.raises(ExtractFailed):
        bridge_extract_facts("hello")


def test_too_many_facts_truncated_to_32(monkeypatch):
    from sspower_mem.mem.extract import bridge_extract_facts
    facts = [f"f{i}" for i in range(40)]
    _set_bridge(monkeypatch, _envelope({"facts": facts}))
    out = bridge_extract_facts("hello")
    assert len(out) == 32
    assert out == facts[:32]


def test_long_fact_truncated_to_512(monkeypatch):
    from sspower_mem.mem.extract import bridge_extract_facts
    long_fact = "x" * 600
    _set_bridge(monkeypatch, _envelope({"facts": [long_fact]}))
    out = bridge_extract_facts("hello")
    assert len(out[0]) == 512
