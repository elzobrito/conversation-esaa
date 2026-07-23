import { createHash } from "node:crypto";
import { access, mkdir, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { extractZip } from "./archive.js";

export const RAG_RELEASE = {
  version: "0.1.0",
  archive: "rag-sqlite-v0.1.0.zip",
  baseUrl: "https://github.com/elzobrito/rag-sqlite/releases/download/v0.1.0",
  sha256: "888d7ac04e7eaa91c35d8f7f48b74df55353c5134ed7317e35f698696a0351a8",
};

function dataRoot(env = process.env, platform = process.platform, home = homedir()) {
  if (platform === "win32") {
    return path.join(env.LOCALAPPDATA || env.APPDATA || home, "conversation-esaa");
  }
  return path.join(env.XDG_DATA_HOME || path.join(home, ".local", "share"), "conversation-esaa");
}

function resolveOnPath(command, env = process.env, platform = process.platform) {
  const finder = platform === "win32" ? "where.exe" : "which";
  const result = spawnSync(finder, [command], {
    encoding: "utf8",
    shell: false,
    env,
    windowsHide: true,
  });
  if (result.status !== 0) return null;
  return path.resolve(result.stdout.trim().split(/\r?\n/, 1)[0]);
}

function runCommand(command, args, dependencies = {}) {
  let executable = command;
  let fullArgs = args;
  if (command.toLowerCase().endsWith(".py")) {
    executable =
      dependencies.python ||
      resolveOnPath("python3", dependencies.env, dependencies.platform) ||
      resolveOnPath("python", dependencies.env, dependencies.platform);
    if (!executable) throw new Error("Python 3.10+ is required for rag-sqlite");
    fullArgs = [command, ...args];
  }
  const result = (dependencies.spawnSync || spawnSync)(executable, fullArgs, {
    encoding: "utf8",
    shell: false,
    windowsHide: true,
  });
  if (result.error || result.status !== 0) {
    throw new Error(`rag-sqlite command failed: ${result.error?.message || result.stderr || result.status}`);
  }
  return result.stdout;
}

export function validateSchema(command, dependencies = {}) {
  let value;
  try {
    value = JSON.parse(runCommand(command, ["--compact", "schema", "query"], dependencies));
  } catch (error) {
    throw new Error(`invalid rag-sqlite schema: ${error.message}`);
  }
  if (value.ok !== true || value.schema_version !== "rag_sqlite.schema.v1") {
    throw new Error("invalid rag-sqlite schema response");
  }
  return value;
}

async function download(url, fetchImpl) {
  const response = await fetchImpl(url, { redirect: "follow" });
  if (!response.ok) throw new Error(`download failed (${response.status}): ${url}`);
  return Buffer.from(await response.arrayBuffer());
}

async function managedCommand(options, dependencies) {
  const fetchImpl = dependencies.fetch || globalThis.fetch;
  if (typeof fetchImpl !== "function") throw new Error("HTTPS fetch is unavailable");
  const root =
    dependencies.dataRoot ||
    path.join(
      dataRoot(dependencies.env, dependencies.platform, dependencies.home),
      "rag-sqlite",
      `v${RAG_RELEASE.version}`,
    );
  const archive = await download(
    `${RAG_RELEASE.baseUrl}/${RAG_RELEASE.archive}`,
    fetchImpl,
  );
  const actual = createHash("sha256").update(archive).digest("hex");
  if (actual !== RAG_RELEASE.sha256) {
    throw new Error(`rag-sqlite checksum mismatch: expected ${RAG_RELEASE.sha256}, got ${actual}`);
  }
  const sums = (
    await download(`${RAG_RELEASE.baseUrl}/SHA256SUMS`, fetchImpl)
  ).toString("utf8");
  if (!sums.split(/\r?\n/).some((line) =>
    line.trim() === `${RAG_RELEASE.sha256}  ${RAG_RELEASE.archive}`)) {
    throw new Error("published SHA256SUMS does not authenticate the pinned archive");
  }
  if (!options.dryRun) {
    await mkdir(root, { recursive: true });
    await extractZip(archive, root);
    await writeFile(
      path.join(root, "managed.json"),
      `${JSON.stringify({
        version: RAG_RELEASE.version,
        sha256: RAG_RELEASE.sha256,
        source: RAG_RELEASE.baseUrl,
      }, null, 2)}\n`,
      "utf8",
    );
  }
  const bundle = path.join(root, `rag-sqlite-v${RAG_RELEASE.version}`);
  return dependencies.platform === "win32"
    ? path.join(bundle, "rag-sqlite.cmd")
    : path.join(bundle, "rag-sqlite");
}

export async function setupRag(options, dependencies = {}) {
  const mode = options.rag || "off";
  if (!["off", "existing", "managed"].includes(mode)) {
    throw new Error(`unsupported RAG mode: ${mode}`);
  }
  if (mode === "off") return { mode, enabled: false };
  let command;
  if (mode === "existing") {
    command =
      options.ragCommand ||
      resolveOnPath("rag-sqlite", dependencies.env, dependencies.platform);
    if (!command) throw new Error("rag-sqlite was not found; use --rag-command");
  } else {
    command = await managedCommand(options, dependencies);
  }
  if (!options.dryRun) validateSchema(command, dependencies);

  const cli = path.join(
    path.resolve(options.workspace),
    ".conversation-esaa",
    "bin",
    "conversation-esaa.ps1",
  );
  if (!options.dryRun) {
    const pwsh =
      dependencies.pwsh ||
      resolveOnPath("pwsh", dependencies.env, dependencies.platform);
    if (!pwsh) throw new Error("PowerShell 7 is required to enable RAG");
    const result = (dependencies.spawnSync || spawnSync)(
      pwsh,
      [
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        cli,
        "rag",
        "enable",
        "--workspace",
        path.resolve(options.workspace),
        "--command",
        command,
      ],
      { encoding: "utf8", shell: false, windowsHide: true },
    );
    if (result.status !== 0) {
      throw new Error(
        "rag-sqlite is installed but RAG could not be enabled; verify local Ollama and embeddinggemma",
      );
    }
  }
  return {
    mode,
    enabled: !options.dryRun,
    command,
    version: mode === "managed" ? RAG_RELEASE.version : undefined,
    sha256: mode === "managed" ? RAG_RELEASE.sha256 : undefined,
  };
}
