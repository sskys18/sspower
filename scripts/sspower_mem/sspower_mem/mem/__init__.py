"""Phase C Mem0 wiring. Importing this package MUST happen before any `import mem0`.

Telemetry shield order:
  1. Set env vars (idempotent; safe if already set).
  2. Import mem0.memory.telemetry — module-level `client_telemetry = AnonymousTelemetry()`
     reads the env var at import.
  3. Defensively patch capture_event / capture_client_event / MEM0_TELEMETRY so a
     malformed env never leaks PostHog calls.

Per docs/specs/2026-05-13-index-provider-registration.md §5.
"""
from __future__ import annotations

import os

os.environ.setdefault("MEM0_TELEMETRY", "False")
os.environ.setdefault("MEM0_TELEMETRY_SAMPLE_RATE", "0")

import mem0.memory.telemetry as _telemetry  # noqa: E402

_telemetry.MEM0_TELEMETRY = False
_telemetry.capture_event = lambda *a, **kw: None
_telemetry.capture_client_event = lambda *a, **kw: None
