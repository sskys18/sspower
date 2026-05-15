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
        # mem/__init__ import time.
        from model2vec import StaticModel

        model_name = getattr(config, "model", None) or _DEFAULT_MODEL
        self._model = StaticModel.from_pretrained(model_name)

    def embed(self, text, memory_action=None):
        vec = self._model.encode(text)
        return vec.tolist() if hasattr(vec, "tolist") else list(vec)
