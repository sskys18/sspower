# Auto-review chokepoints — known gaps + Path B

The `auto-review.sh` and `auto-spec-gate.sh` hooks gate `git push`,
`git merge`, `gh pr create|ready`, and plan-touching `git commit` by
parsing the bash command string with `_parse-git-cmd.py` (Python
`shlex`). Parsing arbitrary bash to infer git intent is unbounded — we
ship a tight subset and accept rare-form bypasses.

## Known acceptable bypasses (Path A)

These either fail safely (hook exits 0, no false block) or require an
unusual invocation:

- `git -S keyid <ref>` (3-token gpg-sign with separate keyid before a
  ref) — `-S` is treated as a no-value flag; `keyid` would be parsed as
  the positional, fail `git rev-parse`, hook exits 0.
- Pipelines, subshells, command substitutions: `eval "git push"`,
  `(cd dir && git commit)`, etc. Treated as caller-side bypass.
- Aliases (`git ci`, `git up`): not expanded. Real git invocation
  inside the alias fires through git's own hooks if installed.
- Custom `git` on `$PATH` resolved by full path (`/usr/local/bin/git
  commit`): only bare `git ` is matched. Full-path invocation skips
  the gate.

These are documented, not bugs.

## Architecture: ask git, don't predict git

The plan-commit gate (`auto-spec-gate.sh`) used to try to predict what
`git commit` would record by parsing the bash command (`-a`, `-i`,
pathspecs, directories, globs, `--include`, `--patch`, `--only`,
`--pathspec-from-file`...). That surface is unbounded and produced a
new bypass each review round.

We now reconstruct the full arg vector from the parser and call
`git commit --dry-run --porcelain --no-verify <args>`. Git itself
expands directories, applies pathspecs, honours -i / -o, etc.; we read
the porcelain output for files whose first column indicates "in this
commit" (any of `[ACDMRTU]`). The parser only needs to know:
`subcommand`, `work_dir`, and the verbatim `subcommand_args` list.

The merge gate (`auto-review.sh`) uses the same principle for octopus
merges -- the parser collects EVERY positional ref after `merge`, and
the hook iterates `git diff HEAD...$src` per source.

## Path B — git-native hooks (follow-up)

The Claude-Code hook approach has a structural cap on accuracy:
parsing arbitrary bash. The robust replacement is to install
git's own hooks in the working repo:

- `.git/hooks/pre-commit` — runs Codex review on staged plan files.
- `.git/hooks/pre-merge-commit` — runs Codex review on incoming diff.
- `.git/hooks/pre-push` — runs Codex review on outgoing diff.

Git itself invokes these with known semantics; no bash parsing
required. Trade-offs:

- Per-repo install (not automatic on plugin load).
- Needs an installer command (`/sspower-install-git-hooks`?).
- `core.hooksPath` / `git commit --no-verify` can still bypass, but
  those are explicit user actions, not parsing edge cases.

Suggested next step: ship a small `scripts/install-git-hooks.sh` that
writes the three hook files into the current repo and add a one-liner
to the README. Keep the bash-parser hooks as a defense-in-depth layer
for sessions where the git hooks weren't installed.
