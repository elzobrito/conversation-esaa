import { createHash } from "node:crypto";
import {
  access,
  readFile,
  rename,
  unlink,
  writeFile,
} from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { sha256 } from "../files.js";
import { findExecutable } from "../adapters/index.js";
import { install } from "../install.js";

const PRIVATE_PATHS = [
  ".conversation-esaa/activity.jsonl",
  ".conversation-esaa/sync-state.json",
  ".conversation-esaa/state.md",
  ".conversation-esaa/handoff.md",
  ".conversation-esaa/decisions.md",
  ".conversation-esaa/tasks.json",
  ".conversation-esaa/rag",
];

async function exists(file) {
  try {
    await access(file);
    return true;
  } catch {
    return false;
  }
}

export async function loadManifest(workspace) {
  const file = path.join(workspace, ".conversation-esaa", "install-manifest.json");
  let manifest;
  try {
    manifest = JSON.parse(await readFile(file, "utf8"));
  } catch (error) {
    throw new Error(`install manifest is unavailable or invalid: ${error.message}`);
  }
  if (
    manifest.schema_version !== "conversation-esaa.install-manifest.v1" ||
    !Array.isArray(manifest.files)
  ) {
    throw new Error("install manifest has an unsupported schema");
  }
  return { file, manifest };
}

export async function classify(workspace, manifest) {
  const files = [];
  for (const entry of manifest.files) {
    if (
      typeof entry.path !== "string" ||
      entry.path === ".." ||
      entry.path.startsWith("../") ||
      path.isAbsolute(entry.path)
    ) {
      throw new Error(`unsafe manifest path: ${entry.path}`);
    }
    const file = path.join(workspace, ...entry.path.split("/"));
    let state = "missing";
    if (await exists(file)) {
      state = (await sha256(file)) === entry.sha256 ? "intact" : "modified";
    }
    files.push({ ...entry, state });
  }
  return files;
}

function result(command, workspace, extra = {}) {
  return {
    schema_version: "conversation-esaa.installer.v1",
    ok: true,
    command,
    workspace,
    changed: [],
    preserved: [],
    warnings: [],
    errors: [],
    ...extra,
  };
}

export async function status(options) {
  const workspace = path.resolve(options.workspace);
  const { manifest } = await loadManifest(workspace);
  const files = await classify(workspace, manifest);
  return result("status", workspace, {
    version: manifest.version,
    agents: manifest.agents,
    rag: manifest.rag,
    codex_service: manifest.codex_service,
    files,
    healthy: files.every((entry) => entry.state === "intact"),
  });
}

export async function doctor(options, dependencies = {}) {
  const report = await status(options);
  const checks = [];
  let pwsh;
  try {
    pwsh = dependencies.pwsh || findExecutable("pwsh", dependencies.env);
    checks.push({ name: "pwsh", ok: true, detail: pwsh });
  } catch (error) {
    checks.push({ name: "pwsh", ok: false, detail: error.message });
  }
  const drift = report.files.filter((entry) => entry.state !== "intact");
  checks.push({
    name: "manifest",
    ok: drift.length === 0,
    detail: drift.length ? `${drift.length} file(s) drifted` : "all files intact",
  });
  if (pwsh) {
    const cli = path.join(
      report.workspace,
      ".conversation-esaa",
      "bin",
      "conversation-esaa.ps1",
    );
    const execution = (dependencies.spawnSync || spawnSync)(
      pwsh,
      [
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        cli,
        "verify",
        "--workspace",
        report.workspace,
      ],
      { encoding: "utf8", shell: false, windowsHide: true },
    );
    checks.push({
      name: "conversation-verify",
      ok: execution.status === 0,
      detail: execution.status === 0 ? "ok" : "failed",
    });
  }
  checks.push({
    name: "rag",
    ok: !report.rag?.mode || report.rag.mode === "off" || report.rag.enabled === true,
    detail:
      report.rag?.mode === "off"
        ? "disabled"
        : report.rag?.enabled
          ? "enabled"
          : report.rag?.error || "not ready",
  });
  report.command = "doctor";
  report.checks = checks;
  report.ok = checks.every((check) => check.ok);
  report.exit_code = report.ok ? 0 : checks.some(
    (check) => check.name === "pwsh" && !check.ok,
  ) ? 3 : 2;
  return report;
}

export async function updateOrRepair(options, command, dependencies = {}) {
  const workspace = path.resolve(options.workspace);
  const { manifest } = await loadManifest(workspace);
  const files = await classify(workspace, manifest);
  const modified = files.filter((entry) => entry.state === "modified");
  if (modified.length && !options.force) {
    const report = result(command, workspace, {
      ok: false,
      exit_code: 2,
      conflicts: modified.map((entry) => entry.path),
    });
    report.errors.push("modified installer-owned files require --force");
    return report;
  }
  const runInstall = dependencies.install || install;
  const installed = await runInstall(
    {
      ...options,
      command: "install",
      workspace,
      agents: manifest.agents || [],
      rag: manifest.rag?.mode || "off",
      ragCommand: manifest.rag?.mode === "existing" ? manifest.rag.command : undefined,
      codexService: manifest.codex_service || "off",
      nonInteractive: true,
      yes: false,
    },
    dependencies.installDependencies,
  );
  installed.command = command;
  installed.exit_code = 0;
  return installed;
}

function removeConversationCommands(groups) {
  if (!Array.isArray(groups)) return groups;
  return groups
    .map((group) => ({
      ...group,
      hooks: Array.isArray(group?.hooks)
        ? group.hooks.filter(
            (hook) => !String(hook?.command || "").includes(".conversation-esaa"),
          )
        : group?.hooks,
    }))
    .filter((group) => !Array.isArray(group.hooks) || group.hooks.length > 0);
}

async function cleanMergedHook(workspace, relative, dryRun) {
  const file = path.join(workspace, ...relative.split("/"));
  if (!(await exists(file))) return false;
  const value = JSON.parse(await readFile(file, "utf8"));
  if (relative === ".agents/hooks.json") {
    delete value["conversation-esaa"];
  } else if (value.hooks && typeof value.hooks === "object") {
    for (const event of Object.keys(value.hooks)) {
      value.hooks[event] = removeConversationCommands(value.hooks[event]);
    }
  }
  if (!dryRun) await writeFile(file, `${JSON.stringify(value, null, 2)}\n`, "utf8");
  return true;
}

async function removeCodexService(workspace, manifest, options, dependencies) {
  if (manifest.codex_service !== "user") return null;
  const platform = dependencies.platform || process.platform;
  const id = createHash("sha256").update(workspace).digest("hex").slice(0, 12);
  if (platform === "linux") {
    const file = path.join(
      dependencies.home || homedir(),
      ".config",
      "systemd",
      "user",
      `conversation-esaa-${id}.service`,
    );
    if ((await exists(file)) && !options.dryRun) await unlink(file);
    return file;
  }
  if (platform === "win32" && !options.dryRun) {
    (dependencies.spawnSync || spawnSync)(
      "schtasks.exe",
      ["/Delete", "/F", "/TN", `ConversationESAA-${id}`],
      { encoding: "utf8", shell: false, windowsHide: true },
    );
    return `Scheduled Task ConversationESAA-${id}`;
  }
  return null;
}

export async function uninstall(options, dependencies = {}) {
  const workspace = path.resolve(options.workspace);
  const { file: manifestFile, manifest } = await loadManifest(workspace);
  const files = await classify(workspace, manifest);
  const report = result("uninstall", workspace, {
    preserved_private: [...PRIVATE_PATHS],
  });
  for (const entry of files) {
    const file = path.join(workspace, ...entry.path.split("/"));
    if (entry.kind === "owned" && entry.state === "intact") {
      if (!options.dryRun) await unlink(file);
      report.changed.push(entry.path);
    } else if (
      entry.kind === "merged" &&
      [
        ".grok/hooks/conversation-esaa.json",
        ".claude/settings.json",
        ".agents/hooks.json",
      ].includes(entry.path)
    ) {
      if (await cleanMergedHook(workspace, entry.path, options.dryRun)) {
        report.changed.push(entry.path);
      }
    } else {
      report.preserved.push(entry.path);
    }
  }
  const service = await removeCodexService(
    workspace,
    manifest,
    options,
    dependencies,
  );
  if (service) report.changed.push(service);
  const backup = `${manifestFile}.uninstalled-${Date.now()}.json`;
  if (!options.dryRun) await rename(manifestFile, backup);
  report.changed.push(backup);
  return report;
}
