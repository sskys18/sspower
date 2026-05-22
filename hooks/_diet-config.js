#!/usr/bin/env node
// sspower diet — shared configuration resolver
//
// Resolution order for default mode:
//   1. SSPOWER_DIET_DEFAULT environment variable
//   2. Config file defaultMode field:
//      - $XDG_CONFIG_HOME/sspower/diet.json (any platform, if set)
//      - ~/.config/sspower/diet.json (macOS / Linux fallback)
//      - %APPDATA%\sspower\diet.json (Windows fallback)
//   3. 'full'
//
// Adapted from caveman plugin (MIT, Julius Brussee).
// Security-hardened flag read/write preserved — flag path is predictable so
// we must refuse symlinks and cap read size to prevent local attacker
// redirection to secrets (e.g. ~/.ssh/id_rsa).

const fs = require('fs');
const path = require('path');
const os = require('os');

// Persistent modes only. One-shot skills (compress-memory) do their work
// via slash commands and must never be written to the persistent flag.
const VALID_MODES = ['off', 'lite', 'full', 'ultra'];

function getConfigDir() {
  if (process.env.XDG_CONFIG_HOME) {
    return path.join(process.env.XDG_CONFIG_HOME, 'sspower');
  }
  if (process.platform === 'win32') {
    return path.join(
      process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming'),
      'sspower'
    );
  }
  return path.join(os.homedir(), '.config', 'sspower');
}

function getConfigPath() {
  return path.join(getConfigDir(), 'diet.json');
}

function getDefaultMode() {
  const envMode = process.env.SSPOWER_DIET_DEFAULT;
  if (envMode && VALID_MODES.includes(envMode.toLowerCase())) {
    return envMode.toLowerCase();
  }

  try {
    const config = JSON.parse(fs.readFileSync(getConfigPath(), 'utf8'));
    if (config.defaultMode && VALID_MODES.includes(config.defaultMode.toLowerCase())) {
      return config.defaultMode.toLowerCase();
    }
  } catch (e) { /* missing or invalid — fall through */ }

  return 'full';
}

// Active-flag I/O now delegates to the single config file (~/.claude/sspower/
// config.json) via _config.js. The legacy dotfile diet flag is
// retired (see scripts/sspower-migrate.sh). flagPath args are accepted but
// ignored for backward call-signature compatibility.
const _cfg = require('./_config');

function safeWriteFlag(_flagPath, content) {
  const m = String(content == null ? '' : content).trim().toLowerCase();
  return _cfg.writeActiveDiet(m);
}

function readFlag(_flagPath) {
  return _cfg.readActiveDiet();
}

module.exports = { getDefaultMode, getConfigDir, getConfigPath, VALID_MODES, safeWriteFlag, readFlag };
