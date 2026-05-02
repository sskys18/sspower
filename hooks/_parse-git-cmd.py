#!/usr/bin/env python3
"""Parse a bash command string and report git-invocation details.

Reads the raw bash command from stdin. Writes a single JSON object to
stdout with these keys (always present, defaults shown):

    {
      "subcommand":   "",     # e.g. "commit", "push", "merge"
      "merge_source": "",     # first positional arg of `git merge`
      "commit_all":   false   # true if -a / --all (or short combo like -am)
    }

Honours shell quoting via shlex so things like
  FOO="bar baz" git -c "user.name=foo bar" commit -m "msg with space"
are parsed correctly. Pipelines and command substitutions are out of
scope -- the auto-review hooks treat those as caller-side bypass.
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

# Subcommand-specific flags that take a separate value token.
_SUBCMD_FLAGS_WITH_VALUE = {
    "merge": {
        "-m", "-F", "-X", "-s", "-S", "-T",
        "--message", "--file", "--strategy", "--strategy-option",
        "--gpg-sign", "--into-name",
    },
    "commit": {
        "-m", "-F", "-c", "-C", "-t", "-S",
        "--message", "--file", "--reedit-message", "--reuse-message",
        "--template", "--gpg-sign", "--cleanup", "--author", "--date",
        "--fixup", "--squash", "--pathspec-from-file", "--trailer",
    },
}

_ENV_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")


def _empty() -> dict:
    return {"subcommand": "", "merge_source": "", "commit_all": False}


def parse(cmd: str) -> dict:
    try:
        toks = shlex.split(cmd, posix=True)
    except ValueError:
        # Unbalanced quotes etc. -- treat as opaque, no decision.
        return _empty()

    # Strip leading env assignments (FOO=bar BAZ=qux git ...).
    while toks and _ENV_ASSIGN.match(toks[0]):
        toks.pop(0)

    if not toks or toks[0] != "git":
        return _empty()
    toks = toks[1:]

    # Strip git-level flags (and paired values).
    skip_next = False
    while toks:
        if skip_next:
            toks.pop(0)
            skip_next = False
            continue
        t = toks[0]
        if t.startswith("--") and "=" in t:
            toks.pop(0)
            continue
        if t in _GIT_FLAGS_WITH_VALUE:
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
    rest = toks[1:]

    if out["subcommand"] == "commit":
        # `-a` / `--all` auto-stages tracked modifications. Also catch
        # short-flag combos like `-am`, `-av`, `-avm`.
        short_combo = re.compile(r"^-[A-Za-z]+$")
        for t in rest:
            if t == "--all":
                out["commit_all"] = True
                break
            if short_combo.match(t) and "a" in t[1:]:
                out["commit_all"] = True
                break

    elif out["subcommand"] == "merge":
        flags_with_value = _SUBCMD_FLAGS_WITH_VALUE["merge"]
        skip_next = False
        for t in rest:
            if skip_next:
                skip_next = False
                continue
            if t.startswith("--") and "=" in t:
                continue
            if t in flags_with_value:
                skip_next = True
                continue
            if t.startswith("-"):
                continue
            out["merge_source"] = t
            break

    return out


def main() -> int:
    cmd = sys.stdin.read()
    json.dump(parse(cmd), sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
