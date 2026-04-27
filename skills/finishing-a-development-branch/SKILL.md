---
name: finishing-a-development-branch
description: Use when implementation is complete, all tests pass, and you need to decide how to integrate the work - guides completion of development work by presenting structured options for merge, PR, or cleanup
---

# Finishing a Development Branch

**Core principle:** Verify tests → Present options → Execute choice → Clean up.

**Announce at start:** "I'm using the finishing-a-development-branch skill to complete this work."

## The Process

### Step 0: Verify Codex Branch Review Complete (HARD GATE)

Before anything else: run a Codex review of the full branch diff. Skipping this step is a merge-readiness failure, regardless of whether tests pass or Claude already reviewed.

```bash
git diff $(git merge-base HEAD main)..HEAD > /tmp/branch.diff
node "${CLAUDE_PLUGIN_ROOT}/scripts/codex-bridge.mjs" review \
  --prompt "Review the branch diff at /tmp/branch.diff. Flag bugs, regressions, missing tests, security issues. Out of scope: stylistic refactors. Return structured verdict."
```

Block on `verdict`:
- `approve` → proceed to Step 1.
- `needs-attention` → fix every issue from `issues[]`, commit, re-run review until `approve`. Do NOT merge or PR with unresolved findings.
- `reject` → return to implementation; the branch is not ready.

If `sspower:second-opinion` was already invoked and approved on the current HEAD, that satisfies this gate — skip the re-run.

### Step 1: Verify Tests

Run project's test suite. **If tests fail: STOP. Do not proceed to Step 2.**

### Step 2: Determine Base Branch

```bash
git merge-base HEAD main 2>/dev/null || git merge-base HEAD master 2>/dev/null
```

### Step 3: Present Options

Present exactly these 4 options:
```
Implementation complete. What would you like to do?

1. Merge back to <base-branch> locally
2. Push and create a Pull Request
3. Keep the branch as-is (I'll handle it later)
4. Discard this work

Which option?
```

### Step 4: Execute Choice

Read `references/option-details.md` for full bash commands and flows per option.

### Step 5: Cleanup Worktree (MANDATORY for Options 1, 3, 4)

**Do not skip this step.** Orphaned worktrees waste disk and cause confusion.

```bash
# List worktrees to find the one for this branch
git worktree list | grep $(git branch --show-current)

# Remove worktree (Options 1, 4 — branch is done)
git worktree remove <worktree-path>

# Option 2 (PR): keep worktree until PR merges, then remove
# Option 3 (keep): keep worktree — user wants it
```

Report cleanup result: "Cleaned up worktree at `<path>`" or "Keeping worktree at `<path>` for Option 2/3."

## Quick Reference

| Option | Merge | Push | Keep Worktree | Cleanup Branch |
|--------|-------|------|---------------|----------------|
| 1. Merge locally | ✓ | - | - | ✓ |
| 2. Create PR | - | ✓ | ✓ | - |
| 3. Keep as-is | - | - | ✓ | - |
| 4. Discard | - | - | - | ✓ (force) |

## Red Flags

**Never:**
- Proceed with failing tests
- Merge without verifying tests on result
- Delete work without confirmation
- Force-push without explicit request

**Always:**
- Verify tests before offering options
- Present exactly 4 options
- Get typed confirmation for Option 4
- Clean up worktree for Options 1 & 4 only

## Integration

**Prerequisite:**
- **Codex review** - Run `codex-bridge.mjs review` for independent second opinion before finishing

**Called by:**
- **subagent-driven-development** (Step 7) - After all tasks complete
- **executing-plans** (Step 5) - After all batches complete

**Pairs with:**
- **using-git-worktrees** - Cleans up worktree created by that skill
