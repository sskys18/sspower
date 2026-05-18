#!/usr/bin/env node
// sspower diet — UserPromptSubmit tracker
// Parses user prompt for /diet commands + natural activation, updates flag,
// emits per-turn reinforcement so diet stays in model attention.
//
// Adapted from caveman/hooks/caveman-mode-tracker.js (MIT, Julius Brussee).

const { getDefaultMode } = require('./_diet-config');
const { writeActiveDiet, clearActiveDiet, readActiveDiet } = require('./_config');

let input = '';
process.stdin.on('data', chunk => { input += chunk; });
process.stdin.on('end', () => {
  try {
    const data = JSON.parse(input);
    const prompt = (data.prompt || '').trim().toLowerCase();

    // Natural-language activation: "be terse", "activate diet", "talk terse"
    if (/\b(activate|enable|turn on|start)\b.*\b(diet|terse)\b/i.test(prompt) ||
        /\b(diet|terse)\b.*\b(mode|on|activate|enable)\b/i.test(prompt) ||
        /\bbe terse\b/i.test(prompt)) {
      if (!/\b(stop|disable|turn off|deactivate|off)\b/i.test(prompt)) {
        const mode = getDefaultMode();
        if (mode !== 'off') writeActiveDiet(mode);
      }
    }

    // Slash commands. Only /diet (level switch) mutates the persistent flag.
    // One-shot commands like /diet-commit, /diet-review, /diet-compress are
    // handled by their own skills and must not clobber the user's active
    // intensity level (doing so would silently suppress per-turn diet
    // reinforcement on later prompts).
    if (prompt.startsWith('/diet')) {
      const parts = prompt.split(/\s+/);
      const cmd = parts[0];
      const arg = parts[1] || '';

      if (cmd === '/diet' || cmd === '/diet:diet' || cmd === '/sspower:diet') {
        let mode = null;
        if (arg === 'lite') mode = 'lite';
        else if (arg === 'ultra') mode = 'ultra';
        else if (arg === 'off') mode = 'off';
        else if (arg === 'full') mode = 'full';
        else mode = getDefaultMode();

        if (mode && mode !== 'off') {
          writeActiveDiet(mode);
        } else if (mode === 'off') {
          clearActiveDiet();
        }
      }
    }

    // Deactivation
    if (/\b(stop|disable|deactivate|turn off)\b.*\b(diet|terse|caveman)\b/i.test(prompt) ||
        /\b(diet|terse|caveman)\b.*\b(stop|disable|deactivate|turn off|off)\b/i.test(prompt) ||
        /\bnormal mode\b/i.test(prompt)) {
      clearActiveDiet();
    }

    // Per-turn reinforcement
    const activeMode = readActiveDiet();
    if (activeMode) {
      process.stdout.write(JSON.stringify({
        hookSpecificOutput: {
          hookEventName: "UserPromptSubmit",
          additionalContext: "DIET MODE ACTIVE (" + activeMode + "). " +
            "Drop articles/filler/pleasantries/hedging. Fragments OK. " +
            "Code/commits/security: write normal."
        }
      }));
    }
  } catch (e) { /* silent */ }
});
