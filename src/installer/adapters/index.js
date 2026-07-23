import { createHash } from "node:crypto";
import { homedir } from "node:os";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { appendUniqueHook, readJsonObject, writeJson } from "./json.js";

function quoteCommandPart(value) {
  return `"${String(value).replaceAll('"', '\\"')}"`;
}

export function findExecutable(name = "pwsh", env = process.env) {
  const command = process.platform === "win32" ? "where.exe" : "which";
  const result = spawnSync(command, [name], {
    encoding: "utf8",
    shell: false,
    env,
    windowsHide: true,
  });
  if (result.status !== 0) throw new Error("PowerShell 7 executable not found");
  return path.resolve(result.stdout.trim().split(/\r?\n/, 1)[0]);
}

function syncCommand(pwsh, cli, workspace, agent, extra = []) {
  return [
    quoteCommandPart(pwsh),
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    quoteCommandPart(cli),
    "sync",
    "--agent",
    agent,
    "--workspace",
    quoteCommandPart(workspace),
    ...extra,
  ].join(" ");
}

async function configureHookAgent(agent, file, events, context) {
  const config = await readJsonObject(file);
  for (const [event, timeout, extra = []] of events) {
    appendUniqueHook(config, event, {
      type: "command",
      command: syncCommand(
        context.pwsh,
        context.cli,
        context.workspace,
        agent,
        extra,
      ),
      timeout,
    });
  }
  await writeJson(file, config, context.dryRun);
  return file;
}

async function configureAntigravity(context) {
  const file = path.join(context.workspace, ".agents", "hooks.json");
  const config = await readJsonObject(file);
  const wrapper = path.join(
    context.workspace,
    ".conversation-esaa",
    "bin",
    "antigravity-hook-sync.ps1",
  );
  config["conversation-esaa"] = {
    Stop: [{
      type: "command",
      command: [
        quoteCommandPart(context.pwsh),
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        quoteCommandPart(wrapper),
        "-WorkspaceRoot",
        quoteCommandPart(context.workspace),
      ].join(" "),
      timeout: 60,
    }],
  };
  await writeJson(file, config, context.dryRun);
  return file;
}

function systemdEscape(value) {
  return value.replaceAll("\\", "\\\\").replaceAll('"', '\\"');
}

async function configureCodexService(context) {
  const watcher = path.join(
    context.workspace,
    ".conversation-esaa",
    "bin",
    "codex-watch.ps1",
  );
  if (context.codexService !== "user") {
    return {
      mode: "manual",
      instruction: `${context.pwsh} -NoProfile -File "${watcher}" -WorkspaceRoot "${context.workspace}"`,
    };
  }
  if (context.platform === "linux") {
    const id = createHash("sha256").update(context.workspace).digest("hex").slice(0, 12);
    const file = path.join(
      context.home,
      ".config",
      "systemd",
      "user",
      `conversation-esaa-${id}.service`,
    );
    const unit = `[Unit]
Description=Conversation ESAA Codex watcher (${systemdEscape(context.workspace)})

[Service]
ExecStart="${systemdEscape(context.pwsh)}" -NoProfile -File "${systemdEscape(watcher)}" -WorkspaceRoot "${systemdEscape(context.workspace)}"
Restart=on-failure

[Install]
WantedBy=default.target
`;
    if (!context.dryRun) {
      await mkdir(path.dirname(file), { recursive: true });
      await writeFile(file, unit, "utf8");
    }
    return { mode: "systemd-user", file };
  }
  if (context.platform === "win32") {
    const taskName = `ConversationESAA-${createHash("sha256")
      .update(context.workspace)
      .digest("hex")
      .slice(0, 12)}`;
    const taskCommand = `${quoteCommandPart(context.pwsh)} -NoProfile -File ${quoteCommandPart(watcher)} -WorkspaceRoot ${quoteCommandPart(context.workspace)}`;
    if (!context.dryRun) {
      const result = spawnSync(
        "schtasks.exe",
        ["/Create", "/F", "/SC", "ONLOGON", "/TN", taskName, "/TR", taskCommand],
        { encoding: "utf8", shell: false, windowsHide: true },
      );
      if (result.status !== 0) {
        throw new Error(`failed to create Codex Scheduled Task: ${result.stderr}`);
      }
    }
    return { mode: "scheduled-task", task: taskName };
  }
  return {
    mode: "manual",
    instruction: `${context.pwsh} -NoProfile -File "${watcher}" -WorkspaceRoot "${context.workspace}"`,
  };
}

export async function configureAgents(options, dependencies = {}) {
  const context = {
    workspace: path.resolve(options.workspace),
    cli: path.join(
      path.resolve(options.workspace),
      ".conversation-esaa",
      "bin",
      "conversation-esaa.ps1",
    ),
    pwsh: dependencies.pwsh || findExecutable("pwsh", dependencies.env),
    dryRun: Boolean(options.dryRun),
    codexService: options.codexService || "off",
    platform: dependencies.platform || process.platform,
    home: dependencies.home || homedir(),
  };
  const configured = [];
  let codex = null;
  for (const agent of options.agents) {
    if (agent === "grok") {
      configured.push(await configureHookAgent(
        agent,
        path.join(context.workspace, ".grok", "hooks", "conversation-esaa.json"),
        [
          ["UserPromptSubmit", 15],
          ["Stop", 20],
          ["PreCompact", 25, ["--Mode", "compact"]],
        ],
        context,
      ));
    } else if (agent === "claude") {
      configured.push(await configureHookAgent(
        agent,
        path.join(context.workspace, ".claude", "settings.json"),
        [
          ["UserPromptSubmit", 20],
          ["Stop", 30],
          ["PreCompact", 30, ["--Mode", "compact"]],
        ],
        context,
      ));
    } else if (agent === "antigravity") {
      configured.push(await configureAntigravity(context));
    } else if (agent === "codex") {
      codex = await configureCodexService(context);
    }
  }
  return { configured, codex, pwsh: context.pwsh };
}
