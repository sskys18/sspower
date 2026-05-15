"""Idempotent Mem0 upserts. Caller-driven dedup via metadata.id + metadata.kind.

Per docs/specs/2026-05-13-index-backend-integration-design.md §6.1 D11 and
docs/specs/2026-05-13-index-provider-registration.md §8.

Memory.search at mem0 @ 70bc9e51 takes user_id INSIDE filters; top_k (not limit).
"""
from __future__ import annotations


def _exists_raw(mem, effective_id: str, user_id: str) -> bool:
    hits = mem.search(
        query=" ",
        filters={"user_id": user_id, "AND": [{"block_id": effective_id}, {"kind": "raw"}]},
        top_k=1,
        threshold=0.0,
    )
    return bool(hits.get("results"))


def _exists_extracted(mem, raw_id: str, fact_hash: str, user_id: str) -> bool:
    hits = mem.search(
        query=" ",
        filters={
            "user_id": user_id,
            "AND": [{"raw_id": raw_id}, {"kind": "extracted"}, {"fact_hash": fact_hash}],
        },
        top_k=1,
        threshold=0.0,
    )
    return bool(hits.get("results"))


def raw_upsert(mem, content: str, meta: dict, *, user_id: str) -> bool:
    """Insert raw record if not present (by metadata.block_id + metadata.kind=raw).

    meta MUST contain "block_id" (sspower's stable id). We use `block_id` rather
    than `id` because Mem0 reserves `id` for its own UUID primary key — caller-supplied
    `id` is stripped from the persisted metadata at this upstream SHA.

    Returns True if a write was performed, False if skipped.
    """
    payload_meta = {**meta, "kind": "raw"}
    if _exists_raw(mem, payload_meta["block_id"], user_id):
        return False
    mem.add(
        messages=[{"role": "user", "content": content}],
        user_id=user_id,
        metadata=payload_meta,
        infer=False,
    )
    return True


def extracted_upsert(mem, fact_text: str, meta: dict, *, user_id: str) -> bool:
    """Insert extracted-fact record if not present (by raw_id + kind + fact_hash).

    Returns True if a write was performed, False if skipped.
    """
    payload_meta = {**meta, "kind": "extracted"}
    if _exists_extracted(mem, payload_meta["raw_id"], payload_meta["fact_hash"], user_id):
        return False
    mem.add(
        messages=[{"role": "user", "content": fact_text}],
        user_id=user_id,
        metadata=payload_meta,
        infer=False,
    )
    return True
