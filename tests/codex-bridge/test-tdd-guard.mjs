import { test } from "node:test";
import assert from "node:assert/strict";
import { __test_applyTddGuard as applyTddGuard } from "../../scripts/codex-bridge.mjs";

function makeResult(structured) {
  return { sessionId: "test-sid", structured };
}

test("BLOCKED passthrough — no mutation", () => {
  const r = makeResult({ status: "BLOCKED", blocked_reason: "preexisting", tests: { ran: true, passed: 5, failed: 0, details: "" } });
  applyTddGuard(r, "test");
  assert.equal(r.structured.status, "BLOCKED");
  assert.equal(r.structured.blocked_reason, "preexisting");
});

test("DONE + ran=true + failed=0 — stays DONE", () => {
  const r = makeResult({ status: "DONE", blocked_reason: "", tests: { ran: true, passed: 3, failed: 0, details: "ok" } });
  applyTddGuard(r, "test");
  assert.equal(r.structured.status, "DONE");
  assert.equal(r.structured.blocked_reason, "");
});

test("DONE + ran=false — BLOCKED no_run", () => {
  const r = makeResult({ status: "DONE", blocked_reason: "", tests: { ran: false, passed: 0, failed: 0, details: "" } });
  applyTddGuard(r, "test");
  assert.equal(r.structured.status, "BLOCKED");
  assert.match(r.structured.blocked_reason, /tests\.ran is not boolean true/);
});

test("DONE + ran=\"true\" (string) — BLOCKED no_run (strict boolean)", () => {
  const r = makeResult({ status: "DONE", blocked_reason: "", tests: { ran: "true", passed: 1, failed: 0, details: "" } });
  applyTddGuard(r, "test");
  assert.equal(r.structured.status, "BLOCKED");
  assert.match(r.structured.blocked_reason, /tests\.ran is not boolean true/);
});

test("DONE + ran=true + failed=2 — BLOCKED failures", () => {
  const r = makeResult({ status: "DONE", blocked_reason: "", tests: { ran: true, passed: 3, failed: 2, details: "" } });
  applyTddGuard(r, "test");
  assert.equal(r.structured.status, "BLOCKED");
  assert.match(r.structured.blocked_reason, /2 failing test/);
});

test("DONE + ran=true + failed=-1 — BLOCKED invalid_failed (negative)", () => {
  const r = makeResult({ status: "DONE", blocked_reason: "", tests: { ran: true, passed: 5, failed: -1, details: "" } });
  applyTddGuard(r, "test");
  assert.equal(r.structured.status, "BLOCKED");
  assert.match(r.structured.blocked_reason, /not a non-negative integer/);
});

test("DONE + ran=true + failed=\"0\" (string) — BLOCKED invalid_failed", () => {
  const r = makeResult({ status: "DONE", blocked_reason: "", tests: { ran: true, passed: 1, failed: "0", details: "" } });
  applyTddGuard(r, "test");
  assert.equal(r.structured.status, "BLOCKED");
  assert.match(r.structured.blocked_reason, /not a non-negative integer/);
});

test("DONE + ran=true + failed=NaN — BLOCKED invalid_failed", () => {
  const r = makeResult({ status: "DONE", blocked_reason: "", tests: { ran: true, passed: 1, failed: NaN, details: "" } });
  applyTddGuard(r, "test");
  assert.equal(r.structured.status, "BLOCKED");
  assert.match(r.structured.blocked_reason, /not a non-negative integer/);
});

test("DONE + tests object missing — BLOCKED no_run", () => {
  const r = makeResult({ status: "DONE", blocked_reason: "" });
  applyTddGuard(r, "test");
  assert.equal(r.structured.status, "BLOCKED");
  assert.match(r.structured.blocked_reason, /tests\.ran is not boolean true/);
});

test("no structured output — no throw, no mutation", () => {
  const r = { sessionId: "x", structured: null };
  applyTddGuard(r, "test");
  assert.equal(r.structured, null);
});

test("DONE + ran=true + failed=1.5 (non-integer) — BLOCKED invalid_failed", () => {
  const r = makeResult({ status: "DONE", blocked_reason: "", tests: { ran: true, passed: 1, failed: 1.5, details: "" } });
  applyTddGuard(r, "test");
  assert.equal(r.structured.status, "BLOCKED");
  assert.match(r.structured.blocked_reason, /not a non-negative integer/);
});
