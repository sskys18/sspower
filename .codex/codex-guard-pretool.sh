#!/usr/bin/env bash
# Codex PreToolUse guard (B6 / D-B4).
#
# Threat model: COOPERATIVE Codex worker. This guard prevents the common
# routine cases (`git commit`, `git -C p push`, `git merge`, `rm -rf`,
# `rm --recursive`), including path-qualified binaries (`/usr/bin/git`)
# and one level of `bash -c '...'` / `sh -c "..."` wrapping. It does NOT
# defend against adversarial evasion — deeper nesting, `xargs`,
# `find -exec`, `eval`, command substitution `$(...)`, two-level shell
# wrapping are out of scope at this PreToolUse layer. The REAL perimeter
# is the Codex sandbox + approval_policy=never + network_access=false
# (B6/D-B5, Task 4). This hook is advisory + defense-in-depth on the
# routine path. Fail-open: unparsable input -> allow (must never wedge
# a cooperative worker).
set -u
STDIN_JSON="$(cat 2>/dev/null || true)"

DECISION="$(printf '%s' "$STDIN_JSON" | node -e '
let s = "";
process.stdin.on("data", d => s += d).on("end", () => {
  let cmd = "";
  try { const j = JSON.parse(s); const t = j.tool_input || {}; cmd = String(t.command || t.cmd || ""); }
  catch { return process.stdout.write("allow\t"); }            // unparsable -> fail-open allow
  if (!cmd.trim()) return process.stdout.write("allow\t");

  // One level of `bash -c <quoted>` / `sh -c` / `zsh -c` unwrapping:
  // replace the wrapper with its payload so the routine
  // `bash -c "git push"` case is classified.
  const unwrap = (str) => {
    const m = str.match(/(?:^|\s)(?:ba|z)?sh\s+-c\s+(["\x27])([\s\S]*)\1\s*$/);
    return m ? m[2] : str;
  };
  cmd = unwrap(cmd);

  // Split into command segments on shell separators; classify each.
  const segs = cmd.split(/(?:&&|\|\||[;&|\n])/);

  // a bare command token, optionally path-qualified, at segment start
  // (leading whitespace allowed). e.g. `git`, `/usr/bin/git`, `./rm`.
  const startCmd = (seg, name) =>
    new RegExp("^\\s*(?:\\S*/)?" + name + "(?:\\s|$)").test(seg);

  const recursiveRm = (seg) => {
    if (!startCmd(seg, "rm")) return false;
    if (/(^|\s)--recursive(\s|=|$)/.test(seg)) return true;
    const flags = seg.match(/(^|\s)-[A-Za-z]+/g) || [];
    return flags.some(f => /[rR]/.test(f.replace(/^\s*-/, "")));
  };

  const gitDestructive = (seg) => {
    if (!startCmd(seg, "git")) return false;
    let rest = seg.replace(/^\s*(?:\S*\/)?git\b/, "").trim();
    const GLOBAL_WITH_ARG = /^(-C|-c|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix)(=\S+|\s+\S+)/;
    const GLOBAL_NOARG = /^(--paginate|--no-pager|--bare|--no-replace-objects|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs|-p)\b/;
    let guard = 0;
    while (rest && guard++ < 20) {
      let m;
      if ((m = rest.match(GLOBAL_WITH_ARG))) { rest = rest.slice(m[0].length).trim(); continue; }
      if ((m = rest.match(GLOBAL_NOARG)))    { rest = rest.slice(m[0].length).trim(); continue; }
      break;
    }
    const sub = (rest.split(/\s+/)[0] || "");
    if (sub === "commit" || sub === "push") return true;
    if (sub === "merge") return true;        // exact "merge" only; NOT merge-base/merge-tree/merge-file
    return false;
  };

  for (const seg of segs) {
    if (gitDestructive(seg)) return process.stdout.write("deny\tsspower owns the git surface (D-B4). Codex must not commit/push/merge; leave changes uncommitted for the supervisor.");
    if (recursiveRm(seg))    return process.stdout.write("deny\trecursive rm is forbidden inside Codex (D-B4).");
  }
  if (/(^|\s)(npm\s+(install|i|ci)|pnpm\s+(install|add)|yarn\s+(install|add))(\s|$)/.test(cmd))
    return process.stdout.write("ask\tPackage install requested -- confirm before Codex mutates dependencies.");

  return process.stdout.write("allow\t");
});
' 2>/dev/null || printf 'allow\t')"

# DECISION is "<verb>\t<reason>". Fail-open: any non-deny/ask -> allow.
VERB="${DECISION%%$'\t'*}"
REASON="${DECISION#*$'\t'}"

case "$VERB" in
  deny|ask)
    REASON_JSON="$(printf '%s' "$REASON" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.stringify(s)))' 2>/dev/null || true)"
    case "$REASON_JSON" in
      '"'*'"') : ;;
      *) REASON_JSON='"Blocked by sspower Codex guard (D-B4)."' ;;   # valid-JSON fallback
    esac
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":%s}}\n' "$VERB" "$REASON_JSON"
    exit 0
    ;;
  *)
    exit 0   # allow (default / fail-open)
    ;;
esac
