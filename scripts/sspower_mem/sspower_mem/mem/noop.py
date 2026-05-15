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
