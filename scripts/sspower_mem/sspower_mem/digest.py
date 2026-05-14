"""Digest block: id, format, parse, append, search.

Block format (spec §6.4):
    ## <ISO-8601-ts> · <scope> · <layer> · <id>
    [meta] <JSON-encoded dict>
    <content>

    ---

Meta is serialized as a single JSON object on its own line, prefixed with
`[meta] `. JSON handles commas / equals / quotes in values losslessly,
fixing the unsafe `key=value, key=value` shape from spec v8.
"""
from __future__ import annotations

import datetime
import hashlib
import json
import pathlib
import re
from typing import Iterator

from sspower_mem.io import safe_append_strict, safe_makedirs_strict


_HEADER_RE = re.compile(
    r"^## (?P<ts>\S+) · (?P<scope>[^·]+?) · (?P<layer>[^·]+?) · (?P<id>\S+)\s*$"
)
_META_RE = re.compile(r"^\[meta\] (.+)$")
_SEPARATOR = "\n---\n\n"


def compute_id(scope: str, layer: str, content: str) -> str:
    """16-char SHA-1 over scope|layer|content (spec §6.1, v4 widened from 8)."""
    return hashlib.sha1(f"{scope}|{layer}|{content}".encode("utf-8")).hexdigest()[:16]


def iso_now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def format_block(
    ts: str,
    scope: str,
    layer: str,
    block_id: str,
    meta: dict,
    content: str,
) -> str:
    """Render one block. Caller appends to digest.md atomically."""
    body = content.rstrip("\n")
    meta_line = "[meta] " + json.dumps(meta, separators=(",", ":"), sort_keys=True)
    return f"## {ts} · {scope} · {layer} · {block_id}\n{meta_line}\n{body}{_SEPARATOR}"


def parse_blocks(text: str) -> Iterator[dict]:
    """Yield {ts, scope, layer, id, meta, content} per block.

    Tolerant: skips malformed blocks rather than raising.
    """
    raw_blocks = text.split(_SEPARATOR)
    for raw in raw_blocks:
        raw = raw.strip("\n")
        if not raw:
            continue
        lines = raw.split("\n")
        if not lines:
            continue
        h = _HEADER_RE.match(lines[0])
        if not h:
            continue
        meta: dict = {}
        body_start = 1
        if len(lines) > 1:
            m = _META_RE.match(lines[1])
            if m:
                try:
                    meta = json.loads(m.group(1))
                except json.JSONDecodeError:
                    meta = {}
                body_start = 2
        body = "\n".join(lines[body_start:])
        yield {
            "ts": h.group("ts"),
            "scope": h.group("scope"),
            "layer": h.group("layer"),
            "id": h.group("id"),
            "meta": meta,
            "content": body,
        }


def _existing_blocks_by_base(digest_path: pathlib.Path) -> dict[str, list[dict]]:
    """Map base_id (with any _dup<N> stripped) to blocks already present."""
    if not digest_path.exists():
        return {}
    by_base: dict[str, list[dict]] = {}
    for blk in parse_blocks(digest_path.read_text(encoding="utf-8")):
        bid = blk["id"]
        base = bid.split("_dup", 1)[0]
        by_base.setdefault(base, []).append(blk)
    return by_base


def append_block_or_skip(
    digest_path: pathlib.Path,
    trust_root: pathlib.Path,
    scope: str,
    layer: str,
    content: str,
    meta: dict,
    ts: str | None = None,
    *,
    parent_anchor: pathlib.Path | None = None,
) -> tuple[str, bool]:
    """Append a block using collision-safe ids.

    Returns (effective_id, was_new). was_new=False means an identical block
    already existed and no write was performed.
    """
    if parent_anchor is not None:
        safe_makedirs_strict(trust_root, parent_anchor)

    base_id = compute_id(scope, layer, content)
    existing = _existing_blocks_by_base(digest_path)
    for blk in existing.get(base_id, []):
        if blk["content"].rstrip("\n") == content.rstrip("\n"):
            return blk["id"], False

    if base_id in existing:
        suffixes = [
            int(b["id"].split("_dup", 1)[1])
            for b in existing[base_id]
            if "_dup" in b["id"] and b["id"].split("_dup", 1)[1].isdigit()
        ]
        n = max(suffixes, default=0) + 1
        effective_id = f"{base_id}_dup{n}"
    else:
        effective_id = base_id

    block = format_block(
        ts=ts or iso_now(),
        scope=scope,
        layer=layer,
        block_id=effective_id,
        meta=meta,
        content=content,
    )
    safe_append_strict(digest_path, block, trust_root)
    return effective_id, True
