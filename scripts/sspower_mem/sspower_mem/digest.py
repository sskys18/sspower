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
import re
from typing import Iterator


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
