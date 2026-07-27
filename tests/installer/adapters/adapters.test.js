import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { configureAgents } from "../../../src/installer/adapters/index.js";

test("Claude and Antigravity preserve unrelated configuration", async () => {
  const workspace = await mkdtemp(path.join(os.tmpdir(), "conv-adapters-"));
  const cli = path.join(
    workspace,
    ".conversation-esaa",
    "bin",
    "conversation-esaa.ps1",
  );
  await mkdir(path.join(workspace, ".claude"), { recursive: true });
  await mkdir(path.join(workspace, ".agents"), { recursive: true });
  await writeFile(
    path.join(workspace, ".claude", "settings.json"),
    JSON.stringify({
      permissions: { allow: ["Read"] },
      hooks: {
        Stop: [
          { hooks: [{ type: "command", command: "custom-stop", timeout: 9 }] },
          {
            hooks: [{
              type: "command",
              command: `pwsh -NoProfile -File "${cli}" sync --agent claude --workspace "${workspace}"`,
              timeout: 20,
            }],
          },
          {
            hooks: [{
              type: "command",
              command: `"/old/pwsh" -NoProfile -File "${cli}" sync --agent=claude --workspace "${workspace}"`,
              timeout: 20,
            }],
          },
          {
            hooks: [{
              type: "command",
              command: `pwsh -NoProfile -File "${cli}" sync --agent grok --workspace "${workspace}"`,
              timeout: 20,
            }],
          },
        ],
      },
    }),
  );
  await writeFile(
    path.join(workspace, ".agents", "hooks.json"),
    JSON.stringify({ custom: { Stop: [{ type: "command", command: "custom" }] } }),
  );
  const result = await configureAgents(
    {
      workspace,
      agents: ["claude", "antigravity"],
      dryRun: false,
      codexService: "off",
    },
    { pwsh: "/opt/powershell/pwsh" },
  );
  const claude = JSON.parse(
    await readFile(path.join(workspace, ".claude", "settings.json"), "utf8"),
  );
  const antigravity = JSON.parse(
    await readFile(path.join(workspace, ".agents", "hooks.json"), "utf8"),
  );
  assert.deepEqual(claude.permissions, { allow: ["Read"] });
  const stopCommands = claude.hooks.Stop.flatMap((group) =>
    group.hooks.map((hook) => hook.command));
  assert.equal(
    stopCommands.filter((command) =>
      command.includes("/opt/powershell/pwsh") &&
      command.includes("--agent claude")).length,
    1,
  );
  assert.equal(stopCommands.includes("custom-stop"), true);
  assert.equal(
    stopCommands.some((command) => command.includes("--agent grok")),
    true,
  );
  assert.equal(
    stopCommands.filter((command) =>
      command.includes("conversation-esaa.ps1") &&
      /--agent(?:=|\s+)claude/.test(command)).length,
    1,
  );
  assert.equal(antigravity.custom.Stop[0].command, "custom");
  assert.equal(antigravity["conversation-esaa"].Stop[0].timeout, 60);
  assert.equal(result.pwsh, "/opt/powershell/pwsh");
});

test("invalid JSON fails closed and remains unchanged", async () => {
  const workspace = await mkdtemp(path.join(os.tmpdir(), "conv-adapters-"));
  const file = path.join(workspace, ".claude", "settings.json");
  await mkdir(path.dirname(file), { recursive: true });
  await writeFile(file, "{invalid");
  await assert.rejects(
    configureAgents(
      {
        workspace,
        agents: ["claude"],
        dryRun: false,
        codexService: "off",
      },
      { pwsh: "/usr/bin/pwsh" },
    ),
    /invalid existing JSON/,
  );
  assert.equal(await readFile(file, "utf8"), "{invalid");
});

test("Codex service is manual unless explicitly requested", async () => {
  const workspace = await mkdtemp(path.join(os.tmpdir(), "conv-adapters-"));
  const manual = await configureAgents(
    {
      workspace,
      agents: ["codex"],
      dryRun: false,
      codexService: "off",
    },
    { pwsh: "/usr/bin/pwsh", platform: "linux", home: workspace },
  );
  assert.equal(manual.codex.mode, "manual");
  assert.equal(
    await readFile(path.join(workspace, ".config", "systemd", "user", "missing"), "utf8")
      .then(() => true, () => false),
    false,
  );

  const enabled = await configureAgents(
    {
      workspace,
      agents: ["codex"],
      dryRun: false,
      codexService: "user",
    },
    { pwsh: "/usr/bin/pwsh", platform: "linux", home: workspace },
  );
  assert.equal(enabled.codex.mode, "systemd-user");
  assert.equal(
    (await readFile(enabled.codex.file, "utf8")).includes(
      'ExecStart="/usr/bin/pwsh"',
    ),
    true,
  );
});
