# Agent rules (Codex worker)

sspower drives git. As the Codex worker you MUST NOT run `git commit`,
`git push`, or `git merge` — leave your changes uncommitted; the
supervisor commits. Never run `rm -rf`. Do not install packages
(`npm/pnpm/yarn install|add`) without explicit approval — these are
hook-enforced and will be denied or prompted. Fix LSP error-severity
diagnostics in files you changed before you stop.
