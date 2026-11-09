import { access, cp, mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { SUPPORTED_AGENTS } from "./args.js";
import { sha256, workspaceRelative, writeJsonAtomic } from "./files.js";
import { runPowerShell } from "./powershell.js";
import { promptAgents } from "./prompts.js";
import { configureAgents } from "./adapters/index.js";
import { readPackageMetadata } from "./package.js";
import { setupRag } from "./rag/index.js";

const packageRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../..",
);
const runtimeNames = [
  "conv-sync.ps1",
  "conversation-esaa.ps1",
  "conv-bootstrap.ps1",
  "codex-watch.ps1",
  "antigravity-hook-sync.ps1",
  "cursor-hook.ps1",
  "conv-rag.ps1",
  "conv-memory.ps1",
];

async function exists(file) {
  try {
    await access(file);
    return true;
  } catch {
    return false;
  }
}

export async function resolveAgents(options, io = {}) {
  if (options.agents.length) return options.agents;
  if (options.yes) return SUPPORTED_AGENTS;
  if (options.nonInteractive || !process.stdin.isTTY) {
    throw new Error(
      "agent selection is required in non-interactive mode; use --agents or --yes",
    );
  }
  return promptAgents(SUPPORTED_AGENTS, io);
}

export async function install(options, dependencies = {}) {
  const packageMetadata = await readPackageMetadata();
  const run = dependencies.runPowerShell || runPowerShell;
  const agents = await resolveAgents(options, dependencies.io);
  const workspace = path.resolve(options.workspace);
  const bootstrap =
    dependencies.bootstrap ||
    path.join(packageRoot, ".conversation-esaa", "bin", "conv-bootstrap.ps1");
  if (!(await exists(bootstrap))) {
    throw new Error(`packaged bootstrap not found: ${bootstrap}`);
  }

  // Ship the memory engine with each installation; never rely on a developer checkout.
  const memorySource = path.join(packageRoot, "src", "memory");
  const memoryTarget = path.join(workspace, ".conversation-esaa", "bin", "memory");
  if (!options.force && await exists(memoryTarget)) {
    const manifestPath = path.join(workspace, ".conversation-esaa", "install-manifest.json");
    let prior = null;
    try { prior = JSON.parse(await readFile(manifestPath, "utf8")); } catch { /* no trusted baseline */ }
    for (const subdir of ["core", "adapter"]) {
      for (const name of await readdir(path.join(memorySource, subdir))) {
        const target = path.join(memoryTarget, subdir, name);
        if (!(await exists(target))) continue;
        const entry = prior?.files?.find((f) => f.path === workspaceRelative(workspace, target));
        if ((!entry || entry.sha256 !== await sha256(target)) && await sha256(target) !== await sha256(path.join(memorySource, subdir, name))) {
          throw new Error(`modified or unmanaged memory engine file requires --force: ${target}`);
        }
      }
    }
    const moduleFile = path.join(memoryTarget, "package.json");
    if (await exists(moduleFile)) {
      const entry = prior?.files?.find((f) => f.path === workspaceRelative(workspace, moduleFile));
      const matchesBaseline = entry && entry.sha256 === await sha256(moduleFile);
      if (!matchesBaseline && await readFile(moduleFile, "utf8") !== '{"type":"module"}\n') {
        throw new Error(`modified or unmanaged memory module file requires --force: ${moduleFile}`);
      }
    }
  }

  const integrationPaths = {
    grok: ".grok/hooks/conversation-esaa.json",
    claude: ".claude/settings.json",
    antigravity: ".agents/hooks.json",
    cursor: ".cursor/hooks.json",
  };
  const existing = new Set();
  for (const agent of agents) {
    const relative = integrationPaths[agent];
    if (relative && (await exists(path.join(workspace, relative)))) {
      existing.add(relative);
    }
  }

  const bootstrapArgs = [
    "-WorkspaceRoot",
    workspace,
    "-Agents",
    agents.join(","),
    "-Json",
    "-SkipAgentIntegrations",
  ];
  if (options.dryRun) bootstrapArgs.push("-DryRun");
  if (options.force) bootstrapArgs.push("-Force");
  const bootstrapResult = JSON.parse(
    run(bootstrap, bootstrapArgs, dependencies.powershellOptions),
  );
  const adapterResult = await (dependencies.configureAgents || configureAgents)(
    { ...options, workspace, agents },
    dependencies.adapterOptions,
  );
  let ragResult;
  try {
    ragResult = await (dependencies.setupRag || setupRag)(
      { ...options, workspace },
      dependencies.ragOptions,
    );
  } catch (error) {
    ragResult = { mode: options.rag || "off", enabled: false, error: error.message };
  }

  const result = {
    schema_version: "conversation-esaa.installer.v1",
    ok: true,
    command: "install",
    workspace,
    version: packageMetadata.version,
    agents,
    changed: bootstrapResult.changed || [],
    preserved: bootstrapResult.preserved || [],
    warnings: bootstrapResult.warnings || [],
    errors: [],
    next_steps: bootstrapResult.warnings || [],
    dry_run: Boolean(options.dryRun),
    adapters: adapterResult,
    rag: ragResult,
  };
  if (options.dryRun) return result;

  await mkdir(memoryTarget, { recursive: true });
  await cp(memorySource, memoryTarget, { recursive: true });
  await writeFile(path.join(memoryTarget, "package.json"), '{"type":"module"}\n');

  const files = [];
  for (const subdir of ["core", "adapter"]) {
    for (const name of await readdir(path.join(memorySource, subdir))) {
      const file = path.join(memoryTarget, subdir, name);
      files.push({ path: workspaceRelative(workspace, file), sha256: await sha256(file), kind: "owned" });
    }
  }
  const memoryPackage = path.join(memoryTarget, "package.json");
  files.push({ path: workspaceRelative(workspace, memoryPackage), sha256: await sha256(memoryPackage), kind: "owned" });
  for (const name of runtimeNames) {
    const file = path.join(workspace, ".conversation-esaa", "bin", name);
    if (await exists(file)) {
      files.push({
        path: workspaceRelative(workspace, file),
        sha256: await sha256(file),
        kind: "owned",
      });
    }
  }
  for (const agent of agents) {
    const relative = integrationPaths[agent];
    if (relative && (await exists(path.join(workspace, relative)))) {
      files.push({
        path: relative,
        sha256: await sha256(path.join(workspace, relative)),
        kind: existing.has(relative) ? "merged" : "owned",
      });
    }
  }
  if (await exists(path.join(workspace, ".gitignore"))) {
    files.push({
      path: ".gitignore",
      sha256: await sha256(path.join(workspace, ".gitignore")),
      kind: "merged",
    });
  }
  const manifest = {
    schema_version: "conversation-esaa.install-manifest.v1",
    version: packageMetadata.version,
    workspace,
    agents,
    rag: ragResult,
    codex_service: options.codexService,
    files,
  };
  const manifestPath = path.join(
    workspace,
    ".conversation-esaa",
    "install-manifest.json",
  );
  await writeJsonAtomic(manifestPath, manifest);
  result.changed.push(manifestPath);
  return result;
}
