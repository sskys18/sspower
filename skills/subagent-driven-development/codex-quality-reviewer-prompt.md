# Codex Code Quality Reviewer Prompt Template

Use this template when dispatching Codex as the quality reviewer via `codex-bridge.mjs review`.

The structured output schema (`quality-review-output.json`) is enforced by `--output-schema`.

**Only dispatch after spec compliance review passes.**

```
codex-bridge.mjs review --cd {WORKING_DIR} --prompt @/tmp/sdd-quality-review-N.md
```

Write this to the prompt file:

````markdown
<task>
You are performing a code quality review of Task {N}: {TASK_NAME}.
The implementation has already passed spec compliance — your job is to verify
it is well-built: clean, tested, maintainable, and secure.
</task>

<change_context>
What was implemented: {WHAT_WAS_IMPLEMENTED}
Plan/requirements: {PLAN_OR_REQUIREMENTS}

Review the git diff between commits:
  Base: {BASE_SHA}
  Head: {HEAD_SHA}

Run: git diff {BASE_SHA}..{HEAD_SHA}
</change_context>

<review_criteria>
Architecture and design:
- SOLID principles and established patterns
- Proper separation of concerns and loose coupling
- Integration with existing systems
- Each file has one clear responsibility with well-defined interface

Code quality:
- Proper error handling and type safety
- Code organization, naming conventions, maintainability
- No security vulnerabilities (injection, XSS, OWASP top 10)
- No performance issues

Testing:
- Test coverage and quality
- Tests use real code — flag any mock that isn't an external network boundary
- Tests verify real behavior, not mock behavior
- Edge cases covered

This change specifically:
- Are units decomposed for independent understanding and testing?
- Does implementation follow the file structure from the plan?
- Did this change create or significantly grow files? (Don't flag pre-existing sizes)
</review_criteria>

<grounding_rules>
Every issue must reference a specific file and line range.
Do not flag hypothetical problems — only real issues visible in the diff.
Severity guide:
- blocking: correctness, security, data-loss — must fix before merge
- advisory: style, naming, doc-only nits, minor refactors — ship and follow up

Verdict guide:
- approve: no issues, ship as-is
- approve-with-followups: only advisory issues, ship and queue followups
- needs-attention: at least one blocking issue

For mechanical fixes (typos, missing imports, simple refactors), include
'suggested_patch' as a unified diff against current HEAD. For
design/architecture issues that need human judgment, set
'suggested_patch' to null. The schema requires the field on every issue.
</grounding_rules>
````

## Interpreting the Response

| Codex verdict | SDD action |
|---|---|
| `approve` | Mark task complete, proceed to next task |
| `approve-with-followups` | Mark complete, append advisory issues to `.sspower/followups.md`, proceed |
| `needs-attention` | At least one blocking issue — must fix before proceeding |

Issue handling:
- **blocking**: Must fix before proceeding. Resume Codex implementer with fix instructions. Auto-review hook applies `suggested_patch` automatically when present.
- **advisory**: Note for later, can proceed. Written to `.sspower/followups.md` automatically by the auto-review hook on `approve-with-followups`.

After fixes, re-run quality review to confirm resolution. Auto-review hook caps at 3 rounds per branch (`SSPOWER_REVIEW_MAX_ROUNDS`); if hit, the hook denies and surfaces the unresolved findings.
