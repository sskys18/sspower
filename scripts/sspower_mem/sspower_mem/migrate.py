"""Phase D — one-shot migration of legacy wiki + user-global memory.

Sources (spec §7.2):
  * <cwd>/.claude/wiki/sessions/*.md   → layer=episodic, scope=project:<hash>
  * <cwd>/.claude/wiki/decisions.md    → layer=decision, split on H2 or HR
  * <cwd>/.claude/wiki/gotchas.md      → layer=gotcha,   split on H2 or HR
  * ~/.claude/projects/*/memory/*.md   → layer=user-global, scope=user:global
                                          (MEMORY.md skipped — it is an index)

Each block is routed through cmd_add → append_block_or_skip → Mem0 raw + extracted.
Idempotency: same (scope, layer, content) yields same block_id; cmd_add returns
was_new=False on second invocation. No state diff after second run.
"""
from __future__ import annotations

import datetime
import json
import os
import pathlib
import re
from collections.abc import Iterator
from typing import TypedDict


class Block(TypedDict):
    layer: str
    content: str
    meta: dict[str, str]
    source_path: pathlib.Path


_MEMORY_INDEX_SKIP = frozenset({"MEMORY.md"})


def _iso_mtime(p: pathlib.Path) -> str:
    ts = datetime.datetime.fromtimestamp(p.stat().st_mtime, tz=datetime.timezone.utc)
    return ts.strftime("%Y-%m-%dT%H:%M:%SZ")


def _read_text(p: pathlib.Path) -> str:
    return p.read_text(encoding="utf-8")


def _stringify_meta(d: dict) -> dict[str, str]:
    """meta values must round-trip through digest JSON; coerce to str."""
    out: dict[str, str] = {}
    for k, v in d.items():
        if v is None:
            continue
        out[k] = v if isinstance(v, str) else json.dumps(v) if isinstance(v, (dict, list)) else str(v)
    return out


def iter_session_blocks(cwd: pathlib.Path) -> Iterator[Block]:
    """Enumerate .md files under <cwd>/.claude/wiki/sessions/.

    For each .md, attach paired .json metadata when present (sibling with same
    basename). Orphan .json (no .md sibling) is skipped — decision §1.
    """
    sessions_dir = cwd / ".claude" / "wiki" / "sessions"
    if not sessions_dir.is_dir():
        return
    for md in sorted(sessions_dir.glob("*.md")):
        if not md.is_file():
            continue
        meta: dict = {
            "migrated_from": str(md),
            "original_mtime": _iso_mtime(md),
        }
        sibling_json = md.with_suffix(".json")
        if sibling_json.is_file():
            meta["migrated_from_json"] = str(sibling_json)
            try:
                payload = json.loads(_read_text(sibling_json))
            except json.JSONDecodeError:
                payload = {}
            jmeta = payload.get("meta") or {}
            for key in (
                "session_id_full",
                "date",
                "time",
                "event",
                "project",
                "cwd",
                "git_branch",
                "model",
                "duration_active_min",
                "duration_wall_min",
            ):
                if key in jmeta:
                    meta[key] = jmeta[key]
            tokens = payload.get("tokens") or {}
            if "cost_estimate" in tokens:
                meta["cost_usd"] = tokens["cost_estimate"]
            stats = payload.get("stats") or {}
            if "total_tools" in stats:
                meta["total_tools"] = stats["total_tools"]
        yield Block(
            layer="episodic",
            content=_read_text(md),
            meta=_stringify_meta(meta),
            source_path=md,
        )
