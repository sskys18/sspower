# Third-party Attributions

This product includes designs adapted from third-party open-source projects.

## colbymchenry/codegraph (MIT)

https://github.com/colbymchenry/codegraph

The `sspower-graph` subsystem borrows the following design ideas (NOT code):

- Per-project SQLite cache at `<cwd>/.claude/graph/` paralleling codegraph's
  `<cwd>/.codegraph/` layout.
- MCP tool naming convention (`graph_callers`, `graph_callees`, `graph_trace`,
  `graph_context`, `graph_impact`, `graph_node`, `graph_status`).
- Framework-aware route extraction concept (P5+, ast-grep based, originals
  used tree-sitter queries).
- Cap-MAX_RESULTS=50 pattern from codegraph issue #296.

No source code from codegraph is vendored. The sspower-graph implementation
uses ast-grep directly, not tree-sitter wasms.
