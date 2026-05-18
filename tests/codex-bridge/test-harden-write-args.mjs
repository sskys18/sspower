import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
const BRIDGE = new URL("../../scripts/codex-bridge.mjs", import.meta.url).pathname;

function bridgeArgs(extra) {
  const out = execFileSync("node", [BRIDGE, ...extra, "--print-args", "--prompt", "noop"], { encoding: "utf8" });
  return JSON.parse(out.trim().split("\n").pop());
}

test("implement --write carries hardened -c overrides", () => {
  const { args: a } = bridgeArgs(["implement", "--write", "--cd", "."]);
  const j = a.join(" ");
  assert.match(j, /approval_policy="never"/);
  assert.match(j, /sandbox_workspace_write\.network_access=false/);
  assert.match(j, /--sandbox workspace-write/);
});

test("implement WITHOUT --write does not harden (read-only, no network knob)", () => {
  const { args: a } = bridgeArgs(["implement", "--cd", "."]);
  const j = a.join(" ");
  assert.doesNotMatch(j, /approval_policy="never"/);
  assert.doesNotMatch(j, /network_access=false/);
  assert.match(j, /--sandbox read-only/);
});

test("review path stays read-only, unhardened", () => {
  const { args: a } = bridgeArgs(["review", "--cd", "."]);
  const j = a.join(" ");
  assert.doesNotMatch(j, /approval_policy="never"/);
  assert.doesNotMatch(j, /network_access=false/);
  assert.match(j, /--sandbox read-only/);
});

test("D-4a: repair-loop resume is hardened in source", () => {
  const src = readFileSync(new URL("../../scripts/codex-bridge.mjs", import.meta.url), "utf8");

  // Isolate the runCodexResume function body: from its declaration to the
  // start of the NEXT top-level function declaration.
  const startMatch = src.match(/function\s+runCodexResume\s*\(/);
  assert.ok(startMatch, "runCodexResume function not found");
  const start = startMatch.index;
  const after = src.slice(start + startMatch[0].length);
  const nextFn = after.search(/\n(?:async\s+)?function\s+\w+\s*\(/);
  const resumeBody = nextFn === -1 ? src.slice(start) : src.slice(start, start + startMatch[0].length + nextFn);

  // Extract the `if (hardenWrite) { ... }` block within runCodexResume and
  // assert BOTH hardening flags live INSIDE it (not pushed unconditionally).
  const gate = resumeBody.match(/if\s*\(\s*hardenWrite\s*\)\s*\{([\s\S]*?)\}/);
  assert.ok(gate, "runCodexResume must gate hardening behind `if (hardenWrite)`");
  assert.match(gate[1], /approval_policy="never"/, "approval_policy=never must be inside the hardenWrite block");
  assert.match(gate[1], /sandbox_workspace_write\.network_access=false/, "network_access=false must be inside the hardenWrite block");
  assert.match(resumeBody, /hardenWrite\s*=\s*false/, "runCodexResume options must default hardenWrite=false");

  // EVERY runCodexResume(...) call must pass hardenWrite: true (repair loop
  // + resume CLI + steer -- all write-capable). No unhardened resume path
  // may exist (D-4a defense-in-depth).
  const callRe = /runCodexResume\s*\(/g;
  let m, callCount = 0;
  while ((m = callRe.exec(src))) {
    const pre = src.slice(Math.max(0, m.index - 12), m.index);
    if (/function\s+$/.test(pre)) continue;        // skip the declaration
    callCount++;
    const window = src.slice(m.index, m.index + 600);
    assert.match(window, /hardenWrite:\s*true/, `runCodexResume call #${callCount} (idx ${m.index}) must pass hardenWrite: true`);
  }
  assert.ok(callCount >= 3, `expected >=3 runCodexResume call sites, found ${callCount}`);
});
