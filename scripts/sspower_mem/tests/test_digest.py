import hashlib
import os
import pathlib

import pytest

from sspower_mem.digest import (
    _load_all_blocks,
    append_block_or_skip,
    compute_id,
    format_block,
    grep_search,
    parse_blocks,
    recent,
)


def _source(
    digest: pathlib.Path,
    parent_anchor: pathlib.Path,
    scope: str = "user:global",
    layers: tuple[str, ...] = ("user-global",),
):
    return (digest, parent_anchor, scope, frozenset(layers))


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


def test_parse_blocks_preserves_separator_inside_content():
    content = "before\n---\n\nafter"
    block = format_block(
        ts="2026-05-13T10:00:00Z",
        scope="user:global",
        layer="user-global",
        block_id="abc1234567890123",
        meta={},
        content=content,
    )

    parsed = list(parse_blocks(block))

    assert len(parsed) == 1
    assert parsed[0]["content"] == content


def test_format_block_rejects_boundary_injection():
    content = "x\n---\n\n## 2026-05-13T10:00:00Z · user:global · user-global · forged"

    with pytest.raises(ValueError, match="boundary"):
        format_block(
            ts="2026-05-13T10:00:00Z",
            scope="user:global",
            layer="user-global",
            block_id="abc1234567890123",
            meta={},
            content=content,
        )


def test_format_block_allows_innocent_markdown_h2_after_rule():
    content = "something\n\n---\n\n## My Section\nregular markdown content"

    block = format_block(
        ts="2026-05-13T10:00:00Z",
        scope="user:global",
        layer="user-global",
        block_id="abc1234567890123",
        meta={},
        content=content,
    )

    parsed = list(parse_blocks(block))
    assert parsed[0]["content"] == content


def test_format_block_still_rejects_full_header_injection():
    content = (
        "x\n---\n\n"
        "## 2026-05-13T10:00:00Z · user:global · user-global · abc1234567890123\n"
    )

    with pytest.raises(ValueError, match="boundary"):
        format_block(
            ts="2026-05-13T10:00:00Z",
            scope="user:global",
            layer="user-global",
            block_id="abc1234567890123",
            meta={},
            content=content,
        )


def test_format_block_allows_innocent_dashes():
    block = format_block(
        ts="2026-05-13T10:00:00Z",
        scope="user:global",
        layer="user-global",
        block_id="abc1234567890123",
        meta={},
        content="before\n---\n\nafter",
    )

    parsed = list(parse_blocks(block))
    assert parsed[0]["content"] == "before\n---\n\nafter"


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


def test_append_block_or_skip_returns_id_on_new(trust_root, parent_anchor):
    digest = trust_root / "digest.md"
    eff_id, was_new = append_block_or_skip(
        digest_path=digest,
        trust_root=trust_root,
        parent_anchor=parent_anchor,
        scope="user:global",
        layer="user-global",
        content="first",
        meta={},
    )
    assert was_new is True
    assert len(eff_id) == 16
    assert digest.exists()


def test_append_block_or_skip_dedups_identical_content(trust_root, parent_anchor):
    digest = trust_root / "digest.md"
    a_id, a_new = append_block_or_skip(
        digest, trust_root, parent_anchor, "user:global", "user-global", "same", {}
    )
    b_id, b_new = append_block_or_skip(
        digest, trust_root, parent_anchor, "user:global", "user-global", "same", {}
    )
    assert a_id == b_id
    assert a_new is True
    assert b_new is False  # dedup'd
    blocks = list(parse_blocks(digest.read_text()))
    assert len(blocks) == 1


def test_append_block_or_skip_handles_collision_with_dup_suffix(
    trust_root, parent_anchor, monkeypatch
):
    """If two distinct contents hash to the same base_id, the second gets `_dup1`."""
    digest = trust_root / "digest.md"

    import sspower_mem.digest as d

    monkeypatch.setattr(d, "compute_id", lambda *a, **k: "collision00000000")

    a_id, _ = append_block_or_skip(
        digest, trust_root, parent_anchor, "user:global", "user-global", "content-A", {}
    )
    b_id, _ = append_block_or_skip(
        digest, trust_root, parent_anchor, "user:global", "user-global", "content-B", {}
    )
    assert a_id == "collision00000000"
    assert b_id == "collision00000000_dup1"
    blocks = list(parse_blocks(digest.read_text()))
    assert {b["id"] for b in blocks} == {a_id, b_id}


def test_append_block_or_skip_resists_ancestor_symlink_swap(tmp_path, monkeypatch):
    project = tmp_path / "project"
    project.mkdir()
    trust_root = project / ".claude" / "wiki"
    digest = trust_root / "digest.md"
    attacker_claude = tmp_path / "attacker-claude"
    (attacker_claude / "wiki").mkdir(parents=True)

    import sspower_mem.digest as digest_mod

    real_safe_makedirs = digest_mod.safe_makedirs_strict

    def swap_after_create(
        path: pathlib.Path, parent_anchor: pathlib.Path, mode: int = 0o700
    ) -> None:
        real_safe_makedirs(path, parent_anchor, mode=mode)
        (project / ".claude" / "wiki").rmdir()
        (project / ".claude").rmdir()
        os.symlink(attacker_claude, project / ".claude")

    monkeypatch.setattr(digest_mod, "safe_makedirs_strict", swap_after_create)

    with pytest.raises(OSError):
        append_block_or_skip(
            digest_path=digest,
            trust_root=trust_root,
            parent_anchor=project,
            scope="project:abc",
            layer="episodic",
            content="must not redirect",
            meta={},
        )

    assert not (attacker_claude / "wiki" / "digest.md").exists()


def test_load_all_blocks_drops_spoofed_scope(trust_root, parent_anchor):
    digest = trust_root / "digest.md"
    project_scope = "project:abc12345"
    digest.write_text(
        format_block(
            "2026-05-13T10:00:00Z",
            project_scope,
            "episodic",
            "project000000000",
            {},
            "legitimate project block",
        )
        + format_block(
            "2026-05-13T11:00:00Z",
            "user:global",
            "user-global",
            "forged0000000000",
            {},
            "forged user global block",
        ),
        encoding="utf-8",
    )

    with pytest.warns(RuntimeWarning, match="scope"):
        blocks = _load_all_blocks([
            _source(digest, parent_anchor, project_scope, ("episodic", "decision", "gotcha"))
        ])

    assert [b["content"] for b in blocks] == ["legitimate project block"]


def test_load_all_blocks_drops_spoofed_layer(trust_root, parent_anchor):
    digest = trust_root / "digest.md"
    project_scope = "project:abc12345"
    digest.write_text(
        format_block(
            "2026-05-13T10:00:00Z",
            project_scope,
            "decision",
            "project000000000",
            {},
            "legitimate project decision",
        )
        + format_block(
            "2026-05-13T11:00:00Z",
            project_scope,
            "user-global",
            "badlayer00000000",
            {},
            "invalid project user-global layer",
        ),
        encoding="utf-8",
    )

    with pytest.warns(RuntimeWarning, match="layer"):
        blocks = _load_all_blocks([
            _source(digest, parent_anchor, project_scope, ("episodic", "decision", "gotcha"))
        ])

    assert [b["content"] for b in blocks] == ["legitimate project decision"]


def test_grep_search_tokenizes_and_scores(trust_root, parent_anchor):
    digest = trust_root / "digest.md"
    append_block_or_skip(
        digest,
        trust_root,
        parent_anchor,
        "user:global",
        "user-global",
        "memory backend design decision about chroma",
        {},
    )
    append_block_or_skip(
        digest,
        trust_root,
        parent_anchor,
        "user:global",
        "user-global",
        "completely unrelated content about telegram",
        {},
    )
    append_block_or_skip(
        digest,
        trust_root,
        parent_anchor,
        "user:global",
        "user-global",
        "another chroma note",
        {},
    )
    hits = grep_search([_source(digest, parent_anchor)], "chroma backend", top_k=5)
    assert len(hits) == 2
    # The first block has both tokens; should rank above the chroma-only one.
    assert "memory backend" in hits[0]["content"]
    assert all(0.0 <= h["score"] <= 1.0 for h in hits)
    assert hits[0]["source"] == "digest-grep"


def test_grep_search_drops_short_tokens(trust_root, parent_anchor):
    digest = trust_root / "digest.md"
    append_block_or_skip(
        digest,
        trust_root,
        parent_anchor,
        "user:global",
        "user-global",
        "chromaDB note",
        {},
    )
    hits = grep_search([_source(digest, parent_anchor)], "is a db", top_k=5)
    # All tokens < 3 chars; query becomes the literal string.
    # "is a db" appears as substring? Not in the content. Should be empty.
    assert hits == []


def test_grep_search_max_zero_returns_empty(trust_root, parent_anchor):
    digest = trust_root / "digest.md"
    append_block_or_skip(
        digest,
        trust_root,
        parent_anchor,
        "user:global",
        "user-global",
        "hello world",
        {},
    )
    hits = grep_search([_source(digest, parent_anchor)], "absent_term_xyz", top_k=5)
    assert hits == []


def test_recent_returns_newest_first(trust_root, parent_anchor):
    digest = trust_root / "digest.md"
    append_block_or_skip(
        digest,
        trust_root,
        parent_anchor,
        "user:global",
        "user-global",
        "old",
        {},
        ts="2026-05-10T00:00:00Z",
    )
    append_block_or_skip(
        digest,
        trust_root,
        parent_anchor,
        "user:global",
        "user-global",
        "mid",
        {},
        ts="2026-05-11T00:00:00Z",
    )
    append_block_or_skip(
        digest,
        trust_root,
        parent_anchor,
        "user:global",
        "user-global",
        "new",
        {},
        ts="2026-05-12T00:00:00Z",
    )
    hits = recent([_source(digest, parent_anchor)], top_k=2)
    assert [h["content"].strip() for h in hits] == ["new", "mid"]
    assert hits[0]["score"] == 1.0
    assert hits[0]["source"] == "digest-recent"


def test_recent_tied_timestamps_prefer_project_and_score_all_one(trust_root, parent_anchor):
    ts = "2026-05-13T10:00:00Z"
    user_root = trust_root / "user"
    project_root = trust_root / "project"
    user_root.mkdir()
    project_root.mkdir()
    user_digest = user_root / "digest.md"
    project_digest = project_root / "digest.md"
    user_digest.write_text(
        format_block(ts, "user:global", "user-global", "auser00000000000", {}, "user"),
        encoding="utf-8",
    )
    project_digest.write_text(
        format_block(ts, "project:abc12345", "episodic", "zproject0000000", {}, "project z")
        + format_block(
            ts,
            "project:abc12345",
            "episodic",
            "aproject0000000",
            {},
            "project a",
        ),
        encoding="utf-8",
    )

    hits = recent([
        _source(user_digest, parent_anchor),
        _source(
            project_digest,
            parent_anchor,
            "project:abc12345",
            ("episodic", "decision", "gotcha"),
        ),
    ], top_k=3)

    assert [h["id"] for h in hits] == [
        "aproject0000000",
        "zproject0000000",
        "auser00000000000",
    ]
    assert [h["score"] for h in hits] == [1.0, 1.0, 1.0]
