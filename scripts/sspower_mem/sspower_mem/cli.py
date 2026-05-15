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
    if args.idx_only:
        print(
            "sspower-mem: --idx-only requires the Phase C index backend; Phase A always uses digest",
            file=sys.stderr,
        )
        return 30

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

    try:
        if args.mode == "recent":
            hits = recent(sources, top_k=args.top_k, layer_filter=layer_filter)
        elif args.query:
            hits = grep_search(sources, args.query, top_k=args.top_k, layer_filter=layer_filter)
        else:
            print("sspower-mem: search requires --query or --mode recent", file=sys.stderr)
            return 30
    except OSError as e:
        print(f"sspower-mem: digest read failed: {e}", file=sys.stderr)
        return 20

    if args.json:
        print(json.dumps(hits, indent=2))
    else:
        for hit in hits:
            print(
                f"[{hit['source']} {hit['score']:.3f}] "
                f"{hit['ts']} · {hit['scope']} · {hit['layer']} · {hit['id']}"
            )
            print(_sanitize_for_terminal(hit["content"]))
            print("---")
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
