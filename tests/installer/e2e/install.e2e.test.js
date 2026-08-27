import assert from "node:assert/strict";
import {
  access,
  mkdtemp,
  mkdir,
  readFile,
  unlink,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { findExecutable } from "../../../src/installer/adapters/index.js";

const repo = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../..",
);

function resolveInvocation(executable, args) {
  if (typeof executable === "object") {
    return {
      command: executable.command,
      args: [...executable.args, ...args],
    };
  }
  if (process.platform === "win32" && executable === "npm") {
    assert.ok(process.env.npm_execpath, "npm_execpath is required on Windows");
    return {
      command: process.execPath,
      args: [process.env.npm_execpath, ...args],
    };
  }
  return { command: executable, args };
}

function run(executable, args, options = {}) {
  const invocation = resolveInvocation(executable, args);
  const result = spawnSync(invocation.command, invocation.args, {
    encoding: "utf8",
    shell: false,
    windowsHide: true,
    ...options,
  });
  assert.equal(
    result.status,
    0,
    `${invocation.command} ${invocation.args.join(" ")}\nstatus=${result.status}\n${result.stdout}\n${result.stderr}\n${result.error || ""}`,
  );
  return result.stdout;
}

async function fileExists(file) {
  try {
    await access(file);
    return true;
  } catch {
    return false;
  }
}

async function packedCli() {
  const root = await mkdtemp(path.join(os.tmpdir(), "conv-esaa-pack-"));
  const output = JSON.parse(
    run("npm", ["pack", "--json", "--pack-destination", root], { cwd: repo }),
  );
  const archive = path.join(root, output[0].filename);
  const prefix = path.join(root, "install");
  run("npm", ["install", "--prefix", prefix, archive]);
  const cli = {
    command: process.execPath,
    args: [
      path.join(
        prefix,
        "node_modules",
        "conversation-esaa",
        "src",
        "cli.js",
      ),
    ],
  };
  return { root, cli };
}

test("packed CLI installs every agent alone and all agents together", async () => {
  const { root, cli } = await packedCli();
  const expected = {
    grok: ".grok/hooks/conversation-esaa.json",
    claude: ".claude/settings.json",
    antigravity: ".agents/hooks.json",
  };
  for (const agent of ["grok", "claude", "codex", "antigravity"]) {
    const workspace = path.join(root, `workspace-${agent}`);
    const result = JSON.parse(
      run(cli, [
        "install",
        "--workspace",
        workspace,
        "--agents",
        agent,
        "--non-interactive",
        "--json",
      ]),
    );
    assert.equal(result.ok, true);
    assert.equal(result.version, "1.3.1");
    assert.deepEqual(result.agents, [agent]);
    if (expected[agent]) {
      assert.equal(await fileExists(path.join(workspace, expected[agent])), true);
    }
    assert.equal(
      await fileExists(
        path.join(workspace, ".conversation-esaa", "install-manifest.json"),
      ),
      true,
    );
    assert.equal(
      await fileExists(
        path.join(workspace, ".conversation-esaa", "bin", "conv-bootstrap.ps1"),
      ),
      true,
    );
  }

  const workspace = path.join(root, "projeto com espaços e ç");
  await mkdir(path.join(workspace, ".claude"), { recursive: true });
  await writeFile(
    path.join(workspace, ".claude", "settings.json"),
    JSON.stringify({ permissions: { allow: ["Read"] } }),
  );
  const all = JSON.parse(
    run(cli, [
      "install",
      "--workspace",
      workspace,
      "--yes",
      "--non-interactive",
      "--json",
    ]),
  );
  assert.equal(all.ok, true);
  const claude = JSON.parse(
    await readFile(path.join(workspace, ".claude", "settings.json"), "utf8"),
  );
  assert.deepEqual(claude.permissions, { allow: ["Read"] });
  for (const event of ["UserPromptSubmit", "Stop", "PreCompact"]) {
    const commands = claude.hooks[event].flatMap((group) =>
      group.hooks.map((hook) => hook.command));
    assert.equal(
      commands.filter((command) =>
        command.includes("conversation-esaa.ps1") &&
        /--agent(?:=|\s+)claude/.test(command)).length,
      1,
    );
  }

  const status = JSON.parse(
    run(cli, ["status", "--workspace", workspace, "--json"]),
  );
  assert.equal(status.version, "1.3.1");
  assert.equal(status.healthy, true);
  const doctor = JSON.parse(
    run(cli, ["doctor", "--workspace", workspace, "--json"]),
  );
  assert.equal(doctor.ok, true);
  assert.equal(
    status.files.some((entry) =>
      entry.path === ".conversation-esaa/bin/conv-bootstrap.ps1" &&
      entry.kind === "owned" &&
      entry.state === "intact"),
    true,
  );

  const installedCli = path.join(
    workspace,
    ".conversation-esaa",
    "bin",
    "conversation-esaa.ps1",
  );
  run(findExecutable(), [
    "-NoProfile",
    "-File",
    installedCli,
    "init",
    "--workspace",
    workspace,
  ]);
  assert.equal(
    await fileExists(
      path.join(workspace, ".conversation-esaa", "bin", "conv-bootstrap.ps1"),
    ),
    true,
  );
});


function conversationHookCommands(settings, event) {
  const groups = settings?.hooks?.[event] || [];
  return groups.flatMap((group) =>
    (group.hooks || [])
      .map((hook) => hook.command)
      .filter((command) =>
        typeof command === "string" && command.includes("conversation-esaa.ps1")),
  );
}

test("clean claude install writes one SkipIfLocked hook per event", async () => {
  const { root, cli } = await packedCli();
  const workspace = path.join(root, "clean-claude");
  run(cli, [
    "install",
    "--workspace",
    workspace,
    "--agent",
    "claude",
    "--non-interactive",
    "--json",
  ]);
  const settings = JSON.parse(
    await readFile(path.join(workspace, ".claude", "settings.json"), "utf8"),
  );
  for (const event of ["UserPromptSubmit", "Stop", "PreCompact"]) {
    const commands = conversationHookCommands(settings, event);
    assert.equal(commands.length, 1, event);
    assert.match(commands[0], /--SkipIfLocked/);
  }
});

test("bootstrap without SkipAgentIntegrations then adapter keeps one claude hook", async () => {
  const { root, cli } = await packedCli();
  const workspace = path.join(root, "double-writer");
  await mkdir(workspace, { recursive: true });
  const bootstrap = path.join(
    repo,
    ".conversation-esaa",
    "bin",
    "conv-bootstrap.ps1",
  );
  run(findExecutable(), [
    "-NoProfile",
    "-File",
    bootstrap,
    "-WorkspaceRoot",
    workspace,
    "-Agents",
    "claude",
    "-Json",
  ]);
  run(cli, [
    "install",
    "--workspace",
    workspace,
    "--agent",
    "claude",
    "--non-interactive",
    "--json",
  ]);
  const settings = JSON.parse(
    await readFile(path.join(workspace, ".claude", "settings.json"), "utf8"),
  );
  for (const event of ["UserPromptSubmit", "Stop", "PreCompact"]) {
    assert.equal(conversationHookCommands(settings, event).length, 1, event);
  }
});

test("packed upgrade converges legacy Claude hooks without touching unrelated hooks", async () => {
  const { root, cli } = await packedCli();
  const workspace = path.join(root, "legacy-hooks");
  const settings = path.join(workspace, ".claude", "settings.json");
  const installedCli = path.join(
    workspace,
    ".conversation-esaa",
    "bin",
    "conversation-esaa.ps1",
  );
  await mkdir(path.dirname(settings), { recursive: true });
  await writeFile(
    settings,
    JSON.stringify({
      permissions: { allow: ["Read"] },
      hooks: {
        Stop: [
          { hooks: [{ type: "command", command: "unrelated-stop" }] },
          {
            hooks: [{
              type: "command",
              command: `pwsh -NoProfile -File "${installedCli}" sync --agent claude --workspace "${workspace}"`,
            }],
          },
          {
            hooks: [{
              type: "command",
              command: `"/legacy/pwsh" -NoProfile -File "${installedCli}" sync --agent=claude --workspace "${workspace}"`,
            }],
          },
        ],
      },
    }),
  );
  run(cli, [
    "install",
    "--workspace",
    workspace,
    "--agent",
    "claude",
    "--non-interactive",
    "--json",
  ]);
  const value = JSON.parse(await readFile(settings, "utf8"));
  const commands = value.hooks.Stop.flatMap((group) =>
    group.hooks.map((hook) => hook.command));
  assert.equal(commands.includes("unrelated-stop"), true);
  const synced = commands.filter((command) =>
    command.includes("conversation-esaa.ps1") &&
    /--agent(?:=|\s+)claude/.test(command));
  assert.equal(synced.length, 1);
  assert.match(synced[0], /--SkipIfLocked/);
});

test("dry-run and workspace metacharacters cannot execute commands", async () => {
  const { root, cli } = await packedCli();
  const sentinel = path.join(root, "must-not-exist");
  const workspace = path.join(
    root,
    `literal ; $(touch ${path.basename(sentinel)}) ç`,
  );
  const result = JSON.parse(
    run(cli, [
      "install",
      "--workspace",
      workspace,
      "--agents",
      "codex",
      "--non-interactive",
      "--dry-run",
      "--json",
    ]),
  );
  assert.equal(result.ok, true);
  assert.equal(await fileExists(workspace), false);
  assert.equal(await fileExists(sentinel), false);
});

test("repair, update, and uninstall preserve conversation history", async () => {
  const { root, cli } = await packedCli();
  const workspace = path.join(root, "lifecycle");
  run(cli, [
    "install",
    "--workspace",
    workspace,
    "--agents",
    "codex",
    "--non-interactive",
    "--json",
  ]);
  const activity = path.join(workspace, ".conversation-esaa", "activity.jsonl");
  const bootstrap = path.join(
    workspace,
    ".conversation-esaa",
    "bin",
    "conv-bootstrap.ps1",
  );
  await writeFile(activity, "PRIVATE-HISTORY\n");
  await unlink(bootstrap);
  const unhealthy = JSON.parse(
    run(cli, ["status", "--workspace", workspace, "--json"]),
  );
  assert.equal(unhealthy.healthy, false);
  assert.equal(
    unhealthy.files.some((entry) =>
      entry.path === ".conversation-esaa/bin/conv-bootstrap.ps1" &&
      entry.state === "missing"),
    true,
  );
  for (const command of ["repair", "update"]) {
    const value = JSON.parse(
      run(cli, [command, "--workspace", workspace, "--json"]),
    );
    assert.equal(value.ok, true);
    assert.equal(await readFile(activity, "utf8"), "PRIVATE-HISTORY\n");
    assert.equal(await fileExists(bootstrap), true);
  }
  const removed = JSON.parse(
    run(cli, ["uninstall", "--workspace", workspace, "--json"]),
  );
  assert.equal(removed.ok, true);
  assert.equal(await readFile(activity, "utf8"), "PRIVATE-HISTORY\n");
  assert.equal(
    await fileExists(
      path.join(workspace, ".conversation-esaa", "bin", "conversation-esaa.ps1"),
    ),
    false,
  );
  assert.equal(await fileExists(bootstrap), false);
});

test(
  "managed RAG consumes the pinned release without breaking core install",
  { skip: process.env.CONVERSATION_ESAA_SKIP_NETWORK === "1" },
  async () => {
    const { root, cli } = await packedCli();
    const workspace = path.join(root, "managed-rag");
    const env = {
      ...process.env,
      XDG_DATA_HOME: path.join(root, "data"),
      LOCALAPPDATA: path.join(root, "data"),
    };
    const value = JSON.parse(
      run(
        cli,
        [
          "install",
          "--workspace",
          workspace,
          "--agents",
          "codex",
          "--rag",
          "managed",
          "--non-interactive",
          "--json",
        ],
        { env },
      ),
    );
    assert.equal(value.ok, true);
    assert.equal(value.rag.mode, "managed");
    assert.equal(
      await fileExists(
        path.join(workspace, ".conversation-esaa", "install-manifest.json"),
      ),
      true,
    );
  },
);
