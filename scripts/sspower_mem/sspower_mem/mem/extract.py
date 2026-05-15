"""Client-side LLM extraction via codex-bridge.mjs complete --json.

Per docs/specs/2026-05-13-index-backend-integration-design.md §6.1.5.
Per D14: every malformed wire response classifies as ExtractFailed (rc=10
at the cmd_add level). Empty {"facts": []} is success (rc=0).
"""
from __future__ import annotations

import json
import os
import pathlib
import subprocess

MAX_FACTS = 32
MAX_FACT_CHARS = 512

EXTRACT_TEMPLATE = (
    "Extract durable factual claims from the text below as a JSON object of the form "
    '{"facts": ["fact 1", "fact 2"]}. Each fact must be a single self-contained sentence. '
    "Omit speculation, opinions, and meta-commentary. If no facts are present, return "
    '{"facts": []}. Output ONLY the JSON object. No Markdown fences. No prose.\n\n'
    "TEXT:\n{content}"
)


class ExtractFailed(Exception):
    """Raised when the bridge response cannot be parsed as a valid facts list."""


def _bridge_path() -> str:
    """Resolve codex-bridge.mjs path. Honors SSPOWER_BRIDGE_PATH for tests."""
    override = os.environ.get("SSPOWER_BRIDGE_PATH")
    if override:
        return override
    # Production path: <plugin>/scripts/codex-bridge.mjs.
    # extract.py lives at <plugin>/scripts/sspower_mem/sspower_mem/mem/extract.py.
    here = pathlib.Path(__file__).resolve()
    return str(here.parent.parent.parent.parent / "codex-bridge.mjs")


def bridge_extract_facts(content: str, timeout_ms: int = 60_000) -> list[str]:
    """Call codex-bridge complete --json, parse, validate, truncate.

    Returns list[str] (possibly empty) on success.
    Raises ExtractFailed for any wire-level failure.
    """
    bridge = _bridge_path()
    prompt = EXTRACT_TEMPLATE.replace("{content}", content)

    if bridge.endswith((".mjs", ".js")):
        argv = ["node", bridge, "complete", "--json", "--prompt", prompt, "--timeout", str(timeout_ms)]
    else:
        argv = [bridge, "complete", "--json", "--prompt", prompt, "--timeout", str(timeout_ms)]

    try:
        cp = subprocess.run(argv, capture_output=True, text=True, timeout=(timeout_ms / 1000) + 5)
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError) as e:
        raise ExtractFailed(f"bridge invocation failed: {e}") from e

    if cp.returncode != 0:
        raise ExtractFailed(f"bridge exited rc={cp.returncode}; stderr={cp.stderr[:500]}")

    try:
        envelope = json.loads(cp.stdout)
    except json.JSONDecodeError as e:
        raise ExtractFailed(f"bridge stdout not valid JSON: {e}; stdout={cp.stdout[:500]}") from e

    if isinstance(envelope, dict) and "error" in envelope:
        raise ExtractFailed(f"bridge JSON error field: {envelope['error']}")

    try:
        content_str = envelope["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError) as e:
        raise ExtractFailed(f"envelope missing choices[0].message.content: {e}") from e

    try:
        body = json.loads(content_str)
    except json.JSONDecodeError as e:
        raise ExtractFailed(f"content not valid JSON: {e}; content={content_str[:500]}") from e

    if not isinstance(body, dict) or "facts" not in body:
        raise ExtractFailed(f"content missing 'facts' key: {body!r}")

    facts = body["facts"]
    if not isinstance(facts, list):
        raise ExtractFailed(f"'facts' must be a list, got {type(facts).__name__}")

    for i, f in enumerate(facts):
        if not isinstance(f, str):
            raise ExtractFailed(f"facts[{i}] is not a string: {type(f).__name__}")

    facts = facts[:MAX_FACTS]
    facts = [f[:MAX_FACT_CHARS] for f in facts]
    return facts
