"""Factory registration + Memory builder.

register_providers(): idempotent; registers sspower-noop LLM (public API)
and sspower-model2vec embedder (private dict mutation, Phase 0 §2 caveat 2).
Raises RuntimeError loudly if EmbedderFactory.provider_to_class is renamed.

build_memory(scope_id, idx_dir, chroma_dir, history_db_path): construct a
Mem0 Memory instance with pinned history-db path, deterministic collection
name "sspower_memories", and a NoOpLLM that stays inert (sspower never sends
infer=True).
"""
from __future__ import annotations

import pathlib

from mem0.configs.base import EmbedderConfig, LlmConfig, MemoryConfig, VectorStoreConfig
from mem0.configs.llms.base import BaseLlmConfig
from mem0.utils.factory import EmbedderFactory, LlmFactory

_LLM_NAME = "sspower-noop"
_LLM_PATH = "sspower_mem.mem.noop.NoOpLLM"
_EMB_NAME = "sspower-model2vec"
_EMB_PATH = "sspower_mem.mem.embedder.Model2VecEmbedder"

_COLLECTION = "sspower_memories"


def register_providers() -> None:
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
    """Construct a Mem0 Memory using sspower-noop + sspower-model2vec."""
    register_providers()

    from mem0 import Memory

    # LlmConfig / EmbedderConfig validators have a hardcoded provider allow-list
    # that rejects sspower-noop / sspower-model2vec. Bypass via model_construct
    # (skips field validators). Mem0 still looks up the provider class in the
    # registered LlmFactory.provider_to_class / EmbedderFactory.provider_to_class.
    llm_cfg = LlmConfig.model_construct(provider=_LLM_NAME, config={})
    emb_cfg = EmbedderConfig.model_construct(
        provider=_EMB_NAME, config={"model": "minishlab/potion-base-8M"}
    )
    # chroma IS in the allow-list, so full validation runs and converts config
    # into a typed ChromaConfig sub-model (needed for Mem0's attr access).
    vec_cfg = VectorStoreConfig(
        provider="chroma",
        config={"collection_name": _COLLECTION, "path": str(chroma_dir)},
    )

    config = MemoryConfig.model_construct(
        history_db_path=str(history_db_path),
        llm=llm_cfg,
        embedder=emb_cfg,
        vector_store=vec_cfg,
    )
    return Memory(config)
