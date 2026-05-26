// scripts/graph/astgrep.mjs
import { spawn } from 'node:child_process';

const BIN = process.env.SSPOWER_AST_GREP_BIN ?? 'ast-grep';

export function runRule(rulePath, filePath, { timeoutMs = 10_000 } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(BIN, ['scan', '-r', rulePath, filePath, '--json=compact'], {
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    const timer = setTimeout(() => {
      child.kill('SIGKILL');
      reject(new Error(`ast-grep timeout after ${timeoutMs}ms: ${rulePath} ${filePath}`));
    }, timeoutMs);
    child.stdout.on('data', c => { stdout += c; });
    child.stderr.on('data', c => { stderr += c; });
    child.on('error', e => { clearTimeout(timer); reject(e); });
    child.on('close', code => {
      clearTimeout(timer);
      if (code !== 0 && stdout.trim() === '') {
        return reject(new Error(`ast-grep exit ${code}: ${stderr.trim()}`));
      }
      let parsed;
      try {
        parsed = stdout.trim() === '' ? [] : JSON.parse(stdout);
      } catch (e) {
        return reject(new Error(`ast-grep json parse failed: ${e.message}; stdout=${stdout.slice(0, 200)}`));
      }
      resolve(parsed.map(normalize));
    });
  });
}

function normalize(m) {
  // Verified shape for ast-grep 0.43.0 `scan --json=compact`:
  // { text, range: { start:{line,column}, end:{line,column}, byteOffset:{start,end} }, ... }
  // Fail loud if the shape drifts in a future ast-grep release rather than
  // silently producing nodes with NaN line numbers.
  if (!m.range?.start || !m.range?.end || !m.range?.byteOffset) {
    throw new Error(`ast-grep JSON shape changed: missing range.{start,end,byteOffset} on ${JSON.stringify(m).slice(0, 200)}`);
  }
  return {
    text: m.text,
    startLine: m.range.start.line + 1,
    endLine: m.range.end.line + 1,
    startCol: m.range.start.column + 1,
    endCol: m.range.end.column + 1,
    byteStart: m.range.byteOffset.start,
    byteEnd: m.range.byteOffset.end,
  };
}
