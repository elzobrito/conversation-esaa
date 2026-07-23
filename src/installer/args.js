import path from "node:path";

export const SUPPORTED_AGENTS = ["grok", "claude", "codex", "antigravity"];

function takeValue(argv, index, option) {
  const value = argv[index + 1];
  if (!value || value.startsWith("--")) {
    throw new Error(`${option} requires a value`);
  }
  return value;
}

export function parseArgs(argv, cwd = process.cwd()) {
  const options = {
    command: "help",
    workspace: path.resolve(cwd),
    agents: [],
    json: false,
    dryRun: false,
    yes: false,
    nonInteractive: false,
    force: false,
    rag: undefined,
    ragCommand: undefined,
    codexService: "off",
  };
  let index = 0;
  if (argv[0] && !argv[0].startsWith("-")) {
    options.command = argv[0];
    index = 1;
  }
  for (; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--workspace") {
      options.workspace = path.resolve(cwd, takeValue(argv, index, arg));
      index += 1;
    } else if (arg === "--agent") {
      options.agents.push(takeValue(argv, index, arg));
      index += 1;
    } else if (arg === "--agents") {
      options.agents.push(...takeValue(argv, index, arg).split(","));
      index += 1;
    } else if (arg === "--rag") {
      options.rag = takeValue(argv, index, arg);
      index += 1;
    } else if (arg === "--rag-command") {
      options.ragCommand = takeValue(argv, index, arg);
      index += 1;
    } else if (arg === "--codex-service") {
      options.codexService = takeValue(argv, index, arg);
      index += 1;
    } else if (arg === "--json") {
      options.json = true;
    } else if (arg === "--dry-run") {
      options.dryRun = true;
    } else if (arg === "--yes") {
      options.yes = true;
    } else if (arg === "--non-interactive") {
      options.nonInteractive = true;
    } else if (arg === "--force") {
      options.force = true;
    } else if (arg === "--help" || arg === "-h") {
      options.command = "help";
    } else if (arg === "--version" || arg === "-v") {
      options.command = "version";
    } else {
      throw new Error(`unknown option: ${arg}`);
    }
  }
  options.agents = [
    ...new Set(options.agents.map((value) => value.trim().toLowerCase()).filter(Boolean)),
  ];
  const unsupported = options.agents.filter(
    (agent) => !SUPPORTED_AGENTS.includes(agent),
  );
  if (unsupported.length) {
    throw new Error(`unsupported agent: ${unsupported.join(", ")}`);
  }
  return options;
}
