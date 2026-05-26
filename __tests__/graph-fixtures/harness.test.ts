// @ts-nocheck
import { describe, expect, it } from 'vitest';
import { existsSync, readFileSync, readdirSync, mkdtempSync, rmSync, cpSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { build } from '../../scripts/graph/build.mjs';
import { openDb, initSchema } from '../../scripts/graph/db.mjs';

const FIXTURES_DIR = path.resolve(import.meta.dirname);
const FIXTURE_PACKS = readdirSync(FIXTURES_DIR, { withFileTypes: true })
  .filter((d) => d.isDirectory())
  .map((d) => d.name);

const P_THRESHOLD = 0.85;
const R_THRESHOLD = 0.70;

// Edge tokens encode (src, tgt) by default. If the golden specifies a
// confidence for an edge, the token includes it — so P/R drops when the
// extractor classifies a known edge with the wrong confidence.
function edgeTokens(rows, requireConfidence) {
  return new Set(rows.map(r => requireConfidence.has(`${r.src_qname}->${r.tgt_qname}`)
    ? `${r.src_qname}->${r.tgt_qname}@c${r.confidence}`
    : `${r.src_qname}->${r.tgt_qname}`));
}
function expectedEdgeTokens(expected) {
  const requireConfidence = new Set(
    expected.edges
      .filter(e => typeof e.confidence === 'number')
      .map(e => `${e.source}->${e.target}`)
  );
  const tokens = new Set(expected.edges.map(e => typeof e.confidence === 'number'
    ? `${e.source}->${e.target}@c${e.confidence}`
    : `${e.source}->${e.target}`));
  return { tokens, requireConfidence };
}
function nodeSet(rows) {
  return new Set(rows.map(r => r.qualified_name));
}
function expectedNodeSet(expected) {
  return new Set(expected.nodes.map((n) => n.qualifiedName ?? n.name));
}

describe('graph-fixtures extractor accuracy', () => {
  for (const pack of FIXTURE_PACKS) {
    const packDir = path.join(FIXTURES_DIR, pack);
    const expectedPath = path.join(packDir, 'expected.json');
    if (!existsSync(expectedPath)) continue;
    const expected = JSON.parse(readFileSync(expectedPath, 'utf8'));

    it(`pack '${pack}' meets P=${P_THRESHOLD}, R=${R_THRESHOLD}`, async () => {
      const tmp = mkdtempSync(path.join(os.tmpdir(), `fixture-${pack}-`));
      cpSync(packDir, tmp, { recursive: true });
      const graphDir = path.join(tmp, '.claude', 'graph');
      mkdirSync(graphDir, { recursive: true });
      await build({ rootDir: tmp, graphDir, log: () => {} });

      const db = openDb(path.join(graphDir, 'index.sqlite'));
      initSchema(db);
      const nodes = db.prepare('SELECT * FROM nodes').all();
      const edges = db.prepare(
        `SELECT src.qualified_name AS src_qname, tgt.qualified_name AS tgt_qname, e.confidence AS confidence
           FROM edges e
           JOIN nodes src ON e.source = src.id
           JOIN nodes tgt ON e.target = tgt.id`
      ).all();
      db.close();

      const gotNodes = nodeSet(nodes);
      const wantNodes = expectedNodeSet(expected);
      const { tokens: wantEdges, requireConfidence } = expectedEdgeTokens(expected);
      const gotEdges = edgeTokens(edges, requireConfidence);

      const got = new Set([...gotNodes, ...[...gotEdges].map(e => `edge:${e}`)]);
      const want = new Set([...wantNodes, ...[...wantEdges].map(e => `edge:${e}`)]);

      const tp = [...got].filter(x => want.has(x)).length;
      const precision = got.size === 0 ? 0 : tp / got.size;
      const recall    = want.size === 0 ? 1 : tp / want.size;

      const detail = {
        pack, precision, recall,
        missing: [...want].filter(x => !got.has(x)),
        extra: [...got].filter(x => !want.has(x)),
      };
      expect(precision, `P=${precision.toFixed(3)} ${JSON.stringify(detail)}`).toBeGreaterThanOrEqual(P_THRESHOLD);
      expect(recall, `R=${recall.toFixed(3)} ${JSON.stringify(detail)}`).toBeGreaterThanOrEqual(R_THRESHOLD);

      rmSync(tmp, { recursive: true });
    }, 30_000);
  }

  it('at least one fixture pack present', () => {
    expect(FIXTURE_PACKS.length).toBeGreaterThan(0);
  });
});
