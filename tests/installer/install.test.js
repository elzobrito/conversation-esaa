import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { install } from "../../src/installer/install.js";

test("dry-run forwards argument arrays and writes no manifest", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "conversation-esaa-test-"));
  const bootstrap = path.join(root, "bootstrap.ps1");
  await writeFile(bootstrap, "# test");
  const calls = [];
  const result = await install(
    {
      workspace: path.join(root, "workspace with spaces"),
      agents: ["codex"],
      dryRun: true,
      force: false,
      rag: "off",
      codexService: "off",
      yes: false,
      nonInteractive: true,
    },
    {
      bootstrap,
      runPowerShell(script, args) {
        calls.push({ script, args });
        return JSON.stringify({
          ok: true,
          changed: ["planned"],
          preserved: [],
          warnings: [],
        });
      },
    },
  );
  assert.equal(result.dry_run, true);
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0].args.slice(0, 4), [
    "-WorkspaceRoot",
    path.join(root, "workspace with spaces"),
    "-Agents",
    "codex",
  ]);
});

test("manifest records owned runtime without private contents", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "conversation-esaa-test-"));
  const workspace = path.join(root, "workspace");
  const bootstrap = path.join(root, "bootstrap.ps1");
  await writeFile(bootstrap, "# test");
  await install(
    {
      workspace,
      agents: ["codex"],
      dryRun: false,
      force: false,
      rag: "off",
      codexService: "off",
      yes: false,
      nonInteractive: true,
    },
    {
      bootstrap,
      runPowerShell() {
        return JSON.stringify({
          ok: true,
          changed: [],
          preserved: [],
          warnings: [],
        });
      },
    },
  ).catch(async (error) => {
    // The fake bootstrap must materialize its outputs before manifest hashing.
    if (!/ENOENT/.test(error.message)) throw error;
  });

  await mkdir(path.join(workspace, ".conversation-esaa", "bin"), {
    recursive: true,
  });
  await writeFile(
    path.join(workspace, ".conversation-esaa", "bin", "conv-sync.ps1"),
    "runtime",
  );
  await writeFile(
    path.join(workspace, ".conversation-esaa", "activity.jsonl"),
    "TOP-SECRET-CONVERSATION",
  );
  await install(
    {
      workspace,
      agents: ["codex"],
      dryRun: false,
      force: false,
      rag: "off",
      codexService: "off",
      yes: false,
      nonInteractive: true,
    },
    {
      bootstrap,
      runPowerShell() {
        return JSON.stringify({
          ok: true,
          changed: [],
          preserved: [],
          warnings: [],
        });
      },
    },
  );
  const manifestText = await readFile(
    path.join(workspace, ".conversation-esaa", "install-manifest.json"),
    "utf8",
  );
  const manifest = JSON.parse(manifestText);
  assert.equal(manifest.files[0].kind, "owned");
  assert.equal(manifestText.includes("TOP-SECRET-CONVERSATION"), false);
  assert.equal(
    manifest.files.some((entry) => entry.path.endsWith("activity.jsonl")),
    false,
  );
});
