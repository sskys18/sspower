#!/usr/bin/env node
import { runRule } from '../../scripts/graph/astgrep.mjs';
import assert from 'node:assert/strict';
import path from 'node:path';

const ROOT = path.resolve(import.meta.dirname, '..', '..');
const fixture = path.join(ROOT, '__tests__', 'graph-fixtures', 'ts-js', 'sample-input.ts');

const fns = await runRule(path.join(ROOT, 'scripts/graph/rules/ts-function.yml'), fixture);
assert.equal(fns.length, 3, `expected 3 functions, got ${fns.length}`);

const helper = fns.find(n => n.text.startsWith('function helper'));
assert.equal(helper.startLine, 5, `helper.startLine=${helper.startLine}`);
assert.equal(helper.endLine, 7);
assert.ok(typeof helper.byteStart === 'number');
assert.ok(typeof helper.byteEnd === 'number');

const calls = await runRule(path.join(ROOT, 'scripts/graph/rules/ts-call.yml'), fixture);
assert.equal(calls.length, 3);

console.log('OK astgrep wrapper');
