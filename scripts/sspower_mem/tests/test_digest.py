import hashlib
import pathlib

import pytest

from sspower_mem.digest import compute_id, format_block, parse_blocks


def test_compute_id_is_stable_sha1_16():
    a = compute_id("project:abc", "decision", "use the index")
    b = compute_id("project:abc", "decision", "use the index")
    assert a == b
    assert a == hashlib.sha1(b"project:abc|decision|use the index").hexdigest()[:16]


def test_compute_id_differs_on_content_change():
    assert compute_id("project:abc", "decision", "use the index") != \
           compute_id("project:abc", "decision", "use the index!")


def test_format_block_round_trips_through_parse():
    block = format_block(
        ts="2026-05-13T10:00:00Z",
        scope="project:abc12345",
        layer="episodic",
        block_id="0123456789abcdef",
        meta={"foo": "bar"},
        content="some content\nspanning lines",
    )
    parsed = list(parse_blocks(block))
    assert len(parsed) == 1
    p = parsed[0]
    assert p["ts"] == "2026-05-13T10:00:00Z"
    assert p["scope"] == "project:abc12345"
    assert p["layer"] == "episodic"
    assert p["id"] == "0123456789abcdef"
    assert p["meta"] == {"foo": "bar"}
    assert p["content"].rstrip() == "some content\nspanning lines"


def test_parse_blocks_handles_multiple():
    b1 = format_block("2026-05-13T10:00:00Z", "user:global", "user-global",
                     "id0000000000000a", {}, "first")
    b2 = format_block("2026-05-13T11:00:00Z", "user:global", "user-global",
                     "id0000000000000b", {"k": "v"}, "second")
    parsed = list(parse_blocks(b1 + b2))
    assert [p["id"] for p in parsed] == ["id0000000000000a", "id0000000000000b"]


def test_meta_serialization_handles_commas_and_equals():
    """Path-safe meta serialization: values may contain commas/equals."""
    block = format_block(
        ts="2026-05-13T10:00:00Z",
        scope="user:global",
        layer="user-global",
        block_id="abc1234567890123",
        meta={"migrated_from": "/path/with,comma=equals.md"},
        content="x",
    )
    parsed = list(parse_blocks(block))
    assert parsed[0]["meta"]["migrated_from"] == "/path/with,comma=equals.md"
