import { readFile } from "node:fs/promises";

const packageFile = new URL("../../package.json", import.meta.url);
let cachedMetadata;

export async function readPackageMetadata() {
  if (!cachedMetadata) {
    const value = JSON.parse(await readFile(packageFile, "utf8"));
    if (
      value?.name !== "conversation-esaa" ||
      typeof value?.version !== "string" ||
      !value.version.trim()
    ) {
      throw new Error("package.json has invalid conversation-esaa metadata");
    }
    cachedMetadata = Object.freeze({
      name: value.name,
      version: value.version,
    });
  }
  return cachedMetadata;
}
