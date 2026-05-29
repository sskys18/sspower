# sspower Workflow template — find → verify → critic

A copy-and-adapt script for the Workflow tool. Demonstrates the two sspower
patterns (codex verifier lens, completeness critic) and the git-in-main-thread
constraint. Author it inline via the Workflow tool — do **not** write it to a
file first.

## Shape

- `pipeline()` over found items: each verifies the moment its find completes —
  no barrier wasting wall-clock.
- Per finding, **two Claude lenses always** (a correctness skeptic + an
  independent reproduce check); a **codex** lens is added only for
  high-severity findings or a sample — codex is ~90s + $, never per-finding at
  scale. Majority-real survives (2 lenses → unanimous; 3 → majority).
- A final `parallel()` barrier feeds every surviving finding to a completeness
  critic that names what the run missed.
- Agents only read/analyze/edit. No git. The script **returns** the work; the
  caller (or flow MERGE) commits.

## Script

> **Runtime shape, not a standalone module.** This block is the native Workflow
> script shape: a module-level `export const meta = {…}` **plus** an
> async-context body that uses top-level `await` and ends with top-level
> `return`. The Workflow tool wraps the body in an async function — so a plain
> `node --check --input-type=module` on this block reports "Illegal return
> statement". That is expected; it is **not** a bug. Verify the body by
> async-wrapping it (strip the `export const meta` literal first), or just run
> it through the Workflow tool.

```js
export const meta = {
  name: 'audit-and-verify',
  description: 'Find issues across a surface, verify each with diverse lenses incl. codex, critic the run',
  phases: [
    { title: 'Find' },
    { title: 'Verify' },
    { title: 'Critic' },
  ],
}

// args = { surface: string[], lens: string }  — passed via Workflow `args`.
// NOTE: the script sandbox has NO Node API — no process.env, no process.cwd().
// The codex lens resolves the bridge with `find` and runs `$(pwd)` as SHELL
// text inside the agent's Bash — not JS interpolation.
const FINDING = {
  type: 'object',
  required: ['findings'],
  properties: {
    findings: { type: 'array', items: {
      type: 'object', required: ['id', 'file', 'desc', 'severity'],
      properties: { id: {type:'string'}, file: {type:'string'}, desc: {type:'string'},
                    severity: {type:'string', enum:['high','medium','low']} },
    }},
  },
}
const VERDICT = {
  type: 'object', required: ['real', 'why'],
  properties: { real: {type:'boolean'}, why: {type:'string'} },
}

const seen = new Set()

const verified = await pipeline(
  args.surface,
  // stage 1: find on one slice of the surface
  (slice, _orig, i) =>
    agent(`Find ${args.lens} issues in: ${slice}. Report each as {id,file,desc,severity} (severity = high|medium|low).`,
      { label: `find:${i}`, phase: 'Find', schema: FINDING }),

  // stage 2: dedup vs seen, then verify each fresh finding.
  // Two Claude lenses ALWAYS; the codex lens is added only for high-severity
  // findings or a deterministic sample — codex is ~90s + $, never per-finding.
  (found) => {
    // Key off concrete fields, NOT the agent-supplied `id` (not guaranteed
    // stable or unique across slices — two slices both emitting id "1" would
    // drop a distinct finding). dedup + sampling must be deterministic.
    const key = f => `${f.file} | ${(f.desc || '').trim().toLowerCase()}`
    const fresh = found.findings.filter(f => !seen.has(key(f)))
    fresh.forEach(f => seen.add(key(f)))
    const SAMPLE_EVERY = 10 // codex-check ~1/N of findings, gated on a STABLE
                            // hash of the derived key — NOT a slice-local index
                            // (which would be 0 for every single-finding slice).
    const sampled = f => ([...key(f)].reduce((h, c) => (h * 31 + c.charCodeAt(0)) >>> 0, 7) % SAMPLE_EVERY) === 0
    return parallel(fresh.map(f => () => {
      const lenses = [
        // lens A — correctness skeptic (default to refuted)
        () => agent(`Try to REFUTE this ${args.lens} finding. Default real=false if unsure: ${f.desc} (${f.file})`,
              { label: `skeptic:${f.id}`, phase: 'Verify', schema: VERDICT }),
        // lens B — independent reproduce / confirm
        () => agent(`Independently check whether this holds in ${f.file}: ${f.desc}. real=true only if you confirm it.`,
              { label: `repro:${f.id}`, phase: 'Verify', schema: VERDICT }),
      ]
      // lens C — codex, only when it earns its cost. The bridge's `review`
      // returns quality-review-output (verdict/issues/…), NOT {real}, so map
      // explicitly. Finder text is passed as MODEL text and reaches the bridge
      // via `--prompt @<tmpfile>` — it never lands on a shell command line, so
      // finder-controlled `$()`/backticks/metachars cannot inject. The bridge
      // path is resolved with `find` (don't assume $CLAUDE_PLUGIN_ROOT is set
      // in a background agent's shell), matching `second-opinion`.
      if (f.severity === 'high' || sampled(f)) {
        lenses.push(() => agent(
          `Get codex's verdict on this ${args.lens} finding, then MAP it to {real, why}.\n` +
          `  file: ${f.file}\n  description: ${f.desc}\n\n` +
          'Steps (Bash):\n' +
          '1. Resolve the bridge (do NOT assume $CLAUDE_PLUGIN_ROOT is set):\n' +
          '   BR=$(find ~/.claude/plugins -name codex-bridge.mjs -path "*/sspower/*" | head -1)\n' +
          '2. Write the question (file + description above, phrased "Is this a real issue?") to a temp file\n' +
          '   OUTSIDE the repo via the Write tool — e.g. $(mktemp /tmp/wf-codex.XXXXXX) — never a shell echo/heredoc.\n' +
          '3. Run: node "$BR" review --cd "$(pwd)" --prompt @<that-temp-file>\n' +
          '4. real=true ONLY if verdict is "needs-attention" with a blocking issue matching this finding; ' +
          'otherwise real=false. Put codex\'s reasoning in why.',
          { label: `codex:${f.id}`, phase: 'Verify', schema: VERDICT }))
      }
      return parallel(lenses).then(vs => {
        const ok = vs.filter(Boolean)
        const need = ok.length === 2 ? 2 : Math.ceil(ok.length / 2) // 2 lenses: unanimous; 3: majority
        const real = ok.filter(v => v.real).length >= need
        return { ...f, real, votes: ok }
      })
    }))
  },
)

const confirmed = verified.flat().filter(Boolean).filter(f => f.real)

// completeness critic — barrier: it reasons over the whole confirmed set
phase('Critic')
const gaps = await agent(
  `These ${args.lens} findings were confirmed: ${JSON.stringify(confirmed.map(f => ({file:f.file, desc:f.desc})))}. ` +
  `What did this audit MISS — a part of the surface not scanned, a class of issue not checked, ` +
  `a claim asserted but unverified? List concrete next-round targets.`,
  { schema: { type:'object', required:['gaps'], properties:{ gaps:{type:'array', items:{type:'string'}} } } },
)

// Return structured data. NO git here — the caller / flow MERGE commits.
return { confirmed, gaps: gaps.gaps }
```

## Adapting

- **Loop-until-dry** instead of one pass: wrap find→verify in
  `while (dry < 2)`, recording fresh findings to `seen` each round, `dry++`
  when a round adds nothing. Catches the tail a fixed count misses.
- **Tune codex cost**: raise the gate (`severity === 'high'` only) or lower it
  (smaller `SAMPLE_EVERY`) to trade $ vs coverage. For low-stakes runs, drop
  lens C entirely and keep the two Claude lenses.
- **Dedup against `seen`, never against `confirmed`** — else a finding the
  verifiers rejected reappears every round and the loop never converges.
- **Budget scaling**: gate loops on `budget.total && budget.remaining() > N`;
  with no `+Nk` directive `remaining()` is `Infinity` and the loop runs to the
  agent cap.

## What this template deliberately does NOT do

- No `commit`/`push`/`merge` inside any agent — see SKILL.md's hard constraint.
- It does not replace `second-opinion`; it *calls* the codex bridge that
  `second-opinion` wraps — **selectively** (high-severity/sampled), and maps the
  bridge's `quality-review-output` verdict to `{real, why}` rather than assuming
  the bridge returns `{real}`.
