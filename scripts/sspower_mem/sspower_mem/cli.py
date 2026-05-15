"""CLI entry point.

Exit codes per spec section 6.1:
  0 = ok
 10 = degraded (Phase A: not yet triggered; reserved for B/C)
 20 = HARD (digest unwritable / traversal / outside trust_root)
 30 = dep missing (Phase A: bootstrap not run / unexpected import error)
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import sys

from sspower_mem.digest import (
    DigestSource,
    _load_all_blocks,
    append_block_or_skip,
    grep_search,
    recent,
)
from sspower_mem.doctor import bootstrap, health
from sspower_mem.io import _assert_regular_private_file, safe_read_strict
from sspower_mem.lock import acquire_lock
from sspower_mem.scope import (
    canonicalize_cwd,
    digest_path,
    parent_anchor,
    scope_id,
    trust_root,
    user_sspower_dir,
)

PROJECT_LAYERS = frozenset({"episodic", "decision", "gotcha"})
USER_LAYERS = frozenset({"user-global"})
_CONTROL_RE = re.compile(r"[\x00-\x08\x0b-\x1f\x7f-\x9f]")
MAX_CONTENT_FILE_BYTES = 8 * 1024 * 1024


def _sanitize_for_terminal(s: str) -> str:
    return _CONTROL_RE.sub("?", s)


def _resolve_cwd(args: argparse.Namespace) -> pathlib.Path | None:
    if not getattr(args, "cwd", None):
        # Project-scope without --cwd: fall back to os.getcwd() for interactive use.
        if getattr(args, "scope", "") in ("project", "project,user"):
            return canonicalize_cwd(os.getcwd())
        return None
    return canonicalize_cwd(args.cwd)


def _parse_meta(meta_args: list[str]) -> dict:
    out: dict = {}
    for entry in meta_args or []:
        if "=" not in entry:
            raise ValueError(f"--meta entry must be key=value, got: {entry}")
        key, value = entry.split("=", 1)
        out[key.strip()] = value.strip()
    return out


def _read_content_file(path: str) -> str:
    abs_path = pathlib.Path(os.path.abspath(path))
    file_flags = os.O_RDONLY
    if hasattr(os, "O_NONBLOCK"):
        file_flags |= os.O_NONBLOCK
    if hasattr(os, "O_NOFOLLOW"):
        file_flags |= os.O_NOFOLLOW

    file_fd = os.open(abs_path, file_flags)
    try:
        _assert_regular_private_file(file_fd, abs_path)
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(file_fd, 1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_CONTENT_FILE_BYTES:
                raise OSError(f"content exceeds max bytes: {MAX_CONTENT_FILE_BYTES}")
            chunks.append(chunk)
        return b"".join(chunks).decode("utf-8")
    finally:
        os.close(file_fd)


def _validate_layer_for_scope(scope: str, layer: str) -> str | None:
    allowed_layers = PROJECT_LAYERS if scope == "project" else USER_LAYERS
    if layer in allowed_layers:
        return None

    if layer in PROJECT_LAYERS:
        return f"layer {layer} is only valid with --scope project"
    if layer in USER_LAYERS:
        return f"layer {layer} is only valid with --scope user"
    return f"unknown layer {layer}"


def cmd_add(args: argparse.Namespace) -> int:
    layer_error = _validate_layer_for_scope(args.scope, args.layer)
    if layer_error:
        print(f"sspower-mem: {layer_error}", file=sys.stderr)
        return 30

    try:
        cwd = _resolve_cwd(args) if args.scope == "project" else None
    except FileNotFoundError as e:
        print(f"sspower-mem: {e}", file=sys.stderr)
        return 20

    sc_id = scope_id(args.scope, cwd)
    troot = trust_root(args.scope, cwd)
    panchor = parent_anchor(args.scope, cwd)
    dpath = digest_path(args.scope, cwd)
    try:
        content = args.content if args.content is not None else _read_content_file(args.content_file)
    except OSError as e:
        print(f"sspower-mem: content file read failed: {e}", file=sys.stderr)
        return 20
    meta = _parse_meta(args.meta)
    if args.no_llm:
        meta = {**meta, "no_llm": True}

    lock_path = user_sspower_dir() / "idx" / ".lock"
    if not lock_path.exists():
        print(
            f"sspower-mem: lock missing at {lock_path}; run `sspower-mem doctor --bootstrap`",
            file=sys.stderr,
        )
        return 30

    raw_status = "n/a"
    extracted_status = "n/a"
    eff_id = ""
    was_new = False
    overall_rc = 0
    try:
        with acquire_lock(lock_path, parent_anchor=parent_anchor("user", None)):
            # Step 1 — durable digest append.
            try:
                eff_id, was_new = append_block_or_skip(
                    digest_path=dpath, trust_root=troot, parent_anchor=panchor,
                    scope=sc_id, layer=args.layer, content=content, meta=meta,
                )
            except (OSError, ValueError) as e:
                print(f"sspower-mem: digest write failed: {e}", file=sys.stderr)
                return 20

            # Step 2 — lazy import + raw upsert.
            mem_obj, raw_ok = _try_raw_upsert(sc_id, eff_id, args.layer, content, meta)
            if not raw_ok:
                raw_status = "skipped"
                extracted_status = (
                    "skipped-intentional" if args.no_llm else "skipped-failed"
                )
                overall_rc = 10
            else:
                raw_status = "ok"
                if args.no_llm:
                    extracted_status = "skipped-intentional"
                else:
                    extracted_status = _try_extract_and_write(
                        mem_obj, sc_id, eff_id, args.layer, content, meta,
                    )
                    if extracted_status != "ok":
                        overall_rc = 10
    except OSError as e:
        print(f"sspower-mem: lock unavailable: {e}", file=sys.stderr)
        return 30

    print(json.dumps({
        "id": eff_id, "new": was_new,
        "raw": raw_status, "extracted": extracted_status,
    }))
    return overall_rc


def _try_raw_upsert(scope_id_str, eff_id, layer, content, meta):
    """Returns (Memory|None, ok: bool). Lazy-import all Mem0 deps inside."""
    try:
        import sspower_mem.mem  # noqa: F401 — telemetry shield runs here
        from sspower_mem.mem.factory import build_memory
        from sspower_mem.mem.idx import raw_upsert
    except ImportError as e:
        _log_errors_jsonl({"stage": "step2_import", "err": str(e)})
        return None, False

    idx_dir = user_sspower_dir() / "idx"
    chroma_dir = idx_dir / "chroma"
    history_db = idx_dir / "history.db"
    try:
        mem = build_memory(
            scope_id=scope_id_str, idx_dir=idx_dir,
            chroma_dir=chroma_dir, history_db_path=history_db,
        )
        block_meta = {
            "block_id": eff_id, "layer": layer, "scope": scope_id_str,
            "ts": _iso_now(),
            **{k: v for k, v in meta.items() if k != "kind"},
        }
        raw_upsert(mem, content, block_meta, user_id=scope_id_str)
        return mem, True
    except Exception as e:
        _log_errors_jsonl({"stage": "step2_index", "err": str(e)})
        return None, False


def _try_extract_and_write(mem, scope_id_str, eff_id, layer, content, meta):
    """Returns one of: "ok", "skipped-failed", "skipped-partial"."""
    try:
        from sspower_mem.mem.extract import ExtractFailed, bridge_extract_facts
        from sspower_mem.mem.idx import extracted_upsert
    except ImportError as e:
        _log_errors_jsonl({"stage": "step3_import", "err": str(e)})
        return "skipped-failed"

    try:
        facts = bridge_extract_facts(content)
    except ExtractFailed as e:
        _log_errors_jsonl({"stage": "step3a_extract", "err": str(e)})
        return "skipped-failed"

    import hashlib
    block_meta = {
        "block_id": eff_id, "layer": layer, "scope": scope_id_str, "ts": _iso_now(),
        **{k: v for k, v in meta.items() if k != "kind"},
    }
    for fact_index, fact_text in enumerate(facts):
        fact_hash = hashlib.sha1(f"{eff_id}:{fact_text}".encode()).hexdigest()[:16]
        fact_meta = {
            **block_meta, "raw_id": eff_id,
            "fact_index": fact_index, "fact_hash": fact_hash,
        }
        try:
            extracted_upsert(mem, fact_text, fact_meta, user_id=scope_id_str)
        except Exception as e:
            _log_errors_jsonl({
                "stage": "step3b_index", "err": str(e),
                "raw_id": eff_id, "fact_index": fact_index,
            })
            return "skipped-partial"
    return "ok"


def _iso_now():
    import datetime
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _log_errors_jsonl(record: dict):
    """Append a single JSON line to ~/.claude/sspower/idx/errors.jsonl.
    Never raises — failure to log must not break the add path."""
    try:
        from sspower_mem.io import safe_append_strict
        idx_dir = user_sspower_dir() / "idx"
        errors = idx_dir / "errors.jsonl"
        safe_append_strict(
            errors,
            json.dumps({"ts": _iso_now(), **record}) + "\n",
            user_sspower_dir(),
            pathlib.Path.home(),
        )
    except Exception:
        pass


def cmd_search(args: argparse.Namespace) -> int:
    scopes = args.scope.split(",")
    needs_project = "project" in scopes
    sources: list[DigestSource] = []

    try:
        cwd = canonicalize_cwd(args.cwd) if args.cwd and needs_project else None
        for scope in scopes:
            if scope == "project":
                if cwd is None:
                    cwd = canonicalize_cwd(os.getcwd())
                sources.append((
                    digest_path("project", cwd),
                    parent_anchor("project", cwd),
                    scope_id("project", cwd),
                    PROJECT_LAYERS,
                ))
            elif scope == "user":
                sources.append((
                    digest_path("user", None),
                    parent_anchor("user", None),
                    scope_id("user", None),
                    USER_LAYERS,
                ))
            else:
                print(f"sspower-mem: unknown scope: {scope}", file=sys.stderr)
                return 30
    except FileNotFoundError as e:
        print(f"sspower-mem: {e}", file=sys.stderr)
        return 20

    layer_filter = args.layer.split(",") if args.layer else None

    # --mode recent → digest-only (no semantic op).
    if args.mode == "recent":
        try:
            hits = recent(sources, top_k=args.top_k, layer_filter=layer_filter)
        except OSError as e:
            print(f"sspower-mem: digest read failed: {e}", file=sys.stderr)
            return 20
        _emit_search(hits, args.json)
        return 0

    if not args.query:
        print("sspower-mem: search requires --query or --mode recent", file=sys.stderr)
        return 30

    # --query path: try Mem0 index; fall back to grep on exception or empty (unless --idx-only).
    index_hits, index_raised = _try_index_search(
        scope_ids=[s[2] for s in sources],
        query=args.query, top_k=args.top_k, layer_filter=layer_filter,
    )

    if args.idx_only:
        if index_raised:
            print("sspower-mem: index search raised under --idx-only", file=sys.stderr)
            return 10
        _emit_search(index_hits, args.json)
        return 0

    if index_hits:
        _emit_search(index_hits, args.json)
        return 0

    # Index empty or raised → grep fallback.
    try:
        grep_hits = grep_search(sources, args.query, top_k=args.top_k, layer_filter=layer_filter)
    except OSError as e:
        print(f"sspower-mem: digest read failed: {e}", file=sys.stderr)
        return 20
    _emit_search(grep_hits, args.json)
    return 0


def _try_index_search(scope_ids, query, top_k, layer_filter):
    """Run Memory.search per scope, min-max normalize per scope, merge.

    Returns (merged_hits: list[dict], index_raised: bool).
    """
    try:
        import sspower_mem.mem  # noqa: F401
        from sspower_mem.mem.factory import build_memory
    except ImportError:
        return [], True

    idx_dir = user_sspower_dir() / "idx"
    try:
        mem = build_memory(
            scope_id=scope_ids[0], idx_dir=idx_dir,
            chroma_dir=idx_dir / "chroma",
            history_db_path=idx_dir / "history.db",
        )
    except Exception:
        return [], True

    all_normalized: list[dict] = []
    for sid in scope_ids:
        try:
            filters = {"user_id": sid}
            if layer_filter:
                filters["OR"] = [{"layer": lf} for lf in layer_filter]
            resp = mem.search(query=query, filters=filters, top_k=top_k, threshold=0.0)
        except Exception:
            return [], True
        scope_hits = resp.get("results", []) or []
        if not scope_hits:
            continue
        scores = [float(h.get("score", 0.0)) for h in scope_hits]
        smin, smax = min(scores), max(scores)
        for h in scope_hits:
            raw = float(h.get("score", 0.0))
            norm = 1.0 if smin == smax else (raw - smin) / (smax - smin)
            md = h.get("metadata", {}) or {}
            kind = md.get("kind", "")
            corr_id = md.get("raw_id") or md.get("block_id") or h.get("id")
            all_normalized.append({
                "id": corr_id,
                "source": "index",
                "score": norm,
                "content": h.get("memory") or h.get("text") or "",
                "scope": md.get("scope") or sid,
                "layer": md.get("layer", ""),
                "ts": md.get("ts", ""),
                "_kind": kind,
            })

    all_normalized = _dedupe_index_hits(all_normalized)
    all_normalized.sort(key=lambda h: (-h["score"], -_ts_key(h["ts"]) if h["ts"] else 0, h["id"] or ""))
    return all_normalized[:top_k], False


def _dedupe_index_hits(hits):
    """Collapse raw/extracted duplicates: when multiple hits share the same
    raw_id (or block_id when raw_id absent), keep kind=extracted, drop kind=raw.

    Spec §6.1 read path.
    """
    seen: dict[str, dict] = {}
    for h in hits:
        key = h.get("id") or ""
        existing = seen.get(key)
        if existing is None:
            seen[key] = h
            continue
        existing_kind = existing.get("_kind", "")
        new_kind = h.get("_kind", "")
        if new_kind == "extracted" and existing_kind != "extracted":
            seen[key] = h
    return list(seen.values())


def _emit_search(hits, as_json):
    cleaned = [{k: v for k, v in h.items() if not k.startswith("_")} for h in hits]
    if as_json:
        print(json.dumps(cleaned, indent=2))
        return
    for hit in cleaned:
        print(f"[{hit['source']} {hit['score']:.3f}] "
              f"{hit['ts']} · {hit['scope']} · {hit['layer']} · {hit['id']}")
        print(_sanitize_for_terminal(hit["content"]))
        print("---")


def _ts_key(ts: str) -> int:
    import datetime
    try:
        return int(datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")
                   .replace(tzinfo=datetime.timezone.utc).timestamp())
    except (ValueError, TypeError):
        return 0


def cmd_digest(args: argparse.Namespace) -> int:
    """Print an in-scope digest summary.

    The --rebuild-chroma flag is reserved for Phase C, when the index backend
    exists. Phase A rejects it explicitly so recovery commands do not silently
    no-op.
    """
    if args.rebuild_chroma:
        print(
            "sspower-mem: --rebuild-chroma is reserved for Phase C (no index "
            "backend in Phase A); rerun after Phase C lands",
            file=sys.stderr,
        )
        return 30

    try:
        cwd = _resolve_cwd(args) if args.scope == "project" else None
    except FileNotFoundError as e:
        print(f"sspower-mem: {e}", file=sys.stderr)
        return 20

    dpath = digest_path(args.scope, cwd)
    panchor = parent_anchor(args.scope, cwd)
    sc_id = scope_id(args.scope, cwd)
    allowed_layers = PROJECT_LAYERS if args.scope == "project" else USER_LAYERS
    try:
        safe_read_strict(dpath, panchor)
        blocks = _load_all_blocks([(dpath, panchor, sc_id, allowed_layers)])
    except FileNotFoundError:
        print(
            json.dumps(
                {
                    "path": str(dpath),
                    "exists": False,
                    "blocks": 0,
                    "by_layer": {},
                    "latest_ts": None,
                }
            )
        )
        return 0
    except OSError as e:
        print(f"sspower-mem: digest read failed: {e}", file=sys.stderr)
        return 20

    by_layer: dict[str, int] = {}
    for block in blocks:
        by_layer[block["layer"]] = by_layer.get(block["layer"], 0) + 1

    summary = {
        "path": str(dpath),
        "exists": True,
        "blocks": len(blocks),
        "by_layer": by_layer,
        "latest_ts": blocks[-1]["ts"] if blocks else None,
    }
    print(json.dumps(summary))
    return 0


def cmd_doctor(args: argparse.Namespace) -> int:
    if args.bootstrap:
        result = bootstrap()
        print(json.dumps(result))
        return 0

    result = health()
    print(json.dumps(result))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="sspower-mem")
    sub = parser.add_subparsers(dest="cmd", required=True)

    add = sub.add_parser("add", help="Append a memory block")
    add.add_argument("--scope", required=True, choices=["project", "user"])
    add.add_argument(
        "--layer",
        required=True,
        choices=["episodic", "decision", "gotcha", "user-global"],
    )
    content_group = add.add_mutually_exclusive_group(required=True)
    content_group.add_argument("--content")
    content_group.add_argument("--content-file")
    add.add_argument("--cwd")
    add.add_argument("--meta", action="append", default=[])
    add.add_argument("--no-llm", action="store_true")
    add.set_defaults(func=cmd_add)

    search = sub.add_parser("search", help="Search memory")
    search.add_argument("--scope", required=True)
    search.add_argument("--cwd")
    search.add_argument("--layer")
    search_group = search.add_mutually_exclusive_group(required=True)
    search_group.add_argument("--query")
    search_group.add_argument("--mode", choices=["recent"])
    search.add_argument("--top-k", type=int, default=8)
    search.add_argument("--json", action="store_true")
    search.add_argument("--idx-only", action="store_true")  # Phase A: rejected with rc=30 (Phase C requires backend)
    search.set_defaults(func=cmd_search)

    digest = sub.add_parser("digest", help="Print digest summary or rebuild index")
    digest.add_argument("--scope", required=True, choices=["project", "user"])
    digest.add_argument("--cwd")
    digest.add_argument(
        "--rebuild-chroma",
        action="store_true",
        help="Reserved for Phase C; Phase A rejects with rc=30",
    )
    digest.add_argument(
        "--no-llm",
        action="store_true",
        help="Reserved for Phase C; no-op in Phase A",
    )
    digest.set_defaults(func=cmd_digest)

    doctor = sub.add_parser("doctor", help="Health + bootstrap")
    doctor.add_argument("--bootstrap", action="store_true")
    doctor.set_defaults(func=cmd_doctor)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except Exception as e:
        print(f"sspower-mem: unexpected error: {e}", file=sys.stderr)
        return 30
