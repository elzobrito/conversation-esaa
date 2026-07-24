#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "./installer/args.js";
import { install } from "./installer/install.js";
import {
  doctor,
  status,
  uninstall,
  updateOrRepair,
} from "./installer/lifecycle/index.js";

const packageRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

function help() {
  return `Conversation ESAA installer

Usage:
  conversation-esaa install [options]
  conversation-esaa status|doctor|update|repair|uninstall [options]

Install options:
  --workspace <path>          workspace (default: current directory)
  --agent <name>              repeatable agent selection
  --agents <comma-list>       grok, claude, codex, antigravity
  --rag <off|existing|managed>
  --json                      machine-readable output
  --dry-run                   plan without changes
  --yes                       accept safe defaults
  --non-interactive           reject missing choices
  --force                     replace modified owned files
`;
}

export async function main(argv = process.argv.slice(2)) {
  let options;
  try {
    options = parseArgs(argv);
    if (options.command === "help") {
      process.stdout.write(help());
      return 0;
    }
    if (options.command === "version") {
      const pkg = JSON.parse(
        await readFile(path.join(packageRoot, "package.json"), "utf8"),
      );
      process.stdout.write(`${pkg.version}\n`);
      return 0;
    }
    let result;
    if (options.command === "install") result = await install(options);
    else if (options.command === "status") result = await status(options);
    else if (options.command === "doctor") result = await doctor(options);
    else if (options.command === "update" || options.command === "repair") {
      result = await updateOrRepair(options, options.command);
    } else if (options.command === "uninstall") result = await uninstall(options);
    else throw new Error(`unsupported command: ${options.command}`);
    if (options.json) {
      process.stdout.write(`${JSON.stringify(result)}\n`);
    } else {
      process.stdout.write(
        `${result.ok ? "OK" : "Needs attention"}: ${result.command} in ${result.workspace}\n`,
      );
      if (result.agents) process.stdout.write(`Agents: ${result.agents.join(", ")}\n`);
      for (const step of result.next_steps || []) process.stdout.write(`Next: ${step}\n`);
    }
    return result.exit_code || 0;
  } catch (error) {
    const result = {
      schema_version: "conversation-esaa.installer.v1",
      ok: false,
      command: options?.command || "unknown",
      workspace: options?.workspace || process.cwd(),
      errors: [error.message],
    };
    if (options?.json) {
      process.stdout.write(`${JSON.stringify(result)}\n`);
    } else {
      process.stderr.write(`conversation-esaa: ${error.message}\n`);
    }
    return /unknown option|requires a value|unsupported agent/.test(error.message)
      ? 1
      : 3;
  }
}

process.exitCode = await main();
