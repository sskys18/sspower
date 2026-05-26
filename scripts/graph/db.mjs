// scripts/graph/db.mjs
import { DatabaseSync } from 'node:sqlite';
import fs from 'node:fs';
import path from 'node:path';

export function openDb(dbPath) {
  fs.mkdirSync(path.dirname(dbPath), { recursive: true, mode: 0o700 });
  const db = new DatabaseSync(dbPath);
  db.exec('PRAGMA journal_mode=WAL');
  db.exec('PRAGMA foreign_keys=ON');
  db.exec('PRAGMA synchronous=NORMAL');
  return db;
}

const SCHEMA = `
CREATE TABLE IF NOT EXISTS files (
  path            TEXT PRIMARY KEY,
  content_hash    TEXT NOT NULL,
  language        TEXT NOT NULL,
  indexed_at      INTEGER NOT NULL,
  node_count      INTEGER DEFAULT 0
);
CREATE TABLE IF NOT EXISTS nodes (
  id              TEXT PRIMARY KEY,
  kind            TEXT NOT NULL,
  name            TEXT NOT NULL,
  qualified_name  TEXT NOT NULL,
  file_path       TEXT NOT NULL REFERENCES files(path) ON DELETE CASCADE,
  language        TEXT NOT NULL,
  start_line      INTEGER NOT NULL,
  end_line        INTEGER NOT NULL,
  signature       TEXT,
  span_sha8       TEXT NOT NULL,
  updated_at      INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS edges (
  source          TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
  target          TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
  kind            TEXT NOT NULL,
  line            INTEGER,
  confidence      INTEGER NOT NULL,
  PRIMARY KEY (source, target, kind, line)
);
CREATE TABLE IF NOT EXISTS imports (
  importer_path   TEXT NOT NULL REFERENCES files(path) ON DELETE CASCADE,
  imported_path   TEXT NOT NULL,
  PRIMARY KEY (importer_path, imported_path)
);
CREATE INDEX IF NOT EXISTS idx_imports_imported ON imports(imported_path);
CREATE INDEX IF NOT EXISTS idx_nodes_name        ON nodes(name);
CREATE INDEX IF NOT EXISTS idx_nodes_qname       ON nodes(qualified_name);
CREATE INDEX IF NOT EXISTS idx_nodes_file        ON nodes(file_path);
CREATE INDEX IF NOT EXISTS idx_edges_target_kind ON edges(target, kind);
`;

const FTS = `
CREATE VIRTUAL TABLE IF NOT EXISTS nodes_fts USING fts5(
  name, qualified_name, signature,
  content='nodes', content_rowid='rowid'
);
`;

const TRIGGERS = `
CREATE TRIGGER IF NOT EXISTS nodes_ai AFTER INSERT ON nodes BEGIN
  INSERT INTO nodes_fts(rowid, name, qualified_name, signature)
  VALUES (new.rowid, new.name, new.qualified_name, new.signature);
END;
CREATE TRIGGER IF NOT EXISTS nodes_ad AFTER DELETE ON nodes BEGIN
  INSERT INTO nodes_fts(nodes_fts, rowid, name, qualified_name, signature)
  VALUES('delete', old.rowid, old.name, old.qualified_name, old.signature);
END;
CREATE TRIGGER IF NOT EXISTS nodes_au AFTER UPDATE ON nodes BEGIN
  INSERT INTO nodes_fts(nodes_fts, rowid, name, qualified_name, signature)
  VALUES('delete', old.rowid, old.name, old.qualified_name, old.signature);
  INSERT INTO nodes_fts(rowid, name, qualified_name, signature)
  VALUES (new.rowid, new.name, new.qualified_name, new.signature);
END;
`;

export function initSchema(db) {
  db.exec(SCHEMA);
  db.exec(FTS);
  db.exec(TRIGGERS);
}

export function nodeId(filePath, qualifiedName, spanSha8) {
  return `${filePath}#${qualifiedName}#${spanSha8}`;
}
