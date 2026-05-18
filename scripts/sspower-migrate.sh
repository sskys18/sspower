#!/usr/bin/env bash
# One-shot, idempotent migration: legacy ~/.claude/sspower-* root files
# -> ~/.claude/sspower/. Run ONCE after upgrading the plugin. Safe to re-run.
#
# Sequencing: the legacy .sspower-diet flag may be live in a running
# session. Running this mid-session moves diet state into config.json;
# until reloaded hooks pick it up, one diet re-init may occur. Prefer
# running at a session boundary.
set -euo pipefail

BASE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
DIR="$BASE/sspower"
mkdir -p "$DIR"

moved=0
ts="$(date -u +%Y%m%dT%H%M%SZ)"
mv_if() {  # $1=src $2=dst
  [ -e "$1" ] || return 0
  if [ ! -e "$2" ]; then
    mv "$1" "$2"; echo "moved: $1 -> $2"; moved=$((moved+1))
  else
    # Conflict: new code already created $2 (post-upgrade, pre-migrate).
    # NEVER leave the legacy root file orphaned (acceptance criterion) and
    # NEVER silently drop its data. Archive the legacy source beside the
    # destination with a timestamp, then remove it from root.
    local bak="$2.pre-migrate-$ts"
    mv "$1" "$bak"
    echo "conflict: $2 existed; legacy archived -> $bak (root cleared)"
    moved=$((moved+1))
  fi
}

mv_if "$BASE/sspower-codex-failures.jsonl" "$DIR/failures.jsonl"
mv_if "$BASE/sspower-codex.log"            "$DIR/codex.log"
mv_if "$BASE/sspower-codex-patches.md"     "$DIR/patches.md"

# Diet flag -> config.json .diet. IDEMPOTENT: only write diet when there is
# a legacy flag to migrate, OR when config.json has no diet yet. A re-run
# after the flag is gone must NOT clobber an already-migrated value.
CONFIG="$DIR/config.json"
NODE_CFG="$(cd "$(dirname "$0")/.." && pwd)/hooks/_config.js"

migrated_diet=""
if [ -f "$BASE/.sspower-diet" ]; then
  raw="$(tr -d '[:space:]' < "$BASE/.sspower-diet" | tr '[:upper:]' '[:lower:]')"
  case "$raw" in lite|full|ultra) migrated_diet="$raw" ;; *) migrated_diet="off" ;; esac
  rm -f "$BASE/.sspower-diet"
  echo "migrated diet flag: $migrated_diet"
fi

if [ -n "$migrated_diet" ]; then
  # Legacy flag existed THIS run -> authoritative. writeConfigKey merges
  # DEFAULTS, so log_rotate_lines is set on a brand-new file in the same call.
  CLAUDE_CONFIG_DIR="$BASE" node -e "require('$NODE_CFG').writeConfigKey('diet','$migrated_diet')"
elif [ ! -f "$CONFIG" ]; then
  # Brand-new config, no legacy flag: one write seeds the file. writeConfigKey
  # read-merges DEFAULTS, so the file lands as {"diet":"off","log_rotate_lines":1000}.
  CLAUDE_CONFIG_DIR="$BASE" node -e "require('$NODE_CFG').writeConfigKey('log_rotate_lines',1000)"
else
  # Config already exists, no legacy flag this run: touch NOTHING.
  # Re-run safety — never overwrite a previously migrated diet value.
  echo "config exists, no legacy flag: diet untouched (idempotent)"
fi

echo "done. moved=$moved config=$CONFIG"
ls -la "$DIR"
