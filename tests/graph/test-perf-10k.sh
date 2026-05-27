#!/usr/bin/env bash
set -euo pipefail
if [[ "${SSPOWER_GRAPH_PERF:-0}" != "1" ]]; then
  echo "test-perf-10k.sh SKIP (set SSPOWER_GRAPH_PERF=1 to run)"
  exit 0
fi
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
exec node "$HERE/tests/graph/perf-10k.mjs"
