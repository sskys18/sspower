# Plan — semble-rewrite owns `ls -R`/`grep -R` (hooks.json reorder)

> Spec: `docs/specs/2026-05-19-semble-rewrite-ownership-design.md` (Codex
> plan-review: approve). Branch: `fix/semble-rewrite-ownership` (spec
> committed `ca3ebe8`, base `main` `f68f630`). Approach B (reorder, no
> script edits).

## Goal

Reorder `PreToolUse:Bash` hooks so `semble-rewrite.sh` runs BEFORE
`cmd-rewrite.sh` → semble-rewrite's gitignore-aware `ls -R`→tree /
`grep -R IDENT`→search (explicit `ask`) actually reaches the user
instead of being shadowed by rtk. Everything else unchanged.

## Files

| Action | Path | Responsibility |
|---|---|---|
| MODIFY | `hooks/hooks.json` | Reorder `PreToolUse[Bash].hooks`: semble-rewrite, cmd-rewrite, auto-review |
| MODIFY | `tests/hooks/test-semble-rewrite.sh` | Append chain-invariant assertions proving the reorder delivers |
| MODIFY | `docs/ARCHITECTURE.md` | Correct DP-3 note + record multi-hook `updatedInput` chaining fact |
| MODIFY | `.claude/wiki/gotchas.md` | Append the chaining gotcha (local sidecar; durable copy in ARCHITECTURE) |

No edits to `hooks/semble-rewrite.sh` or `hooks/cmd-rewrite.sh`.

---

## Task 1 — Reorder `hooks/hooks.json`

### Step 1.1 — Edit

In `hooks/hooks.json`, the `PreToolUse` array's `"matcher":"Bash"` group
currently orders hooks: `cmd-rewrite.sh`, `semble-rewrite.sh`,
`auto-review.sh`. Replace that exact block:

Old:
```json
      {
        "type": "command",
        "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/cmd-rewrite.sh\"",
        "timeout": 3
      },
      {
        "type": "command",
        "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/semble-rewrite.sh\"",
        "timeout": 3
      },
      {
        "type": "command",
        "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/auto-review.sh\"",
        "timeout": 600
      }
```

New (semble-rewrite first; cmd-rewrite second; auto-review last):
```json
      {
        "type": "command",
        "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/semble-rewrite.sh\"",
        "timeout": 3
      },
      {
        "type": "command",
        "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/cmd-rewrite.sh\"",
        "timeout": 3
      },
      {
        "type": "command",
        "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/auto-review.sh\"",
        "timeout": 600
      }
```

### Step 1.2 — Validate

```bash
jq -e . hooks/hooks.json >/dev/null && echo "JSON OK"
jq -r '.hooks.PreToolUse[]|select(.matcher=="Bash")|[.hooks[].command]|@tsv' hooks/hooks.json
```

Expected: `JSON OK`; the tsv line shows, left→right:
`…/hooks/semble-rewrite.sh` then `…/hooks/cmd-rewrite.sh` then
`…/hooks/auto-review.sh`.

---

## Task 2 — Chain-invariant assertions in `tests/hooks/test-semble-rewrite.sh`

A unit test cannot drive Claude Code's live hook engine, so assert the
exact invariants the reorder depends on. **Two insertion points** — the
order invariant (Inv-4) is semble-independent and MUST run even on
fail-open (no-`semble_rs`) machines, so it goes ABOVE the test's
`if ! command -v semble_rs …; then … exit 0; fi` early-exit block. The
semble-dependent invariants (Inv-1/2/3) go before the final PASS line.

### Step 2.1 — Add `skip()` helper if missing (manual, exact-match safe)

`grep -n 'skip()' tests/hooks/test-semble-rewrite.sh` — if no match, use
the Edit tool to change the line
`FAIL=0; ok(){ echo "PASS: $1"; }; bad(){ echo "FAIL: $1 :: $2"; FAIL=1; }`
to that same line followed by a new line:
`skip(){ echo "SKIP: $1"; }`
(Edit tool, not `sed` — avoids the macOS/Linux `sed -i ''` portability
trap. If `skip()` already present, skip this step.)

### Step 2.2 — Inv-4 (order regression guard) ABOVE the no-semble early-exit

The file has, near the top, a no-`semble_rs` early-exit:
`if ! command -v semble_rs >/dev/null 2>&1; then … exit 0; fi`.
Using the Edit tool, insert this block IMMEDIATELY BEFORE that
`if ! command -v semble_rs` line so it always runs:

```bash
# Inv-4 (semble-independent): hooks.json reorder is actually in place —
# semble-rewrite BEFORE cmd-rewrite, and auto-review is the LAST Bash hook
# (last-anchored, not loose order). Must run even when semble_rs absent.
HJ="$(cd "$(dirname "$0")/../.." && pwd)/hooks/hooks.json"
if jq -e '
  ([.hooks.PreToolUse[]|select(.matcher=="Bash")|.hooks[].command]) as $c
  | ($c|map(test("semble-rewrite"))|index(true)) as $s
  | ($c|map(test("cmd-rewrite"))|index(true)) as $m
  | ($c|length) as $n
  | ($s != null and $m != null and ($s < $m) and ($c[$n-1]|test("auto-review")))
' "$HJ" >/dev/null 2>&1; then
  ok "chain Inv-4: semble-rewrite<cmd-rewrite & auto-review LAST"
else
  bad "Inv-4 order" "$(jq -c '[.hooks.PreToolUse[]|select(.matcher=="Bash")|.hooks[].command]' "$HJ")"
fi
```

### Step 2.3 — Inv-1/2/3 (semble-dependent) before the final PASS line

Using the Edit tool, insert BEFORE the last line
`[[ $FAIL -eq 0 ]] && echo "PASS: test-semble-rewrite" …`:

```bash
# ── Reorder chain invariants (semble-dependent) ──────────────────────
# Inv-1: semble-rewrite (now FIRST) emits ask + semble cmd on bare ls -R.
O="$(j 'ls -R src' | "$H")"
echo "$O" | jq -e '(.hookSpecificOutput.permissionDecision=="ask") and (.hookSpecificOutput.updatedInput.command=="semble_rs tree src")' >/dev/null \
  && ok "chain Inv-1: semble first → ask+tree" || bad "Inv-1" "$O"

# Inv-2: semble's emitted command passes through cmd-rewrite untouched
# (rtk has no semble_rs equivalent) → semble's decision survives the chain.
CR="$(cd "$(dirname "$0")/../.." && pwd)/hooks/cmd-rewrite.sh"
if command -v rtk >/dev/null 2>&1; then
  O="$(printf '{"tool_input":{"command":"semble_rs tree src"}}' | "$CR" 2>/dev/null)"
  [[ -z "$O" ]] && ok "chain Inv-2: cmd-rewrite passthrough semble tree" || bad "Inv-2 (rtk grabbed semble_rs?)" "$O"
  O="$(printf '{"tool_input":{"command":"semble_rs search --compact runLspGate ."}}' | "$CR" 2>/dev/null)"
  [[ -z "$O" ]] && ok "chain Inv-2b: passthrough semble search" || bad "Inv-2b" "$O"
else
  skip "chain Inv-2 (rtk absent — cmd-rewrite no-ops, passthrough holds trivially)"
fi

# Inv-3: non-overlap command → semble-rewrite no-ops (empty) so the
# original reaches cmd-rewrite/rtk unchanged (rtk broad surface intact).
for c in 'git status' 'cat foo.txt' 'npm install' 'ls -la'; do
  O="$(j "$c" | "$H")"
  [[ -z "$O" ]] && ok "chain Inv-3 non-overlap untouched: $c" || bad "Inv-3: $c" "$O"
done
```

### Step 2.4 — Run

```bash
bash -n tests/hooks/test-semble-rewrite.sh && echo "syntax OK"
bash tests/hooks/test-semble-rewrite.sh; echo "rc=$?"
```

Expected: ends `PASS: test-semble-rewrite`, **`rc=0`** (status read
directly, NOT through a pipe). Output includes `PASS: chain Inv-4`
(even with no semble_rs), and on a semble box also `Inv-1`, `Inv-2`,
`Inv-3` (×4).

---

## Task 3 — Docs

### Step 3.1 — `docs/ARCHITECTURE.md` table + narrative

Line ~100-101 table rows currently:
```
| `PreToolUse:Bash` | `cmd-rewrite.sh` | sync, 3s | Optional command rewriter (`rtk`) for token savings. |
| `PreToolUse:Bash` | `semble-rewrite.sh` | sync, 3s | `ls -R` -> tree & `grep -R ident` -> search; both explicit ASK. |
```
Replace with (semble-rewrite row FIRST, note ownership):
```
| `PreToolUse:Bash` | `semble-rewrite.sh` | sync, 3s | **Runs FIRST.** `ls -R`->`semble_rs tree` & `grep -R ident`->`semble_rs search`, both explicit ASK, gitignore-aware. Owns these 2 patterns. |
| `PreToolUse:Bash` | `cmd-rewrite.sh` | sync, 3s | `rtk` token-saver for ALL OTHER commands (git/read/find/gh/pnpm…). Receives `semble_rs …` for the 2 patterns and passes through (no rtk equiv). |
```

Line ~590 narrative `…(PreToolUse:Bash, between cmd-rewrite & auto-review)…`
→ change to `(PreToolUse:Bash, **runs first** — before cmd-rewrite &
auto-review)` and append one paragraph after that bullet:

```
**Hook ordering is load-bearing (2026-05-19).** Claude Code chains
`updatedInput` across sibling PreToolUse hooks in array order. When
`cmd-rewrite` ran first (shipped P5), rtk rewrote `ls -R`/`grep -R` to
`rtk …` and the chained `semble-rewrite` no longer matched → P5's
rewrite was dead. Fix = `semble-rewrite` first; it owns the 2 patterns,
emits `semble_rs …`+ask, and `cmd-rewrite` passes that through (rtk has
no `semble_rs` equivalent). This corrects the shipped P5 plan's DP-3
assumption (it claimed semble-rewrite would no-op as already-rewritten;
it actually no-op'd because rtk-prefixed — wrong reason, zero value).
rtk keeps its broad token-saving surface for every other command.
```

### Step 3.2 — `.claude/wiki/gotchas.md` append

Append at end of `.claude/wiki/gotchas.md`:

```
## PreToolUse sibling-hook updatedInput chaining (2026-05-19)
Claude Code CLI chains `updatedInput` across sibling PreToolUse hooks in
ARRAY ORDER (verified live: `ls -R` → rtk-compressed output, no
ask-prompt, when cmd-rewrite preceded semble-rewrite). A hook that must
OWN a command pattern MUST run before any earlier hook that would rewrite
it — otherwise it receives the already-rewritten command and silently
no-ops. Fix applied: semble-rewrite reordered before cmd-rewrite
(`hooks/hooks.json` PreToolUse:Bash). Durable rationale in committed
`docs/ARCHITECTURE.md` (this sidecar is gitignored).
```

---

## Task 4 — Verify & commit

### Step 4.1 — Full verification

```bash
jq -e . hooks/hooks.json >/dev/null && echo "hooks.json valid"
jq -r '.hooks.PreToolUse[]|select(.matcher=="Bash")|[.hooks[].command]|@tsv' hooks/hooks.json
for h in hooks/semble-rewrite.sh hooks/cmd-rewrite.sh hooks/auto-review.sh; do bash -n "$h" && echo "syntax OK: $h"; done
# Run each suite WITHOUT a pipe so $? is the test's status, not tail's.
for t in test-semble-rewrite test-semble-context test-semble-session test-codex-lsp-posttool; do
  bash "tests/hooks/$t.sh" >/tmp/p_$t.out 2>&1; rc=$?
  echo "$t rc=$rc :: $(tail -1 /tmp/p_$t.out)"
done
```

Expected: `hooks.json valid`; order tsv = semble-rewrite→cmd-rewrite→auto-review;
all `syntax OK`; every suite line `rc=0 :: PASS: …`. Any `rc!=0` = failure
(no longer masked by `tail`).

### Step 4.2 — Live smoke (manual, in-session — records the real engine)

In a Claude Code session on this branch, run `ls -R hooks/__pycache__`.
Expected: an **ask-prompt** for `semble_rs tree hooks/__pycache__` (NOT
rtk-compressed auto-run output). This is the only check that exercises
the real multi-hook engine; record the observed result in the PR/commit.

### Step 4.3 — Commit (standalone chokepoint)

**Do NOT `git add .claude/wiki/gotchas.md`** — `.gitignore` line 3 is
`.claude/`; `git add` of an ignored path ERRORS and aborts the whole add
(it does not silently skip). The gotcha's durable copy lives in
`docs/ARCHITECTURE.md` (Task 3.1); the sidecar stays local-only by design.

Stage only tracked files:
```bash
git add hooks/hooks.json tests/hooks/test-semble-rewrite.sh docs/ARCHITECTURE.md
```
Then, as its own Bash invocation:
```bash
git commit -F /tmp/sr-commit-msg.txt
```
(Write the message to `/tmp/sr-commit-msg.txt` first — Conventional
Commit, no `&&`/`|` literals in the body to avoid the chained-shell scan.)

## Self-review

- Spec coverage: reorder (T1) ✓, chain-invariant tests (T2) ✓, ARCHITECTURE
  DP-3 correction + chaining fact (T3.1) ✓, gotcha (T3.2) ✓, verification
  incl. live smoke (T4) ✓. All spec §Changes + §Verification rows mapped.
- Placeholder scan: none — every step has exact code/command/expected.
- Consistency: hook filenames, `semble_rs tree/search`, decision `ask`
  consistent with shipped semble-rewrite.sh + spec.

## Risks

- **R1** chaining is CLI-behavior; verified live `[High]`. Live smoke
  (4.2) re-confirms post-change. Fallback documented in spec (Approach A).
- **R2** `.claude/wiki/gotchas.md` is gitignored — `git add` of it would
  ERROR/abort the stage (not silent-skip). Mitigated: Task 4.3 excludes
  it from `git add`; durable rationale is the committed ARCHITECTURE
  paragraph (T3.1).
- **R3** `skip()` injection uses the Edit tool (exact-match), not
  `sed -i` — eliminates the macOS/Linux `sed -i ''` portability trap
  entirely (Step 2.1).
- **R4** test status was masked by `| tail -1`; Step 4.1 now runs each
  suite unpiped and reports `rc=` explicitly.

## Execution Handoff

Plan complete. Three execution options:
1. **Subagent-Driven** → `sspower:subagent-driven-development` (4 small
   sequential tasks — limited parallelism; inline is fine here)
2. **Inline Execution (recommended)** → `sspower:executing-plans` — tiny
   surgical change, one branch, fastest
3. **Codex execute** → `codex-bridge.mjs implement --write`

Which approach?
