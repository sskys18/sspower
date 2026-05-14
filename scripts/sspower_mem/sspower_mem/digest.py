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
import warnings
from typing import Iterator, TypeAlias

from sspower_mem.io import safe_append_strict, safe_makedirs_strict, safe_read_strict


_HEADER_RE = re.compile(
    r"^## (?P<ts>\S+) · (?P<scope>[^·]+?) · (?P<layer>[^·]+?) · (?P<id>\S+)\s*$"
)
_META_RE = re.compile(r"^\[meta\] (.+)$")
_SEPARATOR = "\n---\n\n"
_BLOCK_BOUNDARY_RE = re.compile(
    r"\n---\n\n(?=## \S+ · [^·]+? · [^·]+? · \S+\s*(?:\n|$)|\s*\Z)"
)
_INJECTION_RE = re.compile(r"(?:^|\n)---\n\n## \S+ · [^·]+? · [^·]+? · \S+\s*(?:\n|$)")

DigestSource: TypeAlias = tuple[pathlib.Path, pathlib.Path, str, frozenset[str]]


def _validate_digest_path_under_trust_root(
    digest_path: pathlib.Path,
    trust_root: pathlib.Path,
) -> None:
    try:
        rel = digest_path.relative_to(trust_root)
    except ValueError as e:
        raise OSError(f"digest path {digest_path} not under trust_root {trust_root}") from e

    if not rel.parts:
        raise OSError(f"digest path {digest_path} must name a file below trust_root {trust_root}")

    for part in rel.parts:
        if part in ("", ".", ".."):
            raise OSError(f"digest path {digest_path} contains traversal component {part!r}")


def _source_parts(source: DigestSource) -> DigestSource:
    if not (isinstance(source, tuple) and len(source) == 4):
        raise TypeError(
            "digest source must be "
            "(digest_path, parent_anchor, expected_scope, allowed_layers) tuple, "
            f"got {type(source).__name__}"
        )
    return source


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
    """Render one block. Caller appends to digest.md atomically.

    Callers must scrub or escape content containing the reserved digest boundary
    before passing it here.
    """
    if _INJECTION_RE.search(content):
        raise ValueError("content contains reserved digest boundary pattern; refusing to append")
    body = content
    meta_line = "[meta] " + json.dumps(meta, separators=(",", ":"), sort_keys=True)
    return f"## {ts} · {scope} · {layer} · {block_id}\n{meta_line}\n{body}{_SEPARATOR}"


def parse_blocks(text: str) -> Iterator[dict]:
    """Yield {ts, scope, layer, id, meta, content} per block.

    Tolerant: skips malformed blocks rather than raising.
    """
    raw_blocks = _BLOCK_BOUNDARY_RE.split(text)
    for raw in raw_blocks:
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


def _existing_blocks_by_base(
    digest_path: pathlib.Path,
    parent_anchor: pathlib.Path,
    expected_scope: str,
    allowed_layers: frozenset[str],
) -> dict[str, list[dict]]:
    """Map base_id (with any _dup<N> stripped) to blocks already present."""
    by_base: dict[str, list[dict]] = {}
    for blk in _load_all_blocks([
        (digest_path, parent_anchor, expected_scope, allowed_layers)
    ]):
        bid = blk["id"]
        base = bid.split("_dup", 1)[0]
        by_base.setdefault(base, []).append(blk)
    return by_base


def append_block_or_skip(
    digest_path: pathlib.Path,
    trust_root: pathlib.Path,
    parent_anchor: pathlib.Path,
    scope: str,
    layer: str,
    content: str,
    meta: dict,
    ts: str | None = None,
) -> tuple[str, bool]:
    """Append a block using collision-safe ids.

    Returns (effective_id, was_new). was_new=False means an identical block
    already existed and no write was performed.
    """
    _validate_digest_path_under_trust_root(digest_path, trust_root)
    safe_makedirs_strict(trust_root, parent_anchor)

    base_id = compute_id(scope, layer, content)
    existing = _existing_blocks_by_base(digest_path, parent_anchor, scope, frozenset({layer}))
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
    safe_append_strict(digest_path, block, trust_root, parent_anchor)
    return effective_id, True


_TOKEN_RE = re.compile(r"[a-z0-9]+")


def _tokenize(query: str) -> list[str]:
    """Lowercase, split on word boundaries, drop tokens < 3 chars.
    Falls back to the literal query as one token if zero remain.
    """
    toks = [t for t in _TOKEN_RE.findall(query.lower()) if len(t) >= 3]
    return toks if toks else [query.lower()]


def _load_all_blocks(digest_sources: list[DigestSource]) -> list[dict]:
    blocks: list[dict] = []
    for source in digest_sources:
        p, read_root, expected_scope, allowed_layers = _source_parts(source)
        try:
            text = safe_read_strict(p, read_root)
        except FileNotFoundError:
            continue
        for blk in parse_blocks(text):
            if blk["scope"] != expected_scope:
                warnings.warn(
                    "dropped digest block "
                    f"{blk['id']!r} from {p}: scope {blk['scope']!r} "
                    f"does not match source scope {expected_scope!r}",
                    RuntimeWarning,
                    stacklevel=2,
                )
                continue
            if blk["layer"] not in allowed_layers:
                warnings.warn(
                    "dropped digest block "
                    f"{blk['id']!r} from {p}: layer {blk['layer']!r} "
                    f"is not allowed for source scope {expected_scope!r}",
                    RuntimeWarning,
                    stacklevel=2,
                )
                continue
            blocks.append(blk)
    return blocks


def grep_search(
    digest_paths: list[DigestSource],
    query: str,
    top_k: int = 8,
    layer_filter: list[str] | None = None,
) -> list[dict]:
    """Deterministic grep scoring per spec §6.1 read path."""
    tokens = _tokenize(query)
    candidates: list[tuple[float, dict]] = []
    for blk in _load_all_blocks(digest_paths):
        if layer_filter and blk["layer"] not in layer_filter:
            continue
        text_lower = blk["content"].lower()
        hits = sum(text_lower.count(t) for t in tokens)
        if hits == 0:
            continue
        raw = hits / max(1, len(blk["content"]) / 1000)
        candidates.append((raw, blk))
    if not candidates:
        return []
    max_raw = max(r for r, _ in candidates)
    if max_raw == 0:
        return []
    scored = [
        {
            "id": b["id"],
            "source": "digest-grep",
            "score": r / max_raw,
            "content": b["content"],
            "scope": b["scope"],
            "layer": b["layer"],
            "ts": b["ts"],
        }
        for r, b in candidates
    ]
    scored.sort(key=lambda h: (-h["score"], -_ts_key(h["ts"]), h["id"]))
    return scored[:top_k]


def recent(
    digest_paths: list[DigestSource],
    top_k: int = 8,
    layer_filter: list[str] | None = None,
) -> list[dict]:
    """Top-k newest blocks by ts. Score = linear position normalized."""
    blocks = _load_all_blocks(digest_paths)
    if layer_filter:
        blocks = [b for b in blocks if b["layer"] in layer_filter]
    if not blocks:
        return []
    blocks.sort(key=lambda b: (-_ts_key(b["ts"]), _scope_priority(b["scope"]), b["id"]))
    chosen = blocks[:top_k]
    n = len(chosen)
    scores = (
        [1.0] * n
        if n > 0 and len({b["ts"] for b in chosen}) == 1
        else [1.0 if n == 1 else 1.0 - (i / (n - 1)) for i in range(n)]
    )
    out: list[dict] = []
    for score, b in zip(scores, chosen):
        out.append({
            "id": b["id"],
            "source": "digest-recent",
            "score": score,
            "content": b["content"],
            "scope": b["scope"],
            "layer": b["layer"],
            "ts": b["ts"],
        })
    return out


def _ts_key(ts: str) -> int:
    """Sortable int from an ISO timestamp (epoch seconds). Returns 0 on parse failure."""
    try:
        return int(
            datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")
            .replace(tzinfo=datetime.timezone.utc)
            .timestamp()
        )
    except ValueError:
        return 0


def _scope_priority(scope: str) -> int:
    return 0 if scope.startswith("project:") else 1
