import { access } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { SUPPORTED_AGENTS } from "./args.js";
import { sha256, workspaceRelative, writeJsonAtomic } from "./files.js";
import { runPowerShell } from "./powershell.js";
import { promptAgents } from "./prompts.js";
import { configureAgents } from "./adapters/index.js";
import { setupRag } from "./rag/index.js";

const packageRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../..",
);
const runtimeNames = [
  "conv-sync.ps1",
  "conversation-esaa.ps1",
  "codex-watch.ps1",
  "antigravity-hook-sync.ps1",
  "conv-rag.ps1",
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
  const run = dependencies.runPowerShell || runPowerShell;
  const agents = await resolveAgents(options, dependencies.io);
  const workspace = path.resolve(options.workspace);
  const bootstrap =
    dependencies.bootstrap ||
    path.join(packageRoot, ".conversation-esaa", "bin", "conv-bootstrap.ps1");
  if (!(await exists(bootstrap))) {
    throw new Error(`packaged bootstrap not found: ${bootstrap}`);
  }

  const integrationPaths = {
    grok: ".grok/hooks/conversation-esaa.json",
    claude: ".claude/settings.json",
    antigravity: ".agents/hooks.json",
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
    version: "1.3.0",
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

  const files = [];
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
    version: "1.3.0",
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
