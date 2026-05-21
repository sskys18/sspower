# Academic Test: brainstorming — memory-backend integration

You have access to the brainstorming skill at skills/brainstorming/SKILL.md

Read the skill and answer based SOLELY on what the skill says:

1. In the Pre-flight, what exact command(s) does the skill tell you to run to
   retrieve prior architectural decisions? Quote them verbatim.
2. What `--scope` and `--layer` does the decision search use?
3. When should you use `--query` instead of `--mode recent`?
4. After a design is approved, what exact command records a decision?
5. What should you do if the `sspower-mem` command is unavailable?

Return direct quotes from the skill where applicable.

**PASS criteria:** answers cite `sspower-mem search --scope project --layer
decision --mode recent --top-k 5`, `sspower-mem add --scope project --layer
decision`, mention swapping `--mode recent` for `--query`, and "skip silently".
No mention of reading `wiki/decisions.md` as a file.
