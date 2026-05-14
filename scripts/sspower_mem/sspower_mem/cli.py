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
import sys

from sspower_mem.digest import append_block_or_skip, grep_search, parse_blocks, recent
from sspower_mem.doctor import bootstrap, health
from sspower_mem.io import safe_read_strict
from sspower_mem.lock import acquire_lock
from sspower_mem.scope import (
    canonicalize_cwd,
    digest_path,
    parent_anchor,
    scope_id,
    trust_root,
    user_sspower_dir,
)


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


def _read_content(arg: str) -> str:
    if arg.startswith("@"):
        return pathlib.Path(arg[1:]).read_text(encoding="utf-8")
    return arg


def cmd_add(args: argparse.Namespace) -> int:
    if args.scope == "project" and args.layer == "user-global":
        print("sspower-mem: layer user-global is only valid with --scope user", file=sys.stderr)
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
    content = _read_content(args.content)
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
    scopes = args.scope.split(",")
    needs_project = "project" in scopes
    paths: list[pathlib.Path] = []

    try:
        cwd = canonicalize_cwd(args.cwd) if args.cwd and needs_project else None
        for scope in scopes:
            if scope == "project":
                if cwd is None:
                    cwd = canonicalize_cwd(os.getcwd())
                paths.append(digest_path("project", cwd))
            elif scope == "user":
                paths.append(digest_path("user", None))
            else:
                print(f"sspower-mem: unknown scope: {scope}", file=sys.stderr)
                return 30
    except FileNotFoundError as e:
        print(f"sspower-mem: {e}", file=sys.stderr)
        return 20

    layer_filter = args.layer.split(",") if args.layer else None

    try:
        if args.mode == "recent":
            hits = recent(paths, top_k=args.top_k, layer_filter=layer_filter)
        elif args.query:
            hits = grep_search(paths, args.query, top_k=args.top_k, layer_filter=layer_filter)
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
            print(hit["content"])
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
    try:
        digest_text = safe_read_strict(dpath, dpath.parent)
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

    blocks = list(parse_blocks(digest_text))
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
    add.add_argument("--content", required=True)
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
    search.add_argument("--idx-only", action="store_true")
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
