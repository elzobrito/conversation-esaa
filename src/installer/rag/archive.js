import { inflateRawSync } from "node:zlib";
import { mkdir, writeFile, chmod } from "node:fs/promises";
import path from "node:path";

const EOCD = 0x06054b50;
const CENTRAL = 0x02014b50;
const LOCAL = 0x04034b50;

function unsafeName(name) {
  const normalized = name.replaceAll("\\", "/");
  return (
    normalized.startsWith("/") ||
    /^[A-Za-z]:\//.test(normalized) ||
    normalized.split("/").includes("..")
  );
}

export function inspectZip(buffer) {
  let eocd = -1;
  const lower = Math.max(0, buffer.length - 65_557);
  for (let offset = buffer.length - 22; offset >= lower; offset -= 1) {
    if (buffer.readUInt32LE(offset) === EOCD) {
      eocd = offset;
      break;
    }
  }
  if (eocd < 0) throw new Error("invalid ZIP: end record not found");
  const count = buffer.readUInt16LE(eocd + 10);
  let offset = buffer.readUInt32LE(eocd + 16);
  const entries = [];
  for (let index = 0; index < count; index += 1) {
    if (buffer.readUInt32LE(offset) !== CENTRAL) {
      throw new Error("invalid ZIP central directory");
    }
    const madeBy = buffer.readUInt16LE(offset + 4);
    const compression = buffer.readUInt16LE(offset + 10);
    const compressedSize = buffer.readUInt32LE(offset + 20);
    const size = buffer.readUInt32LE(offset + 24);
    const nameLength = buffer.readUInt16LE(offset + 28);
    const extraLength = buffer.readUInt16LE(offset + 30);
    const commentLength = buffer.readUInt16LE(offset + 32);
    const external = buffer.readUInt32LE(offset + 38);
    const localOffset = buffer.readUInt32LE(offset + 42);
    const name = buffer
      .subarray(offset + 46, offset + 46 + nameLength)
      .toString("utf8");
    const unixMode = madeBy >> 8 === 3 ? external >>> 16 : 0;
    if (
      unsafeName(name) ||
      (unixMode & 0o170000) === 0o120000 ||
      (compression !== 0 && compression !== 8)
    ) {
      throw new Error(`unsafe ZIP entry: ${name}`);
    }
    entries.push({ name, compression, compressedSize, size, localOffset, unixMode });
    offset += 46 + nameLength + extraLength + commentLength;
  }
  return entries;
}

export async function extractZip(buffer, destination) {
  const entries = inspectZip(buffer);
  for (const entry of entries) {
    if (entry.name.endsWith("/")) continue;
    if (buffer.readUInt32LE(entry.localOffset) !== LOCAL) {
      throw new Error(`invalid ZIP local header: ${entry.name}`);
    }
    const nameLength = buffer.readUInt16LE(entry.localOffset + 26);
    const extraLength = buffer.readUInt16LE(entry.localOffset + 28);
    const start = entry.localOffset + 30 + nameLength + extraLength;
    const compressed = buffer.subarray(start, start + entry.compressedSize);
    const content =
      entry.compression === 8 ? inflateRawSync(compressed) : Buffer.from(compressed);
    if (content.length !== entry.size) {
      throw new Error(`invalid ZIP size: ${entry.name}`);
    }
    const target = path.resolve(destination, ...entry.name.replaceAll("\\", "/").split("/"));
    const boundary = `${path.resolve(destination)}${path.sep}`;
    if (!target.startsWith(boundary)) throw new Error(`unsafe ZIP target: ${entry.name}`);
    await mkdir(path.dirname(target), { recursive: true });
    await writeFile(target, content, { mode: entry.unixMode & 0o777 || 0o644 });
    if (entry.unixMode & 0o111) await chmod(target, entry.unixMode & 0o777);
  }
  return entries;
}
