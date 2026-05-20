# P5 — semble_rs context + command rewrite (Claude-side context layer)

> Spec: `docs/specs/2026-05-17-codex-worker-lsp-gate-design.md` Phase B7, §9 P5, D-B6, R1.
> Roadmap source: `docs/plans/2026-05-18-codex-worker-lsp-trackB-P2-P6.md` §P5.
> Re-validation gate (handoff Resume #1): MET — `docs/plans/notes/P5-semble-revalidation-findings.md`.
> Branch base: `main` @ `9bc8121` (P2–P4 shipped). Plan authored 2026-05-19 (KST).

## Goal

Ship Phase B7: four **advisory, fail-open** Claude-side hooks that put `semble_rs` /
codex-lsp signal in front of the supervisor. None of them block, deny, or gate.
This is the context layer, not a control layer (D-B6 promotion is OUT OF SCOPE — §Risks).

## Pre-plan facts (measured this session, this repo, 307 files)

| Tool (warm) | latency | bytes | Source |
|---|---|---|---|
| `semble_rs plan "<task>"` | ~0.35 s | 2.4–3.0 KB | `time` x2, this repo |
| `semble_rs search --compact <q>` | ~0.39 s | 0.44 KB | `time`, this repo |
| `semble_rs tree` | ~0.29 s | 3.7 KB vs `ls -R` 18.6 KB | findings note |
| `codex-lsp hook post-tool-use` (1 file) | ~2 s | — | spec §2 |

Warm latency is a non-issue. Cold first-run = one-time ~60 MB model download
(findings note §latency) → SessionStart detached warm + every hook hard-timeouts
and fails OPEN. semble_rs is pre-1.0 (R1): `command -v … || exit 0` everywhere.

## Design decisions (locked for this plan)

- **DP-1 `tree` rewrite justified on gitignore-correctness, NOT tokens.** Findings
  note: the spec §2 3000× figure is a kimp-pathological artifact (collapsed to ~5×
  on a clean repo). The real, repo-independent argument: `ls -R` is gitignore-blind
  (walks `node_modules`/`target`/`dist`), `semble_rs tree` is gitignore-aware →
  *more correct output*, token win incidental. Do NOT cite 3000× anywhere.
  **Recursion flag is UPPERCASE `-R` ONLY for `ls`** — `ls -r` is reverse-sort,
  not recursive; matching lowercase `r` would mis-rewrite a non-recursive
  listing. (grep differs: both `-R` and `-r` are recursive there — DP-2.)
- **DP-2 `grep -R` → `semble_rs search` is semantically lossy → STRICT gate + ASK only.**
  grep is literal/regex line match; `semble_rs search` is keyword/symbol semantic
  ranking — NOT equivalent. Rewrite ONLY when: every flag token is **exactly `-R`
  or `-r`** (ANY other flag — `-n -i -E -P -F -w -x -e`, combined like `-Rn`, or
  long `--recursive` — disqualifies, pass-through); AND the pattern is a bare
  identifier (`^[A-Za-z_][A-Za-z0-9_]*$`); AND at most one path arg. Tokenized
  match (not a flag-bundle regex) so separated flags (`grep -R -r x .`) are
  classified correctly, not silently mis-rewritten. Even then emit an
  **explicit `permissionDecision:"ask"`** (NOT merely an unset field — an
  unset decision falls through to the normal Bash permission flow, which can
  auto-run if `semble_rs` is allowlisted; explicit `ask` guarantees the
  substitution is shown and confirmed). **BOTH `ls -R`→`tree` and
  `grep -R`→`search` use explicit `ask`** — neither auto-allows. Earlier drafts
  auto-allowed `ls` on the DP-1 gitignore argument, but the rewrite also drops
  `ls` modifier flags (`-l/-a/-d/-s`/sort/classify) — a semantic change, so it
  too must be confirmed. Spec line 236 says "allow/ask, never deny"; we choose
  **ask for both**, deny for neither. Single emit path, no auto-allow surface.
- **DP-3 PreToolUse chain order: cmd-rewrite.sh → semble-rewrite.sh → auto-review.sh.**
  New hook slots BETWEEN the existing two. If a prior hook already changed the
  command (cmd-rewrite emitted `updatedInput`), Claude re-invokes PreToolUse with
  the rewritten command; semble-rewrite re-reads `.tool_input.command` from stdin
  each call and no-ops when its patterns don't match — no coordination state needed.
  > **SUPERSEDED 2026-05-19** — see `docs/specs/2026-05-19-semble-rewrite-ownership-spec.md`
  > and `docs/plans/2026-05-19-semble-rewrite-ownership-plan.md`. Final order is
  > **semble-rewrite.sh → cmd-rewrite.sh → auto-review.sh** (semble-rewrite owns
  > `ls -R` / `grep -R <IDENT>` so rtk does not auto-run them). Live-confirmed
  > by fresh-process smoke 2026-05-20.
- **DP-4 PostToolUse codex-lsp is DE-FANGED to advisory.** codex-lsp
  `hook post-tool-use` natively emits `{"decision":"block",...}` (verified in
  `tools/codex-lsp/dist/codex-hook.js`). P5 is advisory-first (D-B6). The wrapper
  strips `decision`/`reason` and re-emits ONLY
  `hookSpecificOutput.additionalContext` → Claude sees diagnostics, is never
  blocked. Scope = the just-edited file (codex-lsp extracts it from
  `tool_input.file_path` itself). Hard 4 s timeout, fail-OPEN.
- **DP-5 Four separate hook scripts, not edits to existing hooks.** `prompt-submit`
  / `session-start` are `set -euo pipefail` single-emit scripts; the
  UserPromptSubmit & SessionStart arrays already chain multiple independent hooks
  (diet-track, codex-track-prompt, diet-activate). Adding peers is the established
  pattern and keeps each script single-responsibility + independently testable.
- **DP-6 Resolver reuse.** codex-lsp path via the shipped
  `scripts/lib/codex-lsp-path.mjs` `resolveCodexLspCli()` (override env → vendored
  → null). No new path logic.

## Files

| Action | Path | Responsibility |
|---|---|---|
| CREATE | `hooks/semble-context.sh` | UserPromptSubmit: coding-intent-gated `semble_rs plan` inject (advisory, capped) |
| CREATE | `hooks/semble-rewrite.sh` | PreToolUse:Bash: `ls -R`→`tree` & `grep -R IDENT`→`search --compact`, both explicit ASK |
| CREATE | `hooks/semble-session.sh` | SessionStart: availability line + detached warm |
| CREATE | `hooks/codex-lsp-posttool.sh` | PostToolUse:Write\|Edit\|MultiEdit: codex-lsp on edited file, de-fanged advisory |
| MODIFY | `hooks/hooks.json` | register the 4 hooks in their event arrays |
| CREATE | `tests/hooks/test-semble-context.sh` | gate + fail-open + cap assertions |
| CREATE | `tests/hooks/test-semble-rewrite.sh` | rewrite/no-op/ask-vs-allow matrix |
| CREATE | `tests/hooks/test-semble-session.sh` | availability output + non-blocking |
| CREATE | `tests/hooks/test-codex-lsp-posttool.sh` | de-fang (no `decision:block`) + fail-open |
| CREATE | `tests/hooks/fixtures/codex-lsp-stub-block.cjs` | committed stub: emits codex-lsp `decision:block` (de-fang test) |
| CREATE | `tests/hooks/fixtures/codex-lsp-stub-empty.cjs` | committed stub: consumes stdin, emits nothing (clean path) |
| CREATE | `tests/hooks/fixtures/codex-lsp-stub-fail.cjs` | committed stub: consumes stdin, exits 1 (fail-open path) |
| MODIFY | `docs/ARCHITECTURE.md` | add P5 section (durable decisions DP-1..DP-6; `.claude/` is gitignored) |

`docs/handoff.md` is intentionally NOT a plan task — it is updated during the
`finishing-a-development-branch` step (post-merge), not by any task here.

All hook scripts: `chmod +x`, `#!/usr/bin/env bash`, bash 3.2-safe (no `${V,,}`,
no `mapfile`; [[memory: bash_portability]]). Plugin root via
`${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}`.

---

## Task 1 — `hooks/semble-context.sh` (UserPromptSubmit semble inject)

### Step 1.1 — Write the hook

Create `hooks/semble-context.sh`:

```bash
#!/usr/bin/env bash
# UserPromptSubmit hook — inject token-cheap repo orientation via `semble_rs plan`
# on coding-intent prompts. Advisory only (additionalContext). Fail-OPEN: any
# error / missing semble_rs / timeout → emit nothing, exit 0.
#
# Disable: export SSPOWER_SEMBLE=0
# Opt-out per-prompt: prompt starts with raw: RAW: nosemble: NOSEMBLE: noenrich:
# Tune: SSPOWER_SEMBLE_TIMEOUT (s, default 6), SSPOWER_SEMBLE_MAX_CHARS (default 3000)
#
# CLI signature (verified `semble_rs plan --help` + run): `semble_rs plan
# <TASK> [PATH]` — PATH is a real second positional (default `.`). The
# two-arg form `semble_rs plan "$USER_PROMPT" "$CWD"` below is correct and
# empirically confirmed (output prints `Path: <CWD>`).

set -uo pipefail   # NOT -e: we must fail open, not abort

DIAG_LOG="${HOME}/.claude/sspower/codex.log"

log_hook() {
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$(dirname "$DIAG_LOG")" 2>/dev/null
  printf '%s [%s] hook.semble-context %s\n' "$ts" "$1" "$2" >> "$DIAG_LOG" 2>/dev/null || true
}

INPUT="$(cat)"

emit_nothing() { exit 0; }   # UserPromptSubmit: no JSON == no added context

# jq is a hard dep for safe JSON in/out (it backs cmd-rewrite, codex-lsp-posttool
# already). Missing jq → fail-OPEN silent, never hand-roll fragile escaping.
command -v jq >/dev/null 2>&1 || emit_nothing

extract_field() { printf '%s' "$INPUT" | jq -r ".${1} // empty" 2>/dev/null; }
USER_PROMPT="$(extract_field prompt)"
CWD="$(extract_field cwd)"; [[ -z "$CWD" ]] && CWD="$(pwd)"

emit_context() {
  # jq builds + escapes the JSON (handles all control chars, not just \n\t\r).
  jq -n --arg c "$1" \
    '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$c}}'
  exit 0
}

# ── Gate ──────────────────────────────────────────────────────────────
[[ "${SSPOWER_SEMBLE:-1}" == "0" ]] && emit_nothing
command -v semble_rs >/dev/null 2>&1 || { log_hook info "kind=skip reason=no-semble"; emit_nothing; }
[[ -z "$USER_PROMPT" ]] && emit_nothing
(( ${#USER_PROMPT} < 20 )) && emit_nothing

MAX_CHARS="${SSPOWER_SEMBLE_MAX_CHARS:-3000}"
[[ "$MAX_CHARS" =~ ^[0-9]+$ ]] || MAX_CHARS=3000
MAX_CHARS=$((10#$MAX_CHARS))
(( ${#USER_PROMPT} > 8000 )) && emit_nothing   # already context-rich

[[ "$USER_PROMPT" =~ ^/ ]] && emit_nothing
[[ "$USER_PROMPT" =~ ^(raw:|RAW:|nosemble:|NOSEMBLE:|noenrich:) ]] && emit_nothing

LC="$(printf '%s' "$USER_PROMPT" | tr '[:upper:]' '[:lower:]')"
case "$LC" in
  "what is"*|"what's"*|"show"*|"list"*|"explain"*|"describe"*|"tell me"*) emit_nothing ;;
  "hi"|"hello"|"hey"|"thanks"|"thank you"|"ok"|"yes"|"no"|"done"|"go"|"push") emit_nothing ;;
  "help"|"status"|"why"*) emit_nothing ;;
esac
echo "$LC" | grep -qE '\b(add|fix|build|refactor|implement|change|write|create|debug|update|modify|remove|delete|rename|move|migrate|port|wire|ship|integrate|setup|install|configure|test|bug|error|broken|failing|crash)\b' \
  || { log_hook info "kind=skip reason=no-coding-intent"; emit_nothing; }

# Only inject inside a git repo (semble is gitignore-aware; non-repo = noise)
git -C "$CWD" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { log_hook info "kind=skip reason=not-git"; emit_nothing; }

# ── Run semble_rs plan with portable hard timeout, fail-open ───────────
SEM_TIMEOUT="${SSPOWER_SEMBLE_TIMEOUT:-6}"
[[ "$SEM_TIMEOUT" =~ ^[0-9]+$ ]] || SEM_TIMEOUT=6
SEM_TIMEOUT=$((10#$SEM_TIMEOUT))

if command -v gtimeout >/dev/null 2>&1; then TO=(gtimeout "$SEM_TIMEOUT")
elif command -v timeout >/dev/null 2>&1; then TO=(timeout "$SEM_TIMEOUT")
elif command -v perl >/dev/null 2>&1; then TO=(perl -e 'alarm shift; exec @ARGV' "$SEM_TIMEOUT")
else TO=(); fi   # no timeout binary AND no perl (extreme): run unbounded, never hard-fail

START="$(date +%s)"
OUT=""
# bash-3.2-safe empty-array expansion (${arr[@]+…}) — no set -u unbound error.
if OUT="$(${TO[@]+"${TO[@]}"} semble_rs plan "$USER_PROMPT" "$CWD" 2>/dev/null)"; then
  DUR=$(( $(date +%s) - START ))
  if [[ -n "$OUT" ]]; then
    # HARD char cap: final string (slice + marker) is ≤ MAX_CHARS, not
    # MAX_CHARS + marker. Marker reserved at 28 chars; floor MAX_CHARS at 64.
    if (( ${#OUT} > MAX_CHARS )); then
      (( MAX_CHARS < 64 )) && MAX_CHARS=64
      MARK="
[...truncated]"
      OUT="${OUT:0:$(( MAX_CHARS - ${#MARK} ))}${MARK}"
    fi
    log_hook info "kind=inject dur=${DUR}s bytes=${#OUT} cwd=$CWD"
    emit_context "[semble_rs repo orientation — advisory, token-cheap; verify before acting]:
${OUT}"
  fi
  log_hook warn "kind=empty dur=${DUR}s cwd=$CWD"; emit_nothing
else
  RC=$?; DUR=$(( $(date +%s) - START ))
  case "$RC" in
    124|142) log_hook warn "kind=timeout dur=${DUR}s cwd=$CWD" ;;
    *)       log_hook error "kind=semble_failed rc=$RC dur=${DUR}s cwd=$CWD" ;;
  esac
  emit_nothing
fi
```

### Step 1.2 — Make executable

```bash
chmod +x hooks/semble-context.sh
```

Expected: no output, exit 0.

### Step 1.3 — Smoke

```bash
printf '{"prompt":"add a retry to the codex bridge resume loop","cwd":"%s"}' "$(pwd)" \
  | hooks/semble-context.sh | head -c 200; echo
```

Expected: a single JSON line beginning
`{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"[semble_rs repo orientation`.

```bash
printf '{"prompt":"what is this repo?","cwd":"%s"}' "$(pwd)" | hooks/semble-context.sh; echo "rc=$?"
```

Expected: empty output, `rc=0` (read-intent gate skip).

---

## Task 2 — `hooks/semble-rewrite.sh` (PreToolUse:Bash rewrite)

### Step 2.1 — Write the hook

Create `hooks/semble-rewrite.sh`:

```bash
#!/usr/bin/env bash
# PreToolUse:Bash hook — opportunistic, NEVER-DENY command rewrites:
#   ls -R [path]                 → semble_rs tree [path]              (explicit ASK; DP-1)
#   grep -R/-r <BARE_IDENT> [p]  → semble_rs search --compact <q> [p] (explicit ASK; DP-2 lossy)
# Verified CLI signatures (semble_rs --help + live run, 2026-05-19):
#   `semble_rs tree [PATH]`                    — PATH optional 2nd positional
#   `semble_rs search --compact <QUERY> [PATH]`— QUERY then optional PATH
# Fail-OPEN: no semble_rs / no jq / parse fail / non-match → exit 0 (pass through).
# Disable: export SSPOWER_SEMBLE_REWRITE=0

set -uo pipefail

[[ "${SSPOWER_SEMBLE_REWRITE:-1}" == "0" ]] && exit 0
command -v jq        >/dev/null 2>&1 || exit 0
command -v semble_rs >/dev/null 2>&1 || exit 0

INPUT="$(cat)"
CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')"
[[ -z "$CMD" ]] && exit 0

# Bail ONLY on command-structure metacharacters (compound/redirect/subshell).
# Glob/brace/bracket/tilde in a single path token are valid filenames — they
# are made literal-safe by `set -f` (no expansion during tokenize) + `shq`
# (quoted on emit), so they are NOT pre-rejected (that contradicted shq and
# dropped legit paths like `src/[id]`).
case "$CMD" in
  *'|'*|*'&'*|*';'*|*'>'*|*'<'*|*'$('*|*'`'*|*$'\n'*) exit 0 ;;
esac

# Shell-quote every value interpolated into the emitted command so the rewrite
# is literal-safe regardless of path characters.
shq() { printf '%q' "$1"; }

# SINGLE emit path: EXPLICIT permissionDecision:"ask" for BOTH ls and grep.
# Rationale (DP-1/DP-2): the rewrite changes semantics (gitignore-aware tree ≠
# `ls -R`; semantic search ≠ literal grep) and may drop modifier flags — so it
# must always be shown/confirmed, never auto-allowed. $1=command $2=reason.
emit_ask() {
  jq -n --arg cmd "$1" --arg why "$2" \
        --argjson ti "$(printf '%s' "$INPUT" | jq -c '.tool_input')" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",
      permissionDecisionReason:$why,
      updatedInput:($ti + {command:$cmd})}}'
  exit 0
}

# Tokenize on whitespace. `set -f` disables glob expansion so a literal `*`
# in the command is NOT expanded against cwd. bash-3.2-safe (no mapfile).
set -f
# shellcheck disable=SC2206
TOK=( $CMD )
set +f
(( ${#TOK[@]} == 0 )) && exit 0

# ── ls … -R … [path] → semble_rs tree [path]  (explicit ASK, DP-1) ─────
# Separated flags OK (`ls -l -R src`). Recursion flag is UPPERCASE -R ONLY:
# `ls -r` is reverse-sort, NOT recursive. Each flag token must be a clean
# short-flag bundle (^-[a-zA-Z]+$); at most one non-flag path. Else skip.
# ASK (not allow): tree is gitignore-aware (DP-1) AND drops ls modifier flags
# (-l/-a/-d/-s/sort/classify) — a semantic change the user must confirm.
if [[ "${TOK[0]}" == "ls" ]]; then
  has_R=0; patharg=""; bad=0
  for (( i=1; i<${#TOK[@]}; i++ )); do
    t="${TOK[$i]}"
    if [[ "$t" == -* ]]; then
      [[ "$t" =~ ^-[a-zA-Z]+$ ]] || { bad=1; break; }     # reject --long, -1=, etc.
      [[ "$t" == *R* ]] && has_R=1                          # UPPERCASE R only
    elif [[ -z "$patharg" ]]; then
      patharg="$t"
    else
      bad=1; break                                          # >1 path arg
    fi
  done
  if (( bad == 0 && has_R == 1 )); then
    emit_ask "semble_rs tree $(shq "${patharg:-.}")" \
      "semble-rewrite: ls -R → semble_rs tree (gitignore-aware; drops ls modifier flags — confirm)"
  fi
fi

# ── grep -R|-r <BARE_IDENT> [path] → semble_rs search --compact (ASK) ──
# DP-2 STRICT: every flag token must be EXACTLY -R or -r (no -Rn, -i, -E,
# --recursive …). Exactly one pattern (bare identifier) + ≤1 path. Else skip.
if [[ "${TOK[0]}" == "grep" ]]; then
  has_R=0; bad=0; i=1
  while (( i < ${#TOK[@]} )) && [[ "${TOK[$i]}" == -* ]]; do
    case "${TOK[$i]}" in
      -R|-r) has_R=1 ;;
      *)     bad=1; break ;;
    esac
    (( i++ ))
  done
  if (( bad == 0 && has_R == 1 && i < ${#TOK[@]} )); then
    pat="${TOK[$i]}"; (( i++ ))
    patharg="."
    if (( i < ${#TOK[@]} )); then patharg="${TOK[$i]}"; (( i++ )); fi
    # DP-2: a flag-looking token AFTER the pattern (e.g. `grep -R ident -n`)
    # means a non-R/r flag slipped past the leading-flag loop → disqualify.
    # Also no trailing tokens beyond a single path arg.
    if (( i == ${#TOK[@]} )) && [[ "$patharg" != -* ]]; then
      pat="${pat%\"}"; pat="${pat#\"}"; pat="${pat%\'}"; pat="${pat#\'}"
      if [[ "$pat" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        emit_ask "semble_rs search --compact $(shq "$pat") $(shq "$patharg")" \
          "semble-rewrite: grep -R → semble_rs search (semantic≠literal — confirm the substitution)"
      fi
    fi
  fi
fi

exit 0
```

### Step 2.2 — Make executable

```bash
chmod +x hooks/semble-rewrite.sh
```

### Step 2.3 — Smoke matrix

```bash
# Build JSON with jq so embedded quotes/regex metachars are valid (NOT printf).
j() { jq -nc --arg c "$1" '{tool_input:{command:$c}}'; }
j 'ls -R src'              | hooks/semble-rewrite.sh   # → ASK, semble_rs tree src
j 'ls -l -R src'           | hooks/semble-rewrite.sh   # → ASK (separated flags)
j 'ls -laR'                | hooks/semble-rewrite.sh   # → ASK, semble_rs tree .
j 'grep -R runLspGate src' | hooks/semble-rewrite.sh   # → ASK, semble_rs search --compact runLspGate src
j 'ls -r src'              | hooks/semble-rewrite.sh; echo "rc=$?"  # → empty (lowercase r = reverse, DP-1)
j 'grep -Rn ident .'       | hooks/semble-rewrite.sh; echo "rc=$?"  # → empty (-Rn not exactly -R)
j 'grep -R -i Foo src'     | hooks/semble-rewrite.sh; echo "rc=$?"  # → empty (-i disqualifies)
j 'grep -RE "foo|bar" .'   | hooks/semble-rewrite.sh; echo "rc=$?"  # → empty (-RE / regex)
j 'grep -R "a.*b" .'       | hooks/semble-rewrite.sh; echo "rc=$?"  # → empty (non-ident pattern)
j 'ls -la'                 | hooks/semble-rewrite.sh; echo "rc=$?"  # → empty (no -R)
j 'ls -R | head'           | hooks/semble-rewrite.sh; echo "rc=$?"  # → empty (pipe bail)
```

All four rewrite cases emit `"permissionDecision":"ask"` (single emit path —
no auto-allow). Everything else: empty + `rc=0` (pass-through).

Expected: the first FOUR commands emit JSON with `"permissionDecision":"ask"`
and the rewritten `semble_rs …` in `updatedInput.command`; every remaining
command emits nothing + `rc=0` (pass-through).

---

## Task 3 — `hooks/semble-session.sh` (SessionStart availability + warm)

### Step 3.1 — Write the hook

Create `hooks/semble-session.sh`:

```bash
#!/usr/bin/env bash
# SessionStart hook — one-line availability status + DETACHED model warm.
# Never blocks: warm runs backgrounded & disowned (cold = one-time ~60 MB dl).
# Fail-OPEN: missing tools → status line says so, exit 0.

set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

have() { command -v "$1" >/dev/null 2>&1 && echo "ok" || echo "MISSING"; }

S_SEMBLE="$(have semble_rs)"
S_NODE="$(have node)"
S_JQ="$(have jq)"

# codex-lsp path via the canonical resolver (DP-6: SSPOWER_CODEX_LSP_CLI
# override → vendored → null). Never hardcode the vendored path.
S_LSP="MISSING"
if [[ "$S_NODE" == "ok" ]]; then
  _cli="$(node -e 'import("'"${PLUGIN_ROOT}"'/scripts/lib/codex-lsp-path.mjs").then(m=>{const p=m.resolveCodexLspCli();process.stdout.write(p||"")}).catch(()=>{})' 2>/dev/null)"
  [[ -n "$_cli" && -f "$_cli" ]] && S_LSP="ok"
fi

# Detached + time-bounded warm. `( cmd & )` runs in a subshell that exits
# immediately; the child is reparented to init (effective disown, portable —
# bash `disown` is unavailable in a one-shot subshell). A timeout caps the
# one-time ~60 MB cold model pull so a stuck download cannot leak forever.
if [[ "$S_SEMBLE" == "ok" && "${SSPOWER_SEMBLE_WARM:-1}" != "0" ]]; then
  WARM_T="${SSPOWER_SEMBLE_WARM_TIMEOUT:-90}"
  [[ "$WARM_T" =~ ^[0-9]+$ ]] || WARM_T=90; WARM_T=$((10#$WARM_T))
  # Array form (no string word-splitting), consistent with the other hooks.
  # perl-alarm fallback guarantees a hard bound even when neither gtimeout nor
  # timeout exists (stock macOS ships neither; perl is present) — the warm is
  # ALWAYS time-bounded, never an unbounded detached download.
  if command -v gtimeout >/dev/null 2>&1; then WTO=(gtimeout "$WARM_T")
  elif command -v timeout >/dev/null 2>&1; then WTO=(timeout "$WARM_T")
  elif command -v perl >/dev/null 2>&1; then WTO=(perl -e 'alarm shift; exec @ARGV' "$WARM_T")
  else WTO=(); fi   # only if even perl is absent — extreme; warm simply unbounded then
  # bash-3.2-safe: `${arr[@]+"${arr[@]}"}` avoids set -u unbound error on empty array.
  ( ${WTO[@]+"${WTO[@]}"} semble_rs search --compact __sspower_warm__ . >/dev/null 2>&1 & ) >/dev/null 2>&1
fi

STATUS="sspower P5 context layer — semble_rs:${S_SEMBLE} codex-lsp:${S_LSP} node:${S_NODE} jq:${S_JQ}"
[[ "$S_SEMBLE" != "ok" ]] && STATUS="${STATUS} (semble inject + rewrite inert; install: cargo install semble_rs)"

# jq builds the JSON when available; bash fallback only if jq absent (status
# text is ASCII-only and control-char-free by construction, so the fallback
# is safe here — unlike the user-content hooks which hard-require jq).
if command -v jq >/dev/null 2>&1; then
  jq -n --arg c "$STATUS" \
    '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
else
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$STATUS"
fi
exit 0
```

### Step 3.2 — Make executable + smoke

```bash
chmod +x hooks/semble-session.sh
echo '{}' | hooks/semble-session.sh; echo "rc=$?"
```

Expected: one JSON line with `semble_rs:ok codex-lsp:ok node:ok jq:ok`, `rc=0`,
returns immediately (no multi-second stall — warm is detached).

---

## Task 4 — `hooks/codex-lsp-posttool.sh` (advisory LSP on Claude's edits)

### Step 4.1 — Write the hook

codex-lsp `hook post-tool-use` natively emits `{"decision":"block",...}`
(verified `tools/codex-lsp/dist/codex-hook.js`). P5 = advisory (D-B6, DP-4):
strip `decision`/`reason`, re-emit ONLY `additionalContext`.

Create `hooks/codex-lsp-posttool.sh`:

```bash
#!/usr/bin/env bash
# PostToolUse:Write|Edit|MultiEdit — run vendored codex-lsp on the file Claude
# just edited. DE-FANGED to ADVISORY (D-B6): strip codex-lsp's decision:block,
# surface only additionalContext. Fail-OPEN: resolver null / timeout / non-zero
# / no jq → exit 0 silent. Disable: export SSPOWER_CODEX_LSP_POSTTOOL=0

set -uo pipefail

[[ "${SSPOWER_CODEX_LSP_POSTTOOL:-1}" == "0" ]] && exit 0

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
DIAG_LOG="${HOME}/.claude/sspower/codex.log"
log_hook() { local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)";
  mkdir -p "$(dirname "$DIAG_LOG")" 2>/dev/null
  printf '%s [%s] hook.codex-lsp-posttool %s\n' "$ts" "$1" "$2" >> "$DIAG_LOG" 2>/dev/null || true; }

command -v node >/dev/null 2>&1 || exit 0
command -v jq   >/dev/null 2>&1 || exit 0

CLI="$(node -e 'import("'"${PLUGIN_ROOT}"'/scripts/lib/codex-lsp-path.mjs").then(m=>{const p=m.resolveCodexLspCli();process.stdout.write(p||"")}).catch(()=>process.exit(0))' 2>/dev/null)"
[[ -z "$CLI" || ! -f "$CLI" ]] && { log_hook info "kind=skip reason=no-codex-lsp"; exit 0; }

INPUT="$(cat)"

# Portable hard timeout (codex-lsp ~2 s/file; cap 4 s).
TOUT="${SSPOWER_CODEX_LSP_TIMEOUT:-4}"
[[ "$TOUT" =~ ^[0-9]+$ ]] || TOUT=4; TOUT=$((10#$TOUT))
if command -v gtimeout >/dev/null 2>&1; then TO=(gtimeout "$TOUT")
elif command -v timeout >/dev/null 2>&1; then TO=(timeout "$TOUT")
elif command -v perl >/dev/null 2>&1; then TO=(perl -e 'alarm shift; exec @ARGV' "$TOUT")
else TO=(); fi   # no timeout binary AND no perl (extreme): run unbounded, never hard-fail

RAW=""
# bash-3.2-safe empty-array expansion — runs node directly if no wrapper.
if ! RAW="$(printf '%s' "$INPUT" | ${TO[@]+"${TO[@]}"} node "$CLI" hook post-tool-use 2>/dev/null)"; then
  log_hook warn "kind=lsp_nonzero_or_timeout"; exit 0
fi
[[ -z "$RAW" ]] && exit 0   # codex-lsp emits nothing when diagnostics clean

# De-fang (DP-4): keep ONLY hookSpecificOutput.additionalContext. Do NOT fall
# back to top-level .reason — that would re-broaden the block contract. If
# codex-lsp ever emits a verdict without additionalContext, we stay silent
# (fail-open) rather than surface a raw block reason.
CTX="$(printf '%s' "$RAW" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
[[ -z "$CTX" ]] && { log_hook info "kind=skip reason=no-additionalContext"; exit 0; }

log_hook info "kind=advisory_diag bytes=${#CTX}"
jq -n --arg c "ADVISORY (P5, non-blocking) — codex-lsp diagnostics on your last edit; fix before proceeding:
$CTX" \
  '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}'
exit 0
```

### Step 4.2 — Make executable + smoke

```bash
chmod +x hooks/codex-lsp-posttool.sh
# Liveness only — NOT an assertion. Output depends on repo LSP config; the
# only invariant here is rc=0 (advisory hook must never hard-fail).
printf '{"tool_name":"Edit","tool_input":{"file_path":"%s/README.md"},"tool_response":{}}' "$(pwd)" \
  | hooks/codex-lsp-posttool.sh; echo "rc=$?"
```

Expected: `rc=0`. Output may be empty (no LSP server for `.md`) or an advisory
block — both acceptable; this step only proves the hook runs without erroring.
The deterministic de-fang / fail-open assertions live in Task 6.4 (stubbed
codex-lsp), which is the real acceptance gate for this hook.

---

## Task 5 — Register hooks in `hooks/hooks.json`

### Step 5.1 — Read current file

`cat hooks/hooks.json` — confirm structure matches the diff base below.

### Step 5.2 — Edit: add semble-context to UserPromptSubmit

In the `UserPromptSubmit[0].hooks` array, append AFTER the
`codex-track-prompt.sh` entry:

```json
          ,{
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/semble-context.sh\"",
            "timeout": 8,
            "async": false
          }
```

(Exact edit: locate the `codex-track-prompt.sh` block's closing `}` inside
`UserPromptSubmit`, add the comma + new object before the array's `]`.)

### Step 5.3 — Edit: add semble-rewrite to PreToolUse:Bash

In the `PreToolUse` array's `"matcher": "Bash"` group, insert BETWEEN
`cmd-rewrite.sh` and `auto-review.sh` (DP-3 order):

```json
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/semble-rewrite.sh\"",
            "timeout": 3
          },
```

### Step 5.4 — Edit: add codex-lsp-posttool as new PostToolUse group

Add a new top-level `"PostToolUse"` key (none exists today) to the `hooks`
object, after `PreToolUse`:

```json
    "PostToolUse": [
      {
        "matcher": "Write|Edit|MultiEdit",
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/codex-lsp-posttool.sh\"",
            "timeout": 6,
            "async": false
          }
        ]
      }
    ],
```

### Step 5.5 — Edit: add semble-session to SessionStart

In `SessionStart[0].hooks`, append AFTER the `diet-activate.js` entry:

```json
          ,{
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/semble-session.sh\"",
            "timeout": 5,
            "async": false
          }
```

### Step 5.6 — Validate JSON

```bash
jq -e . hooks/hooks.json >/dev/null && echo "JSON OK"
jq -r '.hooks | keys[]' hooks/hooks.json
```

Expected: `JSON OK`; keys include `PostToolUse` plus the pre-existing
SessionStart/UserPromptSubmit/PreToolUse/PreCompact/SessionEnd.

```bash
# Select by MATCHER, not array index — index 0 is not guaranteed to be Bash.
jq -r '
  ([.hooks.UserPromptSubmit[]?.hooks[]?.command]                       | map(select(test("semble-context"))) | length) as $ctx |
  ([.hooks.PreToolUse[]? | select(.matcher=="Bash") | .hooks[].command] ) as $bash |
  ([.hooks.PostToolUse[]? | select(.matcher|test("Write")) | .hooks[].command]) as $post |
  ([.hooks.SessionStart[]?.hooks[]?.command]                            | map(select(test("semble-session"))) | length) as $ses |
  "semble-context registered: \($ctx)\nPreToolUse Bash cmds: \($bash|length) (cmd-rewrite→semble-rewrite→auto-review order)\nsemble-rewrite present: \([$bash[]|select(test("semble-rewrite"))]|length)\nPostToolUse codex-lsp: \([$post[]|select(test("codex-lsp-posttool"))]|length)\nsemble-session registered: \($ses)"
' hooks/hooks.json
# Also assert chain ORDER (DP-3): cmd-rewrite before semble-rewrite before auto-review.
jq -r '.hooks.PreToolUse[] | select(.matcher=="Bash") | [.hooks[].command] | @tsv' hooks/hooks.json
```

Expected: `semble-context registered: 1`; `semble-rewrite present: 1`;
`PostToolUse codex-lsp: 1`; `semble-session registered: 1`. The order line
shows `cmd-rewrite.sh` then `semble-rewrite.sh` then `auto-review.sh`
left-to-right (DP-3). If `semble-rewrite` is not strictly between the other
two, fix the array position before proceeding.

---

## Task 6 — Tests

### Step 6.1 — `tests/hooks/test-semble-context.sh`

```bash
#!/usr/bin/env bash
set -uo pipefail
H="$(cd "$(dirname "$0")/../.." && pwd)/hooks/semble-context.sh"
# jq is a test-harness dependency (assertions parse JSON). Absent → SKIP, not
# FAIL: the hooks themselves fail-open without jq; that path is asserted via
# the deterministic no-tool shim, not here.
command -v jq >/dev/null 2>&1 || { echo "SKIP: test-semble-context (no jq — harness dep)"; exit 0; }
FAIL=0; ok(){ echo "PASS: $1"; }; bad(){ echo "FAIL: $1"; FAIL=1; }
skip(){ echo "SKIP: $1"; }

# R1 / determinism: positive-inject assertions run ONLY if a real semble_rs
# PROBE succeeds within a short timeout (covers absent / cold-uninstallable /
# broken binary). HAVE_SEMBLE=1 means the exact command shape the hook uses
# actually produced output here & now. Otherwise the same prompt must
# fail-open empty — asserted instead — so the suite is green either way.
HAVE_SEMBLE=0
if command -v semble_rs >/dev/null 2>&1; then
  if command -v gtimeout >/dev/null 2>&1; then _PT=(gtimeout 20)
  elif command -v timeout >/dev/null 2>&1; then _PT=(timeout 20)
  elif command -v perl >/dev/null 2>&1; then _PT=(perl -e 'alarm shift; exec @ARGV' 20)
  else _PT=(); fi
  if ${_PT[@]+"${_PT[@]}"} semble_rs plan "probe codex bridge resume" "$(pwd)" >/dev/null 2>&1; then
    HAVE_SEMBLE=1
  else
    skip "semble_rs present but probe failed/timed out → treating as absent (fail-open path)"
  fi
fi

# All gate-test prompts are ≥20 chars so the `<20` length gate does NOT pre-empt
# the gate under test (length gate runs before slash/opt-out/read-intent).

# 1. read-intent ("what is" …, ≥20) → no output
OUT="$(printf '{"prompt":"what is the codex bridge resume repair mechanism?","cwd":"%s"}' "$(pwd)" | "$H")"
[[ -z "$OUT" ]] && ok "read-intent skip" || bad "read-intent skip ($OUT)"

# 2. slash command (≥20, leading /) → no output
OUT="$(printf '{"prompt":"/handoff please summarize the whole working session","cwd":"%s"}' "$(pwd)" | "$H")"
[[ -z "$OUT" ]] && ok "slash skip" || bad "slash skip"

# 3. opt-out prefix (≥20) → no output
OUT="$(printf '{"prompt":"nosemble: fix the resume loop bug right now","cwd":"%s"}' "$(pwd)" | "$H")"
[[ -z "$OUT" ]] && ok "nosemble: opt-out" || bad "nosemble: opt-out"

# 4. disabled env → no output even on coding intent
OUT="$(SSPOWER_SEMBLE=0 sh -c "printf '{\"prompt\":\"fix the codex resume bug\",\"cwd\":\"$(pwd)\"}' | '$H'")"
[[ -z "$OUT" ]] && ok "SSPOWER_SEMBLE=0" || bad "SSPOWER_SEMBLE=0"

# 5. coding intent in git repo → inject IF semble present, else fail-open empty
OUT="$(printf '{"prompt":"fix the codex bridge resume repair loop","cwd":"%s"}' "$(pwd)" | "$H")"
if (( HAVE_SEMBLE )); then
  echo "$OUT" | jq -e '.hookSpecificOutput.additionalContext | startswith("[semble_rs repo orientation")' >/dev/null 2>&1 \
    && ok "coding-intent inject" || bad "coding-intent inject ($OUT)"
else
  [[ -z "$OUT" ]] && ok "coding-intent fail-open (no semble)" || bad "coding-intent (no semble, expected empty) ($OUT)"
fi

# 5b. HARD cap: with a tiny MAX, the semble payload after the fixed prefix line
# must not exceed MAX (+ the short truncation marker). semble-only.
if (( HAVE_SEMBLE )); then
  # printf|hook (NOT heredoc) — no dependence on writable temp storage for stdin.
  OUT="$(printf '{"prompt":"fix the codex bridge resume repair loop and lsp gate","cwd":"%s"}' "$(pwd)" | SSPOWER_SEMBLE_MAX_CHARS=64 "$H")"
  CTX="$(echo "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""')"
  # strip the fixed prefix line; remaining payload must be <= 64 + marker(16)
  PAY="${CTX#*$'\n'}"
  if [[ -n "$CTX" ]] && (( ${#PAY} <= 80 )); then ok "hard cap (payload ${#PAY} <= 80)"; else bad "hard cap (payload ${#PAY})"; fi
else
  skip "hard cap (no semble)"
fi

# 6. fail-open when semble_rs binary is genuinely absent — deterministic:
#    build a flat PATH shim with every needed tool symlinked EXCEPT semble_rs.
# SAFETY: install the cleanup trap ONLY after a successful mktemp -d, and guard
# cleanup with [[ -n && -d ]] — an empty $SHIM must NEVER let `rm -f "$SHIM"/*`
# expand to `/*` (root data-loss). If no writable temp dir → skip, not crash.
SHIM="$(mktemp -d 2>/dev/null || true)"
if [[ -z "${SHIM:-}" || ! -d "$SHIM" ]]; then
  skip "fail-open no-semble (no writable temp dir for shim)"
else
  cleanup_shim() {
    [[ -n "${SHIM:-}" && -d "$SHIM" ]] || return 0
    rm -f "$SHIM"/* 2>/dev/null || true
    rmdir "$SHIM" 2>/dev/null || true
  }
  trap cleanup_shim EXIT
  for b in bash sh jq git date dirname cat tr grep sed mkdir printf perl python3 node env timeout gtimeout; do
    p="$(command -v "$b" 2>/dev/null)" && ln -s "$p" "$SHIM/$b" 2>/dev/null
  done
  OUT="$(printf '{"prompt":"fix the resume bug now","cwd":"%s"}' "$(pwd)" | PATH="$SHIM" "$H")"
  [[ -z "$OUT" ]] && ok "fail-open no-semble (deterministic shim)" || bad "fail-open no-semble ($OUT)"
fi

[[ $FAIL -eq 0 ]] && echo "PASS: test-semble-context" || { echo "FAIL: test-semble-context"; exit 1; }
```

Test 6 is now deterministic — semble_rs is provably off `PATH` regardless of where
it lives on the runner. Cleanup uses non-recursive `rm -f` + `rmdir` (AGENTS.md
bans recursive `rm`); the shim is a flat dir of symlinks, no subdirs.

### Step 6.2 — `tests/hooks/test-semble-rewrite.sh`

```bash
#!/usr/bin/env bash
set -uo pipefail
H="$(cd "$(dirname "$0")/../.." && pwd)/hooks/semble-rewrite.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: test-semble-rewrite (no jq — harness dep)"; exit 0; }
FAIL=0; ok(){ echo "PASS: $1"; }; bad(){ echo "FAIL: $1 :: $2"; FAIL=1; }
# jq builder — valid JSON even when the command contains quotes / regex chars.
j(){ jq -nc --arg c "$1" '{tool_input:{command:$c}}'; }

# The hook will not rewrite to a binary that is absent (it would emit a broken
# command). So with no semble_rs the ONLY correct behavior is fail-open
# passthrough for EVERY input — assert that deterministically and stop.
if ! command -v semble_rs >/dev/null 2>&1; then
  for c in 'ls -R src' 'grep -R ident .' 'ls -la' 'cat x'; do
    O="$(j "$c" | "$H")"; [[ -z "$O" ]] && ok "no-semble passthrough: $c" || bad "no-semble passthrough: $c" "$O"
  done
  [[ $FAIL -eq 0 ]] && echo "PASS: test-semble-rewrite" || { echo "FAIL: test-semble-rewrite"; exit 1; }
  exit 0
fi

# ls → EXPLICIT permissionDecision:"ask" (single emit path; no auto-allow).
O="$(j 'ls -R src' | "$H")"
echo "$O" | jq -e '(.hookSpecificOutput.permissionDecision=="ask") and (.hookSpecificOutput.updatedInput.command=="semble_rs tree src")' >/dev/null \
  && ok "ls -R → ask" || bad "ls -R ask" "$O"

O="$(j 'ls -l -R src' | "$H")"   # separated flags must still classify
echo "$O" | jq -e '(.hookSpecificOutput.permissionDecision=="ask") and (.hookSpecificOutput.updatedInput.command=="semble_rs tree src")' >/dev/null \
  && ok "ls -l -R src (separated) → ask" || bad "ls separated" "$O"

O="$(j 'ls -laR' | "$H")"
echo "$O" | jq -e '(.hookSpecificOutput.permissionDecision=="ask") and (.hookSpecificOutput.updatedInput.command=="semble_rs tree .")' >/dev/null \
  && ok "ls -laR → ask, tree ." || bad "ls -laR" "$O"

# grep → EXPLICIT permissionDecision:"ask" (DP-2 — not unset fall-through).
O="$(j 'grep -R runLspGate src' | "$H")"
echo "$O" | jq -e '(.hookSpecificOutput.permissionDecision=="ask") and (.hookSpecificOutput.updatedInput.command=="semble_rs search --compact runLspGate src")' >/dev/null \
  && ok "grep ident → explicit ask" || bad "grep ask" "$O"

O="$(j 'grep -r ident' | "$H")"  # -r, default path .
echo "$O" | jq -e '(.hookSpecificOutput.permissionDecision=="ask") and (.hookSpecificOutput.updatedInput.command=="semble_rs search --compact ident .")' >/dev/null \
  && ok "grep -r ident → ask, path defaults ." || bad "grep -r default path" "$O"

# DP-2 locked: separated recursive flags `grep -R -r x .` classify correctly.
O="$(j 'grep -R -r x .' | "$H")"
echo "$O" | jq -e '(.hookSpecificOutput.permissionDecision=="ask") and (.hookSpecificOutput.updatedInput.command=="semble_rs search --compact x .")' >/dev/null \
  && ok "grep -R -r x . (separated recursive flags) → ask" || bad "grep separated -R -r" "$O"

# ls ask assertions covered above.
# DP-1: lowercase `ls -r` is REVERSE-sort, NOT recursive → must NOT rewrite.
# DP-2 STRICT: anything beyond exactly -R/-r (grep) must pass through.
for c in 'ls -r src' 'ls -lr' 'ls -r' \
         'grep -Rn ident .' 'grep -R -i Foo src' 'grep -Rw foo .' 'grep -RF lit .' \
         'grep -RE pat .' 'grep --recursive ident .' 'grep -R "a.*b" .' \
         'grep -R ident -n' 'grep -R Foo -i' 'grep -R x a b' \
         'ls -la' 'cat foo' 'ls -R | head' 'ls -R && pwd' 'ls -R src&' 'ls --color -R .'; do
  O="$(j "$c" | "$H")"; [[ -z "$O" ]] && ok "noop: $c" || bad "noop: $c" "$O"
done

O="$(SSPOWER_SEMBLE_REWRITE=0 sh -c "printf '{\"tool_input\":{\"command\":\"ls -R\"}}' | '$H'")"
[[ -z "$O" ]] && ok "disable env" || bad "disable env" "$O"

[[ $FAIL -eq 0 ]] && echo "PASS: test-semble-rewrite" || { echo "FAIL: test-semble-rewrite"; exit 1; }
```

### Step 6.3 — `tests/hooks/test-semble-session.sh`

```bash
#!/usr/bin/env bash
set -uo pipefail
H="$(cd "$(dirname "$0")/../.." && pwd)/hooks/semble-session.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: test-semble-session (no jq — harness dep)"; exit 0; }
FAIL=0; ok(){ echo "PASS: $1"; }; bad(){ echo "FAIL: $1 :: $2"; FAIL=1; }

O="$(echo '{}' | SSPOWER_SEMBLE_WARM=0 "$H")"
echo "$O" | jq -e '.hookSpecificOutput.hookEventName=="SessionStart" and (.hookSpecificOutput.additionalContext|test("semble_rs:(ok|MISSING)") and test("codex-lsp:(ok|MISSING)"))' >/dev/null \
  && ok "status line shape (incl codex-lsp via resolver)" || bad "status line" "$O"

# Detached-warm proof: warm ENABLED (default). If warm ran inline a cold model
# pull would block many seconds; the `( … & )` disown must return immediately.
START="$(date +%s)"
O="$(echo '{}' | "$H")"
DUR=$(( $(date +%s) - START ))
(( DUR <= 3 )) && ok "detached warm non-blocking (<=3s, warm ON)" || bad "warm blocked" "${DUR}s"
echo "$O" | jq -e '.hookSpecificOutput.hookEventName=="SessionStart"' >/dev/null \
  && ok "still emits status with warm on" || bad "warm-on status" "$O"

[[ $FAIL -eq 0 ]] && echo "PASS: test-semble-session" || { echo "FAIL: test-semble-session"; exit 1; }
```

### Step 6.4a — Create committed stub fixtures (normal file authoring)

Create these three files with the Write tool / apply_patch (NOT shell
redirection — the test must not `cat >`/`echo >` at runtime; D-B4 guard). They
are committed fixtures the test references by path.

`tests/hooks/fixtures/codex-lsp-stub-block.cjs`:

```js
let d = "";
process.stdin.on("data", (c) => (d += c));
process.stdin.on("end", () => {
  process.stdout.write(
    JSON.stringify({
      decision: "block",
      reason: "R",
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: "DIAG: x.ts:1 error TS1005",
      },
    }) + "\n",
  );
});
```

`tests/hooks/fixtures/codex-lsp-stub-empty.cjs`:

```js
process.stdin.resume();
process.stdin.on("end", () => {});
```

`tests/hooks/fixtures/codex-lsp-stub-fail.cjs`:

```js
process.stdin.resume();
process.stdin.on("end", () => process.exit(1));
```

(`node <file>` runs `.cjs` as CommonJS — the `process.*` globals are correct.)

### Step 6.4b — `tests/hooks/test-codex-lsp-posttool.sh`

The de-fang assertion needs codex-lsp to emit `decision:block`. The committed
`codex-lsp-stub-block.cjs` fixture supplies it via the `SSPOWER_CODEX_LSP_CLI`
override (resolver honors it first, DP-6) — no runtime file creation.

```bash
#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
H="$ROOT/hooks/codex-lsp-posttool.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: test-codex-lsp-posttool (no jq — harness dep)"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "SKIP: test-codex-lsp-posttool (no node — harness dep)"; exit 0; }
FAIL=0; ok(){ echo "PASS: $1"; }; bad(){ echo "FAIL: $1 :: $2"; FAIL=1; }

# Stubs are COMMITTED fixtures (created as plan deliverables via normal file
# authoring — Step 6.4a), NOT written here with `cat >`/`echo >`. This avoids
# shell-redirection file creation at test runtime (Codex-worker rule / D-B4
# guard) and needs no temp files or cleanup at all.
FX="$ROOT/tests/hooks/fixtures"
STUB="$FX/codex-lsp-stub-block.cjs"   # emits a codex-lsp-style decision:block
EMPTY="$FX/codex-lsp-stub-empty.cjs"  # consumes stdin, emits nothing (clean)
FAILS="$FX/codex-lsp-stub-fail.cjs"   # consumes stdin, exits non-zero
for f in "$STUB" "$EMPTY" "$FAILS"; do
  [[ -f "$f" ]] || { echo "FAIL: missing fixture $f (Step 6.4a not done)"; exit 1; }
done

IN='{"tool_name":"Edit","tool_input":{"file_path":"x.ts"},"tool_response":{}}'

# 1. De-fang: output must NOT contain decision:block, MUST carry the diag text.
O="$(printf '%s' "$IN" | SSPOWER_CODEX_LSP_CLI="$STUB" "$H")"
echo "$O" | jq -e '(has("decision")|not) and (.hookSpecificOutput.additionalContext|test("DIAG: x.ts"))' >/dev/null \
  && ok "de-fang block→advisory" || bad "de-fang" "$O"
echo "$O" | grep -q '"decision"' && bad "decision leaked" "$O" || ok "no decision key"

# 2. Clean (stub emits nothing) → silent pass
O="$(printf '%s' "$IN" | SSPOWER_CODEX_LSP_CLI="$EMPTY" "$H")"
[[ -z "$O" ]] && ok "clean → silent" || bad "clean silent" "$O"

# 3. Fail-open on non-zero codex-lsp exit (the realistic infra-failure path —
#    proves the hook never blocks even when codex-lsp itself errors).
O="$(printf '%s' "$IN" | SSPOWER_CODEX_LSP_CLI="$FAILS" "$H")"
[[ -z "$O" ]] && ok "fail-open on lsp non-zero exit" || bad "lsp-nonzero fail-open" "$O"

# 4. Fail-open: resolver returns null when override points at a missing file
#    AND no vendored copy is found is structurally guaranteed by
#    resolveCodexLspCli (existsSync gate). We assert the operator disable here;
#    the null path is exercised by unit coverage of codex-lsp-path.mjs.
O="$(printf '%s' "$IN" | SSPOWER_CODEX_LSP_POSTTOOL=0 "$H")"
[[ -z "$O" ]] && ok "disable env" || bad "disable env" "$O"

[[ $FAIL -eq 0 ]] && echo "PASS: test-codex-lsp-posttool" || { echo "FAIL: test-codex-lsp-posttool"; exit 1; }
```

### Step 6.5 — chmod + run all four

```bash
chmod +x tests/hooks/test-semble-context.sh tests/hooks/test-semble-rewrite.sh \
         tests/hooks/test-semble-session.sh tests/hooks/test-codex-lsp-posttool.sh
for t in tests/hooks/test-semble-context.sh tests/hooks/test-semble-rewrite.sh \
         tests/hooks/test-semble-session.sh tests/hooks/test-codex-lsp-posttool.sh; do
  echo "── $t"; bash "$t" || exit 1
done
```

Expected: every script ends `PASS: test-…`, overall exit 0.

### Step 6.6 — Regression: non-destructive (no `rm -rf` execution)

`tests/hooks/test-integration.sh:70` and `tests/hooks/test-diet-off.sh:35`
both `trap 'rm -rf …' EXIT`. The Codex-worker rule (AGENTS.md) and edit-safety
forbid the executor running recursive `rm`. So this plan does NOT shell out to
those scripts. Instead, a non-destructive regression proving P5 left the chain
intact:

```bash
# 1. All hooks (new + pre-existing) parse cleanly.
for h in hooks/semble-context.sh hooks/semble-rewrite.sh hooks/semble-session.sh \
         hooks/codex-lsp-posttool.sh hooks/prompt-submit hooks/session-start \
         hooks/cmd-rewrite.sh; do bash -n "$h" && echo "syntax OK: $h"; done

# 2. hooks.json still valid + every command path exists.
jq -e . hooks/hooks.json >/dev/null && echo "hooks.json JSON OK"
jq -r '.hooks[][]?.hooks[]?.command' hooks/hooks.json \
  | sed 's/^"//; s/ .*//; s#\${CLAUDE_PLUGIN_ROOT}#.#; s/"$//' \
  | while read -r f; do [[ -z "$f" || "$f" == node ]] || { [[ -e "$f" ]] && echo "ok $f" || echo "MISSING $f"; }; done

# 3. Pre-existing UserPromptSubmit / SessionStart hooks still emit valid JSON
#    (they perform no recursive deletes — safe to invoke directly).
echo '{"prompt":"hi","cwd":"'"$(pwd)"'"}' | hooks/prompt-submit | jq -e .hookSpecificOutput >/dev/null && echo "prompt-submit OK"
echo '{}' | hooks/session-start | jq -e .hookSpecificOutput >/dev/null && echo "session-start OK"
```

Expected: every line prints `…OK` / `ok …`, no `MISSING`. Full pre-existing
suites (`test-integration.sh`, `test-diet-off.sh`) are run by a maintainer
outside the worker sandbox — explicitly out of this plan's executor scope
because they use recursive cleanup the worker rule forbids. P5 changes only
add new hook entries; it does not touch existing chain logic.

---

## Task 7 — Docs

### Step 7.1a — Update the existing ARCHITECTURE Hooks table

`docs/ARCHITECTURE.md` has a Hooks inventory table (SessionStart /
UserPromptSubmit / PreToolUse rows). `grep -n "Hooks\||.*SessionStart.*|" docs/ARCHITECTURE.md`
to locate it. Append the four P5 hooks to that table so the operator-facing
inventory is not stale (exact rows; match the table's existing column shape —
read the header first and adapt):

```markdown
| SessionStart | `semble-session.sh` | semble/codex-lsp availability + detached warm |
| UserPromptSubmit | `semble-context.sh` | coding-intent `semble_rs plan` inject (advisory) |
| PreToolUse:Bash | `semble-rewrite.sh` | `ls -R`→tree & `grep -R ident`→search — both explicit ASK |
| PostToolUse:Write\|Edit\|MultiEdit | `codex-lsp-posttool.sh` | de-fanged advisory LSP on Claude's edits |
```

If the table's columns differ, conform to the actual header — do not invent a
new shape. This is a required sub-step, not optional.

### Step 7.1b — Add the P5 narrative section

`grep -n "P4\|OUT-OF-SCOPE\|^## " docs/ARCHITECTURE.md | tail -20` to find the
P4 section end, then add after it:

```markdown
### P5 — semble_rs context layer (Phase B7, advisory)

Four Claude-side hooks, all advisory + fail-open (D-B6; semble_rs/codex-lsp pre-1.0, R1):

- `hooks/semble-context.sh` (UserPromptSubmit) — coding-intent-gated
  `semble_rs plan` repo orientation injected as `additionalContext`, char-capped,
  6 s hard timeout, fail-open. Gate mirrors the dead enrich gate in `prompt-submit`.
- `hooks/semble-rewrite.sh` (PreToolUse:Bash, between cmd-rewrite & auto-review) —
  `ls -R`→`semble_rs tree` (gitignore-correct, DP-1; UPPERCASE-R only) and
  `grep -R <BARE_IDENT>`→`semble_rs search --compact` (semantic≠literal, DP-2),
  BOTH via explicit `permissionDecision:"ask"` (single emit path — no
  auto-allow surface; rewrites change semantics so are always confirmed).
  NEVER deny. Bails on any compound command; emitted paths shell-quoted.
- `hooks/semble-session.sh` (SessionStart) — availability line + DETACHED model
  warm (cold = one-time ~60 MB dl; never blocks session start).
- `hooks/codex-lsp-posttool.sh` (PostToolUse:Write|Edit|MultiEdit) — vendored
  codex-lsp on the just-edited file, **de-fanged**: codex-lsp's native
  `decision:block` is stripped; only `additionalContext` surfaces (advisory, D-B6).

OUT OF SCOPE (P5): advisory→block promotion (D-B6, operator-gated, separate step);
`semble_rs digest`; PreToolUse:Read deny-guard; Claude-side Stop block-gate
(spec §11). The `grep`→semantic-search mismatch is bounded by the bare-identifier
gate + ask-only, accepted as a lossy-but-visible convenience, not a correctness path.
```

### Step 7.2 — `docs/handoff.md`

After merge, update Task/Status/Resume per the handoff skill (P5 SHIPPED, next =
optional D-B6 promotion only on operator go). Done in the finishing step, not now.

---

## Verification matrix (P5 acceptance — spec §9 row P5)

| Criterion | Command | Expected |
|---|---|---|
| semble context on coding prompt | Task 1 Step 1.3 | additionalContext starts `[semble_rs repo orientation` |
| read-intent NOT injected | Task 1 Step 1.3 (2nd) | empty, rc 0 |
| `ls -R`→`tree` explicit ASK | `test-semble-rewrite.sh` | `permissionDecision:"ask"`, cmd `semble_rs tree …` |
| `grep ident`→search explicit ASK | `test-semble-rewrite.sh` | `permissionDecision:"ask"`, cmd `semble_rs search …` |
| `ls -r` (reverse) NOT rewritten | `test-semble-rewrite.sh` | empty (uppercase-R-only, DP-1) |
| regex grep NOT rewritten | `test-semble-rewrite.sh` | empty (pass-through) |
| session non-blocking | `test-semble-session.sh` | ≤3 s, status line emitted |
| LSP de-fanged (advisory) | `test-codex-lsp-posttool.sh` | no `decision` key; diag in additionalContext |
| fail-open everywhere | each test's disable/no-tool case | empty out, rc 0 |
| hooks.json valid | `jq -e . hooks/hooks.json` | JSON OK; `PostToolUse` key present |
| regression (non-destructive) | Step 6.6 (syntax + hooks.json + existing-hook smoke) | all `OK`, no `MISSING` |

## Risks & assumptions

- **R1 (carried)** semble_rs/codex-lsp pre-1.0. Mitigation: every hook
  `command -v … || exit 0`, hard timeouts, advisory-only, no critical-path dep.
- **DP-1 carried caveat** `tree` ROI is repo-shape dependent; this plan justifies
  the rewrite on gitignore-correctness only. No 3000× claim anywhere.
- **DP-2 accepted boundary** `grep`→semantic search is lossy; bounded by
  bare-identifier gate + ask-only (substitution always visible). Not a
  correctness regression because the user/Claude confirms each substitution.
- **OUT OF SCOPE — D-B6 promotion.** P5 ships 4 advisory hooks. Promotion of any
  to block is a separate operator-gated decision (handoff Resume #2), NOT this
  plan, NOT automatic. State explicitly so no executor auto-promotes.
- **Assumption** Codex tier unchanged; P5 touches no bridge tier/profile code.
- **`.claude/` is gitignored** → DP-1..DP-6 rationale lives in committed
  `docs/ARCHITECTURE.md` (Task 7) to travel with the PR, not the wiki sidecar.

## Execution Handoff

Plan complete. Three execution options:
1. **Subagent-Driven (recommended)** → `sspower:subagent-driven-development`
   (Tasks 1–4 are independent file creates → parallelizable; Task 5 depends on
   1–4 existing; Task 6 depends on 5; Task 7 last).
2. **Inline Execution** → `sspower:executing-plans`.
3. **Codex execute** → `codex-bridge.mjs implement --write`.

**Which approach?**
