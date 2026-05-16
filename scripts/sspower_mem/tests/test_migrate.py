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


def test_split_h2_blocks_basic(tmp_path):
    from sspower_mem.migrate import _split_blocks

    text = (
        "# Decisions\n\nIntro paragraph dropped.\n\n"
        "## Use Postgres\nReason: ACID needed.\n\n"
        "## Use Redis\nReason: cache layer.\n"
    )
    blocks = list(_split_blocks(text))
    assert blocks == [
        "## Use Postgres\nReason: ACID needed.",
        "## Use Redis\nReason: cache layer.",
    ]


def test_split_hr_blocks_basic(tmp_path):
    from sspower_mem.migrate import _split_blocks

    text = (
        "# Gotchas\n\nPreamble dropped.\n\n"
        "---\n\nFirst gotcha body.\n\n"
        "---\n\nSecond gotcha body.\n"
    )
    blocks = list(_split_blocks(text))
    assert blocks == ["First gotcha body.", "Second gotcha body."]


def test_split_h2_wins_when_both_present(tmp_path):
    from sspower_mem.migrate import _split_blocks

    text = "## Heading\nBody with --- inside text.\n"
    blocks = list(_split_blocks(text))
    assert blocks == ["## Heading\nBody with --- inside text."]


def test_split_stub_file_no_separator_yields_zero_blocks(tmp_path):
    from sspower_mem.migrate import _split_blocks

    text = "# Decisions\n\nDescriptive header only, no entries yet.\n"
    assert list(_split_blocks(text)) == []


def test_split_empty_file(tmp_path):
    from sspower_mem.migrate import _split_blocks

    assert list(_split_blocks("")) == []


def test_split_h2_skips_empty_headings(tmp_path):
    """`## ` with no heading text (trailing space only) must NOT yield a
    junk one-line block. Regex `^## \\S` enforces a non-whitespace char."""
    from sspower_mem.migrate import _split_blocks

    # `## ` is empty heading; `## Real` is valid.
    text = "## \nignored body\n## Real\nreal body\n"
    blocks = list(_split_blocks(text))
    assert blocks == ["## Real\nreal body"]


def test_split_h3_ignored(tmp_path):
    """H3 (`### `) must not be treated as a block separator."""
    from sspower_mem.migrate import _split_blocks

    text = "## Top\nbody\n### Sub-section\nstill same block\n"
    blocks = list(_split_blocks(text))
    assert blocks == ["## Top\nbody\n### Sub-section\nstill same block"]


def test_iter_doc_blocks_decisions_and_gotchas(tmp_path):
    from sspower_mem.migrate import iter_doc_blocks

    wiki = tmp_path / "repo" / ".claude" / "wiki"
    wiki.mkdir(parents=True)
    (wiki / "decisions.md").write_text(
        "# Decisions\n## D1\nbody1\n## D2\nbody2\n", encoding="utf-8"
    )
    (wiki / "gotchas.md").write_text(
        "# Gotchas\n---\nG1 body\n---\nG2 body\n", encoding="utf-8"
    )

    blocks = list(iter_doc_blocks(tmp_path / "repo"))
    by_layer: dict[str, list[str]] = {}
    for b in blocks:
        by_layer.setdefault(b["layer"], []).append(b["content"])
    assert by_layer["decision"] == ["## D1\nbody1", "## D2\nbody2"]
    assert by_layer["gotcha"] == ["G1 body", "G2 body"]
    # provenance + mtime present
    for b in blocks:
        assert b["meta"]["migrated_from"].endswith((".md",))
        assert b["meta"]["original_mtime"].endswith("Z")


def test_iter_doc_blocks_stub_repo_yields_nothing(tmp_path):
    """Regression: this repo's decisions.md / gotchas.md are H1-only stubs.
    Migrate must no-op cleanly without writing the H1 preamble."""
    from sspower_mem.migrate import iter_doc_blocks

    wiki = tmp_path / "repo" / ".claude" / "wiki"
    wiki.mkdir(parents=True)
    (wiki / "decisions.md").write_text(
        "# Decisions\n\nArchitectural calls go here.\n", encoding="utf-8"
    )
    (wiki / "gotchas.md").write_text(
        "# Gotchas\n\nFootguns go here.\n", encoding="utf-8"
    )
    assert list(iter_doc_blocks(tmp_path / "repo")) == []


def test_iter_doc_blocks_missing_files(tmp_path):
    from sspower_mem.migrate import iter_doc_blocks

    cwd = tmp_path / "repo"
    cwd.mkdir()
    assert list(iter_doc_blocks(cwd)) == []


def test_iter_user_global_blocks_skips_memory_index(tmp_path, monkeypatch):
    from sspower_mem.migrate import iter_user_global_blocks

    fake_home = tmp_path / "home"
    proj = fake_home / ".claude" / "projects" / "-Users-x-some-project" / "memory"
    proj.mkdir(parents=True)
    (proj / "MEMORY.md").write_text(
        "- [feedback](feedback_x.md) — index entry\n", encoding="utf-8"
    )
    (proj / "feedback_x.md").write_text(
        "---\nname: feedback-x\ntype: feedback\n---\nBody A\n", encoding="utf-8"
    )
    (proj / "user_role.md").write_text("Body B\n", encoding="utf-8")
    monkeypatch.setenv("HOME", str(fake_home))

    blocks = list(iter_user_global_blocks())
    assert len(blocks) == 2
    sources = {b["source_path"].name for b in blocks}
    assert sources == {"feedback_x.md", "user_role.md"}
    assert all(b["layer"] == "user-global" for b in blocks)
    # MEMORY.md is the index — skipped.
    assert "MEMORY.md" not in sources


def test_iter_user_global_blocks_no_projects_dir(tmp_path, monkeypatch):
    from sspower_mem.migrate import iter_user_global_blocks

    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    assert list(iter_user_global_blocks()) == []


def test_iter_user_global_blocks_multiple_projects(tmp_path, monkeypatch):
    from sspower_mem.migrate import iter_user_global_blocks

    fake_home = tmp_path / "home"
    for name in ("project_a", "project_b"):
        d = fake_home / ".claude" / "projects" / name / "memory"
        d.mkdir(parents=True)
        (d / "MEMORY.md").write_text("idx\n", encoding="utf-8")
        (d / "note.md").write_text(f"Note from {name}\n", encoding="utf-8")
    monkeypatch.setenv("HOME", str(fake_home))

    blocks = list(iter_user_global_blocks())
    contents = sorted(b["content"] for b in blocks)
    assert contents == ["Note from project_a\n", "Note from project_b\n"]


def test_run_migrate_dry_run_returns_plan(tmp_path, monkeypatch):
    from sspower_mem.migrate import run_migrate

    cwd = tmp_path / "repo"
    sessions = cwd / ".claude" / "wiki" / "sessions"
    _make_session_pair(sessions, "260427_18-57_SessionEnd", with_json=True)
    (cwd / ".claude" / "wiki" / "decisions.md").write_text(
        "## D1\nbody\n", encoding="utf-8"
    )
    (cwd / ".claude" / "wiki" / "gotchas.md").write_text(
        "# Gotchas\n", encoding="utf-8"  # stub — no blocks
    )

    fake_home = tmp_path / "home"
    proj = fake_home / ".claude" / "projects" / "px" / "memory"
    proj.mkdir(parents=True)
    (proj / "MEMORY.md").write_text("idx\n", encoding="utf-8")
    (proj / "note.md").write_text("hello\n", encoding="utf-8")
    monkeypatch.setenv("HOME", str(fake_home))

    plan = run_migrate(cwd=cwd, dry_run=True)
    assert plan["totals"] == {
        "project_episodic": 1,
        "project_decision": 1,
        "project_gotcha": 0,
        "user_global": 1,
    }
    # No writes anywhere
    assert not (cwd / ".claude" / "wiki" / "digest.md").exists()
    assert not (fake_home / ".claude" / "sspower").exists()
    assert "sources" in plan and len(plan["sources"]) == 3  # 3 source-blocks reported


def test_run_migrate_dry_run_handles_empty_repo(tmp_path, monkeypatch):
    from sspower_mem.migrate import run_migrate

    cwd = tmp_path / "repo"
    cwd.mkdir()
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    plan = run_migrate(cwd=cwd, dry_run=True)
    assert plan["totals"] == {
        "project_episodic": 0,
        "project_decision": 0,
        "project_gotcha": 0,
        "user_global": 0,
    }
