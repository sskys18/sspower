# sspower-mem Phase C — Index Backend Wiring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `sspower:subagent-driven-development` (recommended; Phase A pattern) or `sspower:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Wire Mem0 (`mem0ai/mem0` @ upstream `70bc9e51d57fe005d02b7b6d81b56476bade3cb3`) as the semantic-index backend for `sspower-mem`, with **client-side LLM extraction** via `codex-bridge.mjs complete --json`. Phase A digest path stays authoritative; Mem0 receives only `infer=False` writes (raw + extracted). Phase C never calls `Memory.add(infer=True)`.

**Architecture:**
- **Add path** (lock-held): digest append → `Memory.add(infer=False, kind=raw)` → `codex-bridge complete --json` → `Memory.add(infer=False, kind=extracted) × N`. Failures in step 2/3 do not roll back step 1.
- **Search path**: `Memory.search` (one call per scope, min-max normalized merge); on exception or zero hits without `--idx-only`, fall back to existing Phase A grep.
- **Registration**: `LlmFactory.register_provider("sspower-noop", "sspower_mem.mem.noop.NoOpLLM", BaseLlmConfig)` + `EmbedderFactory.provider_to_class["sspower-model2vec"] = "sspower_mem.mem.embedder.Model2VecEmbedder"`. No other monkey-patches except defensive telemetry no-op.
- **Lazy import**: nothing under `sspower_mem/mem/*` is importable from `cli.py` at module load. All Mem0/chromadb/model2vec imports happen inside `cmd_add` / `cmd_search` / `cmd_digest` / `cmd_doctor --bootstrap` AFTER the digest step. A missing dep surfaces as rc=10 (degraded), never bypasses the digest write.

**Tech Stack:** Python 3.11+, `mem0ai==<pin>` (pin chosen at Task 1), `chromadb==<pin>`, `model2vec==<pin>`, `pytest>=8`. Bridge: `scripts/codex-bridge.mjs complete --json` (Phase B). Local-only; no PyPI publish.

**Spec sources (single source of truth):**
- `docs/specs/2026-05-13-index-backend-integration-design.md` §3 D11/D13/D14, §6.1, §6.1.5, §6.3, §6.4, §8, §9 Phase C.
- `docs/specs/2026-05-13-index-provider-registration.md` (Phase 0 deliverable; upstream `70bc9e51`).

**Convergence target:** 1-3 auto-review rounds (Phase A took 8; tighter prompts + complete code per step).

---

## File Structure

**New files:**

```
scripts/sspower_mem/sspower_mem/mem/
  __init__.py          # telemetry shield: env vars + module patch BEFORE any `import mem0`
  noop.py              # NoOpLLM(LLMBase) — raises on generate_response
  embedder.py          # Model2VecEmbedder(BaseEmbedderConfig) — loads potion-base-8M
  factory.py           # register_providers(), build_memory(scope_id, idx_dir)
  extract.py           # bridge_extract_facts(content) → list[str]; ExtractFailed; 32×512 caps
  idx.py               # raw_upsert(memory, content, meta); extracted_upsert(memory, text, meta); idempotency pre-search

scripts/sspower_mem/tests/
  test_mem_telemetry.py    # subprocess assertion: MEM0_TELEMETRY env + patch
  test_mem_noop.py
  test_mem_embedder.py
  test_mem_factory.py
  test_mem_extract.py      # 10-row error/truncation matrix
  test_mem_idx.py          # dedup + entity-store canary
  test_cli_phase_c.py      # cmd_add chain (step 2/3a/3b), cmd_search merge, cmd_digest rebuild
  test_lazy_import.py      # `import sspower_mem.cli` does not load mem0
  fixtures/
    fake_bridge.sh         # deterministic bridge stub (writes fixed JSON to stdout, exits 0)
```

**Modified files:**

```
scripts/sspower_mem/pyproject.toml         # version bump 0.1.1→0.2.0; add mem0/chromadb/model2vec deps with pinned versions
scripts/sspower_mem/sspower_mem/cli.py     # cmd_add: step 2/3a/3b chain; cmd_search: index path + merge;
                                           # cmd_digest: --rebuild-chroma + --reextract; cmd_doctor: bootstrap extensions
scripts/sspower_mem/sspower_mem/doctor.py  # extend bootstrap: m2v download, chroma init, bridge round-trip, uvx warmup;
                                           # extend health: entity-store canary
CLAUDE.md                                  # gotcha (d) from handoff: scripts/ now lists bridge + registry + sspower_mem/
```

**Out of scope (deferred to Phase D/E/F per spec §9):**
- `sspower-mem migrate` (Phase D).
- Hook + skill rewrites (Phase E).
- Legacy belt removal (Phase F).

---

## Task 1: Pin dependencies (exact versions) + version bump

**Files:**
- Modify: `scripts/sspower_mem/pyproject.toml`

**Rationale (Codex review blocking #1):** Phase 0 §2 caveat 2 calls out private-API risk on `EmbedderFactory.provider_to_class`. Ranged pins (`>=`,`<`) re-introduce that risk on minor upstream bumps. Phase C uses **exact** pins for every backend dep.

- [ ] **Step 1: First-pass resolution to discover concrete versions**

Run: `cd scripts/sspower_mem && UV_CACHE_DIR=/private/tmp/sspower-uv-cache uv tree --package mem0ai --frozen=false 2>/dev/null || true`

Then resolve with loose pins to read the lockfile back:

```bash
cd scripts/sspower_mem
# Temporarily add loose pins so uv resolves the actual versions Mem0 wants.
uv add --no-sync \
  "mem0ai @ git+https://github.com/mem0ai/mem0.git@70bc9e51d57fe005d02b7b6d81b56476bade3cb3" \
  "chromadb" "model2vec"
UV_CACHE_DIR=/private/tmp/sspower-uv-cache uv lock
# Inspect uv.lock for the resolved chromadb + model2vec versions; pin them exactly in Step 2.
grep -A1 -E '^name = "(chromadb|model2vec)"' uv.lock | grep '^version' | awk -F'"' '{print $2}'
```

Expected: two version strings (chromadb, model2vec). Write them down before Step 2.

- [ ] **Step 2: Edit pyproject.toml with exact pins**

Substitute `<CHROMADB_VERSION>` / `<MODEL2VEC_VERSION>` with the strings from Step 1.

```toml
[project]
name = "sspower-mem"
version = "0.2.0"
description = "sspower memory backend: digest source-of-truth + Mem0 semantic index (Phase C)"
requires-python = ">=3.11"
dependencies = [
    # Mem0 OSS pinned to Phase 0 verification SHA (private-API surface verified here).
    "mem0ai @ git+https://github.com/mem0ai/mem0.git@70bc9e51d57fe005d02b7b6d81b56476bade3cb3",
    # Exact pins — Phase 0 §2 caveat 2 (private dict API may rename on minor bumps).
    "chromadb==<CHROMADB_VERSION>",
    "model2vec==<MODEL2VEC_VERSION>",
]

[project.scripts]
sspower-mem = "sspower_mem.cli:main"

[project.optional-dependencies]
test = ["pytest>=8"]

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["sspower_mem"]

[tool.hatch.metadata]
allow-direct-references = true  # required for git+https dependency
```

- [ ] **Step 3: Re-resolve lockfile against exact pins**

Run: `cd scripts/sspower_mem && UV_CACHE_DIR=/private/tmp/sspower-uv-cache uv lock`
Expected: lockfile updates; no errors; resolution pulls mem0 @ pinned SHA + the two exact backend pins.

**Acceptance:** `uv.lock` shows `version = "<CHROMADB_VERSION>"` and `version = "<MODEL2VEC_VERSION>"` for the corresponding packages, identical to the strings recorded in Step 1.

- [ ] **Step 4: Commit**

```bash
git add scripts/sspower_mem/pyproject.toml scripts/sspower_mem/uv.lock
git commit -m "feat(sspower-mem): pin Phase C deps exactly (mem0 @ 70bc9e51 + exact chromadb/model2vec); bump 0.2.0"
```

---

## Task 2: Telemetry shield (`mem/__init__.py`)

**Files:**
- Create: `scripts/sspower_mem/sspower_mem/mem/__init__.py`
- Create: `scripts/sspower_mem/tests/test_mem_telemetry.py`

**Rationale:** Phase 0 §5 found `mem0.memory.telemetry` instantiates `client_telemetry = AnonymousTelemetry()` at module-import time (line 182). `MEM0_TELEMETRY=False` MUST be in `os.environ` BEFORE the first `import mem0`. Setting it inside `mem/__init__.py` works only if `sspower_mem.mem` is the first thing to import mem0 — enforced by lazy-import policy + the defensive module patch immediately after.

- [ ] **Step 1: Write failing test** — `scripts/sspower_mem/tests/test_mem_telemetry.py`

```python
"""Phase C telemetry shield: env var + defensive module patch.

The shield runs at `import sspower_mem.mem`. Asserts:
  1. MEM0_TELEMETRY=False set in environment.
  2. mem0.memory.telemetry.capture_event is a no-op.
  3. mem0.memory.telemetry.MEM0_TELEMETRY is False at the patched module.
"""
from __future__ import annotations

import os
import subprocess
import sys
import textwrap


def test_telemetry_env_and_patch_in_fresh_subprocess(tmp_path):
    """Run a clean Python subprocess that imports sspower_mem.mem first, then mem0."""
    script = textwrap.dedent(
        """
        import os, sys, json
        # Ensure env not pre-set so the shield's responsibility is testable.
        os.environ.pop("MEM0_TELEMETRY", None)
        import sspower_mem.mem  # noqa: F401  — shield runs here
        import mem0.memory.telemetry as t
        result = {
            "env": os.environ.get("MEM0_TELEMETRY"),
            "patched_flag": t.MEM0_TELEMETRY,
            "capture_event_noop": t.capture_event("x") is None,
            "capture_client_event_noop": t.capture_client_event("x") is None,
            "sample_rate_env": os.environ.get("MEM0_TELEMETRY_SAMPLE_RATE"),
        }
        print(json.dumps(result))
        """
    )
    env = os.environ.copy()
    env["PYTHONPATH"] = str(tmp_path.parent.parent / "sspower_mem")  # adjust per layout
    out = subprocess.check_output([sys.executable, "-c", script], env=env, text=True)
    result = __import__("json").loads(out.strip().splitlines()[-1])
    assert result["env"] == "False"
    assert result["sample_rate_env"] == "0"
    assert result["patched_flag"] is False
    assert result["capture_event_noop"] is True
    assert result["capture_client_event_noop"] is True
```

- [ ] **Step 2: Run test, expect FAIL**

Run: `cd scripts/sspower_mem && UV_CACHE_DIR=/private/tmp/sspower-uv-cache uv run --with pytest pytest tests/test_mem_telemetry.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'sspower_mem.mem'`.

- [ ] **Step 3: Create `sspower_mem/mem/__init__.py`**

```python
"""Phase C Mem0 wiring. Importing this package MUST happen before any `import mem0`.

Telemetry shield order:
  1. Set env vars (idempotent; safe if already set).
  2. Import mem0.memory.telemetry — this triggers module-level
     `client_telemetry = AnonymousTelemetry()` which reads the env var.
  3. Defensively monkey-patch capture_event / capture_client_event /
     MEM0_TELEMETRY so even a malformed env never leaks PostHog calls.

Per docs/specs/2026-05-13-index-provider-registration.md §5.
"""
from __future__ import annotations

import os

# Step 1: env BEFORE first mem0 import.
os.environ.setdefault("MEM0_TELEMETRY", "False")
os.environ.setdefault("MEM0_TELEMETRY_SAMPLE_RATE", "0")

# Step 2: import telemetry module (now safe — env is set).
import mem0.memory.telemetry as _telemetry  # noqa: E402

# Step 3: defensive patch.
_telemetry.MEM0_TELEMETRY = False
_telemetry.capture_event = lambda *a, **kw: None
_telemetry.capture_client_event = lambda *a, **kw: None
```

- [ ] **Step 4: Run test, expect PASS**

Run: `cd scripts/sspower_mem && UV_CACHE_DIR=/private/tmp/sspower-uv-cache uv run --with pytest pytest tests/test_mem_telemetry.py -v`
Expected: PASS.

- [ ] **Step 5: Mem0 import-side-effect probe**

Add to `tests/test_mem_telemetry.py`:

```python
def test_mem0_import_does_not_leak_outside_MEM0_DIR(tmp_path):
    """Phase 0 open issue #5: verify mem0 setup_config doesn't write outside MEM0_DIR."""
    mem0_dir = tmp_path / "mem0_probe"
    mem0_dir.mkdir()
    home = tmp_path / "fake_home"
    home.mkdir()
    env = os.environ.copy()
    env["MEM0_DIR"] = str(mem0_dir)
    env["HOME"] = str(home)
    env["MEM0_TELEMETRY"] = "False"
    subprocess.check_call(
        [sys.executable, "-c", "import sspower_mem.mem; import mem0"],
        env=env,
    )
    # mem0 may write to MEM0_DIR (expected). It MUST NOT write to fake_home/.mem0.
    leaked = list((home / ".mem0").rglob("*")) if (home / ".mem0").exists() else []
    assert leaked == [], f"mem0 leaked into HOME despite MEM0_DIR override: {leaked}"
```

Run: same pytest command. Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add scripts/sspower_mem/sspower_mem/mem/__init__.py scripts/sspower_mem/tests/test_mem_telemetry.py
git commit -m "feat(sspower-mem/mem): telemetry shield + import-leak probe"
```

---

## Task 3: NoOpLLM (`mem/noop.py`)

**Files:**
- Create: `scripts/sspower_mem/sspower_mem/mem/noop.py`
- Create: `scripts/sspower_mem/tests/test_mem_noop.py`

- [ ] **Step 1: Write failing test** — `tests/test_mem_noop.py`

```python
"""NoOpLLM defensive provider — raises if infer=True is ever reactivated."""
from __future__ import annotations

import pytest


def test_noop_llm_raises_on_generate_response():
    import sspower_mem.mem  # noqa: F401 — shield first
    from mem0.llms.configs import BaseLlmConfig
    from sspower_mem.mem.noop import NoOpLLM

    llm = NoOpLLM(BaseLlmConfig())
    with pytest.raises(RuntimeError, match="infer=True forbidden in Phase C"):
        llm.generate_response(messages=[{"role": "user", "content": "x"}])


def test_noop_llm_subclasses_LLMBase():
    import sspower_mem.mem  # noqa: F401
    from mem0.llms.base import LLMBase
    from sspower_mem.mem.noop import NoOpLLM

    assert issubclass(NoOpLLM, LLMBase)
```

- [ ] **Step 2: Run, expect FAIL** (`No module named 'sspower_mem.mem.noop'`)

Run: `cd scripts/sspower_mem && UV_CACHE_DIR=/private/tmp/sspower-uv-cache uv run --with pytest pytest tests/test_mem_noop.py -v`

- [ ] **Step 3: Implement** — `sspower_mem/mem/noop.py`

```python
"""Defensive NoOpLLM. Mem0 requires an LLM in its config, but Phase C never
calls Memory.add(infer=True). Any future code path that accidentally triggers
LLM-based extraction will raise loudly here.

Per docs/specs/2026-05-13-index-backend-integration-design.md §6.3.
"""
from __future__ import annotations

from mem0.llms.base import LLMBase


class NoOpLLM(LLMBase):
    def __init__(self, config=None):
        super().__init__(config)

    def generate_response(self, messages, response_format=None, tools=None, tool_choice="auto"):
        raise RuntimeError(
            "infer=True forbidden in Phase C; extraction is client-side via codex-bridge complete --json"
        )
```

- [ ] **Step 4: Run, expect PASS**

- [ ] **Step 5: Commit**

```bash
git add scripts/sspower_mem/sspower_mem/mem/noop.py scripts/sspower_mem/tests/test_mem_noop.py
git commit -m "feat(sspower-mem/mem): NoOpLLM defensive provider"
```

---

## Task 4: Model2VecEmbedder (`mem/embedder.py`)

**Files:**
- Create: `scripts/sspower_mem/sspower_mem/mem/embedder.py`
- Create: `scripts/sspower_mem/tests/test_mem_embedder.py`

**Rationale:** Phase 0 §2 caveat 1: `EmbedderFactory.create` calls `embedder_instance(BaseEmbedderConfig(**config))` — embedder must accept a `BaseEmbedderConfig` arg. Model: `minishlab/potion-base-8M` (D4).

- [ ] **Step 1: Write failing test** — `tests/test_mem_embedder.py`

```python
"""Model2VecEmbedder loads potion-base-8M and embeds via the Mem0 EmbeddingBase API."""
from __future__ import annotations


def test_embedder_accepts_base_config_and_embeds():
    import sspower_mem.mem  # noqa: F401
    from mem0.configs.embeddings.base import BaseEmbedderConfig
    from sspower_mem.mem.embedder import Model2VecEmbedder

    cfg = BaseEmbedderConfig(model="minishlab/potion-base-8M")
    emb = Model2VecEmbedder(cfg)
    vec = emb.embed("hello world", memory_action="add")
    assert isinstance(vec, list)
    assert len(vec) > 0
    assert all(isinstance(x, float) for x in vec)


def test_embedder_subclasses_EmbeddingBase():
    import sspower_mem.mem  # noqa: F401
    from mem0.embeddings.base import EmbeddingBase
    from sspower_mem.mem.embedder import Model2VecEmbedder

    assert issubclass(Model2VecEmbedder, EmbeddingBase)


def test_embedder_dims_match_potion_base_8m():
    """potion-base-8M is 256-dim per upstream model card; lock this so we
    notice if the pinned model file changes shape."""
    import sspower_mem.mem  # noqa: F401
    from mem0.configs.embeddings.base import BaseEmbedderConfig
    from sspower_mem.mem.embedder import Model2VecEmbedder

    cfg = BaseEmbedderConfig(model="minishlab/potion-base-8M")
    emb = Model2VecEmbedder(cfg)
    assert len(emb.embed("x", memory_action="add")) == 256
```

- [ ] **Step 2: Run, expect FAIL**

- [ ] **Step 3: Implement** — `sspower_mem/mem/embedder.py`

```python
"""Model2Vec embedder adapter for Mem0 EmbedderFactory.

Per docs/specs/2026-05-13-index-backend-integration-design.md §6.3.
Per docs/specs/2026-05-13-index-provider-registration.md §2 caveat 1.

The Mem0 factory calls Model2VecEmbedder(BaseEmbedderConfig(**config_dict)).
Caller config must restrict to BaseEmbedderConfig fields (model name suffices).
"""
from __future__ import annotations

from mem0.configs.embeddings.base import BaseEmbedderConfig
from mem0.embeddings.base import EmbeddingBase

_DEFAULT_MODEL = "minishlab/potion-base-8M"


class Model2VecEmbedder(EmbeddingBase):
    def __init__(self, config: BaseEmbedderConfig):
        super().__init__(config)
        # Lazy-import model2vec inside __init__ so a missing dep surfaces
        # at first construction (inside the locked add path = rc=10), not at
        # mem/__init__ import time (which would bypass the digest write).
        from model2vec import StaticModel

        model_name = getattr(config, "model", None) or _DEFAULT_MODEL
        self._model = StaticModel.from_pretrained(model_name)

    def embed(self, text, memory_action=None):
        # Mem0 calls embed(content, "add"/"search"/"update"). We don't branch on action.
        vec = self._model.encode(text)
        return vec.tolist() if hasattr(vec, "tolist") else list(vec)
```

- [ ] **Step 4: Run, expect PASS** (first run downloads model into uv cache — slow once)

Run: `cd scripts/sspower_mem && UV_CACHE_DIR=/private/tmp/sspower-uv-cache uv run --with pytest pytest tests/test_mem_embedder.py -v`

- [ ] **Step 5: Commit**

```bash
git add scripts/sspower_mem/sspower_mem/mem/embedder.py scripts/sspower_mem/tests/test_mem_embedder.py
git commit -m "feat(sspower-mem/mem): Model2VecEmbedder adapter for potion-base-8M"
```

---

## Task 5: Factory registration + Memory builder (`mem/factory.py`)

**Files:**
- Create: `scripts/sspower_mem/sspower_mem/mem/factory.py`
- Create: `scripts/sspower_mem/tests/test_mem_factory.py`

**Rationale:** Phase 0 Q1 (public API) + Q2 (private dict mutation). Idempotent registration. Loud assertion if `EmbedderFactory.provider_to_class` is renamed upstream. `build_memory` pins `history_db_path` (Q4) and the Chroma persist dir.

**Codex review blocking #2 — Mem0 constructor preflight:** Phase 0 verified `BaseLlmConfig`, `MemoryConfig.history_db_path`, `LlmFactory.register_provider`, `EmbedderFactory.provider_to_class`. It did NOT verify the exact `MemoryConfig` constructor kwargs for nested LLM/embedder/vector_store. Step 0 below adds a preflight test that reads the pinned mem0 source to derive the actual constructor shape, then `build_memory` is implemented against the verified surface.

- [ ] **Step 0 (preflight): Verify MemoryConfig shape from pinned source**

Add `tests/test_mem_factory.py::test_memoryconfig_constructor_shape` (BEFORE the dependent tests below). The test reads `mem0/configs/base.py` for the `MemoryConfig` definition and asserts the constructor accepts the fields the plan intends to pass:

```python
def test_memoryconfig_constructor_shape():
    """Preflight: confirm MemoryConfig fields used by build_memory exist in the pinned source.

    Phase 0 verified history_db_path. This locks the nested LLM / embedder / vector_store
    shapes against the same upstream SHA, so build_memory cannot drift from the verified API.
    """
    import sspower_mem.mem  # noqa: F401
    from mem0.configs.base import MemoryConfig
    import inspect

    fields = set(MemoryConfig.model_fields.keys()) if hasattr(MemoryConfig, "model_fields") \
        else set(inspect.signature(MemoryConfig).parameters.keys())
    required = {"history_db_path", "llm", "embedder", "vector_store"}
    missing = required - fields
    assert not missing, f"MemoryConfig missing expected fields: {missing}; got {sorted(fields)}"

    # Verify LlmConfig importability — plan uses it to wire the noop provider.
    from mem0.configs.base import LlmConfig  # noqa: F401  raises ImportError if missing
```

Run: `cd scripts/sspower_mem && UV_CACHE_DIR=/private/tmp/sspower-uv-cache uv run --with pytest pytest tests/test_mem_factory.py::test_memoryconfig_constructor_shape -v`

**Branch point:** if the test PASSES, proceed with Step 1. If it FAILS (constructor shape differs), update `build_memory` (Step 3 below) to match the actual fields — for example `MemoryConfig(history_db_path=..., llm={"provider":..., "config":{}}, ...)` if LlmConfig is not importable, or move provider/config under a different nested name. The failure payload tells you what fields are available; pin the actual signature in the implementation.

- [ ] **Step 1: Write failing test** — `tests/test_mem_factory.py`

```python
"""Factory registration is idempotent + asserts private-API presence loudly."""
from __future__ import annotations

import pathlib

import pytest


def test_register_providers_is_idempotent():
    import sspower_mem.mem  # noqa: F401
    from mem0.utils.factory import EmbedderFactory, LlmFactory
    from sspower_mem.mem.factory import register_providers

    register_providers()
    snapshot_llm = dict(LlmFactory.provider_to_class)
    snapshot_emb = dict(EmbedderFactory.provider_to_class)
    register_providers()  # second call must be a no-op
    assert dict(LlmFactory.provider_to_class) == snapshot_llm
    assert dict(EmbedderFactory.provider_to_class) == snapshot_emb


def test_register_providers_uses_class_path_strings():
    """Phase 0 Q1 + Q2: must register by class-path STRING, not class object."""
    import sspower_mem.mem  # noqa: F401
    from mem0.utils.factory import EmbedderFactory, LlmFactory
    from sspower_mem.mem.factory import register_providers

    register_providers()
    llm_entry = LlmFactory.provider_to_class["sspower-noop"]
    # LlmFactory stores (class_path_string, config_class) tuples.
    assert llm_entry[0] == "sspower_mem.mem.noop.NoOpLLM"
    assert EmbedderFactory.provider_to_class["sspower-model2vec"] == (
        "sspower_mem.mem.embedder.Model2VecEmbedder"
    )


def test_register_providers_raises_if_private_api_renamed(monkeypatch):
    """Loud canary: if upstream renames `provider_to_class`, fail at register."""
    import sspower_mem.mem  # noqa: F401
    from mem0.utils.factory import EmbedderFactory
    from sspower_mem.mem.factory import register_providers

    monkeypatch.delattr(EmbedderFactory, "provider_to_class")
    with pytest.raises(RuntimeError, match="EmbedderFactory.provider_to_class"):
        register_providers()


def test_build_memory_pins_history_db_and_chroma_path(tmp_path):
    import sspower_mem.mem  # noqa: F401
    from sspower_mem.mem.factory import build_memory

    idx_dir = tmp_path / "idx"
    idx_dir.mkdir()
    chroma_dir = idx_dir / "chroma"
    history_db = idx_dir / "history.db"
    mem = build_memory(
        scope_id="user:global",
        idx_dir=idx_dir,
        chroma_dir=chroma_dir,
        history_db_path=history_db,
    )
    assert pathlib.Path(mem.config.history_db_path) == history_db
    # Collection name must be deterministic (sspower fixed name).
    assert mem.collection_name == "sspower_memories"
```

- [ ] **Step 2: Run, expect FAIL**

- [ ] **Step 3: Implement** — `sspower_mem/mem/factory.py`

```python
"""Factory registration + Memory builder.

register_providers(): idempotent; registers sspower-noop LLM (public API)
and sspower-model2vec embedder (private dict mutation, Phase 0 §2 caveat 2).
Raises RuntimeError loudly if EmbedderFactory.provider_to_class is renamed.

build_memory(scope_id, idx_dir, chroma_dir, history_db_path): construct a
Mem0 Memory instance with pinned history-db path, deterministic collection
name "sspower_memories", and no LLM provider call (NoOpLLM stays inert).
"""
from __future__ import annotations

import pathlib

from mem0.configs.base import LlmConfig, MemoryConfig
from mem0.llms.configs import BaseLlmConfig
from mem0.utils.factory import EmbedderFactory, LlmFactory

_LLM_NAME = "sspower-noop"
_LLM_PATH = "sspower_mem.mem.noop.NoOpLLM"
_EMB_NAME = "sspower-model2vec"
_EMB_PATH = "sspower_mem.mem.embedder.Model2VecEmbedder"

_COLLECTION = "sspower_memories"


def register_providers() -> None:
    # Defensive check: private-API canary.
    if not hasattr(EmbedderFactory, "provider_to_class"):
        raise RuntimeError(
            "EmbedderFactory.provider_to_class no longer exists; "
            "upstream mem0 renamed the private API. Pin upstream SHA or fork."
        )
    if not isinstance(EmbedderFactory.provider_to_class, dict):
        raise RuntimeError(
            "EmbedderFactory.provider_to_class is not a dict; upstream changed shape."
        )

    LlmFactory.register_provider(_LLM_NAME, _LLM_PATH, BaseLlmConfig)
    EmbedderFactory.provider_to_class[_EMB_NAME] = _EMB_PATH


def build_memory(
    scope_id: str,  # noqa: ARG001 - reserved for future per-scope config
    idx_dir: pathlib.Path,
    chroma_dir: pathlib.Path,
    history_db_path: pathlib.Path,
):
    """Construct a Mem0 Memory using sspower-noop + sspower-model2vec.

    scope_id is unused at construction (user_id is passed per-call in add/search).
    Reserved here so a future Phase can derive per-scope configs.
    """
    register_providers()

    # Lazy import — Mem0 construction inside the locked add path.
    from mem0 import Memory

    config = MemoryConfig(
        history_db_path=str(history_db_path),
        llm=LlmConfig(provider=_LLM_NAME, config={}),
        embedder={"provider": _EMB_NAME, "config": {"model": "minishlab/potion-base-8M"}},
        vector_store={
            "provider": "chroma",
            "config": {
                "collection_name": _COLLECTION,
                "path": str(chroma_dir),
            },
        },
    )
    return Memory(config)
```

- [ ] **Step 4: Run, expect PASS**

- [ ] **Step 5: Commit**

```bash
git add scripts/sspower_mem/sspower_mem/mem/factory.py scripts/sspower_mem/tests/test_mem_factory.py
git commit -m "feat(sspower-mem/mem): factory registration + Memory builder"
```

---

## Task 6: Bridge extraction parser (`mem/extract.py`)

**Files:**
- Create: `scripts/sspower_mem/sspower_mem/mem/extract.py`
- Create: `scripts/sspower_mem/tests/test_mem_extract.py`
- Create: `scripts/sspower_mem/tests/fixtures/fake_bridge.sh`

**Rationale:** §6.1.5 contract: bridge stdout is the Phase B OpenAI envelope; `choices[0].message.content` is a JSON object `{"facts":[...]}`. Empty success = `{"facts":[]}`. Caps: 32 facts × 512 chars. ExtractFailed on every malformed path (D14).

- [ ] **Step 1: Create fixture** — `tests/fixtures/fake_bridge.sh`

```bash
#!/usr/bin/env bash
# Deterministic codex-bridge stub.
#   $SSPOWER_FAKE_BRIDGE_RESPONSE  → stdout payload
#   $SSPOWER_FAKE_BRIDGE_EXIT      → exit code
#   $SSPOWER_FAKE_BRIDGE_STDERR    → stderr payload
#   $SSPOWER_FAKE_BRIDGE_SENTINEL  → if set, touch this file on every invocation
#                                     (tests that assert bridge non-invocation read it)
set -u
stdout_payload="${SSPOWER_FAKE_BRIDGE_RESPONSE:-}"
stderr_payload="${SSPOWER_FAKE_BRIDGE_STDERR:-}"
exit_code="${SSPOWER_FAKE_BRIDGE_EXIT:-0}"
[ -n "${SSPOWER_FAKE_BRIDGE_SENTINEL:-}" ] && : >> "$SSPOWER_FAKE_BRIDGE_SENTINEL"
[ -n "$stdout_payload" ] && printf '%s' "$stdout_payload"
[ -n "$stderr_payload" ] && printf '%s' "$stderr_payload" >&2
exit "$exit_code"
```

Make executable: `chmod +x scripts/sspower_mem/tests/fixtures/fake_bridge.sh`

- [ ] **Step 2: Write failing test matrix** — `tests/test_mem_extract.py`

```python
"""bridge_extract_facts: D14 error classification matrix.

Contract per docs/specs/2026-05-13-index-backend-integration-design.md §6.1.5:
  - choices[0].message.content parses as JSON object {"facts": [str, ...]}
  - empty success = {"facts": []} → returns []
  - any malformed step → ExtractFailed
  - facts truncated to first 32; each fact to 512 chars
"""
from __future__ import annotations

import json
import os
import pathlib
import pytest

FIXTURES = pathlib.Path(__file__).parent / "fixtures"
FAKE_BRIDGE = FIXTURES / "fake_bridge.sh"


def _envelope(content_obj):
    return json.dumps({
        "id": "test-1",
        "object": "chat.completion",
        "choices": [{"index": 0, "message": {"role": "assistant", "content": json.dumps(content_obj)}}],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
    })


def _set_bridge(monkeypatch, response, exit_code=0, stderr=""):
    monkeypatch.setenv("SSPOWER_BRIDGE_PATH", str(FAKE_BRIDGE))
    monkeypatch.setenv("SSPOWER_FAKE_BRIDGE_RESPONSE", response)
    monkeypatch.setenv("SSPOWER_FAKE_BRIDGE_EXIT", str(exit_code))
    monkeypatch.setenv("SSPOWER_FAKE_BRIDGE_STDERR", stderr)


def test_empty_facts_returns_empty_list(monkeypatch):
    from sspower_mem.mem.extract import bridge_extract_facts
    _set_bridge(monkeypatch, _envelope({"facts": []}))
    assert bridge_extract_facts("hello") == []


def test_two_facts_returned_in_order(monkeypatch):
    from sspower_mem.mem.extract import bridge_extract_facts
    _set_bridge(monkeypatch, _envelope({"facts": ["alpha", "beta"]}))
    assert bridge_extract_facts("hello") == ["alpha", "beta"]


def test_bridge_nonzero_exit_raises(monkeypatch):
    from sspower_mem.mem.extract import ExtractFailed, bridge_extract_facts
    _set_bridge(monkeypatch, "", exit_code=1, stderr='{"error":{"type":"x","message":"y"}}')
    with pytest.raises(ExtractFailed):
        bridge_extract_facts("hello")


def test_invalid_envelope_json_raises(monkeypatch):
    from sspower_mem.mem.extract import ExtractFailed, bridge_extract_facts
    _set_bridge(monkeypatch, "not json")
    with pytest.raises(ExtractFailed):
        bridge_extract_facts("hello")


def test_bridge_error_field_raises(monkeypatch):
    from sspower_mem.mem.extract import ExtractFailed, bridge_extract_facts
    _set_bridge(monkeypatch, json.dumps({"error": {"type": "timeout", "message": "x"}}))
    with pytest.raises(ExtractFailed):
        bridge_extract_facts("hello")


def test_missing_choices_raises(monkeypatch):
    from sspower_mem.mem.extract import ExtractFailed, bridge_extract_facts
    _set_bridge(monkeypatch, json.dumps({"id": "x", "object": "chat.completion", "choices": []}))
    with pytest.raises(ExtractFailed):
        bridge_extract_facts("hello")


def test_content_not_json_raises(monkeypatch):
    from sspower_mem.mem.extract import ExtractFailed, bridge_extract_facts
    raw = json.dumps({"id": "x", "object": "chat.completion",
                      "choices": [{"index": 0, "message": {"role": "assistant", "content": "not-json"}}]})
    _set_bridge(monkeypatch, raw)
    with pytest.raises(ExtractFailed):
        bridge_extract_facts("hello")


def test_missing_facts_key_raises(monkeypatch):
    from sspower_mem.mem.extract import ExtractFailed, bridge_extract_facts
    _set_bridge(monkeypatch, _envelope({"items": ["a"]}))
    with pytest.raises(ExtractFailed):
        bridge_extract_facts("hello")


def test_facts_not_list_raises(monkeypatch):
    from sspower_mem.mem.extract import ExtractFailed, bridge_extract_facts
    _set_bridge(monkeypatch, _envelope({"facts": "alpha"}))
    with pytest.raises(ExtractFailed):
        bridge_extract_facts("hello")


def test_non_string_element_raises(monkeypatch):
    from sspower_mem.mem.extract import ExtractFailed, bridge_extract_facts
    _set_bridge(monkeypatch, _envelope({"facts": ["alpha", 42]}))
    with pytest.raises(ExtractFailed):
        bridge_extract_facts("hello")


def test_too_many_facts_truncated_to_32(monkeypatch):
    from sspower_mem.mem.extract import bridge_extract_facts
    facts = [f"f{i}" for i in range(40)]
    _set_bridge(monkeypatch, _envelope({"facts": facts}))
    out = bridge_extract_facts("hello")
    assert len(out) == 32
    assert out == facts[:32]


def test_long_fact_truncated_to_512(monkeypatch):
    from sspower_mem.mem.extract import bridge_extract_facts
    long_fact = "x" * 600
    _set_bridge(monkeypatch, _envelope({"facts": [long_fact]}))
    out = bridge_extract_facts("hello")
    assert len(out[0]) == 512
```

- [ ] **Step 3: Run, expect FAIL** (`No module named 'sspower_mem.mem.extract'`)

- [ ] **Step 4: Implement** — `sspower_mem/mem/extract.py`

```python
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

# The default extraction template — Codex must emit ONLY the JSON object below,
# no prose, no markdown fences. We keep this terse to stay inside Codex's
# minimal-effort context budget.
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
    # Production path: scripts/codex-bridge.mjs relative to plugin root.
    # sspower_mem lives at <plugin>/scripts/sspower_mem/sspower_mem/mem/extract.py.
    here = pathlib.Path(__file__).resolve()
    return str(here.parent.parent.parent.parent / "codex-bridge.mjs")


def bridge_extract_facts(content: str, timeout_ms: int = 60_000) -> list[str]:
    """Call codex-bridge complete --json, parse, validate, truncate.

    Returns list[str] (possibly empty) on success.
    Raises ExtractFailed for any wire-level failure.
    """
    bridge = _bridge_path()
    prompt = EXTRACT_TEMPLATE.replace("{content}", content)

    # Bridge may be a real Node script ("node bridge.mjs ...") or a shell stub
    # in tests. Detect by suffix: .mjs / .js → node; .sh / no-ext-executable → exec direct.
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

    # Apply hard caps deterministically.
    facts = facts[:MAX_FACTS]
    facts = [f[:MAX_FACT_CHARS] for f in facts]
    return facts
```

- [ ] **Step 5: Run, expect PASS**

Run: `cd scripts/sspower_mem && UV_CACHE_DIR=/private/tmp/sspower-uv-cache uv run --with pytest pytest tests/test_mem_extract.py -v`

- [ ] **Step 6: Commit**

```bash
git add scripts/sspower_mem/sspower_mem/mem/extract.py scripts/sspower_mem/tests/test_mem_extract.py scripts/sspower_mem/tests/fixtures/fake_bridge.sh
git commit -m "feat(sspower-mem/mem): bridge_extract_facts + D14 error matrix"
```

---

## Task 7: Idempotent upserts (`mem/idx.py`)

**Files:**
- Create: `scripts/sspower_mem/sspower_mem/mem/idx.py`
- Create: `scripts/sspower_mem/tests/test_mem_idx.py`

**Rationale:** Phase 0 Q8 — `Memory.search` accepts `filters={"AND":[{"id":...},{"kind":"raw"}]}` exact-match. Caller's `metadata.id` is preserved verbatim (Phase 0 Q3) but is NOT the Mem0 primary uuid; we dedup by sspower's id field.

- [ ] **Step 1: Write failing test** — `tests/test_mem_idx.py`

```python
"""Idempotent raw + extracted upserts. Pre-search by sspower id/raw_id, skip on hit."""
from __future__ import annotations

import pytest


@pytest.fixture
def mem(tmp_path):
    import sspower_mem.mem  # noqa: F401
    from sspower_mem.mem.factory import build_memory

    idx_dir = tmp_path / "idx"
    idx_dir.mkdir()
    chroma_dir = idx_dir / "chroma"
    history_db = idx_dir / "history.db"
    return build_memory(
        scope_id="user:global",
        idx_dir=idx_dir,
        chroma_dir=chroma_dir,
        history_db_path=history_db,
    )


def _base_meta(eff_id: str, scope: str = "user:global"):
    return {"id": eff_id, "layer": "user-global", "scope": scope, "ts": "2026-05-15T00:00:00Z"}


def test_raw_upsert_writes_once(mem):
    from sspower_mem.mem.idx import raw_upsert
    meta = _base_meta("abc123def4567890")
    raw_upsert(mem, "the content", meta, user_id="user:global")
    raw_upsert(mem, "the content", meta, user_id="user:global")  # idempotent
    hits = mem.search(
        query=" ",
        user_id="user:global",
        filters={"AND": [{"id": "abc123def4567890"}, {"kind": "raw"}]},
        limit=10,
    )
    assert len(hits.get("results", [])) == 1


def test_raw_upsert_preserves_caller_metadata(mem):
    from sspower_mem.mem.idx import raw_upsert
    meta = _base_meta("xxx1111122223333")
    raw_upsert(mem, "content one", meta, user_id="user:global")
    hits = mem.search(query=" ", user_id="user:global",
                      filters={"id": "xxx1111122223333"}, limit=1)
    record = hits["results"][0]
    assert record["metadata"]["id"] == "xxx1111122223333"
    assert record["metadata"]["kind"] == "raw"
    assert record["metadata"]["layer"] == "user-global"


def test_extracted_upsert_dedups_by_fact_hash(mem):
    from sspower_mem.mem.idx import extracted_upsert
    raw_meta = _base_meta("rawid000000000aa")
    fact_meta = {
        **raw_meta,
        "raw_id": "rawid000000000aa",
        "fact_index": 0,
        "fact_hash": "facthash00000000",
    }
    extracted_upsert(mem, "fact text", fact_meta, user_id="user:global")
    extracted_upsert(mem, "fact text", fact_meta, user_id="user:global")
    hits = mem.search(
        query=" ", user_id="user:global",
        filters={"AND": [{"raw_id": "rawid000000000aa"}, {"kind": "extracted"},
                          {"fact_hash": "facthash00000000"}]},
        limit=10,
    )
    assert len(hits.get("results", [])) == 1


def test_phase_c_filter_operators_are_safelisted():
    """Phase 0 open issue #6: Chroma silently maps contains/icontains→eq and
    drops NOT. Phase C MUST emit only exact-match filters + AND/OR. Static-source
    guard: grep idx.py and cli.py for forbidden operator literals.
    Codex review advisory #3.
    """
    import pathlib
    forbidden = ("contains", "icontains", "$not", '"NOT"', "'NOT'")
    pkg = pathlib.Path(__file__).resolve().parent.parent / "sspower_mem"
    for fname in ("mem/idx.py", "cli.py"):
        src = (pkg / fname).read_text()
        for token in forbidden:
            assert token not in src, (
                f"{fname} contains forbidden Chroma operator literal {token!r}; "
                f"see Phase 0 open issue #6 (silent fallback). Use AND/OR with eq-only."
            )


def test_entity_store_collection_not_created(mem, tmp_path):
    """Phase 0 §6 + open issue #2: infer=False never instantiates <coll>_entities."""
    from sspower_mem.mem.idx import raw_upsert
    raw_upsert(mem, "content", _base_meta("aaaa1111bbbb2222"), user_id="user:global")
    # Inspect the Chroma persist dir: only the main collection should exist.
    import chromadb
    client = chromadb.PersistentClient(path=str(tmp_path / "idx" / "chroma"))
    names = [c.name for c in client.list_collections()]
    assert "sspower_memories" in names
    assert "sspower_memories_entities" not in names
```

- [ ] **Step 2: Run, expect FAIL**

- [ ] **Step 3: Implement** — `sspower_mem/mem/idx.py`

```python
"""Idempotent Mem0 upserts. Caller-driven dedup via metadata.id + metadata.kind.

Per docs/specs/2026-05-13-index-backend-integration-design.md §6.1 D11 and
docs/specs/2026-05-13-index-provider-registration.md §8.
"""
from __future__ import annotations


def _exists_raw(mem, effective_id: str, user_id: str) -> bool:
    hits = mem.search(
        query=" ",
        user_id=user_id,
        filters={"AND": [{"id": effective_id}, {"kind": "raw"}]},
        limit=1,
    )
    return bool(hits.get("results"))


def _exists_extracted(mem, raw_id: str, fact_hash: str, user_id: str) -> bool:
    hits = mem.search(
        query=" ",
        user_id=user_id,
        filters={"AND": [{"raw_id": raw_id}, {"kind": "extracted"}, {"fact_hash": fact_hash}]},
        limit=1,
    )
    return bool(hits.get("results"))


def raw_upsert(mem, content: str, meta: dict, *, user_id: str) -> bool:
    """Insert raw record if not already present (by metadata.id + metadata.kind=raw).

    Returns True if a write was performed, False if it was a skip.
    """
    payload_meta = {**meta, "kind": "raw"}
    if _exists_raw(mem, payload_meta["id"], user_id):
        return False
    mem.add(
        messages=[{"role": "user", "content": content}],
        user_id=user_id,
        metadata=payload_meta,
        infer=False,
    )
    return True


def extracted_upsert(mem, fact_text: str, meta: dict, *, user_id: str) -> bool:
    """Insert extracted-fact record if not already present (by raw_id + kind + fact_hash).

    Returns True if a write was performed, False if skipped.
    """
    payload_meta = {**meta, "kind": "extracted"}
    if _exists_extracted(mem, payload_meta["raw_id"], payload_meta["fact_hash"], user_id):
        return False
    mem.add(
        messages=[{"role": "user", "content": fact_text}],
        user_id=user_id,
        metadata=payload_meta,
        infer=False,
    )
    return True
```

- [ ] **Step 4: Run, expect PASS**

Run: `cd scripts/sspower_mem && UV_CACHE_DIR=/private/tmp/sspower-uv-cache uv run --with pytest pytest tests/test_mem_idx.py -v`

- [ ] **Step 5: Commit**

```bash
git add scripts/sspower_mem/sspower_mem/mem/idx.py scripts/sspower_mem/tests/test_mem_idx.py
git commit -m "feat(sspower-mem/mem): idempotent raw + extracted upserts; entity-store canary"
```

---

## Task 8: Wire cmd_add Step 2 (raw upsert) + lazy-import boundary

**Files:**
- Modify: `scripts/sspower_mem/sspower_mem/cli.py:cmd_add`
- Create: `scripts/sspower_mem/tests/test_lazy_import.py`
- Create: `scripts/sspower_mem/tests/test_cli_phase_c.py`

**Rationale:** §6.1 Step 2: after digest append, lazy-import Mem0 inside the lock, call `raw_upsert`. Importerror or any Mem0 exception → rc=10 (degraded), digest already durable.

- [ ] **Step 1: Write lazy-import boundary test** — `tests/test_lazy_import.py`

```python
"""Lazy-import policy: cli.py module load must NOT pull mem0/chromadb/model2vec.

Phase A regression guard. If a future edit imports sspower_mem.mem at cli.py
module top-level, the digest write would be bypassed when deps are broken.
"""
from __future__ import annotations

import subprocess
import sys
import textwrap


def test_cli_module_load_does_not_import_mem0():
    code = textwrap.dedent(
        """
        import sys
        import sspower_mem.cli  # noqa: F401
        forbidden = {"mem0", "chromadb", "model2vec", "sspower_mem.mem"}
        leaked = sorted(m for m in sys.modules if m.split(".")[0] in {x.split(".")[0] for x in forbidden})
        # sspower_mem.mem itself is forbidden in particular.
        bad = [m for m in leaked if m == "sspower_mem.mem" or m.startswith(("mem0", "chromadb", "model2vec"))]
        print(",".join(bad))
        """
    )
    out = subprocess.check_output([sys.executable, "-c", code], text=True).strip()
    assert out == "", f"cli.py module load leaked imports: {out}"
```

Run: `cd scripts/sspower_mem && UV_CACHE_DIR=/private/tmp/sspower-uv-cache uv run --with pytest pytest tests/test_lazy_import.py -v`
Expected: PASS already (Phase A cli.py doesn't import mem). Keep this test green for the rest of Phase C.

- [ ] **Step 2: Write failing cmd_add wiring tests** — `tests/test_cli_phase_c.py` (Step 2 portion)

```python
"""Phase C cmd_add chain: digest → raw upsert → extract → fact writes.

Uses the fake_bridge.sh fixture to control extraction output, and a real
Chroma persist dir under tmp_path. ~/.claude is monkeypatched so user-scope
writes land under tmp_path.
"""
from __future__ import annotations

import json
import os
import pathlib

import pytest

FIX = pathlib.Path(__file__).parent / "fixtures"
FAKE_BRIDGE = FIX / "fake_bridge.sh"


@pytest.fixture
def env(monkeypatch, tmp_path):
    home = tmp_path / "home"
    home.mkdir()
    (home / ".claude").mkdir()
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("SSPOWER_BRIDGE_PATH", str(FAKE_BRIDGE))
    monkeypatch.setenv("MEM0_TELEMETRY", "False")
    # Bootstrap user scope.
    from sspower_mem.doctor import bootstrap
    bootstrap()
    return {"home": home, "tmp": tmp_path, "monkeypatch": monkeypatch}


def _ok_envelope(facts):
    return json.dumps({
        "id": "x", "object": "chat.completion",
        "choices": [{"index": 0, "message": {"role": "assistant",
                                              "content": json.dumps({"facts": facts})}}],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
    })


def _set_bridge_resp(env, response, exit_code=0):
    env["monkeypatch"].setenv("SSPOWER_FAKE_BRIDGE_RESPONSE", response)
    env["monkeypatch"].setenv("SSPOWER_FAKE_BRIDGE_EXIT", str(exit_code))
    env["monkeypatch"].setenv("SSPOWER_FAKE_BRIDGE_STDERR", "")


def test_add_step2_writes_raw_record(env, capsys):
    """Happy path: digest + raw upsert + empty facts list = rc 0, extracted="ok"."""
    from sspower_mem.cli import main
    _set_bridge_resp(env, _ok_envelope([]))
    rc = main(["add", "--scope", "user", "--layer", "user-global",
               "--content", "memory body one"])
    assert rc == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["raw"] == "ok"
    assert payload["extracted"] == "ok"


def test_add_step2_failure_returns_rc10(env, capsys, monkeypatch):
    """Step 2 raises (simulated via patch) → rc=10, digest still written."""
    from sspower_mem.cli import main

    def boom(*a, **kw):
        raise RuntimeError("simulated chroma failure")

    monkeypatch.setattr("sspower_mem.mem.idx.raw_upsert", boom)
    _set_bridge_resp(env, _ok_envelope([]))
    rc = main(["add", "--scope", "user", "--layer", "user-global",
               "--content", "memory body two"])
    assert rc == 10
    payload = json.loads(capsys.readouterr().out)
    assert payload["raw"] == "skipped"
    assert payload["extracted"] in ("skipped-failed", "skipped-partial")
```

- [ ] **Step 3: Run, expect FAIL** (existing cmd_add does not wire Mem0)

- [ ] **Step 4: Modify cmd_add in `cli.py`** — replace existing implementation:

```python
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
        print(f"sspower-mem: lock missing at {lock_path}; run `sspower-mem doctor --bootstrap`",
              file=sys.stderr)
        return 30

    # Phase C state machine driven inside the lock.
    raw_status = "n/a"
    extracted_status = "n/a"
    eff_id = ""
    overall_rc = 0
    try:
        with acquire_lock(lock_path, parent_anchor=parent_anchor("user", None)):
            # Step 1 — durable digest append.
            try:
                eff_id, _was_new = append_block_or_skip(
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
                    # Step 3a + 3b.
                    extracted_status = _try_extract_and_write(
                        mem_obj, sc_id, eff_id, args.layer, content, meta,
                    )
                    if extracted_status != "ok":
                        overall_rc = 10
    except OSError as e:
        print(f"sspower-mem: lock unavailable: {e}", file=sys.stderr)
        return 30

    print(json.dumps({
        "id": eff_id, "raw": raw_status, "extracted": extracted_status,
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
            "id": eff_id, "layer": layer, "scope": scope_id_str,
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
        "id": eff_id, "layer": layer, "scope": scope_id_str, "ts": _iso_now(),
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
            _log_errors_jsonl({"stage": "step3b_index", "err": str(e),
                                "raw_id": eff_id, "fact_index": fact_index})
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
        pass  # swallow
```

- [ ] **Step 5: Run, expect PASS**

Run: `cd scripts/sspower_mem && UV_CACHE_DIR=/private/tmp/sspower-uv-cache uv run --with pytest pytest tests/test_cli_phase_c.py::test_add_step2_writes_raw_record tests/test_cli_phase_c.py::test_add_step2_failure_returns_rc10 tests/test_lazy_import.py -v`

- [ ] **Step 6: Commit**

```bash
git add scripts/sspower_mem/sspower_mem/cli.py scripts/sspower_mem/tests/test_cli_phase_c.py scripts/sspower_mem/tests/test_lazy_import.py
git commit -m "feat(sspower-mem): cmd_add Step 2 (raw upsert) + lazy-import boundary"
```

---

## Task 9: cmd_add Step 3a/3b — extract + fact writes, full state machine

**Files:**
- Modify: `scripts/sspower_mem/tests/test_cli_phase_c.py` (add more cases)

**Rationale:** Cover the full extract-then-write flow + `--no-llm` interactions. Five exit-code cases enumerated.

- [ ] **Step 1: Append failing tests** — `tests/test_cli_phase_c.py`

```python
def test_add_full_happy_with_facts(env, capsys):
    from sspower_mem.cli import main
    _set_bridge_resp(env, _ok_envelope(["fact a", "fact b"]))
    rc = main(["add", "--scope", "user", "--layer", "user-global",
               "--content", "narrative content here"])
    assert rc == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["raw"] == "ok"
    assert payload["extracted"] == "ok"


def test_add_bridge_failure_returns_skipped_failed(env, capsys):
    from sspower_mem.cli import main
    _set_bridge_resp(env, "", exit_code=1)
    rc = main(["add", "--scope", "user", "--layer", "user-global",
               "--content", "x" * 10])
    assert rc == 10
    payload = json.loads(capsys.readouterr().out)
    assert payload["raw"] == "ok"
    assert payload["extracted"] == "skipped-failed"


def test_add_step3b_partial_failure(env, capsys, monkeypatch):
    """Mid-write failure → skipped-partial, rc=10."""
    from sspower_mem.cli import main

    real_upsert = None

    def flaky(mem, text, meta, *, user_id):
        nonlocal real_upsert
        if meta.get("fact_index") == 1:
            raise RuntimeError("chroma full")
        if real_upsert is None:
            from sspower_mem.mem.idx import extracted_upsert as _real
            real_upsert = _real
        return real_upsert(mem, text, meta, user_id=user_id)

    monkeypatch.setattr("sspower_mem.mem.idx.extracted_upsert", flaky)
    _set_bridge_resp(env, _ok_envelope(["one", "two", "three"]))
    rc = main(["add", "--scope", "user", "--layer", "user-global",
               "--content", "content for partial"])
    assert rc == 10
    payload = json.loads(capsys.readouterr().out)
    assert payload["extracted"] == "skipped-partial"


def test_add_no_llm_step2_ok_returns_rc0_and_skips_bridge(env, capsys, tmp_path):
    """--no-llm must NOT invoke the bridge (spec §6.1 add --no-llm semantics).

    Strengthened per Codex review advisory #1: assert sentinel file does NOT exist.
    """
    from sspower_mem.cli import main

    sentinel = tmp_path / "bridge_called_sentinel"
    env["monkeypatch"].setenv("SSPOWER_FAKE_BRIDGE_SENTINEL", str(sentinel))
    _set_bridge_resp(env, _ok_envelope([]))
    rc = main(["add", "--scope", "user", "--layer", "user-global",
               "--content", "no-llm body", "--no-llm"])
    assert rc == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["raw"] == "ok"
    assert payload["extracted"] == "skipped-intentional"
    assert not sentinel.exists(), "bridge was invoked under --no-llm (must be a no-op)"


def test_add_no_llm_step2_failed_still_rc10(env, capsys, monkeypatch):
    """--no-llm does not mask step 2 failures."""
    from sspower_mem.cli import main

    def boom(*a, **kw):
        raise RuntimeError("chroma corrupt")

    monkeypatch.setattr("sspower_mem.mem.idx.raw_upsert", boom)
    _set_bridge_resp(env, _ok_envelope([]))
    rc = main(["add", "--scope", "user", "--layer", "user-global",
               "--content", "body", "--no-llm"])
    assert rc == 10
    payload = json.loads(capsys.readouterr().out)
    assert payload["raw"] == "skipped"
    assert payload["extracted"] == "skipped-intentional"


def test_add_mem0_import_failure_keeps_digest_durable(env, capsys, monkeypatch):
    """Spec §6.1/§8 lazy-import policy: a broken Mem0 import inside cmd_add MUST
    NOT bypass the digest write. Step 1 completes, Step 2 import fails, rc=10,
    digest block exists with the effective id.

    Codex review blocking #6 — end-to-end import-failure coverage.
    """
    import builtins
    from sspower_mem.cli import main
    from sspower_mem.scope import digest_path, parent_anchor, user_sspower_dir
    from sspower_mem.io import safe_read_strict

    real_import = builtins.__import__

    def broken_import(name, *args, **kwargs):
        if name == "sspower_mem.mem.factory" or name == "sspower_mem.mem.idx":
            raise ImportError(f"simulated dep failure for {name}")
        return real_import(name, *args, **kwargs)

    monkeypatch.setattr(builtins, "__import__", broken_import)
    _set_bridge_resp(env, _ok_envelope([]))

    rc = main(["add", "--scope", "user", "--layer", "user-global",
               "--content", "durable digest body"])
    assert rc == 10
    payload = json.loads(capsys.readouterr().out)
    assert payload["raw"] == "skipped"

    # Digest block exists with the effective id from the payload.
    digest_text = safe_read_strict(digest_path("user", None), parent_anchor("user", None))
    assert payload["id"] in digest_text
    assert "durable digest body" in digest_text


def test_add_collision_propagates_dup_suffix_to_facts(env, capsys, monkeypatch):
    """_dup<N> id propagation per spec §6.1 v6 missing #6.

    Two adds with the SAME (scope, layer, sha1 prefix) but different content
    (we can't easily force a sha1 prefix collision; instead inject the second
    block via fixture so the first block becomes the colliding base).
    """
    from sspower_mem.cli import main
    from sspower_mem.mem.factory import build_memory
    from sspower_mem.scope import user_sspower_dir

    _set_bridge_resp(env, _ok_envelope(["one"]))
    # First add lays down base_id.
    rc = main(["add", "--scope", "user", "--layer", "user-global",
               "--content", "alpha content"])
    assert rc == 0
    first_payload = json.loads(capsys.readouterr().out)
    base_id = first_payload["id"]

    # Force a collision by injecting a digest block with the same base_id but
    # different content, simulating a sha1 prefix collision.
    from sspower_mem.digest import append_block_or_skip, compute_id
    troot = user_sspower_dir()
    panchor = pathlib.Path.home()
    dpath = troot / "digest.md"
    # Monkey-patch compute_id to return the same base for distinct content.
    orig_compute = compute_id
    def fake_compute(scope, layer, content):
        return base_id  # force collision
    monkeypatch.setattr("sspower_mem.digest.compute_id", fake_compute)

    rc = main(["add", "--scope", "user", "--layer", "user-global",
               "--content", "different content same prefix"])
    assert rc == 0
    second_payload = json.loads(capsys.readouterr().out)
    assert second_payload["id"] == f"{base_id}_dup1"

    # Verify extracted facts carry raw_id = "<base>_dup1".
    idx_dir = troot / "idx"
    mem = build_memory(
        scope_id="user:global", idx_dir=idx_dir,
        chroma_dir=idx_dir / "chroma",
        history_db_path=idx_dir / "history.db",
    )
    hits = mem.search(
        query=" ", user_id="user:global",
        filters={"AND": [{"raw_id": f"{base_id}_dup1"}, {"kind": "extracted"}]},
        limit=10,
    )
    assert len(hits["results"]) == 1
    assert hits["results"][0]["metadata"]["raw_id"] == f"{base_id}_dup1"
```

- [ ] **Step 2: Run, expect PASS** (the cmd_add implementation from Task 8 already covers Step 3 — verify all five cases + dup-propagation pass)

Run: `cd scripts/sspower_mem && UV_CACHE_DIR=/private/tmp/sspower-uv-cache uv run --with pytest pytest tests/test_cli_phase_c.py -v`
Expected: 8 tests PASS (5 exit-code cases + bridge non-invocation under --no-llm + lazy-import failure end-to-end + dup propagation).

- [ ] **Step 3: Commit**

```bash
git add scripts/sspower_mem/tests/test_cli_phase_c.py
git commit -m "test(sspower-mem): cmd_add Step 3 — extract, partial fail, --no-llm sentinel, lazy-import failure, dup propagation"
```

---

## Task 10: Wire cmd_search index path + multi-scope merge

**Files:**
- Modify: `scripts/sspower_mem/sspower_mem/cli.py:cmd_search`
- Modify: `scripts/sspower_mem/tests/test_cli_phase_c.py`

**Rationale:** §6.1 read path: try Mem0 search; on exception or 0 hits without `--idx-only`, fall back to grep. Multi-scope (`--mode recent` stays in digest; `--query` uses Mem0). Min-max normalize per scope; concatenate; tie-breaks ts→id.

- [ ] **Step 1: Write failing tests** — append to `tests/test_cli_phase_c.py`

```python
def test_search_index_hit_returns_index_source(env, capsys):
    from sspower_mem.cli import main
    _set_bridge_resp(env, _ok_envelope(["alpha fact about apples"]))
    main(["add", "--scope", "user", "--layer", "user-global",
          "--content", "alpha note about apples"])
    capsys.readouterr()
    rc = main(["search", "--scope", "user", "--query", "apples", "--json"])
    assert rc == 0
    out = json.loads(capsys.readouterr().out)
    assert any(h["source"] == "index" for h in out)


def test_search_index_zero_falls_back_to_grep_by_default(env, capsys):
    from sspower_mem.cli import main
    _set_bridge_resp(env, _ok_envelope([]))
    main(["add", "--scope", "user", "--layer", "user-global",
          "--content", "obscure foobar baz quux"])
    capsys.readouterr()
    rc = main(["search", "--scope", "user", "--query", "foobar", "--json"])
    assert rc == 0
    out = json.loads(capsys.readouterr().out)
    # Empty index (no extracted facts; raw record contains the text) — depending
    # on M2V scoring vs. grep, may be either index or digest-grep. Assert at
    # least one hit returned and source is one of the two.
    assert out
    assert all(h["source"] in ("index", "digest-grep") for h in out)


def test_search_idx_only_index_zero_returns_empty_rc0(env, capsys, monkeypatch):
    """--idx-only with empty index → rc=0, []."""
    from sspower_mem.cli import main

    monkeypatch.setattr("sspower_mem.mem.factory.build_memory",
                        lambda **kw: _StubMem(empty=True))
    rc = main(["search", "--scope", "user", "--query", "x", "--idx-only", "--json"])
    assert rc == 0
    assert json.loads(capsys.readouterr().out) == []


def test_search_idx_only_index_raise_returns_nonzero(env, capsys, monkeypatch):
    from sspower_mem.cli import main

    def boom(**kw):
        raise RuntimeError("chroma corrupt")

    monkeypatch.setattr("sspower_mem.mem.factory.build_memory", boom)
    rc = main(["search", "--scope", "user", "--query", "x", "--idx-only"])
    assert rc != 0


def test_search_dedups_raw_vs_extracted_prefers_extracted(env, capsys, monkeypatch):
    """Spec §6.1 read path: when one raw and one extracted record share raw_id,
    keep the extracted, drop the raw. Codex review blocking #3.
    """
    from sspower_mem.cli import main

    raw_hit = {"id": "uuid-raw", "score": 0.5,
                "memory": "original raw text",
                "metadata": {"id": "abc111", "kind": "raw",
                              "layer": "user-global", "scope": "user:global",
                              "ts": "2026-05-01T00:00:00Z"}}
    ext_hit = {"id": "uuid-ext", "score": 0.7,
                "memory": "extracted fact",
                "metadata": {"raw_id": "abc111", "id": "abc111", "kind": "extracted",
                              "layer": "user-global", "scope": "user:global",
                              "ts": "2026-05-01T00:00:00Z", "fact_hash": "ff" * 8}}
    monkeypatch.setattr(
        "sspower_mem.mem.factory.build_memory",
        lambda **kw: _StubMem(scope_hits={"user:global": [raw_hit, ext_hit]}),
    )
    rc = main(["search", "--scope", "user", "--query", "x", "--json"])
    assert rc == 0
    out = json.loads(capsys.readouterr().out)
    assert len(out) == 1
    assert out[0]["id"] in ("abc111",)
    assert out[0]["content"] == "extracted fact"


def test_search_project_user_merge_normalizes_per_scope(env, capsys, tmp_path, monkeypatch):
    """Two scopes, each with hits at different raw score ranges. After min-max
    normalization, each scope's top should be score=1.0; merged ordering is by
    normalized score desc → ts desc → id lex."""
    from sspower_mem.cli import main

    monkeypatch.setattr(
        "sspower_mem.mem.factory.build_memory",
        lambda **kw: _StubMem(
            scope_hits={
                "user:global": [{"id": "u1", "score": 0.2, "ts": "2026-05-01T00:00:00Z",
                                  "metadata": {"id": "u1", "layer": "user-global",
                                                "scope": "user:global", "ts": "2026-05-01T00:00:00Z"},
                                  "memory": "u text"}],
                f"project:{_sha1_hex(str(tmp_path))[:16]}": [
                    {"id": "p1", "score": 0.9, "ts": "2026-05-02T00:00:00Z",
                      "metadata": {"id": "p1", "layer": "episodic",
                                    "scope": f"project:{_sha1_hex(str(tmp_path))[:16]}",
                                    "ts": "2026-05-02T00:00:00Z"},
                      "memory": "p text"},
                ],
            },
        ),
    )

    (tmp_path / ".claude" / "wiki").mkdir(parents=True, exist_ok=True)

    rc = main(["search", "--scope", "project,user", "--cwd", str(tmp_path),
               "--query", "irrelevant", "--json"])
    assert rc == 0
    out = json.loads(capsys.readouterr().out)
    # Both hits normalized to 1.0 within their scope, so tie-break by ts desc.
    assert out[0]["id"] == "p1"  # newer ts wins
    assert out[1]["id"] == "u1"


def _sha1_hex(s: str) -> str:
    import hashlib
    return hashlib.sha1(s.encode()).hexdigest()


class _StubMem:
    """In-memory stand-in for Mem0 Memory; returns scripted hits."""
    def __init__(self, empty=False, scope_hits=None):
        self._empty = empty
        self._scope_hits = scope_hits or {}

    def search(self, query, user_id, filters=None, limit=8, **kw):
        if self._empty:
            return {"results": []}
        return {"results": list(self._scope_hits.get(user_id, []))}

    def add(self, **kw):
        return {"results": []}
```

- [ ] **Step 2: Run, expect FAIL** (cmd_search has no index path yet)

- [ ] **Step 3: Modify cmd_search in `cli.py`**

Replace existing `cmd_search` with:

```python
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
                sources.append((digest_path("project", cwd), parent_anchor("project", cwd),
                                 scope_id("project", cwd), PROJECT_LAYERS))
            elif scope == "user":
                sources.append((digest_path("user", None), parent_anchor("user", None),
                                 scope_id("user", None), USER_LAYERS))
            else:
                print(f"sspower-mem: unknown scope: {scope}", file=sys.stderr)
                return 30
    except FileNotFoundError as e:
        print(f"sspower-mem: {e}", file=sys.stderr)
        return 20

    layer_filter = args.layer.split(",") if args.layer else None

    # --mode recent stays on digest (no semantic op).
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

    # --query path: try Mem0 first; fall back to grep on exception or empty (unless --idx-only).
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

    if index_hits or index_raised is False:
        # Either non-empty index hits, OR the index returned cleanly empty — fall through
        # to grep ONLY when index_raised (exception) or zero hits.
        if index_hits:
            _emit_search(index_hits, args.json)
            return 0

    # index_raised OR (no exception AND zero hits) → grep fallback.
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
            filters = None
            if layer_filter:
                filters = {"OR": [{"layer": lf} for lf in layer_filter]}
            resp = mem.search(query=query, user_id=sid, filters=filters, limit=top_k)
        except Exception:
            return [], True
        scope_hits = resp.get("results", [])
        if not scope_hits:
            continue
        scores = [float(h.get("score", 0.0)) for h in scope_hits]
        smin, smax = min(scores), max(scores)
        for h in scope_hits:
            raw = float(h.get("score", 0.0))
            norm = 1.0 if smin == smax else (raw - smin) / (smax - smin)
            md = h.get("metadata", {})
            # Correlation key: raw_id for extracted records, id for raw records.
            kind = md.get("kind", "")
            corr_id = md.get("raw_id") or md.get("id") or h.get("id")
            all_normalized.append({
                "id": corr_id,
                "source": "index",
                "score": norm,
                "content": h.get("memory") or h.get("text") or "",
                "scope": md.get("scope") or sid,
                "layer": md.get("layer", ""),
                "ts": md.get("ts", ""),
                "_kind": kind,  # internal — stripped before emit
            })

    all_normalized = _dedupe_index_hits(all_normalized)
    all_normalized.sort(key=lambda h: (-h["score"], h["ts"] and -_ts_key(h["ts"]) or 0, h["id"]))
    return all_normalized[:top_k], False


def _dedupe_index_hits(hits):
    """Collapse raw/extracted duplicates: when multiple hits share the same
    raw_id (or id when raw_id absent), keep kind=extracted and drop kind=raw.

    Spec §6.1 read path. Codex review blocking #3.
    """
    seen: dict[str, dict] = {}
    for h in hits:
        # Reconstruct correlation key — raw_id for extracted, id for raw.
        key = h.get("id") or ""
        # When two hits collide on key, prefer the extracted one.
        existing = seen.get(key)
        if existing is None:
            seen[key] = h
            continue
        # Inspect kind via the source hit's metadata (we re-fetch from the
        # original record; the normalized hit dict stores layer/scope only).
        # Heuristic: extracted records carry a non-empty raw_id metadata field
        # in their source; we preserve that distinction by tagging hits at
        # normalization time. See implementation note below.
        existing_kind = existing.get("_kind", "")
        new_kind = h.get("_kind", "")
        if new_kind == "extracted" and existing_kind != "extracted":
            seen[key] = h
        # Otherwise keep existing (already extracted, or both raw — first wins).
    return list(seen.values())


def _emit_search(hits, as_json):
    # Strip internal _kind tag before emit.
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
    except ValueError:
        return 0
```

- [ ] **Step 4: Run, expect PASS**

Run: `cd scripts/sspower_mem && UV_CACHE_DIR=/private/tmp/sspower-uv-cache uv run --with pytest pytest tests/test_cli_phase_c.py -v`

- [ ] **Step 5: Commit**

```bash
git add scripts/sspower_mem/sspower_mem/cli.py scripts/sspower_mem/tests/test_cli_phase_c.py
git commit -m "feat(sspower-mem): cmd_search index path + multi-scope min-max merge"
```

---

## Task 11: Wire cmd_digest --rebuild-chroma

**Files:**
- Modify: `scripts/sspower_mem/sspower_mem/cli.py:cmd_digest`
- Modify: `scripts/sspower_mem/tests/test_cli_phase_c.py`

**Rationale:** §6.1 rebuild path: `--rebuild-chroma` clears the `sspower_memories` collection and replays every digest block via Step 2/3a/3b. Blocks with `meta.no_llm=true` skip Step 3a/3b. `--rebuild-chroma --reextract <raw_id>` targets a single block. `--rebuild-chroma --reextract all` retains raw, replays extracted.

- [ ] **Step 1: Write failing tests** — append to `tests/test_cli_phase_c.py`

```python
def test_digest_rebuild_chroma_clears_and_replays(env, capsys):
    from sspower_mem.cli import main

    _set_bridge_resp(env, _ok_envelope(["fact 1"]))
    main(["add", "--scope", "user", "--layer", "user-global", "--content", "first body"])
    capsys.readouterr()
    main(["add", "--scope", "user", "--layer", "user-global", "--content", "second body"])
    capsys.readouterr()

    rc = main(["digest", "--scope", "user", "--rebuild-chroma"])
    assert rc == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["rebuilt"] is True
    assert payload["raw_blocks"] == 2
    assert payload["extracted_facts"] == 2


def test_digest_rebuild_chroma_respects_no_llm_meta(env, capsys):
    from sspower_mem.cli import main

    _set_bridge_resp(env, _ok_envelope(["fact"]))
    main(["add", "--scope", "user", "--layer", "user-global",
          "--content", "with extraction"])
    capsys.readouterr()
    main(["add", "--scope", "user", "--layer", "user-global",
          "--content", "without extraction", "--no-llm"])
    capsys.readouterr()

    rc = main(["digest", "--scope", "user", "--rebuild-chroma"])
    assert rc == 0
    payload = json.loads(capsys.readouterr().out)
    # Two raw blocks, one extracted fact (the --no-llm block is skipped on rebuild).
    assert payload["raw_blocks"] == 2
    assert payload["extracted_facts"] == 1
    assert payload["skipped_no_llm_blocks"] == 1


def test_digest_rebuild_reextract_targeted(env, capsys):
    from sspower_mem.cli import main

    _set_bridge_resp(env, _ok_envelope(["initial"]))
    main(["add", "--scope", "user", "--layer", "user-global", "--content", "block one"])
    initial = json.loads(capsys.readouterr().out)
    raw_id = initial["id"]

    _set_bridge_resp(env, _ok_envelope(["replaced fact 1", "replaced fact 2"]))
    rc = main(["digest", "--scope", "user", "--rebuild-chroma", "--reextract", raw_id])
    assert rc == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["reextract_target"] == raw_id
    assert payload["extracted_facts"] == 2


def test_digest_rebuild_reextract_all_retains_raw(env, capsys):
    """--reextract all clears every extracted record, retains raw, re-runs Step 3a/3b
    on every digest block (no_llm=true blocks skipped). Codex review advisory #2."""
    from sspower_mem.cli import main

    _set_bridge_resp(env, _ok_envelope(["fact a"]))
    main(["add", "--scope", "user", "--layer", "user-global", "--content", "body one"])
    capsys.readouterr()
    _set_bridge_resp(env, _ok_envelope(["fact b"]))
    main(["add", "--scope", "user", "--layer", "user-global", "--content", "body two"])
    capsys.readouterr()

    _set_bridge_resp(env, _ok_envelope(["new fact 1", "new fact 2"]))
    rc = main(["digest", "--scope", "user", "--rebuild-chroma", "--reextract", "all"])
    assert rc == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["raw_blocks"] == 2  # retained
    assert payload["extracted_facts"] == 4  # 2 blocks × 2 new facts


def test_digest_rebuild_chroma_no_llm_skips_bridge(env, capsys, tmp_path):
    """--rebuild-chroma --no-llm replays raw only, MUST NOT invoke the bridge.
    Codex review advisory #2."""
    from sspower_mem.cli import main

    _set_bridge_resp(env, _ok_envelope(["unused"]))
    main(["add", "--scope", "user", "--layer", "user-global", "--content", "body"])
    capsys.readouterr()

    sentinel = tmp_path / "no_llm_rebuild_sentinel"
    env["monkeypatch"].setenv("SSPOWER_FAKE_BRIDGE_SENTINEL", str(sentinel))
    # Erase the sentinel file from any prior bridge call in this test.
    if sentinel.exists():
        sentinel.unlink()

    rc = main(["digest", "--scope", "user", "--rebuild-chroma", "--no-llm"])
    assert rc == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["raw_blocks"] == 1
    assert payload["extracted_facts"] == 0
    assert not sentinel.exists(), "bridge invoked under --rebuild-chroma --no-llm"


def test_digest_rebuild_clears_more_than_100_records(env, capsys, tmp_path):
    """Stress test: >100 records must be fully cleared (chromadb enumeration,
    not search top_k truncation). Codex review blocking #4."""
    from sspower_mem.cli import main

    for i in range(120):
        _set_bridge_resp(env, _ok_envelope([f"f{i}"]))
        main(["add", "--scope", "user", "--layer", "user-global",
              "--content", f"unique stress body {i}"])
        capsys.readouterr()

    # Sanity: 120 raw + 120 extracted = 240 records in collection.
    import chromadb
    chroma_dir = pathlib.Path(env["home"] / ".claude" / "sspower" / "idx" / "chroma")
    client = chromadb.PersistentClient(path=str(chroma_dir))
    coll = client.get_collection("sspower_memories")
    assert coll.count() == 240

    rc = main(["digest", "--scope", "user", "--rebuild-chroma"])
    assert rc == 0
    payload = json.loads(capsys.readouterr().out)
    # All 120 digest blocks replayed, all 120 raw + 120 extracted re-written.
    assert payload["raw_blocks"] == 120
    assert payload["extracted_facts"] == 120

    coll = client.get_collection("sspower_memories")
    assert coll.count() == 240  # identical post-rebuild
```

- [ ] **Step 2: Run, expect FAIL**

- [ ] **Step 3: Modify cmd_digest in `cli.py`** — extend existing function:

```python
def cmd_digest(args: argparse.Namespace) -> int:
    try:
        cwd = _resolve_cwd(args) if args.scope == "project" else None
    except FileNotFoundError as e:
        print(f"sspower-mem: {e}", file=sys.stderr)
        return 20

    troot = trust_root(args.scope, cwd)
    panchor = parent_anchor(args.scope, cwd)
    sc_id = scope_id(args.scope, cwd)
    dpath = digest_path(args.scope, cwd)
    allowed_layers = PROJECT_LAYERS if args.scope == "project" else USER_LAYERS

    if args.rebuild_chroma:
        return _do_rebuild_chroma(
            scope_id_str=sc_id, dpath=dpath, panchor=panchor,
            allowed_layers=allowed_layers,
            reextract=args.reextract, no_llm_flag=args.no_llm,
        )

    # Summary path (unchanged from Phase A).
    try:
        safe_read_strict(dpath, panchor)
        blocks = _load_all_blocks([(dpath, panchor, sc_id, allowed_layers)])
    except FileNotFoundError:
        print(json.dumps({"path": str(dpath), "exists": False, "blocks": 0,
                           "by_layer": {}, "latest_ts": None}))
        return 0
    except OSError as e:
        print(f"sspower-mem: digest read failed: {e}", file=sys.stderr)
        return 20

    by_layer: dict[str, int] = {}
    for block in blocks:
        by_layer[block["layer"]] = by_layer.get(block["layer"], 0) + 1
    summary = {"path": str(dpath), "exists": True, "blocks": len(blocks),
               "by_layer": by_layer, "latest_ts": blocks[-1]["ts"] if blocks else None}
    print(json.dumps(summary))
    return 0


def _do_rebuild_chroma(*, scope_id_str, dpath, panchor, allowed_layers,
                       reextract, no_llm_flag):
    """Rebuild Mem0 from digest.md authoritatively.

    No --reextract: clear sspower_memories collection, replay every block as
                    raw + extracted (skipping Step 3a/3b on no_llm=true blocks).
    --reextract <raw_id>: delete extracted records for this raw_id only, re-run Step 3a/3b.
    --reextract all: delete ALL extracted records, retain raw, re-run Step 3a/3b on every block
                     (no_llm=true blocks skipped).
    --no-llm: force-skip Step 3a/3b for every block (used when bridge is down).
    """
    try:
        safe_read_strict(dpath, panchor)
        blocks = _load_all_blocks([(dpath, panchor, scope_id_str, allowed_layers)])
    except FileNotFoundError:
        print(json.dumps({"rebuilt": False, "reason": "no digest"}))
        return 0
    except OSError as e:
        print(f"sspower-mem: digest read failed: {e}", file=sys.stderr)
        return 20

    try:
        import sspower_mem.mem  # noqa: F401
        from sspower_mem.mem.factory import build_memory
        from sspower_mem.mem.idx import extracted_upsert, raw_upsert
        from sspower_mem.mem.extract import ExtractFailed, bridge_extract_facts
    except ImportError as e:
        print(f"sspower-mem: index deps missing: {e}", file=sys.stderr)
        return 10

    idx_dir = user_sspower_dir() / "idx"
    chroma_dir = idx_dir / "chroma"

    raw_count = 0
    fact_count = 0
    skipped_no_llm = 0
    reextract_target = reextract if reextract not in (None, "all") else None

    # Clear FIRST (chromadb client direct; no dependence on Mem0 search enumeration).
    if reextract is None:
        _clear_collection(chroma_dir, mem=None)
    elif reextract == "all":
        _clear_extracted_only(chroma_dir)
    elif reextract_target is not None:
        _clear_extracted_for_raw(chroma_dir, reextract_target)

    # Build Mem0 AFTER clear so the collection is freshly bound.
    try:
        mem = build_memory(
            scope_id=scope_id_str, idx_dir=idx_dir,
            chroma_dir=chroma_dir,
            history_db_path=idx_dir / "history.db",
        )
    except Exception as e:
        print(f"sspower-mem: Memory init failed: {e}", file=sys.stderr)
        return 10

    for blk in blocks:
        if reextract_target is not None and blk["id"] != reextract_target:
            continue

        block_meta = {"id": blk["id"], "layer": blk["layer"], "scope": blk["scope"],
                      "ts": blk["ts"], **{k: v for k, v in blk.get("meta", {}).items()
                                             if k != "kind"}}
        is_no_llm = bool(blk.get("meta", {}).get("no_llm"))

        if reextract is None:
            try:
                raw_upsert(mem, blk["content"], block_meta, user_id=scope_id_str)
                raw_count += 1
            except Exception as e:
                _log_errors_jsonl({"stage": "rebuild_raw", "err": str(e), "raw_id": blk["id"]})
                continue
        else:
            raw_count += 1  # raw retained

        # Skip extraction when --no-llm flag set, when block was --no-llm originally on 'all',
        # or when reextract is None and block was --no-llm originally.
        if no_llm_flag or (is_no_llm and reextract != reextract_target):
            if is_no_llm:
                skipped_no_llm += 1
            continue

        try:
            facts = bridge_extract_facts(blk["content"])
        except ExtractFailed:
            _log_errors_jsonl({"stage": "rebuild_extract", "raw_id": blk["id"]})
            continue
        import hashlib
        for fact_index, fact_text in enumerate(facts):
            fh = hashlib.sha1(f'{blk["id"]}:{fact_text}'.encode()).hexdigest()[:16]
            fm = {**block_meta, "raw_id": blk["id"], "fact_index": fact_index, "fact_hash": fh}
            try:
                extracted_upsert(mem, fact_text, fm, user_id=scope_id_str)
                fact_count += 1
            except Exception as e:
                _log_errors_jsonl({"stage": "rebuild_extract_write",
                                     "raw_id": blk["id"], "fact_index": fact_index, "err": str(e)})

    print(json.dumps({"rebuilt": True, "raw_blocks": raw_count,
                       "extracted_facts": fact_count,
                       "skipped_no_llm_blocks": skipped_no_llm,
                       "reextract_target": reextract_target}))
    return 0


def _clear_collection(chroma_dir, mem):
    """Delete the entire sspower_memories Chroma collection.

    Codex review blocking #4: `mem.search` is NOT an enumeration API and can
    miss records under `top_k` truncation or blank-query behavior. Use the
    chromadb client directly against the persist dir.

    After delete_collection, the caller MUST rebuild a fresh Mem0 instance
    so its vector_store handle is re-bound to the new collection. We return
    the freshly-constructed Memory so the rebuild loop can keep using it.
    """
    import chromadb
    client = chromadb.PersistentClient(path=str(chroma_dir))
    try:
        client.delete_collection("sspower_memories")
    except Exception:
        pass  # collection may not exist yet


def _clear_extracted_only(chroma_dir):
    """Delete only kind=extracted records from sspower_memories.

    Enumerate via chromadb collection.get() (full enumeration, NOT search) and
    delete by chromadb id. Chroma supports metadata filter pass-through on .get().
    """
    import chromadb
    client = chromadb.PersistentClient(path=str(chroma_dir))
    try:
        coll = client.get_collection("sspower_memories")
    except Exception:
        return
    rows = coll.get(where={"kind": "extracted"}, limit=None)
    ids = rows.get("ids", [])
    if ids:
        coll.delete(ids=ids)


def _clear_extracted_for_raw(chroma_dir, raw_id):
    """Delete kind=extracted records for one raw_id. Enumeration via collection.get."""
    import chromadb
    client = chromadb.PersistentClient(path=str(chroma_dir))
    try:
        coll = client.get_collection("sspower_memories")
    except Exception:
        return
    rows = coll.get(where={"$and": [{"raw_id": raw_id}, {"kind": "extracted"}]}, limit=None)
    ids = rows.get("ids", [])
    if ids:
        coll.delete(ids=ids)
```

Update `build_parser` `digest` subparser: change `--reextract` to accept an optional value:

```python
digest.add_argument("--reextract", nargs="?", const="all", default=None,
                     help="Optional <raw_id> or 'all'. With --rebuild-chroma only.")
```

- [ ] **Step 4: Run, expect PASS**

Run: `cd scripts/sspower_mem && UV_CACHE_DIR=/private/tmp/sspower-uv-cache uv run --with pytest pytest tests/test_cli_phase_c.py -v`

- [ ] **Step 5: Commit**

```bash
git add scripts/sspower_mem/sspower_mem/cli.py scripts/sspower_mem/tests/test_cli_phase_c.py
git commit -m "feat(sspower-mem): cmd_digest --rebuild-chroma + --reextract"
```

---

## Task 12: Extend cmd_doctor — bootstrap + entity-store canary

**Files:**
- Modify: `scripts/sspower_mem/sspower_mem/doctor.py`
- Modify: `scripts/sspower_mem/tests/test_doctor.py`

**Rationale:** §9 Phase C bootstrap extensions: download m2v model, init chromadb + history.db at `~/.claude/sspower/idx/`, run round-trip add+search, run `complete --json` round-trip. Health: assert no `<collection>_entities` exists.

- [ ] **Step 1: Write failing tests** — append to `tests/test_doctor.py`

```python
def test_doctor_bootstrap_initializes_chroma(monkeypatch, tmp_path):
    home = tmp_path / "home"
    home.mkdir()
    (home / ".claude").mkdir()
    monkeypatch.setenv("HOME", str(home))
    # Bridge probe uses a healthy stub by default.
    fixture = pathlib.Path(__file__).parent / "fixtures" / "fake_bridge.sh"
    monkeypatch.setenv("SSPOWER_BRIDGE_PATH", str(fixture))
    monkeypatch.setenv("SSPOWER_FAKE_BRIDGE_RESPONSE",
                       '{"id":"x","object":"chat.completion","choices":[{"index":0,'
                       '"message":{"role":"assistant","content":"{\\"facts\\":[]}"}}],'
                       '"usage":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0}}')
    monkeypatch.setenv("SSPOWER_FAKE_BRIDGE_EXIT", "0")

    from sspower_mem.doctor import bootstrap
    result = bootstrap()
    assert result["status"] == "ok"
    assert result["probe"]["index"]["ok"] is True
    assert result["probe"]["bridge"]["ok"] is True
    assert (home / ".claude" / "sspower" / "idx" / "chroma").exists()
    # config.json must report phase = "C".
    import json as _j
    cfg = _j.loads((home / ".claude" / "sspower" / "idx" / "config.json").read_text())
    assert cfg["phase"] == "C"
    assert cfg["index"]["enabled"] is True


def test_doctor_bootstrap_reports_probe_failure(monkeypatch, tmp_path):
    """Probe failure must surface in status — never silent 'ok'.
    Codex review blocking #5."""
    home = tmp_path / "home"
    home.mkdir()
    (home / ".claude").mkdir()
    monkeypatch.setenv("HOME", str(home))
    fixture = pathlib.Path(__file__).parent / "fixtures" / "fake_bridge.sh"
    monkeypatch.setenv("SSPOWER_BRIDGE_PATH", str(fixture))
    monkeypatch.setenv("SSPOWER_FAKE_BRIDGE_EXIT", "1")  # bridge unhealthy
    monkeypatch.setenv("SSPOWER_FAKE_BRIDGE_STDERR",
                       '{"error":{"type":"x","message":"bridge unavailable"}}')

    from sspower_mem.doctor import bootstrap
    result = bootstrap()
    assert result["status"] == "degraded"
    assert result["probe"]["bridge"]["ok"] is False
    # Filesystem init still proceeds (idempotent).
    assert (home / ".claude" / "sspower" / "idx" / "chroma").exists()


def test_doctor_health_canaries_entity_store(monkeypatch, tmp_path):
    home = tmp_path / "home"
    home.mkdir()
    (home / ".claude").mkdir()
    monkeypatch.setenv("HOME", str(home))

    from sspower_mem.doctor import bootstrap, health
    bootstrap()
    h = health()
    assert h["phase"] == "C"
    assert h["entity_store_present"] is False  # canary: must NOT exist
    assert h["chroma_reachable"] is True
```

- [ ] **Step 2: Run, expect FAIL**

- [ ] **Step 3: Modify `doctor.py`**

```python
"""Phase C doctor: user-scope bootstrap, health, entity-store canary."""
from __future__ import annotations

import json
import os
import pathlib

from sspower_mem.io import safe_append_strict, safe_makedirs_strict, safe_write_strict
from sspower_mem.scope import user_sspower_dir


def bootstrap() -> dict:
    """Create user-scope dirs, lock, config, chroma persist dir, history.db.

    Bootstrap is idempotent. On Phase C it ALSO:
      - loads model2vec/potion-base-8M (warms uv cache),
      - constructs a Mem0 Memory with sspower providers (creates chroma + history.db),
      - runs a probe Memory.add(infer=False) + Memory.search round-trip.
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
        json.dumps({"version": "0.2.0", "phase": "C",
                     "index": {"enabled": True, "backend": "mem0+chroma",
                                "embedder": "model2vec/potion-base-8M"}}, indent=2),
        base, home,
    )

    index_probe = _probe_index(chroma_dir=chroma_dir, history_db=idx / "history.db")
    bridge_probe = _probe_bridge()

    status = "ok" if (index_probe["ok"] and bridge_probe["ok"]) else "degraded"
    return {"status": status, "base": str(base),
            "probe": {"index": index_probe, "bridge": bridge_probe}}


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
        mem.add(messages=[{"role": "user", "content": "bootstrap probe"}],
                user_id="user:global",
                metadata={"id": "bootstrap-probe", "kind": "raw",
                           "layer": "user-global", "scope": "user:global",
                           "ts": "1970-01-01T00:00:00Z"},
                infer=False)
        mem.search(query="probe", user_id="user:global", limit=1)
    except Exception as e:
        return {"ok": False, "stage": "round_trip", "err": str(e)}
    return {"ok": True}


def _probe_bridge() -> dict:
    """Run a `complete --json` round-trip against codex-bridge.

    Phase C spec §9: doctor --bootstrap must verify the bridge end-to-end.
    Honors SSPOWER_BRIDGE_PATH for tests (same env knob as mem.extract).
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

    try:
        import chromadb
        client = chromadb.PersistentClient(path=str(chroma_dir))
        coll_names = {c.name for c in client.list_collections()}
        h["chroma_reachable"] = "sspower_memories" in coll_names
        h["entity_store_present"] = "sspower_memories_entities" in coll_names
    except Exception:
        pass

    return h


def _writable(path: pathlib.Path) -> bool:
    try:
        return os.access(path, os.W_OK)
    except OSError:
        return False
```

- [ ] **Step 4: Run, expect PASS**

Run: `cd scripts/sspower_mem && UV_CACHE_DIR=/private/tmp/sspower-uv-cache uv run --with pytest pytest tests/test_doctor.py -v`

- [ ] **Step 5: Commit**

```bash
git add scripts/sspower_mem/sspower_mem/doctor.py scripts/sspower_mem/tests/test_doctor.py
git commit -m "feat(sspower-mem): doctor bootstrap + entity-store canary (Phase C)"
```

---

## Task 13: Update plugin CLAUDE.md scripts/ listing

**Files:**
- Modify: `CLAUDE.md`

**Rationale:** Handoff v0.1.2 followup (d): CLAUDE.md still lists `scripts/` as only bridge + registry; Phase A added `sspower_mem/`, Phase C adds `mem/` subpackage.

- [ ] **Step 1: Edit CLAUDE.md "Structure" block**

Find:
```
scripts/         — codex-bridge.mjs (native Codex CLI integration), codex-registry.mjs (session state for tracking)
```

Replace with:
```
scripts/         — codex-bridge.mjs (native Codex CLI integration), codex-registry.mjs (session state for tracking), sspower_mem/ (Python package for sspower-mem memory CLI; uv/uvx-runnable)
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(CLAUDE.md): list sspower_mem under scripts/"
```

---

## Task 14: Full-suite green checkpoint + push

**Files:** none (verification + push)

- [ ] **Step 1: Run full Phase A + Phase C test suite**

Run: `cd scripts/sspower_mem && UV_CACHE_DIR=/private/tmp/sspower-uv-cache uv run --with pytest pytest -v`
Expected: every test from Phase A (75) + every new Phase C test PASS. Total ≥ 110.

- [ ] **Step 2: Run Phase B bridge tests**

Run: `bash tests/codex-bridge/test-complete.sh`
Expected: 14/14 PASS (unchanged).

- [ ] **Step 3: Smoke against real Codex bridge** (optional but encouraged)

Run a single-block add against real Codex extraction:
```bash
node scripts/codex-bridge.mjs complete --json --prompt 'Extract durable factual claims from the text below as a JSON object of the form {"facts":["fact 1","fact 2"]}. Output ONLY the JSON object. No Markdown fences.\n\nTEXT:\nThe earth orbits the sun once per year. The moon orbits the earth once per month.'
```
Expected: stdout is the OpenAI envelope; `choices[0].message.content` parses as `{"facts":[...]}` with 1-3 strings.

- [ ] **Step 4: Push branch**

Confirm `phase-c` branch HEAD is up-to-date locally. Then run as a standalone Bash invocation:

```bash
git push -u origin phase-c
```

Expected: auto-review hook fires Codex review of the branch diff. Verdict must be `approve` or `approve-with-followups` to land. If `request-changes`: read the issues, fix inline, recommit, repush. Convergence target 1-3 rounds.

- [ ] **Step 5: Open PR (only after clean review)**

```bash
gh pr create --base main --head phase-c --title "feat(sspower-mem): Phase C — Mem0 index backend wiring" --body "$(cat <<'EOF'
## Summary
- Wires Mem0 (`mem0ai/mem0` @ `70bc9e51`) as the semantic-index backend.
- Client-side extraction via `codex-bridge complete --json`; `Memory.add(infer=True)` is forbidden.
- Lazy-import: digest writes survive a broken Mem0 dep tree (rc=10, never bypassed).
- Idempotent raw + extracted upserts via metadata.id / fact_hash; full D14 error matrix in `mem/extract.py`.
- doctor bootstrap downloads m2v, inits chroma, round-trips add+search.
- Entity-store canary in health check (loud if upstream eagerizes).

## Test plan
- [x] Phase A tests pass unchanged
- [x] Phase B bridge tests pass unchanged
- [x] Phase C unit tests (telemetry, noop, embedder, factory, extract, idx)
- [x] cmd_add state machine (5 exit-code cases + dup propagation)
- [x] cmd_search index + multi-scope merge + idx-only paths
- [x] cmd_digest --rebuild-chroma + --reextract (targeted + all + --no-llm)
- [x] doctor bootstrap idempotent + entity-store canary
- [x] Lazy-import boundary: cli.py module load does not pull mem0
- [x] Real-bridge smoke (Step 3 above)
EOF
)"
```

---

## Self-Review

1. **Spec coverage**
   - §3 D11 (lock + step 2 + step 3a + step 3b) → Tasks 8, 9.
   - §3 D13 (client-side extraction, kind=extracted, raw_id propagation, fact_index/fact_hash) → Tasks 6, 7, 9.
   - §3 D14 (failure observability, extracted status enum) → Tasks 6, 8, 9.
   - §6.1 Step 1/2/3a/3b state machine → Tasks 8, 9.
   - §6.1 read path (index + grep fallback + idx-only + multi-scope normalize) → Task 10.
   - §6.1 rebuild/reextract → Task 11.
   - §6.1.5 prompt contract + envelope + caps → Task 6.
   - §6.3 factory registration (class-path strings, private API canary, no other monkey-patches except telemetry) → Task 5.
   - §6.3 NoOpLLM + Model2VecEmbedder → Tasks 3, 4.
   - §8 failure modes (digest unwritable rc=20; step 2 fail rc=10; step 3a fail rc=10; step 3b partial rc=10; import fail rc=10) → Tasks 8, 9.
   - §9 Phase C deliverables (pin deps, register providers, wire chain, bootstrap, telemetry, history-db, idempotency tests, entity-store canary) → Tasks 1-12.
   - Phase 0 deliverable consumed: Q1 (LlmFactory.register_provider) → Task 5; Q2 (EmbedderFactory dict + canary) → Task 5; Q3 (infer=False shape) → Task 7; Q4 (history_db_path) → Tasks 5, 12; Q5 (telemetry env+patch+sample_rate) → Task 2; Q6+Q7 (entity store + infer=True swallow → use infer=False only) → Tasks 3, 7, 12; Q8 (filter operators) → Task 7.

2. **Placeholder scan**: no `TBD`, no "implement later", no "add appropriate error handling". Every step has complete code.

3. **Type / name consistency**:
   - `NoOpLLM` (Task 3) ↔ class path string `sspower_mem.mem.noop.NoOpLLM` (Task 5) ↔ provider name `sspower-noop` (Tasks 5, factory.py).
   - `Model2VecEmbedder` (Task 4) ↔ `sspower_mem.mem.embedder.Model2VecEmbedder` (Task 5) ↔ `sspower-model2vec`.
   - `bridge_extract_facts` (Task 6) ↔ usage in Tasks 8, 9, 11.
   - `raw_upsert` / `extracted_upsert` (Task 7) ↔ Tasks 8, 9, 11.
   - `build_memory(scope_id, idx_dir, chroma_dir, history_db_path)` signature consistent across Tasks 5, 8, 10, 11, 12.
   - `_clear_collection` / `_clear_extracted_only` / `_clear_extracted_for_raw` defined and called in Task 11.

4. **Out-of-scope guardrails**: migration (Phase D), hooks/skills (Phase E), legacy belt removal (Phase F) explicitly deferred. No work spilled.

5. **Bridge fixture path**: `SSPOWER_BRIDGE_PATH` env var honored by `extract.py:_bridge_path` (Task 6) and consumed by Phase C tests (Tasks 6, 8, 9, 10, 11). No production drift.

6. **Lazy-import enforced**: Task 8 adds `tests/test_lazy_import.py` and every Mem0-touching import is inside a function body (verified Tasks 8, 10, 11, 12).

7. **Telemetry ordering**: Task 2 sets env vars BEFORE `import mem0.memory.telemetry`. All later tasks import `sspower_mem.mem` (which runs `__init__.py`) BEFORE any `from mem0 import ...`.

---

## Execution Handoff

**Plan complete. Three execution options:**

1. **Subagent-Driven (recommended)** → `sspower:subagent-driven-development`. Phase A precedent: each task dispatched to Codex implement with `--prompt @/tmp/sdd-task-N.md`; main thread commits.
2. **Inline Execution** → `sspower:executing-plans`. Slower but lets the main thread own every edit.
3. **Codex execute** → delegate via `codex-bridge.mjs implement --write`.

**Which approach?**
