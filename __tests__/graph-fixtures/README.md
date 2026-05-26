# Graph extractor fixtures

Each subdirectory is one language fixture pack with:

- `sample-input.<ext>` - the source file under test
- `expected.json` - ground-truth nodes + edges the extractor must produce

## P0 goldens-only mode

P0 has no extractor. The harness verifies that `expected.json` parses and
that the sample-input file exists. Once P1 wires the TS/JS extractor, the
harness compares extractor output against goldens and gates the P1 ship on
precision >= 0.85 and recall >= 0.70 (spec v5 section 3.3).
