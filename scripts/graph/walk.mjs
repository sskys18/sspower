// scripts/graph/walk.mjs
import fs from 'node:fs/promises';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const SOURCE_EXTS = new Set(['.ts', '.tsx', '.mts', '.cts', '.js', '.jsx', '.mjs', '.cjs']);
const IGNORE_DIRS = new Set(['node_modules', '.git', 'dist', 'build', '.next', '__pycache__', '.venv', 'venv']);

function isGitRepo(dir) {
  try {
    const top = execFileSync('git', ['-C', dir, 'rev-parse', '--show-toplevel'], {
      stdio: ['ignore', 'pipe', 'ignore'],
    }).toString().trim();
    return top.length > 0 ? top : null;
  } catch {
    return null;
  }
}

export async function* walkSources(rootDir) {
  const absRoot = path.resolve(rootDir);
  const top = isGitRepo(absRoot);
  if (top) {
    const tracked = execFileSync('git', ['-C', absRoot, 'ls-files', '-z'], { maxBuffer: 100 * 1024 * 1024 });
    const others  = execFileSync('git', ['-C', absRoot, 'ls-files', '--others', '--exclude-standard', '-z'], { maxBuffer: 100 * 1024 * 1024 });
    const buf = Buffer.concat([tracked, others]);
    const rels = buf.toString('utf8').split('\0').filter(Boolean);
    for (const rel of rels) {
      if (!SOURCE_EXTS.has(path.extname(rel))) continue;
      const abs = path.join(absRoot, rel);
      if (!abs.startsWith(absRoot + path.sep) && abs !== absRoot) continue;
      yield abs;
    }
    return;
  }
  yield* walkFs(absRoot);
}

async function* walkFs(dir) {
  let entries;
  try {
    entries = await fs.readdir(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const e of entries) {
    if (e.isDirectory()) {
      if (IGNORE_DIRS.has(e.name)) continue;
      yield* walkFs(path.join(dir, e.name));
    } else if (e.isFile()) {
      if (SOURCE_EXTS.has(path.extname(e.name))) {
        yield path.join(dir, e.name);
      }
    }
  }
}
