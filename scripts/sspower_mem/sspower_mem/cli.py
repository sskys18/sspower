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
        while True:
            chunk = os.read(file_fd, 1024 * 1024)
            if not chunk:
                break
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

    try:
        with acquire_lock(lock_path):
            try:
                eff_id, was_new = append_block_or_skip(
                    digest_path=dpath,
                    trust_root=troot,
                    parent_anchor=panchor,
                    scope=sc_id,
                    layer=args.layer,
                    content=content,
                    meta=meta,
                )
            except OSError as e:
                print(f"sspower-mem: digest write failed: {e}", file=sys.stderr)
                return 20
            except ValueError as e:
                print(f"sspower-mem: digest write failed: {e}", file=sys.stderr)
                return 20
    except OSError as e:
        print(f"sspower-mem: lock unavailable: {e}", file=sys.stderr)
        return 30

    result = {
        "id": eff_id,
        "new": was_new,
        "raw": "n/a",
        "extracted": "n/a",
    }
    print(json.dumps(result))
    return 0


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
