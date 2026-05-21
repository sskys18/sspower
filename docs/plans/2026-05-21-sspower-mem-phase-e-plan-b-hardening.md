# sspower-mem Phase E — Library Hardening Bundle (Plan-B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use sspower:subagent-driven-development (recommended) or sspower:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Executor:** a Claude agent via sspower:subagent-driven-development — NOT the Codex worker; the `git commit` steps in this plan are in scope and must be run.

**Goal:** Close the residual gaps in four sspower-mem library-hardening followups (bounded reads + `--top-k` bound, text-mode metadata sanitization, lock regression coverage) and one doc-only spec fix.

**Architecture:** Most of these followups were already remediated by commit `44ca088` ("v0.1.1 — trailing newlines, strict lock, bounded reads, trust-root confinement"), written *after* the advisory rounds. This plan targets ONLY the residual gaps that `44ca088` did not cover: (1) reads are byte-counted *during* streaming but never rejected up-front via `fstat` size, and `--top-k` has no bounds; (2) `_emit_search` text mode sanitizes only `content`, leaving `ts/scope/layer/id` raw; (3) `lock.py` is fully hardened but has no hardlink-rejection / explicit-mode regression test; (4) the index-backend spec describes Phase-A flags in present tense as if the index ships in Phase A. Plan-A (hook integration) is out of scope — do not touch `hooks/`.

**Tech Stack:** Python 3.11+, `argparse`, low-level `os` fd APIs (`os.open`, `os.fstat`, `O_NOFOLLOW`), pytest, `uv`/`uvx`.

**Dropped from the prior draft — Task 3 (dedup trailing-newline) is NOT a real bug:** The prior draft claimed `append_block_or_skip`'s dedup `.rstrip("\n")` comparison (`digest.py:170`) silently drops a memory that differs from an existing block only by a trailing newline. **Verified false against the current tree.** `compute_id` (`digest.py:67`) is `hashlib.sha1(f"{scope}|{layer}|{content}".encode("utf-8")).hexdigest()[:16]` — it hashes the *exact* content with no stripping. `append_block_or_skip` computes `base_id = compute_id(scope, layer, content)` at `digest.py:167` and then iterates `existing.get(base_id, [])` at `digest.py:169`. For `content="x"` vs `content="x\n"`, `compute_id` yields two *distinct* base_ids, so the `"x\n"` block's `existing.get(base_id, [])` returns an empty list and the `.rstrip("\n")` comparison at `digest.py:170` is **never reached**. Two blocks reach that comparison only when they *already share a base_id*, i.e. their exact content is already byte-identical (modulo a `_dup<N>` id suffix, which `_existing_blocks_by_base` strips) — in which case `.rstrip("\n")` and an exact compare behave identically. `git show 44ca088 -- scripts/sspower_mem/sspower_mem/digest.py` confirms `44ca088` changed `format_block`'s body (`content.rstrip("\n")` → `content`), `parse_blocks` (`raw.strip("\n")` removed), and added `_validate_digest_path_under_trust_root` — it did **not** touch the dedup loop, and `git log --oneline -- scripts/sspower_mem/sspower_mem/digest.py` shows the `.rstrip("\n")` dedup line is original code from `98fbb73`. **Conclusion:** the `digest.py-trailing-newline` followup was over-stated by the reviewer; the formatter/parser half of it was genuinely fixed by `44ca088`, and the dedup half describes a collision path that cannot occur given exact-content hashing. No code change. No task.

**Prior remediation context (do NOT redo):** Commit `44ca088` already: removed `.rstrip("\n")` from `format_block` body and `.strip("\n")` from `parse_blocks` (formatter/parser preserve trailing newlines — `test_format_block_preserves_trailing_newlines` at `tests/test_digest.py:59` covers this); added `MAX_DIGEST_BYTES = 64 MiB` to `io.py` with a streaming byte-count cap in `safe_read_strict`; added `MAX_CONTENT_FILE_BYTES = 8 MiB` to `cli.py` with the same streaming cap in `_read_content_file`; rewrote `lock.py::_open_lock_file` to use the openat-walk + `O_NOFOLLOW` + `O_NONBLOCK` + `_assert_regular_private_file` + `os.fchmod(fd, 0o600)` pattern. The lock-file open is therefore ALREADY as strong as the digest-file open; that followup is effectively closed in code and this plan only adds the missing regression tests.

**Test command (run from anywhere; uses absolute path):**
```bash
cd /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower/scripts/sspower_mem && UV_CACHE_DIR=/private/tmp/sspower-uv-cache uv run --with pytest pytest tests/ -v
```

**Followup → Task map (spec coverage):**

| Followup | Verified location in current tree | Task |
|----------|-----------------------------------|------|
| unbounded reads (stream-then-reject) + `--top-k` has no bounds | `io.py:206-217` (`safe_read_strict`), `cli.py:67-90` (`_read_content_file`), `cli.py:786` (`--top-k` argparse) | Task 1 |
| text-mode search output sanitizes `content` only, not `ts/scope/layer/id` | `cli.py:424-433` (`_emit_search`) | Task 2 |
| lock-file open hardened in `44ca088` but no hardlink / 0600-mode regression test | `lock.py:33-62` (`_open_lock_file`), `tests/test_lock.py` | Task 3 |
| index-backend spec describes Phase-A flags in present tense | `docs/specs/2026-05-13-index-backend-integration-design.md:261-274` and `:465-528` | Task 4 |
| (DROPPED) `digest.py` dedup trailing-newline | not a bug — see "Dropped" note above | — |

---

## Task 1: Fstat-before-read size guard + `--top-k` bounds validation

`safe_read_strict` (`io.py:174`) and `_read_content_file` (`cli.py:67`) currently stream and reject *after* the running byte total exceeds the cap; this still reads up to the cap from a hostile regular file before failing. Add an `os.fstat(fd).st_size` check immediately after the regular-file assertion so an oversized regular file is rejected before any payload is read. Separately, `--top-k` is declared `search.add_argument("--top-k", type=int, default=8)` at `cli.py:786` with no bounds — a value `< 1` triggers Python negative-slice semantics in `recent`/`grep_search` (`blocks[:top_k]` with negative `top_k` returns all-but-the-last-N, NOT an empty list), and a huge value enlarges the emitted result set and the index-search `top_k` request. Add a validator rejecting `top_k < 1` and `top_k > MAX_TOP_K`.

**Scope note on `--top-k` (be precise — do not overstate the fix):** `MAX_TOP_K` bounds the **emitted result-set size** and the `top_k` value passed into `_try_index_search` / the index `mem.search(...)` request. It does **NOT** bound digest-side materialization: `recent` (`digest.py:277-307`) and `grep_search` (`digest.py:238-274`) both call `_load_all_blocks` to parse and materialize *every* block in the in-scope digest.md, sort the full list, and only then slice `[:top_k]`. Full digest materialization is bounded separately by `MAX_DIGEST_BYTES` (the read cap added in `44ca088`, hardened up-front by this task's fstat guard). Bounding the output set is the correct, cheap guard for `--top-k`; it is not — and should not be described as — a fix for digest-side memory use.

**Design decision — reject vs clamp `--top-k`:** REJECT (exit 30, the "startup dependency / bad invocation" code `cmd_search` already returns for an unknown scope at `cli.py:298-299`). Rationale: silently clamping a user's `--top-k 999999` to 1000 hides the mistake and produces results the user did not ask for; an explicit error is the honest contract. The validator rejects `top_k < 1` (this covers both zero and negatives — important because a negative `top_k` does NOT yield an empty result, it yields a negative Python slice) and `top_k > MAX_TOP_K`. `MAX_TOP_K = 1000` — far above any realistic retrieval need, low enough to bound the emitted set.

**Files:**
- Modify: `scripts/sspower_mem/sspower_mem/io.py` (`safe_read_strict`, the `try` block at lines 205-208)
- Modify: `scripts/sspower_mem/sspower_mem/cli.py` (`_read_content_file`, the `try` block at lines 76-79; add `MAX_TOP_K` after line 41; add `_validate_top_k` helper after `_sanitize_for_terminal` ends at line 45; call it at the top of `cmd_search`, line 274; fix the stale `--idx-only` argparse comment at line 788)
- Test: `scripts/sspower_mem/tests/test_io.py`, `scripts/sspower_mem/tests/test_cli.py`

- [ ] **Step 1: Write the failing fstat-before-read test for `safe_read_strict`**

Append to `scripts/sspower_mem/tests/test_io.py` (the file already imports `os`, `pytest`, `sspower_mem.io as io_mod`, and `safe_read_strict`; the `trust_root` fixture is provided by `tests/conftest.py`):

```python
def test_safe_read_strict_rejects_oversized_via_fstat_before_read(trust_root, monkeypatch):
    """Oversized regular file is rejected by fstat up front, before any payload is read."""
    path = trust_root / "digest.md"
    path.write_bytes(b"x" * 100)
    monkeypatch.setattr(io_mod, "MAX_DIGEST_BYTES", 10)

    real_read = os.read
    read_calls = []

    def _spy_read(fd, n):
        read_calls.append(n)
        return real_read(fd, n)

    monkeypatch.setattr(os, "read", _spy_read)

    with pytest.raises(OSError, match="content exceeds max bytes"):
        safe_read_strict(path, trust_root)

    assert read_calls == [], "fstat guard must reject before any os.read on the file"
```

- [ ] **Step 2: Write the failing fstat-before-read test for `_read_content_file`**

Append to `scripts/sspower_mem/tests/test_cli.py`. First confirm the file's existing imports cover `os`, `pytest`, and a way to reach `cli` — `_read_content_file` is imported inline in the test below, and `cli` is monkeypatched as a module:

```python
def test_read_content_file_rejects_oversized_via_fstat_before_read(tmp_path, monkeypatch):
    """_read_content_file rejects an oversized regular file via fstat, before any os.read."""
    import os
    from sspower_mem import cli as cli_mod
    from sspower_mem.cli import _read_content_file

    big = tmp_path / "payload.txt"
    big.write_bytes(b"x" * 100)
    monkeypatch.setattr(cli_mod, "MAX_CONTENT_FILE_BYTES", 10)

    real_read = os.read
    read_calls = []

    def _spy_read(fd, n):
        read_calls.append(n)
        return real_read(fd, n)

    monkeypatch.setattr(os, "read", _spy_read)

    with pytest.raises(OSError, match="content exceeds max bytes"):
        _read_content_file(str(big))

    assert read_calls == [], "fstat guard must reject before any os.read on the file"
```

- [ ] **Step 3: Run both fstat tests to verify they fail**

Run: `cd /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower/scripts/sspower_mem && UV_CACHE_DIR=/private/tmp/sspower-uv-cache uv run --with pytest pytest tests/test_io.py::test_safe_read_strict_rejects_oversized_via_fstat_before_read tests/test_cli.py::test_read_content_file_rejects_oversized_via_fstat_before_read -v`
Expected: BOTH FAIL — `assert read_calls == []` fails because the current code streams `os.read` before hitting the running-total cap (`read_calls` will be `[1048576]`). The `pytest.raises` clause itself still passes (the streaming cap eventually raises the same message); only the `read_calls == []` assertion fails.

- [ ] **Step 4: Add the fstat guard to `safe_read_strict`**

In `scripts/sspower_mem/sspower_mem/io.py`, inside `safe_read_strict`, the `try` block after `file_fd = os.open(rel.parts[-1], file_flags, dir_fd=cur_fd)` (line 204) currently reads:

```python
        try:
            _assert_regular_private_file(file_fd, path)
            chunks: list[bytes] = []
            total = 0
```

Replace it with:

```python
        try:
            _assert_regular_private_file(file_fd, path)
            if os.fstat(file_fd).st_size > MAX_DIGEST_BYTES:
                raise OSError(f"content exceeds max bytes: {MAX_DIGEST_BYTES}")
            chunks: list[bytes] = []
            total = 0
```

The streaming `total > MAX_DIGEST_BYTES` check below it (line 214) stays as a defence-in-depth backstop: it covers a regular file that GROWS between the `os.fstat` call and the read loop — a TOCTOU race the up-front fstat check cannot close. (It is not needed for non-regular special files: `_assert_regular_private_file` already rejects those before the read loop runs.)

- [ ] **Step 5: Add the fstat guard to `_read_content_file`**

In `scripts/sspower_mem/sspower_mem/cli.py`, inside `_read_content_file`, the `try` block after `file_fd = os.open(abs_path, file_flags)` (line 75) currently reads:

```python
    try:
        _assert_regular_private_file(file_fd, abs_path)
        chunks: list[bytes] = []
        total = 0
```

Replace it with:

```python
    try:
        _assert_regular_private_file(file_fd, abs_path)
        if os.fstat(file_fd).st_size > MAX_CONTENT_FILE_BYTES:
            raise OSError(f"content exceeds max bytes: {MAX_CONTENT_FILE_BYTES}")
        chunks: list[bytes] = []
        total = 0
```

- [ ] **Step 6: Run both fstat tests to verify they pass**

Run: `cd /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower/scripts/sspower_mem && UV_CACHE_DIR=/private/tmp/sspower-uv-cache uv run --with pytest pytest tests/test_io.py -k oversized tests/test_cli.py -k oversized -v`
Expected: PASS — both new fstat tests pass, and any pre-existing `oversized` tests (e.g. a streaming-cap test) still pass.

- [ ] **Step 7: Write the failing `--top-k` validation tests**

Append to `scripts/sspower_mem/tests/test_cli.py`. This block adds seven tests. The first five use the file's existing `_run` helper and `json` import; `_run` is subprocess-based — `(monkeypatch, tmp_path, *argv) -> (rc, out, err)`, signature confirmed at `test_cli.py:23`. The last two are direct `cmd_search` unit tests: `_run` runs the CLI in a child process, so it CANNOT verify monkeypatched call routing. They use the existing direct-`cmd_search` pattern (`Namespace` + `monkeypatch.setenv("HOME")`, as in `test_cli_search_oversized_digest_exits_20` at `test_cli.py:244`) and monkeypatch `cli._try_index_search` to prove the `--query` index path is bounded.

```python
def test_cli_search_rejects_negative_top_k(monkeypatch, tmp_path):
    rc, _, _ = _run(monkeypatch, tmp_path, "doctor", "--bootstrap")
    assert rc == 0
    rc, out, err = _run(
        monkeypatch, tmp_path,
        "search", "--scope", "user", "--mode", "recent", "--top-k", "-1",
    )
    assert rc == 30, err
    assert out == ""
    assert "top-k" in err


def test_cli_search_rejects_zero_top_k(monkeypatch, tmp_path):
    rc, _, _ = _run(monkeypatch, tmp_path, "doctor", "--bootstrap")
    assert rc == 0
    rc, out, err = _run(
        monkeypatch, tmp_path,
        "search", "--scope", "user", "--mode", "recent", "--top-k", "0",
    )
    assert rc == 30, err
    assert out == ""
    assert "top-k" in err


def test_cli_search_rejects_oversized_top_k(monkeypatch, tmp_path):
    rc, _, _ = _run(monkeypatch, tmp_path, "doctor", "--bootstrap")
    assert rc == 0
    rc, out, err = _run(
        monkeypatch, tmp_path,
        "search", "--scope", "user", "--mode", "recent", "--top-k", "1000000",
    )
    assert rc == 30, err
    assert out == ""
    assert "top-k" in err


def test_cli_search_rejects_oversized_top_k_via_query(monkeypatch, tmp_path):
    """A subprocess --query --top-k 1000000 is rejected with rc 30 (index path)."""
    rc, _, _ = _run(monkeypatch, tmp_path, "doctor", "--bootstrap")
    assert rc == 0
    rc, out, err = _run(
        monkeypatch, tmp_path,
        "search", "--scope", "user", "--query", "x", "--top-k", "1000000",
    )
    assert rc == 30, err
    assert out == ""
    assert "top-k" in err


def test_cli_search_accepts_in_range_top_k(monkeypatch, tmp_path):
    rc, _, _ = _run(monkeypatch, tmp_path, "doctor", "--bootstrap")
    assert rc == 0
    rc, _, _ = _run(
        monkeypatch, tmp_path,
        "add", "--scope", "user", "--layer", "user-global", "--content", "hello world",
    )
    assert rc == 0
    rc, out, err = _run(
        monkeypatch, tmp_path,
        "search", "--scope", "user", "--mode", "recent", "--top-k", "1000", "--json",
    )
    assert rc == 0, err
    assert json.loads(out)[0]["source"] == "digest-recent"


def test_cmd_search_query_rejects_oversized_top_k_before_index_call(monkeypatch, tmp_path):
    """An oversized --top-k on the --query path is rejected BEFORE _try_index_search.

    Monkeypatches _try_index_search to fail if it is ever called, proving the
    --top-k bound rejects up front rather than after the index request.
    """
    import sspower_mem.cli as cli_mod
    from sspower_mem.cli import cmd_search

    fake_home = tmp_path / "home"
    fake_home.mkdir()
    monkeypatch.setenv("HOME", str(fake_home))

    def _must_not_call(*a, **kw):
        raise AssertionError("_try_index_search called despite oversized --top-k")

    monkeypatch.setattr(cli_mod, "_try_index_search", _must_not_call)

    rc = cmd_search(
        Namespace(
            scope="user",
            cwd=None,
            layer=None,
            top_k=1_000_000,
            mode=None,
            query="x",
            json=True,
            idx_only=False,
        )
    )
    assert rc == 30


def test_cmd_search_query_forwards_in_range_top_k_to_index(monkeypatch, tmp_path):
    """An in-range --top-k (1000, == MAX_TOP_K) is accepted and forwarded to
    _try_index_search. Uses the literal 1000 rather than importing MAX_TOP_K:
    this test must already PASS at Step 8, before Step 9 defines the constant."""
    import sspower_mem.cli as cli_mod
    from sspower_mem.cli import cmd_search

    fake_home = tmp_path / "home"
    fake_home.mkdir()
    monkeypatch.setenv("HOME", str(fake_home))

    seen: list[int] = []

    def _spy(scope_ids, query, top_k, layer_filter):
        seen.append(top_k)
        return [], False

    monkeypatch.setattr(cli_mod, "_try_index_search", _spy)

    rc = cmd_search(
        Namespace(
            scope="user",
            cwd=None,
            layer=None,
            top_k=1000,
            mode=None,
            query="x",
            json=True,
            idx_only=True,
        )
    )
    assert rc == 0
    assert seen == [1000], "in-range top_k must be forwarded unchanged to the index call"
```

- [ ] **Step 8: Run the `--top-k` tests to verify the bound tests fail**

Run: `cd /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower/scripts/sspower_mem && UV_CACHE_DIR=/private/tmp/sspower-uv-cache uv run --with pytest pytest tests/test_cli.py -k top_k -v`
Expected: `test_cli_search_rejects_negative_top_k`, `test_cli_search_rejects_zero_top_k`, `test_cli_search_rejects_oversized_top_k`, `test_cli_search_rejects_oversized_top_k_via_query`, and `test_cmd_search_query_rejects_oversized_top_k_before_index_call` FAIL (current code has no bound and returns rc 0 / calls the index). `test_cli_search_accepts_in_range_top_k` and `test_cmd_search_query_forwards_in_range_top_k_to_index` PASS (1000 is already accepted today and forwarded unchanged).

- [ ] **Step 9: Add `MAX_TOP_K` constant and `_validate_top_k` helper**

In `scripts/sspower_mem/sspower_mem/cli.py`, the constants near line 40-41 currently read:

```python
_CONTROL_RE = re.compile(r"[\x00-\x08\x0b-\x1f\x7f-\x9f]")
MAX_CONTENT_FILE_BYTES = 8 * 1024 * 1024
```

Replace with:

```python
_CONTROL_RE = re.compile(r"[\x00-\x08\x0b-\x1f\x7f-\x9f]")
MAX_CONTENT_FILE_BYTES = 8 * 1024 * 1024
MAX_TOP_K = 1000
```

Then `_sanitize_for_terminal` currently ends at line 45:

```python
def _sanitize_for_terminal(s: str) -> str:
    return _CONTROL_RE.sub("?", s)
```

Add this helper immediately after it (a blank line, then):

```python
def _validate_top_k(top_k: int) -> str | None:
    """Return an error string if --top-k is below 1 or above MAX_TOP_K.

    Rejecting `< 1` (not just `== 0`) is deliberate: a negative top_k feeds
    a negative Python slice (`blocks[:top_k]`) in digest.recent/grep_search,
    which silently returns all-but-the-last-N blocks rather than an empty set.
    """
    if top_k < 1:
        return f"--top-k must be a positive integer (>= 1), got {top_k}"
    if top_k > MAX_TOP_K:
        return f"--top-k exceeds the maximum of {MAX_TOP_K}, got {top_k}"
    return None
```

- [ ] **Step 10: Call `_validate_top_k` at the top of `cmd_search`**

In `scripts/sspower_mem/sspower_mem/cli.py`, `cmd_search` currently begins at line 273:

```python
def cmd_search(args: argparse.Namespace) -> int:
    scopes = args.scope.split(",")
    needs_project = "project" in scopes
```

Replace those three lines with:

```python
def cmd_search(args: argparse.Namespace) -> int:
    top_k_error = _validate_top_k(args.top_k)
    if top_k_error:
        print(f"sspower-mem: {top_k_error}", file=sys.stderr)
        return 30
    scopes = args.scope.split(",")
    needs_project = "project" in scopes
```

- [ ] **Step 11: Fix the stale `--idx-only` argparse comment (comment-only)**

In `scripts/sspower_mem/sspower_mem/cli.py`, the `--idx-only` argument is declared at line 788 with a stale inline comment. It currently reads:

```python
    search.add_argument("--idx-only", action="store_true")  # Phase A: rejected with rc=30 (Phase C requires backend)
```

The comment is wrong: `cmd_search` does NOT reject `--idx-only` with rc=30. When `--idx-only` is set and the index search raises, `cmd_search` (`cli.py:326-329`) prints a stderr note and returns **rc 10**; when it returns hits it emits them with no grep fallback. Replace that line with:

```python
    search.add_argument("--idx-only", action="store_true")  # --query only: suppresses digest grep fallback; index raise exits rc=10
```

This is a comment-only change — no behavior changes. (`--idx-only` is read only on the `--query` path; it is ignored for `--mode recent`, which returns before the index path.)

- [ ] **Step 12: Run the full io + cli suites to verify all pass**

Run: `cd /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower/scripts/sspower_mem && UV_CACHE_DIR=/private/tmp/sspower-uv-cache uv run --with pytest pytest tests/test_io.py tests/test_cli.py -v`
Expected: PASS — all tests pass, including the nine new ones from this task (2 fstat + 7 `--top-k`: 5 subprocess bound/accept tests + 2 direct `cmd_search` index-path tests).

- [ ] **Step 13: Commit**

```bash
git add scripts/sspower_mem/sspower_mem/io.py scripts/sspower_mem/sspower_mem/cli.py scripts/sspower_mem/tests/test_io.py scripts/sspower_mem/tests/test_cli.py
```

```bash
git commit -m "fix(sspower-mem): fstat-before-read size guard + bound --top-k"
```

---

## Task 2: Sanitize all digest metadata in search text-mode output

`_emit_search` (`cli.py:424`) text mode prints the header line `[{source} {score}] {ts} · {scope} · {layer} · {id}` at `cli.py:430-431` with raw `ts`, `scope`, `layer`, `id` — only `content` passes through `_sanitize_for_terminal` (`cli.py:432`). A digest block whose `scope`/`layer`/`id`/`ts` contains terminal control bytes (parsed from an attacker-influenced `digest.md`) injects escape sequences into the user's terminal. Every parsed digest string emitted in text mode must be sanitized.

**Files:**
- Modify: `scripts/sspower_mem/sspower_mem/cli.py` (`_emit_search`, the text-mode loop at lines 429-433)
- Test: `scripts/sspower_mem/tests/test_cli.py`

- [ ] **Step 1: Write the failing metadata-sanitization test**

Append to `scripts/sspower_mem/tests/test_cli.py` (uses the pytest builtin `capsys` fixture):

```python
def test_emit_search_sanitizes_all_metadata_fields(capsys):
    from sspower_mem.cli import _emit_search

    hit = {
        "source": "digest-grep",
        "score": 0.5,
        "ts": "2026-05-21T00:00:00Z\x1b[31m",
        "scope": "user:\x07global",
        "layer": "user-\x00global",
        "id": "abc\x1bdef",
        "content": "body\x1btext",
    }
    _emit_search([hit], as_json=False)
    out = capsys.readouterr().out

    assert "\x1b" not in out
    assert "\x07" not in out
    assert "\x00" not in out
    # Each stripped control byte is replaced by the "?" substitute char.
    assert "2026-05-21T00:00:00Z?[31m" in out
    assert "user:?global" in out
    assert "user-?global" in out
    assert "abc?def" in out
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower/scripts/sspower_mem && UV_CACHE_DIR=/private/tmp/sspower-uv-cache uv run --with pytest pytest tests/test_cli.py::test_emit_search_sanitizes_all_metadata_fields -v`
Expected: FAIL — `assert "\x1b" not in out` fails because `ts/scope/layer/id` are emitted raw on the header line.

- [ ] **Step 3: Sanitize every metadata field in `_emit_search`**

In `scripts/sspower_mem/sspower_mem/cli.py`, the `_emit_search` text-mode loop at lines 429-433 currently reads:

```python
    for hit in cleaned:
        print(f"[{hit['source']} {hit['score']:.3f}] "
              f"{hit['ts']} · {hit['scope']} · {hit['layer']} · {hit['id']}")
        print(_sanitize_for_terminal(hit["content"]))
        print("---")
```

Replace it with:

```python
    for hit in cleaned:
        source = _sanitize_for_terminal(str(hit["source"]))
        ts = _sanitize_for_terminal(str(hit["ts"]))
        scope = _sanitize_for_terminal(str(hit["scope"]))
        layer = _sanitize_for_terminal(str(hit["layer"]))
        hit_id = _sanitize_for_terminal(str(hit["id"]))
        print(f"[{source} {hit['score']:.3f}] {ts} · {scope} · {layer} · {hit_id}")
        print(_sanitize_for_terminal(hit["content"]))
        print("---")
```

(`source` is also sanitized: although it is CLI-set today, it is emitted on the same line and sanitizing it keeps the contract uniform — every emitted string is sanitized. `score` is a float formatted by `:.3f`, no string content to sanitize.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower/scripts/sspower_mem && UV_CACHE_DIR=/private/tmp/sspower-uv-cache uv run --with pytest pytest tests/test_cli.py::test_emit_search_sanitizes_all_metadata_fields -v`
Expected: PASS.

- [ ] **Step 5: Run the full cli suite to confirm no regression**

Run: `cd /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower/scripts/sspower_mem && UV_CACHE_DIR=/private/tmp/sspower-uv-cache uv run --with pytest pytest tests/test_cli.py -v`
Expected: PASS — all tests pass (existing `--json`-mode tests are unaffected; the `--json` path at `cli.py:426-427` does not call `_sanitize_for_terminal`).

- [ ] **Step 6: Commit**

```bash
git add scripts/sspower_mem/sspower_mem/cli.py scripts/sspower_mem/tests/test_cli.py
```

```bash
git commit -m "fix(sspower-mem): sanitize all digest metadata in search text output"
```

---

## Task 3: Lock-file open hardening — regression coverage

`lock.py::_open_lock_file` (`lock.py:33`) was already rewritten in `44ca088` to mirror the digest-file open: openat-walk, `O_NOFOLLOW`, `O_NONBLOCK`, `_assert_regular_private_file` (`lock.py:55` — rejects non-regular files and `st_nlink != 1` multi-link files via `io.py:18`), and `os.fchmod(file_fd, 0o600)` (`lock.py:56`). **No production code change is needed for the lock open itself.** The residual gap is test coverage: `test_lock.py` has symlinked-final-file and symlinked-parent tests but NO hardlink-rejection test and NO explicit lock-file-mode (0o600) assertion. This task adds those two regression tests to lock in the hardening.

**Files:**
- Test only: `scripts/sspower_mem/tests/test_lock.py` (no production code change)

- [ ] **Step 1: Inspect `test_lock.py` imports**

Run: `cd /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower/scripts/sspower_mem && sed -n '1,15p' tests/test_lock.py`
Expected: confirms the file imports `acquire_lock` from `sspower_mem.lock`, plus `os`/`pytest`. Note whether `stat` is already imported — the new test below imports it locally inside the test function so the append is self-contained regardless.

- [ ] **Step 2: Write the hardlink-rejection and 0600-mode tests**

Append to `scripts/sspower_mem/tests/test_lock.py`:

```python
def test_acquire_lock_refuses_hardlink_to_outside_file(tmp_path):
    """A lock file hard-linked to an outside file (st_nlink > 1) is rejected.

    Also asserts the outside file's mode is unchanged: the lock open does
    os.fchmod(fd, 0o600) AFTER _assert_regular_private_file, so a wrong
    ordering could chmod the hard-linked outside file before raising.
    Capturing the mode before/after locks in rejection-BEFORE-chmod.
    """
    import os
    import stat

    lock_dir = tmp_path / "idx"
    lock_dir.mkdir()
    outside = tmp_path / "outside.lock"
    outside.write_text("attacker-controlled", encoding="utf-8")
    lock_path = lock_dir / ".lock"
    os.link(outside, lock_path)
    mode_before = stat.S_IMODE(outside.stat().st_mode)

    with pytest.raises(OSError):
        with acquire_lock(lock_path, parent_anchor=tmp_path):
            pass

    assert outside.read_text(encoding="utf-8") == "attacker-controlled"
    assert stat.S_IMODE(outside.stat().st_mode) == mode_before, (
        "outside file mode changed — fchmod ran before the hardlink rejection"
    )


def test_acquire_lock_file_created_at_0600(tmp_path):
    """A freshly created lock file ends up at mode 0600."""
    import stat

    lock_dir = tmp_path / "idx"
    lock_dir.mkdir()
    lock_path = lock_dir / ".lock"

    with acquire_lock(lock_path, parent_anchor=tmp_path):
        pass

    assert lock_path.exists()
    assert stat.S_IMODE(lock_path.stat().st_mode) == 0o600
```

- [ ] **Step 3: Run the new tests to verify they pass**

Run: `cd /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower/scripts/sspower_mem && UV_CACHE_DIR=/private/tmp/sspower-uv-cache uv run --with pytest pytest tests/test_lock.py -v`
Expected: PASS — both new tests pass against the already-hardened `_open_lock_file` (`_assert_regular_private_file` raises `OSError("path ... has multiple hard links")` on `st_nlink != 1`; `os.fchmod` sets 0o600). This is a regression-coverage task: a passing test on first run is the expected and acceptable outcome — the tests confirm and lock in `44ca088`'s hardening rather than driving new code.

> Note for the implementer: if either new test FAILS, the lock open is NOT actually hardened as `44ca088`'s message claims — stop and re-read `lock.py::_open_lock_file`, then add the missing `O_NOFOLLOW` / `_assert_regular_private_file` / `os.fchmod` step before proceeding.

- [ ] **Step 4: Commit**

```bash
git add scripts/sspower_mem/tests/test_lock.py
```

```bash
git commit -m "test(sspower-mem): lock-file hardlink rejection + 0600 mode regression coverage"
```

---

## Task 4: Qualify Phase-A index-flag descriptions in the spec (doc-only)

`docs/specs/2026-05-13-index-backend-integration-design.md` describes `--query` and `--idx-only` in two places — the CLI synopsis block (lines 261-274) and the "Read path" block (lines 465-528) — with stale framing that predates the current tree (the spec was drafted against a Phase-A install with no index backend; the package is now v0.3.0 / Phase D and DOES ship the `sspower_mem.mem` subpackage). This must be corrected to describe the **actual current `cli.py` behavior**: the index-backed paths are live when the `sspower_mem.mem` backend imports and a working index exists, and the `--idx-only` rc=10 path is **conditional** on `_try_index_search` raising — it is not a guaranteed outcome.

**Actual current behavior (verified against `cli.py:273-344` and `_try_index_search` at `cli.py:347-397`):**
- `--idx-only` IS a functional flag — but **only on the `--query` path**. At `cli.py:326-331`, when `args.idx_only` is set: if the index search raised (`index_raised` is `True`), `cmd_search` prints `"sspower-mem: index search raised under --idx-only"` to stderr and returns **rc 10**; otherwise it emits the index hits via `_emit_search` and returns **rc 0** with **no grep fallback**. The grep fallback at `cli.py:337-343` is only reached when `--idx-only` is NOT set. With `--mode recent`, `--idx-only` is **accepted by argparse but IGNORED**: `cmd_search` returns from the `args.mode == "recent"` branch (`cli.py:307-314`) before the index path and never reads `args.idx_only`.
- **rc 10 under `--idx-only` is conditional, not guaranteed.** `cmd_search` returns rc 10 ONLY when `_try_index_search` returns `index_raised=True`. `_try_index_search` (`cli.py:347-397`) reports `index_raised=True` in exactly three cases: (1) `import sspower_mem.mem` / `from sspower_mem.mem.factory import build_memory` raises `ImportError`; (2) `build_memory(...)` raises; (3) any per-scope `mem.search(...)` raises. **The current tree (`scripts/sspower_mem/`, v0.3.0) DOES ship the `sspower_mem/mem/` subpackage** (`__init__.py`, `factory.py`, `embedder.py`, `extract.py`, `idx.py`, `noop.py`) and `pyproject.toml` declares `mem0ai`/`chromadb`/`model2vec` — so on a current install with those deps present and a working index, the import path succeeds, `build_memory` succeeds, `mem.search` returns results, and `_try_index_search` returns `index_raised=False` → `--idx-only` exits **rc 0**, not rc 10. rc 10 occurs only when the backend is genuinely missing or broken at runtime (deps not installed, Chroma init failure, search exception). `--idx-only` is therefore a "fail loudly if the index backend is missing/broken" debugging knob — it is NOT a no-op, and it does NOT "consistently exit rc 10".
- `--query` without `--idx-only`: the index is tried; on raise OR empty result, `cmd_search` falls through to the deterministic `grep_search` over `digest.md`.

The spec must NOT say "`--idx-only` has no effect in Phase A", and must NOT claim `--idx-only` "always" / "consistently" exits rc 10 — that is true only when `_try_index_search` raises. Fix is doc-only — no code is touched.

**Files:**
- Modify: `docs/specs/2026-05-13-index-backend-integration-design.md` (CLI synopsis block, lines 261-274; "Read path" block, lines 465-528)

- [ ] **Step 1: Read the current synopsis block to confirm exact text**

Run: `cd /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower && sed -n '261,274p' docs/specs/2026-05-13-index-backend-integration-design.md`
Expected: prints the `sspower-mem search` synopsis and the `--query` / `--mode recent` / `--idx-only` comment lines, present-tense.

- [ ] **Step 2: Replace the synopsis `--query` / `--idx-only` comment lines**

In `docs/specs/2026-05-13-index-backend-integration-design.md`, lines 261-274 currently read:

```
sspower-mem search --scope <project|user|project,user> [--cwd <path>] [--layer <l1,l2,...>]
                   (--query <text> | --mode recent) [--top-k 8] [--json] [--idx-only]
                   # --query <text>:  semantic/grep search (default behavior).
                   # --mode recent:   no query; return top-k most-recent blocks. Bypasses the index;
                   #                  source="digest-recent". Used by hooks/session-start.
                   # Exactly one of --query and --mode is required.
                   # --idx-only: disables ALL digest fallback (both exception fallback AND zero-result
                   #              fallback). Renamed from v5's `--no-grep-fallback` (which only gated
                   #              the 0-result fallback — Codex v6 flagged the ambiguity).
                   #              Behavior with --idx-only set:
                   #                - the index raises  → CLI exits NONZERO (caller debugs the dep/Chroma).
                   #                - the index returns [] → CLI prints [] and exits 0 (legitimate no-match).
                   #              Default (flag NOT set): both fallbacks active, digest grep covers
                   #              both exceptions and zero-result.
```

Replace those 14 lines with:

```
sspower-mem search --scope <project|user|project,user> [--cwd <path>] [--layer <l1,l2,...>]
                   (--query <text> | --mode recent) [--top-k 8] [--json] [--idx-only]
                   # --top-k: must be an integer in [1, 1000]; out-of-range values are
                   #          REJECTED with rc=30 (Phase E hardening). MAX_TOP_K bounds the
                   #          emitted result set and the index-search top_k request — it does
                   #          NOT bound digest-side block materialization (digest.recent /
                   #          grep_search load all in-scope blocks, then slice; that is
                   #          bounded separately by MAX_DIGEST_BYTES).
                   # --query <text>:  the index is tried first; on raise OR empty result the
                   #                  CLI falls through to the deterministic digest grep
                   #                  (source="digest-grep") unless --idx-only is set. When the
                   #                  index backend is absent or broken at runtime, _try_index_search
                   #                  reports index_raised=True and --query resolves to the grep path.
                   # --mode recent:   no query; return top-k most-recent blocks. Bypasses the index;
                   #                  source="digest-recent". Used by hooks/session-start.
                   # Exactly one of --query and --mode is required.
                   # --idx-only: meaningful ONLY with --query — it suppresses the digest grep
                   #              fallback (both the exception fallback AND the zero-result
                   #              fallback) so the CLI emits only index hits. With --mode recent
                   #              it is IGNORED: cmd_search returns from the recent branch before
                   #              the index path and never reads args.idx_only.
                   #              Renamed from v5's `--no-grep-fallback` (which only gated the
                   #              0-result fallback — Codex v6 flagged the ambiguity).
                   #              Behavior with --query and --idx-only set (current code, cli.py cmd_search):
                   #                - _try_index_search raised → CLI prints a stderr note, exits rc=10.
                   #                - the index returned []    → CLI prints [] and exits rc=0 (legit no-match).
                   #                - the index returned hits  → CLI emits them and exits rc=0.
                   #              The rc=10 path is CONDITIONAL: _try_index_search reports
                   #              index_raised=True only when the mem backend import fails, OR
                   #              build_memory raises, OR a per-scope mem.search raises. With the
                   #              sspower_mem.mem subpackage and the mem0ai/chromadb/model2vec deps
                   #              installed and a working index, --idx-only exits rc=0. --idx-only
                   #              is thus a "fail loud if the index is missing/broken" debugging
                   #              knob — NOT a no-op, and NOT a guaranteed rc=10.
                   #              Default (flag NOT set): grep fallback active, covering both the
                   #              index-raise and zero-result cases.
```

- [ ] **Step 3: Read the current "Read path" block to confirm exact text**

Run: `cd /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower && sed -n '465,530p' docs/specs/2026-05-13-index-backend-integration-design.md`
Expected: prints the ` #### Read path` heading, the fenced `search (deterministic order)` block, and the `CLI flags:` sub-block ending with `--idx-only   disable step 3 (index-only mode for debugging)` at line 528.

- [ ] **Step 4: Add an index-backend qualifier under the "Read path" heading**

In `docs/specs/2026-05-13-index-backend-integration-design.md`, line 465 currently reads:

```
#### Read path
```

Replace it with:

```
#### Read path

> **INDEX-BACKEND NOTE:** The index-backed steps below (steps 1, 4 of the
> deterministic order, the `source: "index"` entries, and the index-multi-scope
> `min_max_norm` rule) describe the semantic-index contract. They are live only
> when the `sspower_mem.mem` backend is importable and a working index exists.
> When the backend is absent or broken at runtime, `_try_index_search` reports
> `index_raised=True`: `--query` then resolves to the deterministic grep path,
> and `--idx-only` exits rc=10. When the backend IS present and functional,
> `--query` returns `source: "index"` hits and `--idx-only` exits rc=0. The grep
> fallback scoring and `digest-recent` paths below are always live regardless of
> index-backend state.
```

- [ ] **Step 5: Fix the inaccurate `--idx-only` line in the "Read path" `CLI flags` block**

In the same file, the `CLI flags:` sub-block currently has, at line 528:

```
  --idx-only   disable step 3 (index-only mode for debugging)
```

This is inaccurate: `--idx-only` does not "disable step 3" (step 3 in the list at lines 467-477 is the zero-result grep fallback, and step 4 is the index-hit return) — it disables the grep **fallback** (the index call itself, step 1, always runs). Replace line 528 with:

```
  --idx-only   meaningful only with --query: suppress the grep fallback and
               return only index hits. When _try_index_search raises (backend
               missing/broken) it exits rc=10; on a working index it exits rc=0.
               Ignored with --mode recent. See the search synopsis above for
               the full contract and the conditional rc=10 behavior.
```

- [ ] **Step 6: Verify the spec edits read coherently**

Run: `cd /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower && sed -n '261,290p' docs/specs/2026-05-13-index-backend-integration-design.md` then `cd /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower && sed -n '465,540p' docs/specs/2026-05-13-index-backend-integration-design.md`
Expected: the synopsis carries the `--top-k` bound note and the corrected `--idx-only` conditional-rc=10 description; the "Read path" block carries the `INDEX-BACKEND NOTE` callout and the corrected `--idx-only` `CLI flags` line. No claim that `--idx-only` "has no effect", "disables step 3", or "always/consistently exits rc=10" remains — the rc=10 path is described as conditional on `_try_index_search` raising.

- [ ] **Step 7: Commit**

```bash
git add docs/specs/2026-05-13-index-backend-integration-design.md
```

```bash
git commit -m "docs(sspower-mem): correct Phase-A index-flag descriptions in spec"
```

---

## Final verification

- [ ] **Step 1: Run the full sspower-mem test suite**

Run: `cd /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower/scripts/sspower_mem && UV_CACHE_DIR=/private/tmp/sspower-uv-cache uv run --with pytest pytest tests/ -v`
Expected: PASS — every test passes. Baseline before this plan is **152 tests** (verified via `pytest tests/ --co -q` on the current tree — note the "75" figure in `44ca088`'s commit message is stale and was NOT trusted). This plan adds **12 new tests**, all enumerated:

- Task 1 (9): `test_safe_read_strict_rejects_oversized_via_fstat_before_read`, `test_read_content_file_rejects_oversized_via_fstat_before_read`, `test_cli_search_rejects_negative_top_k`, `test_cli_search_rejects_zero_top_k`, `test_cli_search_rejects_oversized_top_k`, `test_cli_search_rejects_oversized_top_k_via_query`, `test_cli_search_accepts_in_range_top_k`, `test_cmd_search_query_rejects_oversized_top_k_before_index_call`, `test_cmd_search_query_forwards_in_range_top_k_to_index`
- Task 2 (1): `test_emit_search_sanitizes_all_metadata_fields`
- Task 3 (2): `test_acquire_lock_refuses_hardlink_to_outside_file`, `test_acquire_lock_file_created_at_0600`

Expected final count: **164 passing, 0 failures** (152 + 12). No existing assertion is tightened or removed — the prior draft's Task 3, which tightened a digest round-trip assertion, was dropped along with its dedup task.

- [ ] **Step 2: Confirm the working tree is clean**

Run: `cd /Users/sskys/.claude/plugins/marketplaces/sskys18/plugins/sspower && git status --short`
Expected: empty output — all four task commits landed, working tree clean.
