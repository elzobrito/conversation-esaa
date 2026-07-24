import { createHash } from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";

export async function sha256(file) {
  const content = await readFile(file);
  return createHash("sha256").update(content).digest("hex");
}

export async function writeJsonAtomic(file, value) {
  await mkdir(path.dirname(file), { recursive: true });
  const temporary = `${file}.${process.pid}.tmp`;
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, {
    encoding: "utf8",
    mode: 0o600,
  });
  await rename(temporary, file);
}

export function workspaceRelative(workspace, file) {
  const relative = path.relative(workspace, file).split(path.sep).join("/");
  if (!relative || relative === ".." || relative.startsWith("../")) {
    throw new Error(`path escapes workspace: ${file}`);
  }
  return relative;
}
