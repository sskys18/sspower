import hashlib
import pathlib

import pytest

from sspower_mem.digest import (
    append_block_or_skip,
    compute_id,
    format_block,
    grep_search,
    parse_blocks,
    recent,
)


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


def test_append_block_or_skip_returns_id_on_new(trust_root):
    digest = trust_root / "digest.md"
    eff_id, was_new = append_block_or_skip(
        digest_path=digest,
        trust_root=trust_root,
        scope="user:global",
        layer="user-global",
        content="first",
        meta={},
    )
    assert was_new is True
    assert len(eff_id) == 16
    assert digest.exists()


def test_append_block_or_skip_dedups_identical_content(trust_root):
    digest = trust_root / "digest.md"
    a_id, a_new = append_block_or_skip(
        digest, trust_root, "user:global", "user-global", "same", {}
    )
    b_id, b_new = append_block_or_skip(
        digest, trust_root, "user:global", "user-global", "same", {}
    )
    assert a_id == b_id
    assert a_new is True
    assert b_new is False  # dedup'd
    blocks = list(parse_blocks(digest.read_text()))
    assert len(blocks) == 1


def test_append_block_or_skip_handles_collision_with_dup_suffix(trust_root, monkeypatch):
    """If two distinct contents hash to the same base_id, the second gets `_dup1`."""
    digest = trust_root / "digest.md"

    import sspower_mem.digest as d

    monkeypatch.setattr(d, "compute_id", lambda *a, **k: "collision00000000")

    a_id, _ = append_block_or_skip(
        digest, trust_root, "user:global", "user-global", "content-A", {}
    )
    b_id, _ = append_block_or_skip(
        digest, trust_root, "user:global", "user-global", "content-B", {}
    )
    assert a_id == "collision00000000"
    assert b_id == "collision00000000_dup1"
    blocks = list(parse_blocks(digest.read_text()))
    assert {b["id"] for b in blocks} == {a_id, b_id}


def test_grep_search_tokenizes_and_scores(trust_root):
    digest = trust_root / "digest.md"
    append_block_or_skip(
        digest,
        trust_root,
        "user:global",
        "user-global",
        "memory backend design decision about chroma",
        {},
    )
    append_block_or_skip(
        digest,
        trust_root,
        "user:global",
        "user-global",
        "completely unrelated content about telegram",
        {},
    )
    append_block_or_skip(
        digest,
        trust_root,
        "user:global",
        "user-global",
        "another chroma note",
        {},
    )
    hits = grep_search([digest], "chroma backend", top_k=5)
    assert len(hits) == 2
    # The first block has both tokens; should rank above the chroma-only one.
    assert "memory backend" in hits[0]["content"]
    assert all(0.0 <= h["score"] <= 1.0 for h in hits)
    assert hits[0]["source"] == "digest-grep"


def test_grep_search_drops_short_tokens(trust_root):
    digest = trust_root / "digest.md"
    append_block_or_skip(
        digest,
        trust_root,
        "user:global",
        "user-global",
        "chromaDB note",
        {},
    )
    hits = grep_search([digest], "is a db", top_k=5)
    # All tokens < 3 chars; query becomes the literal string.
    # "is a db" appears as substring? Not in the content. Should be empty.
    assert hits == []


def test_grep_search_max_zero_returns_empty(trust_root):
    digest = trust_root / "digest.md"
    append_block_or_skip(
        digest,
        trust_root,
        "user:global",
        "user-global",
        "hello world",
        {},
    )
    hits = grep_search([digest], "absent_term_xyz", top_k=5)
    assert hits == []


def test_recent_returns_newest_first(trust_root):
    digest = trust_root / "digest.md"
    append_block_or_skip(
        digest,
        trust_root,
        "user:global",
        "user-global",
        "old",
        {},
        ts="2026-05-10T00:00:00Z",
    )
    append_block_or_skip(
        digest,
        trust_root,
        "user:global",
        "user-global",
        "mid",
        {},
        ts="2026-05-11T00:00:00Z",
    )
    append_block_or_skip(
        digest,
        trust_root,
        "user:global",
        "user-global",
        "new",
        {},
        ts="2026-05-12T00:00:00Z",
    )
    hits = recent([digest], top_k=2)
    assert [h["content"].strip() for h in hits] == ["new", "mid"]
    assert hits[0]["score"] == 1.0
    assert hits[0]["source"] == "digest-recent"
