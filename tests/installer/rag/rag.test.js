import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { deflateRawSync } from "node:zlib";
import test from "node:test";
import { inspectZip } from "../../../src/installer/rag/archive.js";
import { setupRag, validateSchema } from "../../../src/installer/rag/index.js";

function zipEntry(name, content = "x") {
  const nameBytes = Buffer.from(name);
  const plain = Buffer.from(content);
  const compressed = deflateRawSync(plain);
  const local = Buffer.alloc(30);
  local.writeUInt32LE(0x04034b50, 0);
  local.writeUInt16LE(20, 4);
  local.writeUInt16LE(8, 8);
  local.writeUInt32LE(compressed.length, 18);
  local.writeUInt32LE(plain.length, 22);
  local.writeUInt16LE(nameBytes.length, 26);
  const central = Buffer.alloc(46);
  central.writeUInt32LE(0x02014b50, 0);
  central.writeUInt16LE(0x0314, 4);
  central.writeUInt16LE(20, 6);
  central.writeUInt16LE(8, 10);
  central.writeUInt32LE(compressed.length, 20);
  central.writeUInt32LE(plain.length, 24);
  central.writeUInt16LE(nameBytes.length, 28);
  central.writeUInt32LE((0o100644 << 16) >>> 0, 38);
  const centralOffset = local.length + nameBytes.length + compressed.length;
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(1, 8);
  eocd.writeUInt16LE(1, 10);
  eocd.writeUInt32LE(central.length + nameBytes.length, 12);
  eocd.writeUInt32LE(centralOffset, 16);
  return Buffer.concat([
    local,
    nameBytes,
    compressed,
    central,
    nameBytes,
    eocd,
  ]);
}

test("ZIP validation rejects traversal and symbolic links", () => {
  assert.throws(() => inspectZip(zipEntry("../escape")), /unsafe ZIP entry/);
  const symlink = zipEntry("bundle/link");
  const central = symlink.indexOf(Buffer.from([0x50, 0x4b, 0x01, 0x02]));
  symlink.writeUInt32LE((0o120777 << 16) >>> 0, central + 38);
  assert.throws(() => inspectZip(symlink), /unsafe ZIP entry/);
});

test("managed mode rejects checksum mismatch before extraction", async () => {
  const archive = zipEntry("rag-sqlite-v0.1.0/rag-sqlite", "runtime");
  const fakeFetch = async () => ({
    ok: true,
    status: 200,
    arrayBuffer: async () => archive,
  });
  await assert.rejects(
    setupRag(
      { workspace: "/tmp/workspace", rag: "managed", dryRun: false },
      { fetch: fakeFetch, dataRoot: "/tmp/unused" },
    ),
    /checksum mismatch/,
  );
});

test("existing mode validates the schema without replacing the command", async () => {
  const command = "/opt/rag-sqlite";
  const spawnSync = (executable, args) => {
    assert.equal(executable, command);
    assert.deepEqual(args, ["--compact", "schema", "query"]);
    return {
      status: 0,
      stdout: JSON.stringify({
        schema_version: "rag_sqlite.schema.v1",
        ok: true,
      }),
      stderr: "",
    };
  };
  const schema = validateSchema(command, { spawnSync });
  assert.equal(schema.ok, true);
});

test("invalid schema is rejected", () => {
  assert.throws(
    () => validateSchema("/opt/rag-sqlite", {
      spawnSync: () => ({
        status: 0,
        stdout: JSON.stringify({ schema_version: "wrong", ok: true }),
        stderr: "",
      }),
    }),
    /invalid rag-sqlite schema response/,
  );
});
