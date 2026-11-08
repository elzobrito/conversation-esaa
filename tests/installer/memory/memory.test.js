import assert from "node:assert/strict";
import {
  access,
  lstat,
  mkdtemp,
  mkdir,
  readFile,
  rm,
  symlink,
  unlink,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { install } from "../../../src/installer/install.js";
import {
  doctor,
  status,
  uninstall,
  updateOrRepair,
} from "../../../src/installer/lifecycle/index.js";
import { findExecutable } from "../../../src/installer/adapters/index.js";

async function fileExists(target) {
  try {
    await access(target);
    return true;
  } catch {
    return false;
  }
}

function runPwsh(pwsh, script, args, options = {}) {
  return spawnSync(
    pwsh,
    ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script, ...args],
    {
      encoding: "utf8",
      shell: false,
      windowsHide: true,
      ...options,
    },
  );
}

test("installer manages conv-memory.ps1 and preserves private .conversation-esaa/memory across repair, update, and uninstall", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "conv-installer-mem-"));
  const workspace = path.join(root, "workspace");
  try {
    const installRes = await install({
      workspace,
      agents: ["codex"],
      dryRun: false,
      force: false,
      rag: "off",
      codexService: "off",
      yes: false,
      nonInteractive: true,
    });
    assert.equal(installRes.ok, true);

    const gitignore = await readFile(path.join(workspace, ".gitignore"), "utf8");
    assert.match(gitignore, /\.conversation-esaa\/memory\//);

    const manifestPath = path.join(
      workspace,
      ".conversation-esaa",
      "install-manifest.json",
    );
    const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
    assert.equal(
      manifest.files.some(
        (f) =>
          f.path === ".conversation-esaa/bin/conv-memory.ps1" &&
          f.kind === "owned",
      ),
      true,
    );

    const pwsh = findExecutable("pwsh");
    const convCli = path.join(
      workspace,
      ".conversation-esaa",
      "bin",
      "conversation-esaa.ps1",
    );

    const decRes = runPwsh(pwsh, convCli, [
      "decide",
      "Adopt PostgreSQL 16 with strict WAL archiving",
      "--rationale",
      "Durability and PITR",
      "--agent",
      "codex",
      "--workspace",
      workspace,
    ]);
    assert.equal(decRes.status, 0, decRes.stderr || decRes.stdout);

    const sleepRes = runPwsh(pwsh, convCli, [
      "memory",
      "sleep",
      "--mode",
      "shadow",
      "--seed",
      "42",
      "--workspace",
      workspace,
      "--json",
    ]);
    assert.equal(sleepRes.status, 0, sleepRes.stderr || sleepRes.stdout);
    const sleepPayload = JSON.parse(sleepRes.stdout);
    assert.equal(sleepPayload.status, "OK");

    if (process.platform !== "win32") {
      const memDirStat = await lstat(
        path.join(workspace, ".conversation-esaa", "memory"),
      );
      assert.equal(memDirStat.mode & 0o777, 0o700);
      const propStat = await lstat(sleepPayload.proposal_path);
      assert.equal(propStat.mode & 0o777, 0o600);
    }

    const acceptRes = runPwsh(pwsh, convCli, [
      "memory",
      "accept",
      "--proposal-id",
      sleepPayload.proposal_id,
      "--workspace",
      workspace,
      "--json",
    ]);
    assert.equal(acceptRes.status, 0, acceptRes.stderr || acceptRes.stdout);
    const acceptPayload = JSON.parse(acceptRes.stdout);
    assert.equal(acceptPayload.status, "OK");

    const activeFile = path.join(
      workspace,
      ".conversation-esaa",
      "memory",
      "active.json",
    );
    assert.equal(await fileExists(activeFile), true);
    const activeBefore = await readFile(activeFile, "utf8");

    // Simulate runtime drift on conv-memory.ps1 and run repair + update
    const memScript = path.join(
      workspace,
      ".conversation-esaa",
      "bin",
      "conv-memory.ps1",
    );
    await unlink(memScript);
    const stUnhealthy = await status({ workspace });
    assert.equal(stUnhealthy.healthy, false);

    const repaired = await updateOrRepair(
      { workspace, force: false, dryRun: false },
      "repair",
    );
    assert.equal(repaired.ok, true);
    assert.equal(await fileExists(memScript), true);
    assert.equal(await readFile(activeFile, "utf8"), activeBefore);

    const updated = await updateOrRepair(
      { workspace, force: false, dryRun: false },
      "update",
    );
    assert.equal(updated.ok, true);
    assert.equal(await readFile(activeFile, "utf8"), activeBefore);

    // Ensure install-manifest.json never embeds private memory contents
    const updatedManifestRaw = await readFile(manifestPath, "utf8");
    assert.equal(updatedManifestRaw.includes("PostgreSQL 16"), false);

    const docReport = await doctor({ workspace });
    assert.equal(docReport.ok, true);

    // Uninstall removes owned runtime scripts while preserving .conversation-esaa/memory
    const uninstalled = await uninstall({ workspace, dryRun: false });
    assert.equal(uninstalled.ok, true);
    assert.equal(
      uninstalled.preserved_private.includes(".conversation-esaa/memory"),
      true,
    );
    assert.equal(await fileExists(memScript), false);
    assert.equal(await fileExists(activeFile), true);
    assert.equal(await readFile(activeFile, "utf8"), activeBefore);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("memory verify and sleep reject symlink injection inside .conversation-esaa/memory", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "conv-mem-symlink-"));
  const workspace = path.join(root, "workspace");
  const outsideFile = path.join(root, "outside-secret.json");
  try {
    await install({
      workspace,
      agents: ["codex"],
      dryRun: false,
      force: false,
      rag: "off",
      codexService: "off",
      yes: false,
      nonInteractive: true,
    });
    await writeFile(outsideFile, '{"secret":true}\n', "utf8");

    const pwsh = findExecutable("pwsh");
    const convCli = path.join(
      workspace,
      ".conversation-esaa",
      "bin",
      "conversation-esaa.ps1",
    );

    const shadowDir = path.join(
      workspace,
      ".conversation-esaa",
      "memory",
      "shadow",
    );
    await mkdir(shadowDir, { recursive: true });
    await symlink(outsideFile, path.join(shadowDir, "evil.json"));

    const verifyRes = runPwsh(pwsh, convCli, [
      "memory",
      "verify",
      "--workspace",
      workspace,
      "--json",
    ]);
    assert.notEqual(verifyRes.status, 0);
    assert.match(`${verifyRes.stdout}\n${verifyRes.stderr}`, /UNSAFE_PATH/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
