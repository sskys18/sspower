"""Phase D migrate tests."""
from __future__ import annotations

import hashlib
import json
import pathlib

import pytest


def test_project_scope_hash_matches_spec(tmp_path):
    """scope_id('project', realpath(cwd)) must = f'project:{sha1[:16]}'."""
    from sspower_mem.scope import canonicalize_cwd, scope_id

    real = canonicalize_cwd(str(tmp_path))
    sid = scope_id("project", real)
    expected_hash = hashlib.sha1(str(real).encode()).hexdigest()[:16]
    assert sid == f"project:{expected_hash}"


def test_user_scope_is_global():
    from sspower_mem.scope import scope_id

    assert scope_id("user", None) == "user:global"


def _make_session_pair(sessions_dir: pathlib.Path, basename: str, *, with_json: bool = True):
    sessions_dir.mkdir(parents=True, exist_ok=True)
    md = sessions_dir / f"{basename}.md"
    md.write_text(
        f"# {basename} session\n\n"
        f"- **Project:** `sspower`\n"
        f"- **Branch:** `main`\n\n"
        f"## Stats\n- Tools: 5 calls\n",
        encoding="utf-8",
    )
    if with_json:
        j = sessions_dir / f"{basename}.json"
        j.write_text(
            json.dumps(
                {
                    "meta": {
                        "session_id_full": f"{basename}-uuid",
                        "date": "2026-04-27",
                        "time": "18:57",
                        "event": "SessionEnd",
                        "project": "sspower",
                        "cwd": str(sessions_dir.parent.parent.parent),
                        "git_branch": "main",
                        "model": "claude-opus-4-7",
                        "duration_active_min": 6.2,
                        "duration_wall_min": 6.2,
                    },
                    "tokens": {"cost_estimate": 2.26},
                    "stats": {"total_tools": 5},
                    "conversation": [{"type": "user", "ts": "x", "text": "y"}],
                }
            ),
            encoding="utf-8",
        )
    return md


def test_iter_session_blocks_paired_md_and_json(tmp_path):
    from sspower_mem.migrate import iter_session_blocks

    cwd = tmp_path / "repo"
    sessions = cwd / ".claude" / "wiki" / "sessions"
    _make_session_pair(sessions, "260427_18-57_SessionEnd", with_json=True)

    blocks = list(iter_session_blocks(cwd))
    assert len(blocks) == 1
    blk = blocks[0]
    assert blk["layer"] == "episodic"
    assert blk["content"].startswith("# 260427_18-57_SessionEnd session")
    assert blk["meta"]["migrated_from"].endswith("260427_18-57_SessionEnd.md")
    assert blk["meta"]["migrated_from_json"].endswith("260427_18-57_SessionEnd.json")
    assert blk["meta"]["session_id_full"] == "260427_18-57_SessionEnd-uuid"
    assert blk["meta"]["model"] == "claude-opus-4-7"
    assert blk["meta"]["duration_active_min"] == "6.2"
    assert blk["meta"]["cost_usd"] == "2.26"
    # original_mtime present and ISO-8601 Z
    assert blk["meta"]["original_mtime"].endswith("Z")


def test_iter_session_blocks_md_without_json_no_provenance(tmp_path):
    from sspower_mem.migrate import iter_session_blocks

    cwd = tmp_path / "repo"
    sessions = cwd / ".claude" / "wiki" / "sessions"
    _make_session_pair(sessions, "260512_21-22_SessionEnd", with_json=False)

    blocks = list(iter_session_blocks(cwd))
    assert len(blocks) == 1
    blk = blocks[0]
    assert blk["meta"]["migrated_from"].endswith("260512_21-22_SessionEnd.md")
    assert "migrated_from_json" not in blk["meta"]
    assert "session_id_full" not in blk["meta"]
    assert "original_mtime" in blk["meta"]


def test_iter_session_blocks_empty_dir(tmp_path):
    from sspower_mem.migrate import iter_session_blocks

    cwd = tmp_path / "repo"
    (cwd / ".claude" / "wiki" / "sessions").mkdir(parents=True)
    assert list(iter_session_blocks(cwd)) == []


def test_iter_session_blocks_missing_wiki_dir(tmp_path):
    from sspower_mem.migrate import iter_session_blocks

    cwd = tmp_path / "repo"
    cwd.mkdir()
    assert list(iter_session_blocks(cwd)) == []


def test_iter_session_blocks_skips_orphan_json(tmp_path):
    """A .json without paired .md is NOT ingested (decision §1)."""
    from sspower_mem.migrate import iter_session_blocks

    cwd = tmp_path / "repo"
    sessions = cwd / ".claude" / "wiki" / "sessions"
    sessions.mkdir(parents=True)
    (sessions / "orphan.json").write_text(json.dumps({"meta": {"x": 1}}), encoding="utf-8")
    assert list(iter_session_blocks(cwd)) == []
