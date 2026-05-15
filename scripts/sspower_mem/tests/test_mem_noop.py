"""NoOpLLM defensive provider — raises if infer=True is ever reactivated."""
from __future__ import annotations

import pytest


def test_noop_llm_raises_on_generate_response():
    import sspower_mem.mem  # noqa: F401
    from mem0.configs.llms.base import BaseLlmConfig
    from sspower_mem.mem.noop import NoOpLLM

    llm = NoOpLLM(BaseLlmConfig())
    with pytest.raises(RuntimeError, match="infer=True forbidden in Phase C"):
        llm.generate_response(messages=[{"role": "user", "content": "x"}])


def test_noop_llm_subclasses_LLMBase():
    import sspower_mem.mem  # noqa: F401
    from mem0.llms.base import LLMBase
    from sspower_mem.mem.noop import NoOpLLM

    assert issubclass(NoOpLLM, LLMBase)
