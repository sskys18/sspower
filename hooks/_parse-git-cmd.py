#!/usr/bin/env python3
"""Parse a bash command string and report git-invocation details.

Reads the raw bash command from stdin. Writes a single JSON object to
stdout with these keys (always present, defaults shown):

    {
      "subcommand":      "",     # e.g. "commit", "push", "merge"
      "work_dir":        "",     # value of -C / --git-dir / --work-tree
      "subcommand_args": [],     # tokens after the subcommand, verbatim
      "merge_sources":   []      # positional refs after `merge` (octopus
                                 # safe -- collects all, not just the first)
    }

We deliberately stop trying to predict what each subcommand will do.
Hooks that need that information should re-invoke git with the parsed
args (e.g. `git commit --dry-run --porcelain --no-verify <args>`) and
let git itself answer.

shlex parses the command honouring shell quoting, so things like
  FOO="bar baz" git -c "user.name=foo bar" commit -m "msg with space"
tokenise correctly. Pipelines / command substitutions are out of scope:
the auto-review hooks treat those as caller-side bypass.
"""

from __future__ import annotations

import json
import re
import shlex
import sys


_GIT_FLAGS_WITH_VALUE = {
    "-C", "-c",
    "--git-dir", "--work-tree", "--namespace",
    "--exec-path", "--super-prefix", "--config-env",
}

# Subcommand-specific flags that take a separate value token. We only
# need this for `merge` now, to collect octopus sources correctly.
_MERGE_FLAGS_WITH_VALUE = {
    "-m", "-F", "-X", "-s",
    "--message", "--file", "--strategy", "--strategy-option",
    "--into-name",
}

_ENV_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")


def _empty() -> dict:
    return {
        "subcommand": "",
        "work_dir": "",
        "subcommand_args": [],
        "merge_sources": [],
    }


def parse(cmd: str) -> dict:
    try:
        toks = shlex.split(cmd, posix=True)
    except ValueError:
        return _empty()

    while toks and _ENV_ASSIGN.match(toks[0]):
        toks.pop(0)

    if not toks or toks[0] != "git":
        return _empty()
    toks = toks[1:]

    out_work_dir = ""
    skip_next = False
    capture_next = False
    while toks:
        if skip_next:
            if capture_next:
                out_work_dir = toks[0]
                capture_next = False
            toks.pop(0)
            skip_next = False
            continue
        t = toks[0]
        if t.startswith("--") and "=" in t:
            key, _, val = t.partition("=")
            if key in ("--git-dir", "--work-tree"):
                out_work_dir = val
            toks.pop(0)
            continue
        if t in _GIT_FLAGS_WITH_VALUE:
            if t in ("-C", "--git-dir", "--work-tree"):
                capture_next = True
            toks.pop(0)
            skip_next = True
            continue
        if t.startswith("-"):
            toks.pop(0)
            continue
        break

    if not toks:
        return _empty()

    out = _empty()
    out["subcommand"] = toks[0]
    out["work_dir"] = out_work_dir
    out["subcommand_args"] = toks[1:]

    if out["subcommand"] == "merge":
        # Walk the merge args, skipping flags and their paired values.
        # Collect ALL non-flag tokens so octopus merges are caught.
        skip = False
        for t in out["subcommand_args"]:
            if skip:
                skip = False
                continue
            if t.startswith("--") and "=" in t:
                continue
            if t in _MERGE_FLAGS_WITH_VALUE:
                skip = True
                continue
            if t.startswith("-"):
                continue
            out["merge_sources"].append(t)

    return out


def main() -> int:
    cmd = sys.stdin.read()
    json.dump(parse(cmd), sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
