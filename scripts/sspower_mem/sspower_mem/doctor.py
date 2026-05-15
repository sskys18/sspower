"""Phase C doctor: user-scope bootstrap, health, entity-store canary."""
from __future__ import annotations

import json
import os
import pathlib

from sspower_mem.io import safe_append_strict, safe_makedirs_strict, safe_write_strict
from sspower_mem.scope import user_sspower_dir


def bootstrap() -> dict:
    """Create user-scope dirs, lock, config, chroma persist dir. Phase C also
    runs an index round-trip + bridge probe to warm caches and surface failures.
    """
    home = pathlib.Path.home()
    base = user_sspower_dir()
    idx = base / "idx"
    safe_makedirs_strict(idx, home)

    lock = idx / ".lock"
    safe_append_strict(lock, "", base, home)

    chroma_dir = idx / "chroma"
    safe_makedirs_strict(chroma_dir, home)

    config_path = idx / "config.json"
    safe_write_strict(
        config_path,
        json.dumps({
            "version": "0.2.0", "phase": "C",
            "index": {
                "enabled": True, "backend": "mem0+chroma",
                "embedder": "model2vec/potion-base-8M",
            },
        }, indent=2),
        base, home,
    )

    index_probe = _probe_index(chroma_dir=chroma_dir, history_db=idx / "history.db")
    bridge_probe = _probe_bridge()

    status = "ok" if (index_probe["ok"] and bridge_probe["ok"]) else "degraded"
    return {
        "status": status,
        "base": str(base),
        "probe": {"index": index_probe, "bridge": bridge_probe},
    }


def _probe_index(chroma_dir: pathlib.Path, history_db: pathlib.Path) -> dict:
    """Memory.add(infer=False)+search round-trip; warms m2v + chroma."""
    try:
        import sspower_mem.mem  # noqa: F401
        from sspower_mem.mem.factory import build_memory
    except ImportError as e:
        return {"ok": False, "stage": "import", "err": str(e)}

    try:
        mem = build_memory(
            scope_id="user:global",
            idx_dir=chroma_dir.parent,
            chroma_dir=chroma_dir,
            history_db_path=history_db,
        )
        add_resp = mem.add(
            messages=[{"role": "user", "content": "bootstrap probe"}],
            user_id="user:global",
            metadata={
                "block_id": "bootstrap-probe", "kind": "raw",
                "layer": "user-global", "scope": "user:global",
                "ts": "1970-01-01T00:00:00Z",
            },
            infer=False,
        )
        mem.search(query="probe", filters={"user_id": "user:global"}, top_k=1, threshold=0.0)
        # Clean up — the probe record must not pollute search results.
        for r in (add_resp or {}).get("results", []) or []:
            try:
                mem.delete(memory_id=r["id"])
            except Exception:
                pass
    except Exception as e:
        return {"ok": False, "stage": "round_trip", "err": str(e)}
    return {"ok": True}


def _probe_bridge() -> dict:
    """Run a `complete --json` round-trip against codex-bridge.

    Phase C spec §9: doctor --bootstrap verifies the bridge end-to-end.
    Honors SSPOWER_BRIDGE_PATH for tests.
    """
    try:
        from sspower_mem.mem.extract import ExtractFailed, bridge_extract_facts
        bridge_extract_facts("bootstrap probe text", timeout_ms=10_000)
        return {"ok": True}
    except ExtractFailed as e:
        return {"ok": False, "stage": "bridge", "err": str(e)}
    except Exception as e:
        return {"ok": False, "stage": "bridge", "err": str(e)}


def health() -> dict:
    base = user_sspower_dir()
    idx = base / "idx"
    lock = idx / ".lock"
    digest = base / "digest.md"
    chroma_dir = idx / "chroma"

    h = {
        "phase": "C",
        "lock_writable": lock.exists() and _writable(lock),
        "digest_writable": _writable(digest) if digest.exists() else _writable(base),
        "chroma_reachable": False,
        "entity_store_present": False,
    }

    # Chroma's PersistentClient enforces singleton-per-path with strict settings
    # check; if another client is already bound to the path, opening a fresh one
    # raises. Probe via filesystem inspection (chroma.sqlite3 + per-collection
    # dirs) instead — robust + no client conflicts.
    chroma_sqlite = chroma_dir / "chroma.sqlite3"
    if chroma_sqlite.exists():
        h["chroma_reachable"] = True
        # Per-collection HNSW dirs sit under chroma_dir/<uuid>/; collection NAMES
        # live in chroma.sqlite3. Read them via direct sqlite (no chromadb client).
        try:
            import sqlite3
            con = sqlite3.connect(str(chroma_sqlite))
            try:
                rows = con.execute("SELECT name FROM collections").fetchall()
                names = {r[0] for r in rows}
                h["entity_store_present"] = "sspower_memories_entities" in names
                h["chroma_reachable"] = "sspower_memories" in names
            finally:
                con.close()
        except Exception:
            pass

    return h


def _writable(path: pathlib.Path) -> bool:
    try:
        return os.access(path, os.W_OK)
    except OSError:
        return False
