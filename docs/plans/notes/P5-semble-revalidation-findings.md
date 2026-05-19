# P5 pre-plan — semble_rs re-validation findings

> Executed 2026-05-19 (KST), branch `main` @ `9bc8121`. Re-validates spec §2
> (`docs/specs/2026-05-17-codex-worker-lsp-gate-design.md`) on a **current
> working repo** (this repo, `sspower`, 307 git-tracked files) because the
> original spike (`~/Mine/kimp`, 193 files) is pre-P1 / stale. Gates P5
> (Phase B7) planning per handoff Resume #1. Scope this session: **re-validation
> only** — no P5 plan, no D-B6.

## Tool

`semble_rs` v0.9.1 @ `~/.cargo/bin/semble_rs` (26.1 MB), commands unchanged
(`search/find-related/deps/impact/find-pattern/plan/savings/tree/encode/digest`).

## Measured (sspower, 307 tracked files)

| Metric | sspower (2026-05-19) | spec §2 (kimp, 2026-05-17) | Verdict |
|---|---|---|---|
| `search` warm bytes | **3,785 B** vs grep+read baseline **337,602 B** → **~89×** | 3,639 B vs ~110,447 B → ~30× | ✅ stronger |
| `tree` bytes | **3,706 B** vs `ls -R` **18,649 B** → **~5×** | 4,081 B vs 12,066,847 B → ~3000× | ⚠ collapsed |
| `savings` self-stat | 80% today / **84%** all-time | 86% | ✅ consistent |
| latency | cold **0.33 s** / warm **0.25 s** | cold 5 s (incl 60 MB model dl) / warm 1 s | ✅ better* |

\* Model was already cached from the 2026-05-17 spike — the 5 s cold was a
**one-time** 60 MB model download, not recurring. Steady-state is sub-second.

- search baseline = naive-agent reproduction: `grep -rilE 'lsp.*gate|runLspGate'`
  over `git ls-files` (12 matched files) → `cat` full → byte count.

## Interpretation

- **search win is real and large (~89×)** — exceeds the spike. Core B7 value
  proposition (`UserPromptSubmit` context inject, `grep -R`→`semble_rs search`
  rewrite) holds on a current repo.
- **tree ratio collapsed 3000× → ~5×.** Not a regression: kimp's 12 MB `ls -R`
  was an un-gitignored exploding build/deps tree. sspower is clean
  (gitignore-aware, no `node_modules`/build dirs to blow up `ls -R`). Absolute
  win is modest (3.7 KB vs 18.6 KB). **Signal: the `ls -R`→`tree` rewrite
  benefit is repo-shape-dependent; the spec's 3000× is an artifact of one
  pathological tree, NOT a universal claim. B7 design must not assume it.**
- savings self-stat (~84%) consistent with spike (86%).
- latency no longer a concern in steady state (model cached); cold-dl stall
  only on first-ever run — spec §2's `SessionStart` warmup mitigation (line 237)
  still warranted for fresh machines, not for warm ones.

## Disposition

- Roadmap trigger "re-validate semble_rs on a current working repo" (handoff
  Resume #1) is **MET**. semble_rs proven on a live current repo: search
  strong, savings consistent, latency a non-issue warm.
- **Caveat to carry into P5 planning:** tree-rewrite ROI is conditional on
  repo shape — P5/B7 should justify `ls -R`→`tree` on its own (correctness /
  gitignore-awareness), not on the discredited 3000× figure.
- semble_rs still pre-1.0 / young (R1) — B7 stays advisory-first with
  availability guards, no hard critical-path dependency. Unchanged.
- **Next** (NOT this session — needs explicit user go-ahead): invoke
  `sspower:writing-plans` for P5, plan file
  `docs/plans/2026-05-18-codex-worker-lsp-trackB-P2-P6.md` §P5.
