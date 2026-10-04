import { cellKey, rangeRC } from "../model/address";
import { DEFAULT_COLUMN_WIDTH, newSheet, numberFormatOf, styleAt, usedRange, type Cell, type Workbook } from "../model/workbook";
import { Calculator } from "../formula";
import { formatValue, general, GENERAL } from "../formula/numberFormat";
import { parseEntry } from "../formula/valueParser";
import { WorkbookController } from "../engine/controller";
import { toUTF8 } from "./zip";

/** Text in UTF-8 (with or without BOM), falling back to Windows-1252 like Excel. */
export function decodeText(bytes: Uint8Array): string {
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    text = new TextDecoder("windows-1252").decode(bytes);
  }
  return text.startsWith("﻿") ? text.slice(1) : text;
}

/** CSV and TSV: one sheet of values. */
export function readDelimited(bytes: Uint8Array, separator: string): Workbook {
  const rows = WorkbookController.parseDelimited(decodeText(bytes), separator);
  const sheet = newSheet("Sheet1");
  rows.forEach((row, r) => row.forEach((field, c) => {
    if (!field) return;
    if (field.startsWith("=") && field.length > 1) {
      try {
        sheet.cells.set(cellKey(r, c), { value: null, formula: WorkbookController.normalizeFormula(field.slice(1)) });
        return;
      } catch {
        // Not a formula after all; keep it as text below.
      }
    }
    const parsed = parseEntry(field);
    const cell: Cell = { value: parsed.value };
    if (parsed.format) cell.style = { numberFormat: parsed.format };
    sheet.cells.set(cellKey(r, c), cell);
  }));
  // Widen columns to fit their content, roughly.
  const used = usedRange(sheet);
  if (used && used.end.column - used.start.column < 200) {
    for (let column = used.start.column; column <= used.end.column; column++) {
      let widest = 0;
      for (let row = used.start.row; row <= Math.min(used.end.row, used.start.row + 499); row++) {
        const v = sheet.cells.get(cellKey(row, column))?.value;
        widest = Math.max(widest, v === null || v === undefined ? 0 : [...formatValue(v, GENERAL).text].length);
      }
      const width = Math.min(Math.max(widest, 4), 60) * 7.5 + 12;
      if (width > DEFAULT_COLUMN_WIDTH) sheet.columnWidths.set(column, width);
    }
  }
  return { sheets: [sheet], activeSheetIndex: 0, names: [], author: "", created: new Date() };
}

/** The active sheet's displayed values. */
export function writeDelimited(workbook: Workbook, separator: string): Uint8Array {
  const calculator = new Calculator(workbook);
  calculator.recalculate();
  const index = workbook.activeSheetIndex;
  const sheet = workbook.sheets[index];
  const used = usedRange(sheet);
  if (!used) return new Uint8Array();
  const area = rangeRC(0, 0, used.end.row, used.end.column);
  const lines: string[] = [];
  for (let row = 0; row <= area.end.row; row++) {
    const fields: string[] = [];
    for (let column = 0; column <= area.end.column; column++) {
      const value = calculator.value(index, row, column);
      const format = numberFormatOf(styleAt(sheet, row, column));
      let text = typeof value === "number" && format === GENERAL ? general(value, 17) : formatValue(value, format).text;
      if (text.includes(separator) || /["\n\r]/.test(text)) text = '"' + text.replace(/"/g, '""') + '"';
      fields.push(text);
    }
    lines.push(fields.join(separator));
  }
  return toUTF8(lines.join("\r\n") + "\r\n");
}
