# Auto-review chokepoints — known gaps + Path B

The `auto-review.sh` and `auto-spec-gate.sh` hooks gate `git push`,
`git merge`, `gh pr create|ready`, and plan-touching `git commit` by
parsing the bash command string with `_parse-git-cmd.py` (Python
`shlex`). Parsing arbitrary bash to infer git intent is unbounded — we
ship a tight subset and accept rare-form bypasses.

## Known gaps (current bash-parser implementation)

The bash-string parser at `hooks/_parse-git-cmd.py` covers the common
chokepoint forms (12 rounds of codex review iterated it from naive
regex to shlex+segment+wrapper-strip). The remaining gaps below are
documented here rather than patched -- the surface is unbounded and
each fix invites the next finding. Path B (git-native hooks, see
below) is the structural exit; until then these are accepted:

- **`git commit -i a.md` with `a.md` already in pre-existing index.**
  -i re-stages worktree at commit time, so the bytes recorded come
  from the working tree even for files that were already in the
  index. The current gate sources those files from the index. False
  negative: a worktree-only edit to a pre-staged plan can pass the
  review (the index version was reviewed, not the worktree version).
  Mitigation: stage the worktree change before committing; the next
  invocation of the gate will see the new index.

- **`--git-dir` and `--work-tree` given separately.** The parser
  collapses both into a single `work_dir` value and the hooks pass
  it as `git -C $work_dir`. When a user splits the two
  (`git --git-dir=/x.git --work-tree=/y commit`), only one is
  honoured and git operations may target the wrong tree. Hook would
  then `exit 0` (rev-parse fails) and let the action through. Rare
  in practice; bypassable at user's own discretion.

- **`gh pr merge`.** The current `auto-review.sh` reviews local diff
  vs upstream, which is unrelated to a remote PR's contents. Gating
  on local state for `gh pr merge` would either falsely block (when
  local is dirty but the PR is fine) or falsely approve. The verb
  is therefore NOT in the chokepoint list. PR contents are gated at
  `gh pr create` / `gh pr ready` instead. If you want a merge-time
  re-review, run `gh pr diff <num> | node scripts/codex-bridge.mjs
  review --prompt @-` manually before merging.

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
