import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { readPackageMetadata } from "../../src/installer/package.js";

test("runtime package metadata comes from the packaged package.json", async () => {
  const expected = JSON.parse(
    await readFile(new URL("../../package.json", import.meta.url), "utf8"),
  );
  const metadata = await readPackageMetadata();
  assert.deepEqual(metadata, {
    name: expected.name,
    version: expected.version,
  });
  assert.equal(metadata.version, "1.3.1");
});
