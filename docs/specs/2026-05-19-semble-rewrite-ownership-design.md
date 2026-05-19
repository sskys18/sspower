# Design — semble-rewrite ownership of `ls -R` / `grep -R` (rtk carve-out)

> 2026-05-19 (KST). Branch base: `main` @ `f68f630` (P5/B7 shipped). Scope:
> narrow carve-out. Supersedes the shipped P5 plan's DP-3 assumption.

## Problem (root cause, empirically established)

P5 shipped `hooks/semble-rewrite.sh` in `PreToolUse:Bash` **after**
`hooks/cmd-rewrite.sh` (the rtk delegator). Verified facts:

1. Claude Code CLI **chains `updatedInput` in order** across sibling
   PreToolUse hooks (live test: real `ls -R` produced rtk-compressed
   output + no ask-prompt; `semble-rewrite` fed `rtk ls -R …` no-ops).
   `[High]` Confirmed in this environment + matches SDK docs "changes
   chain together in order".
2. So for `ls -R`/`grep -R`: cmd-rewrite/rtk rewrites first
   (`ls -R src`→`rtk ls -R src`, decision `allow`); semble-rewrite then
   receives the rtk-prefixed command, its `TOK[0]∈{ls,grep}` matcher
   fails → no-ops. **semble-rewrite's two rewrite cases are dead code
   whenever rtk is present.** P5's PreToolUse value is silently nullified.
3. Eval (this repo): `ls -R .` → raw 19,015 B / rtk 357,352 B /
   `semble_rs tree` 3,982 B (gitignore-aware). `grep -R runLspGate .` →
   raw 7,322 / rtk 64,107 / `semble_rs search --compact` 412. rtk is
   **not** gitignore-aware; semble is. rtk remains valuable on its broad
   surface (git/read/find/gh/pnpm — `git diff` 4,915→4,467, etc.), so
   wholesale removal is rejected; only the two recursive-tree patterns
   are carved out.

DP-3 in `docs/plans/2026-05-19-codex-worker-P5-semble-context-layer.md`
("cmd-rewrite first; semble-rewrite no-ops when patterns don't match")
was correct that semble no-ops, but for the WRONG reason (rtk-prefixed,
not already-desired) — so the feature never delivered. This design fixes
that.

## Goal

Make `semble-rewrite.sh` the effective owner of exactly two patterns —
`ls … -R … [path]` (uppercase-R only) and `grep -R|-r <BARE_IDENT> [path]`
— so its gitignore-aware, explicit-`ask` rewrite actually reaches the
user. Keep rtk/cmd-rewrite for every other command unchanged.

## Non-goals

rtk's large-tree weakness in other contexts; rtk version/upgrade;
wholesale rtk removal; merging the hooks; any P3–P6 roadmap item;
changing semble-rewrite's matcher/quoting/ask semantics (shipped, tested).

## Chosen approach — B: reorder hooks (no script edits)

`hooks/hooks.json`, `PreToolUse` group `matcher:"Bash"`: reorder the
`hooks` array to **`semble-rewrite.sh` → `cmd-rewrite.sh` → auto-review.sh`**
(semble-rewrite moves from index 1 to index 0; auto-review stays last).

### Why B over A (skip-list in cmd-rewrite) / C (merge hooks)

- **A** duplicates semble-rewrite's `ls`/`grep` matcher inside
  cmd-rewrite.sh → two matchers that must stay in lock-step (drift risk
  flagged by edit-safety "No Semantic Search").
- **C** rewrites two shipped, separately-tested hooks into one → largest
  change + test surface for a 2-pattern fix (YAGNI).
- **B** is a one-line array reorder, zero logic duplication, and every
  dependency is empirically verified (below).

### Mechanism (verified dependencies)

| Dep | Status | Evidence |
|---|---|---|
| CLI chains `updatedInput` in array order | `[High]` | live `ls -R` → rtk output; `semble-rewrite` fed `rtk ls -R` → empty/rc0 |
| rtk has NO equivalent for `semble_rs …` (passes through) | `[High]` | `rtk rewrite "semble_rs tree ."` → exit 1, empty (×3 variants) |
| permissionDecision = most-restrictive (deny>ask>allow) | `[High]` | Claude Code hooks docs |
| semble-rewrite no-ops on non-overlap input | `[High]` | shipped `tests/hooks/test-semble-rewrite.sh` |

### Behavior after reorder

- **Overlap** (`ls -R src`, `grep -R IDENT [p]`): semble-rewrite (now
  first) emits `semble_rs tree src` / `semble_rs search --compact …` +
  explicit `permissionDecision:"ask"`. Chained command `semble_rs …`
  passes to cmd-rewrite → `rtk rewrite` exit 1 → cmd-rewrite emits
  nothing. Final: semble's command + `ask`. User confirms a
  gitignore-aware, ~90–155× smaller command. Never deny.
- **Non-overlap** (everything else): semble-rewrite no-ops (empty, rc 0)
  → no `updatedInput` → cmd-rewrite receives the ORIGINAL command → rtk
  optimizes exactly as today. git/read/find/gh/pnpm unaffected.
- **auto-review.sh**: unchanged, still last. `ls`/`grep` are not git
  chokepoints; its logic is untouched.

### Edge cases

- semble-rewrite already bails on compound/metachar/glob commands and
  `ls -r` (lowercase reverse) — unchanged, still correct when first.
- If semble-rewrite emits `ask` but the user rejects: normal Claude
  Code flow (command not run) — same as any ask hook.
- rtk absent/disabled: semble-rewrite still owns the 2 patterns; other
  commands run raw (cmd-rewrite already no-ops without rtk). No regression.
- Two hooks both emitting for a non-overlap command: cannot happen —
  semble-rewrite only emits for its 2 patterns; for those rtk passes
  through, so exactly one emitter.

## Changes

| File | Change |
|---|---|
| `hooks/hooks.json` | Reorder `PreToolUse[Bash].hooks`: `semble-rewrite.sh`, `cmd-rewrite.sh`, `auto-review.sh` |
| `tests/hooks/test-semble-rewrite.sh` | Add ordered-chain integration assertions: (a) bare `ls -R src` → `ask`+`semble_rs tree src`; (b) `grep -R IDENT .` → `ask`+`semble_rs search …`; (c) non-overlap `git status` → semble no-op (empty) so rtk path intact; (d) `semble_rs tree .` is rtk-passthrough (exit 1) |
| `docs/ARCHITECTURE.md` | P5 section: correct the DP-3 note — semble-rewrite runs FIRST; document the multi-hook `updatedInput` chaining fact + rtk carve-out rationale |
| `.claude/wiki/gotchas.md` | Append: CLI chains `updatedInput` across sibling PreToolUse hooks in array order → hook that must own a pattern runs FIRST (local sidecar; durable copy in ARCHITECTURE) |

No edits to `semble-rewrite.sh` or `cmd-rewrite.sh` scripts.

## Verification

| Criterion | Command | Expected |
|---|---|---|
| hooks.json valid + order | `jq -r '.hooks.PreToolUse[]\|select(.matcher=="Bash")\|[.hooks[].command]\|@tsv' hooks/hooks.json` | `semble-rewrite.sh` then `cmd-rewrite.sh` then `auto-review.sh` |
| semble owns ls -R | test-semble-rewrite (a) | `ask` + `semble_rs tree src` |
| semble owns grep -R | test-semble-rewrite (b) | `ask` + `semble_rs search …` |
| rtk path intact non-overlap | test-semble-rewrite (c) | semble no-op (empty) on `git status` |
| rtk passthrough semble cmd | test-semble-rewrite (d) | `rtk rewrite "semble_rs tree ."` exit 1 |
| live smoke | run `ls -R <small dir>` in a session | `semble_rs tree` output + ask-prompt (not rtk compressed) |
| regression | `bash -n` all hooks; `jq -e . hooks/hooks.json` | clean |

## Risks

- **R1 — chaining behavior is CLI-version-dependent / undocumented.**
  Mitigated: empirically confirmed in the live environment this ships
  to; `[High]`. If a future Claude Code changes chaining, the live-smoke
  verification catches it. Fallback: Approach A (skip-list) if reorder
  ever stops working.
- **R2 — auto-review must remain last.** Reorder explicitly keeps
  `auto-review.sh` at the end; verified by the order assertion.
- **R3 — non-overlap regression (rtk).** Bounded: semble-rewrite emits
  ONLY for its 2 patterns; everything else still hits rtk unchanged
  (test (c)).
