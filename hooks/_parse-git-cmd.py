#!/usr/bin/env python3
"""Parse a bash command string and report all git/gh invocations it
contains.

Reads the raw bash command from stdin. Writes a JSON object to stdout:

    {
      "invocations": [
        {
          "tool":            "git" | "gh",
          "subcommand":      "",      # e.g. "commit", "push", "merge",
                                       # "pr create", "pr ready"
          "work_dir":        "",      # value of -C / --git-dir / --work-tree
          "subcommand_args": [],      # tokens after the subcommand, verbatim
          "merge_sources":   [],      # positional refs after `merge`
                                       # (octopus-aware)
          "commit_uses_worktree": False,
        },
        ...
      ]
    }

Why a list: shells let you chain commands -- `cd dir && git push`,
`(git commit)`, `git diff && git commit -p`, etc. Returning only the
first token's subcommand misses the chokepoint when the user's
command embeds it later. We tokenise the full string with shlex,
split on shell operators, and parse each segment.

Wrappers honoured per segment: `env [-i] [VAR=val ...]`, `command`,
`exec`, leading env assignments, backslash-escaped `\\git`, and
absolute paths ending in `/git` or `/gh`.

Quoting / pipelines / command substitutions:
  - shlex handles quoting properly.
  - We split on `&&`, `||`, `;`, `|`, `&`, and parens/braces.
  - $(...) is opaque to us; the inner command isn't parsed
    (acceptable: rare in practice and recursive-explosion isn't worth it).
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

_MERGE_FLAGS_WITH_VALUE = {
    "-m", "-F", "-X", "-s",
    "--message", "--file", "--strategy", "--strategy-option",
    "--into-name",
}
_COMMIT_FLAGS_WITH_VALUE = {
    "-m", "-F", "-c", "-C", "-t",
    "--message", "--file", "--reedit-message", "--reuse-message",
    "--template", "--cleanup", "--author", "--date",
    "--fixup", "--squash", "--pathspec-from-file", "--trailer",
}
_COMMIT_SHORT_VALUE_TAKERS = set("SCcmFt")
_COMMIT_WORKTREE_OPTS = {
    "-a", "--all",
    "-i", "--include",
    "-o", "--only",
    "-p", "--patch",
    "--interactive",
}
_COMMIT_WORKTREE_VALUE_OPTS = {"--pathspec-from-file"}
_COMMIT_WORKTREE_SHORT_LETTERS = set("aiop")

_ENV_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

# Shell control operators that terminate one segment and start another.
_OPERATORS = {"&&", "||", "&", ";", "|", "|&", "(", ")", "{", "}", ";;", "!"}

# Shell redirection operators. We drop the operator AND its target
# token, and (if the operator includes `&` or follows a numeric fd
# token) drop the source fd too.
_REDIRECT_OPS = {">", "<", ">>", "<<", "<<<", ">&", "<&", "&>", "&>>"}

# Gh-level flags that take a separate value before the subcommand.
_GH_FLAGS_WITH_VALUE = {"-R", "--repo", "--hostname"}

# Wrappers we strip before looking for `git`.
_PASSTHROUGH_WRAPPERS = {"command", "exec", "builtin", "nice", "nohup", "stdbuf", "ionice", "time"}

# Read-only stdout consumers safe to follow a chokepoint via `|`.
# These cannot mutate the predecessor's HEAD/cwd/remote/index — they
# consume stdout and emit text. Anything not in this set, when piped
# from a chokepoint, must be denied.
_PIPE_READONLY_CONSUMERS = {
    "tail", "head", "cat", "less", "more",
    "grep", "egrep", "fgrep", "rg", "ag",
    "sed", "awk", "wc", "sort", "uniq",
    "jq", "yq", "xq", "column",
    "tee", "tr", "cut", "fold", "rev", "nl", "bat", "fmt",
    "pr", "expand", "unexpand", "paste", "comm", "diff",
    "od", "xxd", "hexdump", "strings", "base64",
}


def _is_git_token(t: str) -> bool:
    if t in ("git", r"\git"):
        return True
    if t.startswith("/") and t.split("/")[-1] == "git":
        return True
    return False


def _is_gh_token(t: str) -> bool:
    if t in ("gh", r"\gh"):
        return True
    if t.startswith("/") and t.split("/")[-1] == "gh":
        return True
    return False


def _strip_env_prefix(toks: list[str]) -> None:
    """Pop leading env-prefix tokens in place: `env [-i] [VAR=val...]`,
    bare `VAR=val` assignments, `command`/`exec` wrappers, etc."""
    while toks:
        t = toks[0]
        if _ENV_ASSIGN.match(t):
            toks.pop(0)
            continue
        if t in _PASSTHROUGH_WRAPPERS:
            toks.pop(0)
            continue
        if t == "env":
            toks.pop(0)
            # Consume env's own flags (-i, -u VAR, -S, -0, --) and
            # assignments. Stop when we hit something that doesn't fit.
            while toks:
                e = toks[0]
                if _ENV_ASSIGN.match(e):
                    toks.pop(0)
                    continue
                if e == "--":
                    toks.pop(0)
                    break
                if e.startswith("-"):
                    # `-u VAR` / `-S string`: consume next if it's not
                    # an assignment or another flag.
                    toks.pop(0)
                    if e in ("-u", "-S") and toks and not toks[0].startswith("-") and not _ENV_ASSIGN.match(toks[0]):
                        toks.pop(0)
                    continue
                break
            continue
        break


def _segment(toks: list[str]) -> list[dict]:
    """Split tokens on shell control operators. Discard redirection
    operators and their targets so files like `> log.txt` don't end up
    parsed as positional pathspec args.

    Returns [{'op': preceding_operator_or_None, 'tokens': [...]}, ...].
    First segment has op=None. Operators preserved so callers can tell
    a pipe (read-only fanout) from a mutating chain (`&&`, `;`, etc).
    """
    out: list[dict] = []
    cur: list[str] = []
    cur_op: str | None = None
    i = 0
    while i < len(toks):
        t = toks[i]
        if t in _OPERATORS:
            if cur:
                out.append({"op": cur_op, "tokens": cur})
                cur = []
            cur_op = t
            i += 1
            continue
        if t in _REDIRECT_OPS:
            # `2>file` shows up as [`2`, `>`, `file`] -- drop the fd.
            # `2>&1` shows up as [`2`, `>&`, `1`] -- same idea.
            if cur and cur[-1].isdigit():
                cur.pop()
            i += 1
            if i < len(toks):
                i += 1   # also skip the redirect target
            continue
        cur.append(t)
        i += 1
    if cur:
        out.append({"op": cur_op, "tokens": cur})
    return out


def _classify_consumer(tokens: list[str]) -> str:
    """Classify a non-git/non-gh segment as 'readonly' or 'unknown'."""
    if not tokens:
        return "unknown"
    head = tokens[0]
    # Strip path so /usr/bin/tail, /opt/homebrew/bin/jq, etc. classify.
    head = head.split("/")[-1]
    return "readonly" if head in _PIPE_READONLY_CONSUMERS else "unknown"


def _parse_git_segment(toks: list[str]) -> dict | None:
    """Given a segment that starts with a git invocation (after env strip),
    return a parsed invocation dict. Return None if not a git invocation."""
    toks = list(toks)  # copy; we'll mutate
    _strip_env_prefix(toks)
    if not toks or not _is_git_token(toks[0]):
        return None
    toks.pop(0)

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
        return None

    inv = {
        "tool": "git",
        "subcommand": toks[0],
        "work_dir": out_work_dir,
        "subcommand_args": toks[1:],
        "merge_sources": [],
        "commit_uses_worktree": False,
    }

    if inv["subcommand"] == "merge":
        skip = False
        for t in inv["subcommand_args"]:
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
            inv["merge_sources"].append(t)

    elif inv["subcommand"] == "commit":
        skip = False
        seen_dashdash = False
        for t in inv["subcommand_args"]:
            if skip:
                skip = False
                continue
            if seen_dashdash:
                inv["commit_uses_worktree"] = True
                break
            if t == "--":
                seen_dashdash = True
                continue
            if t in _COMMIT_WORKTREE_OPTS:
                inv["commit_uses_worktree"] = True
                continue
            if t.startswith("--") and "=" in t:
                key, _, _ = t.partition("=")
                if key in _COMMIT_WORKTREE_VALUE_OPTS:
                    inv["commit_uses_worktree"] = True
                continue
            if t in _COMMIT_WORKTREE_VALUE_OPTS:
                inv["commit_uses_worktree"] = True
                skip = True
                continue
            if t in _COMMIT_FLAGS_WITH_VALUE:
                skip = True
                continue
            if t.startswith("-"):
                if (
                    len(t) >= 2
                    and t[1].isalpha()
                    and t[1] not in _COMMIT_SHORT_VALUE_TAKERS
                    and all(c.isalpha() for c in t[1:])
                ):
                    if any(c in _COMMIT_WORKTREE_SHORT_LETTERS for c in t[1:]):
                        inv["commit_uses_worktree"] = True
                continue
            inv["commit_uses_worktree"] = True
            break

    return inv


def _parse_gh_segment(toks: list[str]) -> dict | None:
    """Detect `gh pr create|ready` (and similar) chokepoints."""
    toks = list(toks)
    _strip_env_prefix(toks)
    if not toks or not _is_gh_token(toks[0]):
        return None
    toks.pop(0)
    # Strip gh-level flags (and paired values) before the subcommand.
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
        if t in _GH_FLAGS_WITH_VALUE:
            toks.pop(0)
            skip_next = True
            continue
        if t.startswith("-"):
            toks.pop(0)
            continue
        break
    if not toks:
        return None
    if len(toks) >= 2 and toks[0] == "pr" and toks[1] in ("create", "ready", "merge"):
        return {
            "tool": "gh",
            "subcommand": f"pr {toks[1]}",
            "work_dir": "",
            "subcommand_args": toks[2:],
            "merge_sources": [],
            "commit_uses_worktree": False,
        }
    return {
        "tool": "gh",
        "subcommand": toks[0],
        "work_dir": "",
        "subcommand_args": toks[1:],
        "merge_sources": [],
        "commit_uses_worktree": False,
    }


def parse(cmd: str) -> dict:
    # Use shlex in punctuation_chars mode so shell operators like
    # `&&`, `||`, `;`, `|`, `(`, `)`, `>`, `<`, `&` come back as
    # separate tokens (default shlex glues `git` and `commit)` into
    # one token, hiding the chained commit).
    try:
        lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        toks = list(lex)
    except ValueError:
        return {"invocations": [], "segments_count": 0}

    segments = _segment(toks)
    invocations = []
    seg_summary = []
    for idx, seg in enumerate(segments):
        raw = seg["tokens"]
        inv = _parse_git_segment(raw)
        if inv is None:
            inv = _parse_gh_segment(raw)
        if inv is not None and inv["subcommand"]:
            inv["chain_position"] = idx
            inv["preceding_op"] = seg["op"]
            invocations.append(inv)
            seg_summary.append({
                "op": seg["op"],
                "kind": "git_or_gh",
                "consumer_class": "git_or_gh",
            })
        else:
            seg_summary.append({
                "op": seg["op"],
                "kind": "other",
                "consumer_class": _classify_consumer(raw),
            })

    return {
        "invocations": invocations,
        # Number of non-empty command segments. > 1 means chained.
        # Hook policy reads `segments` (per-segment op + consumer class)
        # to allow read-only output pipes (`git push | tail`) while
        # denying mutating chains (`cd dir && git push`).
        "segments_count": len(segments),
        "segments": seg_summary,
    }


def main() -> int:
    cmd = sys.stdin.read()
    json.dump(parse(cmd), sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
