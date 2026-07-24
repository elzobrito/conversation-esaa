import assert from "node:assert/strict";
import path from "node:path";
import test from "node:test";
import { parseArgs } from "../../src/installer/args.js";

test("parses workspace, agents, and machine modes", () => {
  const cwd = path.resolve("/tmp");
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
    cwd,
  );
  assert.equal(value.workspace, path.resolve(cwd, "project"));
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
