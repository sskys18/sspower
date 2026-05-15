"""Factory registration is idempotent + asserts private-API presence loudly."""
from __future__ import annotations

import inspect
import pathlib

import pytest


def test_memoryconfig_constructor_shape():
    """Preflight: confirm MemoryConfig fields used by build_memory exist.

    Per docs/specs/2026-05-13-index-backend-integration-design.md §6.3 and
    Phase 0 verification — locks the constructor against unintended drift.
    """
    import sspower_mem.mem  # noqa: F401
    from mem0.configs.base import LlmConfig, MemoryConfig  # noqa: F401

    fields = (
        set(MemoryConfig.model_fields.keys())
        if hasattr(MemoryConfig, "model_fields")
        else set(inspect.signature(MemoryConfig).parameters.keys())
    )
    required = {"history_db_path", "llm", "embedder", "vector_store"}
    missing = required - fields
    assert not missing, f"MemoryConfig missing expected fields: {missing}; got {sorted(fields)}"


def test_register_providers_is_idempotent():
    import sspower_mem.mem  # noqa: F401
    from mem0.utils.factory import EmbedderFactory, LlmFactory
    from sspower_mem.mem.factory import register_providers

    register_providers()
    snapshot_llm = dict(LlmFactory.provider_to_class)
    snapshot_emb = dict(EmbedderFactory.provider_to_class)
    register_providers()
    assert dict(LlmFactory.provider_to_class) == snapshot_llm
    assert dict(EmbedderFactory.provider_to_class) == snapshot_emb


def test_register_providers_uses_class_path_strings():
    """Phase 0 Q1 + Q2: must register by class-path STRING, not class object."""
    import sspower_mem.mem  # noqa: F401
    from mem0.utils.factory import EmbedderFactory, LlmFactory
    from sspower_mem.mem.factory import register_providers

    register_providers()
    llm_entry = LlmFactory.provider_to_class["sspower-noop"]
    assert llm_entry[0] == "sspower_mem.mem.noop.NoOpLLM"
    assert EmbedderFactory.provider_to_class["sspower-model2vec"] == (
        "sspower_mem.mem.embedder.Model2VecEmbedder"
    )


def test_register_providers_raises_if_private_api_renamed(monkeypatch):
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
    assert mem.collection_name == "sspower_memories"
