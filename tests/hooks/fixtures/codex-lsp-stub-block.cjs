let d = "";
process.stdin.on("data", (c) => (d += c));
process.stdin.on("end", () => {
  process.stdout.write(
    JSON.stringify({
      decision: "block",
      reason: "R",
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: "DIAG: x.ts:1 error TS1005",
      },
    }) + "\n",
  );
});
