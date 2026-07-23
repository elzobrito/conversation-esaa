import assert from "node:assert/strict";
import {
  access,
  mkdtemp,
  mkdir,
  readFile,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import test from "node:test";

const repo = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../..",
);

function run(executable, args, options = {}) {
  const result = spawnSync(executable, args, {
    encoding: "utf8",
    shell: false,
    windowsHide: true,
    ...options,
  });
  assert.equal(
    result.status,
    0,
    `${executable} ${args.join(" ")}\n${result.stdout}\n${result.stderr}`,
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
  const cli = path.join(
    prefix,
    "node_modules",
    ".bin",
    process.platform === "win32" ? "conversation-esaa.cmd" : "conversation-esaa",
  );
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

  const status = JSON.parse(
    run(cli, ["status", "--workspace", workspace, "--json"]),
  );
  assert.equal(status.healthy, true);
  const doctor = JSON.parse(
    run(cli, ["doctor", "--workspace", workspace, "--json"]),
  );
  assert.equal(doctor.ok, true);
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
  await writeFile(activity, "PRIVATE-HISTORY\n");
  for (const command of ["repair", "update"]) {
    const value = JSON.parse(
      run(cli, [command, "--workspace", workspace, "--json"]),
    );
    assert.equal(value.ok, true);
    assert.equal(await readFile(activity, "utf8"), "PRIVATE-HISTORY\n");
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
