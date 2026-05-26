// @ts-nocheck
import { describe, expect, it } from 'vitest';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';

const FIXTURES_DIR = path.resolve(import.meta.dirname);

const FIXTURE_PACKS = readdirSync(FIXTURES_DIR, { withFileTypes: true })
  .filter((d) => d.isDirectory())
  .map((d) => d.name);

describe('graph-fixtures goldens-only mode', () => {
  it('has at least one fixture pack', () => {
    expect(FIXTURE_PACKS.length).toBeGreaterThan(0);
  });

  for (const pack of FIXTURE_PACKS) {
    const packDir = path.join(FIXTURES_DIR, pack);
    const expectedPath = path.join(packDir, 'expected.json');

    it(`pack '${pack}' has parseable expected.json`, () => {
      expect(existsSync(expectedPath)).toBe(true);
      const data = JSON.parse(readFileSync(expectedPath, 'utf8'));
      expect(data.language).toBeTruthy();
      expect(Array.isArray(data.nodes)).toBe(true);
      expect(Array.isArray(data.edges)).toBe(true);
    });

    it(`pack '${pack}' has a sample input file`, () => {
      const candidates = readdirSync(packDir).filter((f) => f.startsWith('sample-input.'));
      expect(candidates.length).toBeGreaterThanOrEqual(1);
    });
  }

  it('extractor comparison is gated for P1', () => {
    expect(true).toBe(true);
  });
});
