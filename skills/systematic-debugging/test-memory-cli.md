# Academic Test: systematic-debugging — memory-backend integration

You have access to the systematic-debugging skill at skills/systematic-debugging/SKILL.md

Read the skill and answer based SOLELY on what the skill says:

1. In the Pre-flight, what exact command retrieves known gotchas? Quote it.
2. What `--layer` does the gotcha search use, and does it use `--query` or
   `--mode recent`?
3. After fixing a new gotcha, what exact command records it?
4. What should you do if the `sspower-mem` command is unavailable?

Return direct quotes from the skill where applicable.

**PASS criteria:** answers cite `sspower-mem search --scope project --layer
gotcha --query`, `sspower-mem add --scope project --layer gotcha`, and "skip
silently". No mention of reading or appending `wiki/gotchas.md` as a file.
