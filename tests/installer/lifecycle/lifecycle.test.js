import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  mkdtemp,
  mkdir,
  readFile,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  classify,
  doctor,
  status,
  uninstall,
  updateOrRepair,
} from "../../../src/installer/lifecycle/index.js";

const digest = (value) => createHash("sha256").update(value).digest("hex");

async function fixture() {
  const workspace = await mkdtemp(path.join(os.tmpdir(), "conv-lifecycle-"));
  const esaa = path.join(workspace, ".conversation-esaa");
  await mkdir(path.join(esaa, "bin"), { recursive: true });
  await writeFile(path.join(esaa, "bin", "runtime.ps1"), "runtime");
  await writeFile(path.join(esaa, "activity.jsonl"), "PRIVATE");
  const manifest = {
    schema_version: "conversation-esaa.install-manifest.v1",
    version: "1.3.0",
    agents: ["codex"],
    rag: { mode: "off", enabled: false },
    codex_service: "off",
    files: [{
      path: ".conversation-esaa/bin/runtime.ps1",
      sha256: digest("runtime"),
      kind: "owned",
    }],
  };
  await writeFile(
    path.join(esaa, "install-manifest.json"),
    JSON.stringify(manifest),
  );
  return { workspace, manifest };
}

test("status classifies intact, modified, and missing files", async () => {
  const { workspace, manifest } = await fixture();
  assert.equal((await classify(workspace, manifest))[0].state, "intact");
  await writeFile(
    path.join(workspace, ".conversation-esaa", "bin", "runtime.ps1"),
    "changed",
  );
  assert.equal((await status({ workspace })).files[0].state, "modified");
});

test("repair preserves modified owned files without force", async () => {
  const { workspace } = await fixture();
  const runtime = path.join(workspace, ".conversation-esaa", "bin", "runtime.ps1");
  await writeFile(runtime, "custom");
  const report = await updateOrRepair(
    { workspace, force: false, dryRun: false },
    "repair",
    { install: () => { throw new Error("must not run"); } },
  );
  assert.equal(report.exit_code, 2);
  assert.equal(await readFile(runtime, "utf8"), "custom");
});

test("uninstall removes intact runtime and preserves private data", async () => {
  const { workspace } = await fixture();
  const report = await uninstall({ workspace, dryRun: false });
  assert.equal(report.ok, true);
  assert.equal(
    await readFile(path.join(workspace, ".conversation-esaa", "activity.jsonl"), "utf8"),
    "PRIVATE",
  );
  await assert.rejects(
    readFile(path.join(workspace, ".conversation-esaa", "bin", "runtime.ps1")),
    /ENOENT/,
  );
  assert.equal(report.preserved_private.includes(".conversation-esaa/rag"), true);
});

test("doctor reports verification and manifest health", async () => {
  const { workspace } = await fixture();
  const report = await doctor(
    { workspace },
    {
      pwsh: "/usr/bin/pwsh",
      spawnSync: () => ({ status: 0, stdout: "verify: ok", stderr: "" }),
    },
  );
  assert.equal(report.ok, true);
  assert.equal(report.exit_code, 0);
});
