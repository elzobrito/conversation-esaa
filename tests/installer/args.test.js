import assert from "node:assert/strict";
import test from "node:test";
import { parseArgs } from "../../src/installer/args.js";

test("parses workspace, agents, and machine modes", () => {
  const value = parseArgs(
    [
      "install",
      "--workspace",
      "./project",
      "--agent",
      "codex",
      "--agents",
      "grok,claude",
      "--json",
      "--dry-run",
      "--non-interactive",
    ],
    "/tmp",
  );
  assert.equal(value.workspace, "/tmp/project");
  assert.deepEqual(value.agents, ["codex", "grok", "claude"]);
  assert.equal(value.json, true);
  assert.equal(value.dryRun, true);
});

test("rejects unsupported agents", () => {
  assert.throws(
    () => parseArgs(["install", "--agents", "codex,unknown"]),
    /unsupported agent/,
  );
});
