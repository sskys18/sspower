# Academic Test: writing-plans — memory-backend integration

You have access to the writing-plans skill at skills/writing-plans/SKILL.md

Read the skill and answer based SOLELY on what the skill says:

1. In the Pre-flight, what exact two commands does the skill tell you to run?
   Quote them verbatim.
2. What `--layer` and `--top-k` does each call use?
3. When should you use `--query` instead of `--mode recent`?
4. What should you do if the `sspower-mem` command is unavailable?

Return direct quotes from the skill where applicable.

**PASS criteria:** answers cite `sspower-mem search --scope project --layer
decision --mode recent --top-k 5` AND `--layer episodic --mode recent --top-k
3`, mention swapping for `--query`, and "skip silently". No mention of reading
`wiki/decisions.md` or `sessions/` as files.
