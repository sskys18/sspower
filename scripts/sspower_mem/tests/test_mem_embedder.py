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
    """potion-base-8M is 256-dim per upstream model card; lock the shape."""
    import sspower_mem.mem  # noqa: F401
    from mem0.configs.embeddings.base import BaseEmbedderConfig
    from sspower_mem.mem.embedder import Model2VecEmbedder

    cfg = BaseEmbedderConfig(model="minishlab/potion-base-8M")
    emb = Model2VecEmbedder(cfg)
    assert len(emb.embed("x", memory_action="add")) == 256
