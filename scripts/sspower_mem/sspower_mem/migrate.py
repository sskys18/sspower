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


_H2_LINE_RE = re.compile(r"^## [^#]", re.MULTILINE)
_HR_LINE_RE = re.compile(r"^---$", re.MULTILINE)


def _split_blocks(text: str) -> Iterator[str]:
    """Split a decisions.md / gotchas.md body per decision §3.

    Priority:
      1. If any ^## (H2) line present: split on H2 boundaries; each block is
         the H2 heading + body up to the next H2 (or EOF). Pre-H2 content
         (e.g. an H1 preamble) is dropped.
      2. Else if any ^---$ HR line present: split on HR boundaries; blocks
         are inter-rule text segments with whitespace stripped. Pre-first-HR
         content is dropped.
      3. Else: yield nothing.
    """
    if not text:
        return
    if _H2_LINE_RE.search(text):
        lines = text.split("\n")
        cur: list[str] = []
        in_block = False
        for ln in lines:
            if ln.startswith("## ") and not ln.startswith("###"):
                if in_block and cur:
                    yield "\n".join(cur).rstrip()
                cur = [ln]
                in_block = True
            elif in_block:
                cur.append(ln)
        if in_block and cur:
            yield "\n".join(cur).rstrip()
        return
    if _HR_LINE_RE.search(text):
        parts = re.split(r"(?m)^---$", text)
        # parts[0] is pre-first-HR — drop. Remainder: inter-rule segments.
        for seg in parts[1:]:
            stripped = seg.strip()
            if stripped:
                yield stripped
        return
    return


def _iter_split_file(
    path: pathlib.Path, layer: str
) -> Iterator[Block]:
    if not path.is_file():
        return
    text = _read_text(path)
    mtime = _iso_mtime(path)
    for content in _split_blocks(text):
        yield Block(
            layer=layer,
            content=content,
            meta=_stringify_meta(
                {"migrated_from": str(path), "original_mtime": mtime}
            ),
            source_path=path,
        )


def iter_doc_blocks(cwd: pathlib.Path) -> Iterator[Block]:
    """Enumerate decision + gotcha blocks from <cwd>/.claude/wiki/."""
    wiki = cwd / ".claude" / "wiki"
    yield from _iter_split_file(wiki / "decisions.md", "decision")
    yield from _iter_split_file(wiki / "gotchas.md", "gotcha")


def iter_user_global_blocks() -> Iterator[Block]:
    """Enumerate ~/.claude/projects/*/memory/*.md (skipping MEMORY.md index).

    Uses os.path.expanduser to resolve $HOME so tests can monkeypatch it.
    """
    home = pathlib.Path(os.path.expanduser("~"))
    projects_root = home / ".claude" / "projects"
    if not projects_root.is_dir():
        return
    for proj_dir in sorted(projects_root.iterdir()):
        mem_dir = proj_dir / "memory"
        if not mem_dir.is_dir():
            continue
        for md in sorted(mem_dir.glob("*.md")):
            if md.name in _MEMORY_INDEX_SKIP:
                continue
            if not md.is_file():
                continue
            yield Block(
                layer="user-global",
                content=_read_text(md),
                meta=_stringify_meta(
                    {"migrated_from": str(md), "original_mtime": _iso_mtime(md)}
                ),
                source_path=md,
            )


def _iter_all_blocks(cwd: pathlib.Path) -> Iterator[tuple[str, Block]]:
    """Yield (scope, block) pairs across all three sources."""
    for blk in iter_session_blocks(cwd):
        yield "project", blk
    for blk in iter_doc_blocks(cwd):
        yield "project", blk
    for blk in iter_user_global_blocks():
        yield "user", blk


def _plan_entry(scope: str, blk: Block) -> dict:
    return {
        "scope": scope,
        "layer": blk["layer"],
        "source": str(blk["source_path"]),
        "content_bytes": len(blk["content"].encode("utf-8")),
        "preview": blk["content"][:80].replace("\n", " "),
    }


def run_migrate(
    *,
    cwd: pathlib.Path,
    dry_run: bool = False,
    add_fn=None,
) -> dict:
    """Orchestrate migration. Returns a JSON-serializable summary.

    Parameters:
      cwd       — project root (already canonicalized by caller).
      dry_run   — when True, no state writes; returns plan only.
      add_fn    — injection seam for tests; default uses real cmd_add.
                  Signature: add_fn(scope, layer, content, meta, cwd) -> (rc, eff_id, was_new)
                  Returns rc=0/10 on success-paths; rc=20/30 on hard failure.
    """
    totals = {
        "project_episodic": 0,
        "project_decision": 0,
        "project_gotcha": 0,
        "user_global": 0,
    }
    sources: list[dict] = []
    results: list[dict] = []

    for scope, blk in _iter_all_blocks(cwd):
        # Normalize bucket name: user-global block uses "user_global" bucket.
        bucket = "user_global" if blk["layer"] == "user-global" else f"project_{blk['layer']}"
        totals[bucket] = totals.get(bucket, 0) + 1
        sources.append(_plan_entry(scope, blk))
        if dry_run:
            continue
        if add_fn is None:  # pragma: no cover — defensive; real callers always supply
            raise RuntimeError("add_fn required when dry_run=False")
        rc, eff_id, was_new = add_fn(scope, blk["layer"], blk["content"], blk["meta"], cwd)
        results.append({
            "source": str(blk["source_path"]),
            "scope": scope, "layer": blk["layer"],
            "rc": rc, "block_id": eff_id, "new": was_new,
        })

    out = {"totals": totals, "sources": sources}
    if not dry_run:
        out["results"] = results
        out["rc"] = max((r["rc"] for r in results), default=0)
    return out
