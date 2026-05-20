# Session Handoff
> Generated: 2026-05-20 (post-pruning session)

## Task
sspower plugin pruning + workflow hardening. Removed redundancy
(codex-enrich, auto-apply, MAX_ROUNDS=2 override, always-on auto-
surface). Added skill-usage telemetry + tightened verify-before-fix
rule. Phase E (wiki ↔ sspower-mem consolidation) deliberately deferred.

## Status
### Completed this session (origin/main @ `b802e9f`; claude-config @ `c979d14`)
- **codex-enrich removed** (`a589048`, `9d77fc1`): whole skill dir +
  bridge `cmdEnrich` + 140 LOC hook block + all 3 dangling refs in
  bridge --help/COMMAND_PROFILE/log comment. 22→21 skills, -334 LOC net.
- **Auto-apply removed** (`ad88559`): `SSPOWER_REVIEW_AUTO_APPLY` env
  + `git apply --3way` block gone. Patches now SAVE-only to
  `.claude/sspower/proposed-fixes/round-N.patch`. Manual `git apply`
  required.
- **Auto-surface opt-in** (`7a04817`, `b802e9f`):
  `hooks/codex-track-prompt.sh` body gated on `SSPOWER_CODEX_SURFACE=on`.
  Default OFF saves ~300-500 tokens/turn. Tests updated to opt in +
  new gate assertion (test 8). 8/8 PASS.
- **Brainstorm lifecycle fixed** (`b2681b6`): Test 5 rewritten to
  match server.cjs:326-337 robustness design (bad startup pid →
  disable monitoring + rely on idle timeout, NOT self-terminate).
  9/9 PASS (was 6/3 of non-skipped).
- **Followups drained** (`7d8eda7`, `194924f`, `b399357`): 7 advisory
  items closed — gh-pr-merge header drift, --full-auto stale comments,
  resume test mandatory output, codex-tracking --cd wording, CLAUDE.md
  agent map, plan-review precision, gitignore auto-guard
  (`ensure_sspower_excluded` worktree-safe via `git rev-parse
  --absolute-git-dir`).
- **claude-config** (`3c552b1`, `b0b1a5b`, `c979d14`): stripped 4
  stale sspower env vars from `~/.claude/settings.json`
  (MAX_ROUNDS=2 override, ENRICH=1, SECURITY_EFFORT, SANITY_REVIEW).
  Added `/daily` section 2k — skill-usage counts from JSONL
  `tool_use` events, written to today's daily note. Vault-path
  resolved per 2c convention. Idempotent.
- **Memory rule shipped**: `feedback_codex_review_verify_before_fix.md`
  — verify Codex blocking/advisory claims against actual code before
  patching. Applied consistently this session (caught D-A5
  contradiction, refuted 1 stale-doc advisory, accepted worktree-
  helper patch on its merits).

### In Progress
- None. All gates green, all trees clean, both repos synced.

## Resume Here
1. **Wait ≥3 days, then run `/daily`** and read the new "Skill Usage"
   section to inform a real skill-audit pass (P-E). Demote unused
   skills to `experimental/` or delete; merge high-overlap routing.
2. **Phase E**: start with `/writing-plans` against the consolidation
   spec. Rewrite `hooks/wiki-archive.py` write tail to call
   `sspower-mem add` instead of direct file appends; rewrite
   `hooks/session-start` to append `sspower-mem search` to
   `additionalContext`. Bundles the 10 remaining sspower_mem
   hardening followups (digest bounds, sanitization, lock open).
3. **Optional**: re-draft Inv-A shared-fixture drift-guard test
   (semble-rewrite + cmd-rewrite on shared inputs; assert
   cmd-rewrite SKIPS ⇔ semble EMITS `ask`). Prior 41/41-green draft
   lost; B is smoke-proven so this is CI safety only.

## Decisions (do NOT revisit)
- **Auto-apply removed entirely** (not just flipped default): one
  channel mixed verified-mechanical-typos with unsolicited-refactors;
  user could not tell them apart at push time. Save-only forces a
  deliberate read.
- **Auto-surface default OFF**: cost ~300-500 tokens/turn even when
  no codex work is relevant. Opt-in via
  `export SSPOWER_CODEX_SURFACE=on` only when actively driving codex.
- **codex-enrich deleted, not revived**: spec D-A2 disabled it for a
  notice-injection bug. `semble-context.sh` already provides the
  same "code structure context on coding-intent prompts" via
  `semble_rs` rust binary — lower cost, no Codex spawn, no 20-90s
  latency. Revival would have been redundant.
- **auto-spec-gate.sh stays UNWIRED in hooks.json** (per D-A5
  2026-05-18 spec): `writing-plans` SKILL.md HARD-GATE already runs
  `bridge plan-review` explicitly. Re-wiring at hook level was
  attempted this session (commit dropped) — it duplicated the
  HARD-GATE for the case where you commit plan markdown without
  going through `/writing-plans`, which the user confirmed does not
  happen.
- **`ensure_sspower_excluded` uses `git rev-parse --absolute-git-dir`**,
  not `[ -d "$_repo/.git" ]`: linked worktrees have `.git` as a FILE
  pointing to `<common>/.git/worktrees/<name>/`. rev-parse handles
  all layouts (regular, linked-worktree, bare-with-worktree). Codex
  flagged the original directory check; verified correct, accepted.
- **MAX_ROUNDS back to default 3**: removed
  `SSPOWER_REVIEW_MAX_ROUNDS=2` from `~/.claude/settings.json`.
  Hook default is 3 (auto-review.sh:213 `:-3`).
- **All prior session's decisions remain locked**: semble-rewrite
  Approach B (live-confirmed), always-sq emit, dequote_to QTYPE
  tracking, rtk kept, P5 advisory-first, P2-P4 LSP gate locked.
  See ARCHITECTURE.md.

## Gotchas
- **Hook registry loads at CLI-PROCESS start. `/clear` does NOT reload it.**
  Valid hook-engine smoke = full `claude` quit+relaunch.
  [[feedback-hooks-json-session-start-load]]
- **Verify Codex claims before patching**: every blocking/advisory
  is a hypothesis until you open the cited file/line. This session
  caught one architectural conflict (D-A5) and one stale-doc false-
  flag by following the rule.
  [[feedback-codex-review-verify-before-fix]]
- **bash 3.2 quirks active**: `'\\''` inline mis-parses inside
  `${var//pat/rep}`; `printf %q` does not escape leading `~`. Workarounds
  documented in `hooks/semble-rewrite.sh`.
  [[feedback-bash-portability]]
- **`find` is rtk-wrapped**: when scripting against the file system
  inside a skill / hook with unusual flags (`-newermt`, `-print0`
  pipelines, `-mtime`), `export CMD_REWRITER=__none__` first. Inline
  `CMD_REWRITER=__none__ find ...` in `$(...)` loses the env
  depending on shell. The `/daily` 2k counter uses the export form
  for reliability.
- **Auto-review cap = 3 (default), but counter persists**: deny at
  `N/3` requires `rm <repo>/.git/sspower-review-rounds-<branch>` to
  reset. NOT `SSPOWER_AUTO_REVIEW=off` (that's the bypass escape).
- **chained-shell-check** trips on `&&`/`|`/`;` around chokepoints.
  Run `git commit` standalone, commit message via `-F /tmp/file`.
- **`.claude/` gitignored** in this repo. `ensure_sspower_excluded`
  helper now adds `.claude/sspower/` to `<repo>/.git/info/exclude`
  in CONSUMING repos automatically on first auto-review run.
- **Uncommitted in-session work is fragile**: prior session's
  41/41-green Inv-A drift-guard test was lost when other work
  was reverted. Commit or stash with an explicit label BEFORE any
  rollback.

## Context
- **Branch**: `main` @ `b802e9f`, tree clean, == `origin/main`. No
  worktrees.
- **claude-config**: separate repo, `main` @ `c979d14`, == `origin/main`.
  Holds `/daily` skill + global settings.
- **Tests**: 9 sspower hook suites green. test-track-prompt-hook
  added gate assertion (test 8). 10/10 codex-bridge suites incl.
  test-skip-git-flag. brainstorm-server windows-lifecycle 9/9
  (was 0/3 of non-skipped at session start).
- **Surface delta**: -334 LOC, 22→21 skills, 1 bridge subcommand
  removed, 1 hook simplified 162→23 LOC, 1 env var removed (auto-
  apply), 4 stale env vars removed from user settings.
- **Unknowns**: none.
