import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";

export async function readJsonObject(file, fallback = {}) {
  try {
    const value = JSON.parse(await readFile(file, "utf8"));
    if (!value || Array.isArray(value) || typeof value !== "object") {
      throw new Error("root must be an object");
    }
    return value;
  } catch (error) {
    if (error.code === "ENOENT") return structuredClone(fallback);
    throw new Error(`invalid existing JSON; refusing to overwrite ${file}: ${error.message}`);
  }
}

export async function writeJson(file, value, dryRun = false) {
  if (dryRun) return;
  await mkdir(path.dirname(file), { recursive: true });
  await writeFile(file, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

export function replaceMatchingHook(config, event, hook, matches) {
  config.hooks ||= {};
  const groups = Array.isArray(config.hooks[event]) ? config.hooks[event] : [];
  const retained = [];
  for (const group of groups) {
    if (!Array.isArray(group?.hooks)) {
      retained.push(group);
      continue;
    }
    const hooks = group.hooks.filter((entry) => !matches(entry));
    if (hooks.length) retained.push({ ...group, hooks });
  }
  retained.push({ hooks: [hook] });
  config.hooks[event] = retained;
}
