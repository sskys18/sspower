#!/usr/bin/env bash
# Unit tests for hooks/_config.js — run with: bash tests/config/test_config.sh
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_CONFIG_DIR="$TMP"
C="$PLUGIN_ROOT/hooks/_config.js"
pass=0; fail=0
ok(){ if [ "$1" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $3 (got '$1' want '$2')"; fi; }

# 1. defaults when absent
ok "$(node -e "console.log(require('$C').readActiveDiet())")" "null" "absent->null"
ok "$(node -e "console.log(require('$C').readConfig().log_rotate_lines)")" "1000" "absent->default rotate"

# 2. write + read diet
node -e "require('$C').writeActiveDiet('full')"
ok "$(node -e "console.log(require('$C').readActiveDiet())")" "full" "write full"
ok "$(node -e "const fs=require('fs');console.log(fs.existsSync(require('$C').configPath()))")" "true" "config.json created"

# 3. off -> null, file still present (NOT unlinked), other keys preserved
node -e "require('$C').writeConfigKey('log_rotate_lines',2000)"
node -e "require('$C').clearActiveDiet()"
ok "$(node -e "console.log(require('$C').readActiveDiet())")" "null" "off->null"
ok "$(node -e "const fs=require('fs');console.log(fs.existsSync(require('$C').configPath()))")" "true" "config kept on off"
ok "$(node -e "console.log(require('$C').readConfig().log_rotate_lines)")" "2000" "other key preserved"

# 4. invalid mode -> treated as null
node -e "require('$C').writeConfigKey('diet','bogus')"
ok "$(node -e "console.log(require('$C').readActiveDiet())")" "null" "invalid->null"

# 5. corrupt JSON -> defaults, no throw
printf 'not json{' > "$TMP/sspower/config.json"
ok "$(node -e "console.log(require('$C').readActiveDiet())")" "null" "corrupt->null"
ok "$(node -e "console.log(require('$C').readConfig().log_rotate_lines)")" "1000" "corrupt->default"

# 6. symlink at config path refused (write returns false, no follow)
rm -f "$TMP/sspower/config.json"; ln -s /etc/hosts "$TMP/sspower/config.json"
ok "$(node -e "console.log(require('$C').writeConfigKey('diet','full'))")" "false" "symlink write refused"
ok "$(node -e "console.log(require('$C').readActiveDiet())")" "null" "symlink read refused"

# 7. parent-dir symlink refused on BOTH read and write (security parity)
rm -rf "$TMP/sspower"
mkdir -p "$TMP/real_target"
ln -s "$TMP/real_target" "$TMP/sspower"
ok "$(node -e "console.log(require('$C').readActiveDiet())")" "null" "parent-symlink read refused"
ok "$(node -e "console.log(require('$C').readConfig().log_rotate_lines)")" "1000" "parent-symlink read->defaults"
ok "$(node -e "console.log(require('$C').writeConfigKey('diet','full'))")" "false" "parent-symlink write refused"
ok "$(node -e "const fs=require('fs');console.log(fs.existsSync('$TMP/real_target/config.json'))")" "false" "parent-symlink not followed on write"

echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
