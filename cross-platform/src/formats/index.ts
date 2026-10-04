import type { Workbook } from "../model/workbook";
import { readDelimited, writeDelimited } from "./delimited";
import { FileFormatError, readGrid, writeGrid } from "./native";
import { readXLSX, writeXLSX } from "./xlsx";
import { isZip } from "./zip";

export type FormatID = "grid" | "xlsx" | "csv" | "tsv";

export interface FileFormat {
  id: FormatID;
  name: string;
  shortName: string;
  extensions: string[];
  /** Formats that keep only the active sheet's values. */
  flat: boolean;
}

/** The file types Wired Grid reads and writes. */
export const FORMATS: FileFormat[] = [
  { id: "grid", name: "Grid Workbook", shortName: "Grid", extensions: ["grid"], flat: false },
  { id: "xlsx", name: "Excel Workbook", shortName: "Excel", extensions: ["xlsx"], flat: false },
  { id: "csv", name: "CSV (Comma-Separated)", shortName: "CSV", extensions: ["csv"], flat: true },
  { id: "tsv", name: "Tab-Separated Text", shortName: "TSV", extensions: ["tsv", "tab", "txt"], flat: true },
];

export const formatById = (id: FormatID) => FORMATS.find((f) => f.id === id)!;

export function formatForName(name: string): FileFormat | null {
  const ext = name.split(".").pop()?.toLowerCase() ?? "";
  return FORMATS.find((f) => f.extensions.includes(ext)) ?? null;
}

/** Reads a file, picking the format from its name (or its contents when the name doesn't say). */
export function readWorkbook(name: string, bytes: Uint8Array): { workbook: Workbook; format: FormatID } {
  let format = formatForName(name)?.id;
  if (!format) {
    if (!isZip(bytes)) format = "csv";
    else {
      try {
        return { workbook: readGrid(bytes), format: "grid" };
      } catch {
        format = "xlsx";
      }
    }
  }
  switch (format) {
    case "grid": return { workbook: readGrid(bytes), format };
    case "xlsx": return { workbook: readXLSX(bytes), format };
    case "csv": return { workbook: readDelimited(bytes, ","), format };
    case "tsv": return { workbook: readDelimited(bytes, "\t"), format };
  }
}

export function writeWorkbook(workbook: Workbook, format: FormatID): Uint8Array {
  switch (format) {
    case "grid": return writeGrid(workbook);
    case "xlsx": return writeXLSX(workbook);
    case "csv": return writeDelimited(workbook, ",");
    case "tsv": return writeDelimited(workbook, "\t");
  }
}

export { FileFormatError };
