import { strFromU8, strToU8, unzipSync, zipSync, type Zippable } from "fflate";

/** Reads every file in a ZIP archive. Throws for anything that isn't one. */
export function readZip(bytes: Uint8Array): Map<string, Uint8Array> {
  const entries = unzipSync(bytes);
  const map = new Map<string, Uint8Array>();
  for (const [path, data] of Object.entries(entries)) if (!path.endsWith("/")) map.set(path, data);
  return map;
}

/**
 * Writes a ZIP archive in entry order. Entries listed in `stored` are kept
 * uncompressed (a `mimetype` entry must be, and must come first).
 */
export function writeZip(entries: [string, Uint8Array | string][], stored: string[] = []): Uint8Array {
  const files: Zippable = {};
  for (const [path, data] of entries) {
    const bytes = typeof data === "string" ? strToU8(data) : data;
    files[path] = [bytes, { level: stored.includes(path) ? 0 : 6 }];
  }
  return zipSync(files, { mtime: new Date() });
}

export const utf8 = (bytes: Uint8Array) => strFromU8(bytes);
export const toUTF8 = (text: string) => strToU8(text);

export const isZip = (bytes: Uint8Array) => bytes.length > 4 && bytes[0] === 0x50 && bytes[1] === 0x4b && (bytes[2] === 3 || bytes[2] === 5);
