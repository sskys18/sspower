#!/usr/bin/env bash
# Shared helper. Source, then call: `cmd=$(git_subcommand "$RAW_CMD")`.
# Returns empty string if the command isn't a git invocation.
#
# Handles:
#   - leading env assignments:        FOO=bar GIT_EDITOR=vi git commit
#   - git-level flags before subcmd:  git --no-pager commit / git -C dir commit
#   - paired flags taking a value:    git -c user.name=x commit
#
# Does NOT try to parse pipelines/subshells — those are intentionally
# treated as caller-side bypass by the auto-review hooks.

git_subcommand() {
  local raw="$1"
  # Strip leading VAR=value... env assignments.
  local stripped
  stripped=$(printf '%s' "$raw" | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)+//')

  # Trim leading whitespace.
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"

  # Must start with bare `git ` (not /usr/bin/git, /path/to/git etc. —
  # those would already bypass via path lookup, treat as caller-side).
  case "$stripped" in
    git\ *|git) ;;
    *) return 0 ;;
  esac

  # shellcheck disable=SC2086
  set -- $stripped
  shift  # drop 'git'

  local skip_next=0
  while [ $# -gt 0 ]; do
    local tok="$1"
    if [ "$skip_next" -eq 1 ]; then
      skip_next=0
      shift
      continue
    fi
    case "$tok" in
      # Git-level flags that take a separate argument.
      -C|-c|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix|--config-env)
        skip_next=1
        shift
        continue
        ;;
      # `--key=value` form: single token, just skip it.
      --git-dir=*|--work-tree=*|--namespace=*|--exec-path=*|--super-prefix=*|--config-env=*)
        shift
        continue
        ;;
      # Other git-level flags (no value): --no-pager, --paginate, --bare, etc.
      -*)
        shift
        continue
        ;;
      # First non-flag token = the subcommand.
      *)
        printf '%s' "$tok"
        return 0
        ;;
    esac
  done
  return 0
}
