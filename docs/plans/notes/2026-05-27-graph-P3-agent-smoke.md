# P3 agent smoke results

| Agent | MCP tool called | Before Explore? | Notes |
|---|---|---|---|
| code-reviewer | not run in Codex worker | not verified | Guidance section appended; no explicit `tools:` frontmatter added per P3-D7. Requires supervisor-side Claude Code agent transcript smoke. |
| sanity-reviewer | not run in Codex worker | not verified | Guidance section appended; no explicit `tools:` frontmatter added per P3-D7. Requires supervisor-side Claude Code agent transcript smoke. |
| security-reviewer | not run in Codex worker | not verified | Guidance section appended; no explicit `tools:` frontmatter added per P3-D7. Requires supervisor-side Claude Code agent transcript smoke. |

Codex worker limitation: this environment can edit the agent Markdown and
exercise the MCP server directly, but it does not expose a Claude Code command
that invokes these named reviewer agents and returns transcripts. This note is
therefore a pending manual smoke placeholder, not evidence that each agent
called `graph_*` before Explore.
