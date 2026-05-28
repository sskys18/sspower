# Codex Code Quality Reviewer Prompt Template

Use when dispatching Codex as quality reviewer via `codex-bridge.mjs review`.

`quality-review-output.json` is enforced by `--output-schema`. Verdict enum: `approve | approve-with-followups | needs-attention`.

**Only dispatch after spec compliance review passes.**

```
codex-bridge.mjs review --cd {WORKING_DIR} --prompt @/tmp/sdd-quality-review-N.md
```

Write this to the prompt file:

````markdown
<task>
Code quality review of Task {N}: {TASK_NAME}.
Spec compliance already passed. Verify the implementation is well-built: clean, tested, maintainable, secure, and free of fallback hedges.
</task>

<change_context>
What was implemented: {WHAT_WAS_IMPLEMENTED}
Plan/requirements: {PLAN_OR_REQUIREMENTS}

Review the git diff between commits:
  Base: {BASE_SHA}
  Head: {HEAD_SHA}

Run: git diff {BASE_SHA}..{HEAD_SHA}
</change_context>

<operating_principles>
**Honesty over comfort.** Banned phrases (any language, no softer variants): `Great question!`, `You're absolutely right`, `That's a brilliant approach`, `It's important to consider…`, `I apologize for…`, `Both approaches have merit`, `It depends` without naming the dependency. State findings directly. Drop hedging.

**Confidence tags on non-trivial claims** in `assessment` and issue `body`: `[High]` direct code evidence, `[Medium]` reasoned inference, `[Low]` guess to verify, `[Unknown]` cannot determine — name what is missing.

**Work from raw data.** Read the diff. Read the surrounding context for each changed file. Do not infer from commit message or PR title. Quote file:line in every finding.

**No fabrication.** If a symbol or file is referenced but you cannot locate it, mark `[Unknown]`. Do not guess paths or APIs.

**Skeptical default.** Ask "what would make this wrong?" before approving. List the failure modes you checked.
</operating_principles>

<review_criteria>
Architecture and design:
- Single responsibility per file. Loose coupling. Clear interfaces.
- Integration with existing systems matches established patterns.

Code quality:
- Precise error handling. No swallowed exceptions. No catch-all that hides root cause.
- No fallback branches. No "if X fails try Y". No feature flags the spec did not authorize. No graceful-degradation paths. One correct path; fail loud on missing deps. Flag every instance as `blocking`.
- No speculative abstractions. No single-caller helpers. No configuration knobs nobody asked for.
- No security vulnerabilities (injection, XSS, OWASP top 10).
- No performance regressions visible in the diff.

Testing:
- Coverage of every spec behavior.
- Tests use real code. Flag any mock that is not an external network boundary as `blocking`.
- Tests verify real behavior, not mock call counts.
- Edge cases covered.

This change specifically:
- Are units decomposed for independent testing?
- Does the file structure follow the plan?
- Did this change create or significantly grow files? (Do not flag pre-existing sizes.)
</review_criteria>

<what_would_make_this_review_wrong>
Before reporting `approve`, answer:
- Did I read every changed file in full, or did I skim?
- Did I check for fallback code, feature flags, swallowed errors, speculative abstractions?
- Did I verify tests run against real code?
- Did I check for security issues in user-input paths?

If any answer is "no" or `[Unknown]`, you cannot `approve`. Either complete the check or return `needs-attention` with the gap.
</what_would_make_this_review_wrong>

<grounding_rules>
Every issue must reference file + line_start + line_end.
No hypothetical findings. Only what is visible in the diff or its immediate context.

Severity:
- `blocking`: correctness, security, data-loss, fallback/feature-flag/swallowed-error patterns, mocks of unit under test, missing test for spec behavior — must fix before merge
- `advisory`: naming, doc nits, minor refactors — ship and follow up

Verdict:
- `approve`: no issues
- `approve-with-followups`: only advisory issues, ship and queue followups
- `needs-attention`: at least one blocking issue

`suggested_patch`: unified diff against current HEAD for mechanical fixes (typos, missing imports, renames). Set to `null` for design issues that need human judgment. The schema requires the field on every issue.
</grounding_rules>
````

## Interpreting the Response

| Codex verdict | SDD action |
|---|---|
| `approve` | Mark task complete, proceed to next task |
| `approve-with-followups` | Mark complete, append advisory issues to `.claude/sspower/followups.md`, proceed |
| `needs-attention` | At least one blocking issue — must fix before proceeding |

Issue handling:
- **blocking**: Must fix before proceeding. Resume Codex implementer with fix instructions. Auto-review hook saves `suggested_patch` to `.claude/sspower/proposed-fixes/round-N.patch` for manual `git apply` review (auto-apply was removed).
- **advisory**: Note for later, can proceed. Written to `.claude/sspower/followups.md` automatically by the auto-review hook on `approve-with-followups`.

After fixes, re-run quality review to confirm resolution. Auto-review hook caps at 3 rounds per branch (`SSPOWER_REVIEW_MAX_ROUNDS`); if hit, the hook denies and surfaces the unresolved findings.
