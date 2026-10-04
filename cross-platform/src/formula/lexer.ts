import { MAX_COLUMNS, MAX_ROWS, columnIndex, columnName, quotedSheetName, wholeColumns, wholeRows, range, type CellRange } from "../model/address";
import { FormulaError } from "../model/values";

/** A cell reference as written in a formula, e.g. `Sheet2!$B$4`. */
export interface CellReference {
  sheet?: string;
  row: number;
  column: number;
  rowAbsolute: boolean;
  columnAbsolute: boolean;
}

export function referenceText(r: CellReference, includeSheet = true): string {
  let s = "";
  if (includeSheet && r.sheet !== undefined) s += quotedSheetName(r.sheet) + "!";
  s += (r.columnAbsolute ? "$" : "") + columnName(r.column);
  s += (r.rowAbsolute ? "$" : "") + String(r.row + 1);
  return s;
}

/** A rectangular reference: `A1:B9`, `A:A` or `3:4`. */
export interface RangeReference {
  sheet?: string;
  kind: "cells" | "columns" | "rows";
  start: CellReference;
  end: CellReference;
}

export function referenceRange(r: RangeReference): CellRange {
  switch (r.kind) {
    case "cells": return range({ row: r.start.row, column: r.start.column }, { row: r.end.row, column: r.end.column });
    case "columns": return wholeColumns(Math.min(r.start.column, r.end.column), Math.max(r.start.column, r.end.column));
    case "rows": return wholeRows(Math.min(r.start.row, r.end.row), Math.max(r.start.row, r.end.row));
  }
}

export function rangeReferenceText(r: RangeReference): string {
  const prefix = r.sheet !== undefined ? quotedSheetName(r.sheet) + "!" : "";
  switch (r.kind) {
    case "cells":
      return prefix + referenceText(r.start, false) + ":" + referenceText(r.end, false);
    case "columns":
      return prefix + (r.start.columnAbsolute ? "$" : "") + columnName(r.start.column) + ":" + (r.end.columnAbsolute ? "$" : "") + columnName(r.end.column);
    case "rows":
      return prefix + (r.start.rowAbsolute ? "$" : "") + String(r.start.row + 1) + ":" + (r.end.rowAbsolute ? "$" : "") + String(r.end.row + 1);
  }
}

export type TokenKind =
  | { t: "number"; value: number }
  | { t: "string"; value: string }
  | { t: "bool"; value: boolean }
  | { t: "error"; value: FormulaError }
  | { t: "cell"; ref: CellReference }
  | { t: "range"; ref: RangeReference }
  /** A function name (always followed by "("). */
  | { t: "function"; name: string }
  /** A defined name or unknown identifier. */
  | { t: "name"; name: string }
  | { t: "op"; op: string }
  | { t: "(" } | { t: ")" } | { t: "," } | { t: ";" } | { t: "{" } | { t: "}" }
  | { t: "space" };

export interface FormulaToken {
  kind: TokenKind;
  /** Where the token sits in the source, in UTF-16 offsets. */
  start: number;
  length: number;
  text: string;
}

const isDigit = (c: number) => c >= 48 && c <= 57;
const isLetter = (c: number) => (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
export const isIdentifierStart = (c: number) => isLetter(c) || c === 95 || c === 92 || c > 127;
export const isIdentifierChar = (c: number) => isIdentifierStart(c) || isDigit(c) || c === 46;

const ERRORS_BY_LENGTH = [...FormulaError.all].sort((a, b) => b.code.length - a.code.length);

/** Splits formula text into tokens. The input excludes the leading "=". Throws a FormulaError when it can't. */
export function tokenize(source: string): FormulaToken[] {
  const n = source.length;
  const code = (i: number) => (i < n ? source.charCodeAt(i) : -1);
  const tokens: FormulaToken[] = [];
  let i = 0;
  const add = (kind: TokenKind, start: number) => tokens.push({ kind, start, length: i - start, text: source.slice(start, i) });
  const box = { i: 0 };
  const scan = (sheet: string | undefined) => {
    box.i = i;
    const kind = scanReference(source, box, sheet);
    if (kind) i = box.i;
    return kind;
  };

  while (i < n) {
    const start = i;
    const c = code(i);

    // Whitespace
    if (c === 32 || c === 9 || c === 10 || c === 13) {
      while ([32, 9, 10, 13].includes(code(i))) i++;
      add({ t: "space" }, start);
      continue;
    }

    // String literal
    if (c === 34) {
      i++;
      let value = "";
      let closed = false;
      while (i < n) {
        if (code(i) === 34) {
          if (code(i + 1) === 34) { value += '"'; i += 2; continue; }
          i++;
          closed = true;
          break;
        }
        const segment = i;
        while (i < n && code(i) !== 34) i++;
        value += source.slice(segment, i);
      }
      if (!closed) throw FormulaError.value;
      add({ t: "string", value }, start);
      continue;
    }

    // Error literal
    if (c === 35) {
      const rest = source.slice(i).toUpperCase();
      const error = ERRORS_BY_LENGTH.find((e) => rest.startsWith(e.code));
      if (!error) throw FormulaError.name;
      i += error.code.length;
      add({ t: "error", value: error }, start);
      continue;
    }

    // Quoted sheet name: 'My Sheet'!A1
    if (c === 39) {
      i++;
      let name = "";
      while (i < n) {
        if (code(i) === 39) {
          if (code(i + 1) === 39) { name += "'"; i += 2; continue; }
          break;
        }
        name += source[i];
        i++;
      }
      if (code(i) !== 39 || code(i + 1) !== 33) throw FormulaError.ref;
      i += 2;
      const kind = scan(name);
      if (!kind) throw FormulaError.ref;
      add(kind, start);
      continue;
    }

    // Number (or a row range like 3:5)
    if (isDigit(c) || (c === 46 && isDigit(code(i + 1)))) {
      const save = i;
      const kind = scan(undefined);
      if (kind && kind.t === "range") {
        add(kind, start);
        continue;
      }
      i = save;
      while (isDigit(code(i))) i++;
      if (code(i) === 46) { i++; while (isDigit(code(i))) i++; }
      const e = code(i), next = code(i + 1);
      if ((e === 69 || e === 101) && (isDigit(next) || ((next === 43 || next === 45) && isDigit(code(i + 2))))) {
        i += 2;
        while (isDigit(code(i))) i++;
      }
      const value = Number(source.slice(start, i));
      if (Number.isNaN(value)) throw FormulaError.value;
      add({ t: "number", value }, start);
      continue;
    }

    // Identifier, reference or function
    if (isIdentifierStart(c) || c === 36) {
      const save = i;
      while (isIdentifierChar(code(i)) || code(i) === 36) i++;
      const word = source.slice(start, i);
      if (code(i) === 33 && !word.includes("$")) { // Sheet!Ref
        i++;
        const kind = scan(word);
        if (!kind) throw FormulaError.ref;
        add(kind, start);
        continue;
      }
      if (code(i) === 40 && !word.includes("$")) { // (
        add({ t: "function", name: word.toUpperCase() }, start);
        continue;
      }
      i = save;
      const kind = scan(undefined);
      if (kind) {
        // A reference must not run into more identifier characters (e.g. "A1B").
        if (isIdentifierChar(code(i))) {
          i = save;
        } else {
          add(kind, start);
          continue;
        }
      }
      i = save;
      while (isIdentifierChar(code(i))) i++;
      if (i === start) throw FormulaError.name;
      const name = source.slice(start, i);
      const upper = name.toUpperCase();
      if (upper === "TRUE") add({ t: "bool", value: true }, start);
      else if (upper === "FALSE") add({ t: "bool", value: false }, start);
      else add({ t: "name", name }, start);
      continue;
    }

    // Operators and punctuation
    i++;
    switch (c) {
      case 40: add({ t: "(" }, start); break;
      case 41: add({ t: ")" }, start); break;
      case 44: add({ t: "," }, start); break;
      case 59: add({ t: ";" }, start); break;
      case 123: add({ t: "{" }, start); break;
      case 125: add({ t: "}" }, start); break;
      case 60: // <
        if (code(i) === 61 || code(i) === 62) i++;
        add({ t: "op", op: source.slice(start, i) }, start);
        break;
      case 62: // >
        if (code(i) === 61) i++;
        add({ t: "op", op: source.slice(start, i) }, start);
        break;
      case 43: case 45: case 42: case 47: case 94: case 38: case 61: case 37: case 58:
        add({ t: "op", op: source.slice(start, i) }, start);
        break;
      default:
        throw FormulaError.name;
    }
  }
  return tokens;
}

// MARK: - References

/** Scans a cell, cell range, column range or row range at `box.i`. */
function scanReference(s: string, box: { i: number }, sheet: string | undefined): TokenKind | null {
  const start = box.i;
  const first = scanCell(s, box);
  if (first) {
    const afterFirst = box.i;
    if (s.charCodeAt(box.i) === 58) {
      box.i++;
      const second = scanCell(s, box);
      if (second) {
        return { t: "range", ref: { sheet, kind: "cells", start: { ...first, sheet }, end: { ...second, sheet } } };
      }
    }
    box.i = afterFirst;
    return { t: "cell", ref: { ...first, sheet } };
  }
  box.i = start;
  // Column range A:C
  const c1 = scanColumn(s, box);
  if (c1 && s.charCodeAt(box.i) === 58) {
    box.i++;
    const c2 = scanColumn(s, box);
    if (c2) {
      const a: CellReference = { sheet, row: 0, column: c1[0], rowAbsolute: true, columnAbsolute: c1[1] };
      const b: CellReference = { sheet, row: MAX_ROWS - 1, column: c2[0], rowAbsolute: true, columnAbsolute: c2[1] };
      return { t: "range", ref: { sheet, kind: "columns", start: a, end: b } };
    }
  }
  box.i = start;
  // Row range 3:5
  const r1 = scanRow(s, box);
  if (r1 && s.charCodeAt(box.i) === 58) {
    box.i++;
    const r2 = scanRow(s, box);
    if (r2) {
      const a: CellReference = { sheet, row: r1[0], column: 0, rowAbsolute: r1[1], columnAbsolute: true };
      const b: CellReference = { sheet, row: r2[0], column: MAX_COLUMNS - 1, rowAbsolute: r2[1], columnAbsolute: true };
      return { t: "range", ref: { sheet, kind: "rows", start: a, end: b } };
    }
  }
  box.i = start;
  return null;
}

function scanCell(s: string, box: { i: number }): CellReference | null {
  const start = box.i;
  const column = scanColumn(s, box);
  const row = column ? scanRow(s, box) : null;
  if (!column || !row) { box.i = start; return null; }
  const c = box.i < s.length ? s.charCodeAt(box.i) : -1;
  if (c >= 0 && (isIdentifierChar(c) || c === 40)) { box.i = start; return null; }
  return { row: row[0], column: column[0], rowAbsolute: row[1], columnAbsolute: column[1] };
}

function scanColumn(s: string, box: { i: number }): [number, boolean] | null {
  const start = box.i;
  let absolute = false;
  if (s.charCodeAt(box.i) === 36) { absolute = true; box.i++; }
  const lettersStart = box.i;
  while (box.i < s.length && isLetter(s.charCodeAt(box.i)) && box.i - lettersStart < 4) box.i++;
  const letters = s.slice(lettersStart, box.i);
  const column = letters.length >= 1 && letters.length <= 3 ? columnIndex(letters) : null;
  if (column === null) { box.i = start; return null; }
  return [column, absolute];
}

function scanRow(s: string, box: { i: number }): [number, boolean] | null {
  const start = box.i;
  let absolute = false;
  if (s.charCodeAt(box.i) === 36) { absolute = true; box.i++; }
  const digitsStart = box.i;
  while (box.i < s.length && isDigit(s.charCodeAt(box.i))) box.i++;
  const digits = box.i - digitsStart;
  const row = Number(s.slice(digitsStart, box.i));
  if (digits === 0 || digits > 7 || row < 1 || row > MAX_ROWS) { box.i = start; return null; }
  return [row - 1, absolute];
}
