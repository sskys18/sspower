"""Idempotent raw + extracted upserts. Pre-search by sspower id/raw_id, skip on hit."""
from __future__ import annotations

import pathlib

import pytest


@pytest.fixture
def mem(tmp_path):
    import sspower_mem.mem  # noqa: F401
    from sspower_mem.mem.factory import build_memory

    idx_dir = tmp_path / "idx"
    idx_dir.mkdir()
    chroma_dir = idx_dir / "chroma"
    history_db = idx_dir / "history.db"
    return build_memory(
        scope_id="user:global",
        idx_dir=idx_dir,
        chroma_dir=chroma_dir,
        history_db_path=history_db,
    )


def _base_meta(eff_id: str, scope: str = "user:global"):
    return {"block_id": eff_id, "layer": "user-global", "scope": scope, "ts": "2026-05-15T00:00:00Z"}


def test_raw_upsert_writes_once(mem):
    from sspower_mem.mem.idx import raw_upsert
    meta = _base_meta("abc123def4567890")
    raw_upsert(mem, "the content", meta, user_id="user:global")
    raw_upsert(mem, "the content", meta, user_id="user:global")
    hits = mem.search(
        query=" ",
        filters={"user_id": "user:global", "AND": [{"block_id": "abc123def4567890"}, {"kind": "raw"}]},
        top_k=10,
        threshold=0.0,
    )
    assert len(hits.get("results", [])) == 1


def test_raw_upsert_preserves_caller_metadata(mem):
    from sspower_mem.mem.idx import raw_upsert
    meta = _base_meta("xxx1111122223333")
    raw_upsert(mem, "content one", meta, user_id="user:global")
    hits = mem.search(
        query=" ",
        filters={"user_id": "user:global", "block_id": "xxx1111122223333"},
        top_k=1,
        threshold=0.0,
    )
    record = hits["results"][0]
    md = record.get("metadata", {})
    assert md.get("block_id") == "xxx1111122223333"
    assert md.get("kind") == "raw"
    assert md.get("layer") == "user-global"


def test_extracted_upsert_dedups_by_fact_hash(mem):
    from sspower_mem.mem.idx import extracted_upsert
    raw_meta = _base_meta("rawid000000000aa")
    fact_meta = {
        **raw_meta,
        "raw_id": "rawid000000000aa",
        "fact_index": 0,
        "fact_hash": "facthash00000000",
    }
    extracted_upsert(mem, "fact text", fact_meta, user_id="user:global")
    extracted_upsert(mem, "fact text", fact_meta, user_id="user:global")
    hits = mem.search(
        query=" ",
        filters={
            "user_id": "user:global",
            "AND": [
                {"raw_id": "rawid000000000aa"},
                {"kind": "extracted"},
                {"fact_hash": "facthash00000000"},
            ],
        },
        top_k=10,
        threshold=0.0,
    )
    assert len(hits.get("results", [])) == 1


def test_phase_c_filter_operators_are_safelisted():
    """Phase 0 open issue #6: Chroma silently maps contains/icontains→eq and
    drops NOT. Phase C MUST emit only exact-match + AND/OR.
    """
    forbidden = ("contains", "icontains", "$not", '"NOT"', "'NOT'")
    pkg = pathlib.Path(__file__).resolve().parent.parent / "sspower_mem"
    for fname in ("mem/idx.py",):
        src = (pkg / fname).read_text()
        for token in forbidden:
            assert token not in src, (
                f"{fname} contains forbidden Chroma operator literal {token!r}; "
                f"Phase 0 open issue #6 (silent fallback)."
            )


def test_entity_store_collection_not_created(mem):
    """Phase 0 §6 + open issue #2: infer=False never instantiates <coll>_entities."""
    from sspower_mem.mem.idx import raw_upsert
    raw_upsert(mem, "content", _base_meta("aaaa1111bbbb2222"), user_id="user:global")
    # Re-use Mem0's chroma client (creating a second PersistentClient at the same
    # path fails on Chroma's singleton check).
    client = mem.vector_store.client
    names = [c.name for c in client.list_collections()]
    assert "sspower_memories" in names
    assert "sspower_memories_entities" not in names
