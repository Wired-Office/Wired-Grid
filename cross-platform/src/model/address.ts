/** The size of a worksheet, matching Excel's limits. */
export const MAX_ROWS = 1_048_576;
export const MAX_COLUMNS = 16_384;

/** A zero-based cell position. `A1` is row 0, column 0. */
export interface CellAddress {
  row: number;
  column: number;
}

export const addr = (row: number, column: number): CellAddress => ({ row, column });

/** A number key for maps of cells (row-major, so sorting keys sorts addresses). */
export const cellKey = (row: number, column: number) => row * MAX_COLUMNS + column;
export const keyRow = (key: number) => Math.floor(key / MAX_COLUMNS);
export const keyColumn = (key: number) => key % MAX_COLUMNS;
export const keyAddress = (key: number): CellAddress => ({ row: keyRow(key), column: keyColumn(key) });

export const isValidAddress = (a: CellAddress) => a.row >= 0 && a.column >= 0 && a.row < MAX_ROWS && a.column < MAX_COLUMNS;
export const sameAddress = (a: CellAddress, b: CellAddress) => a.row === b.row && a.column === b.column;
export const compareAddress = (a: CellAddress, b: CellAddress) => (a.row !== b.row ? a.row - b.row : a.column - b.column);

export function clampAddress(a: CellAddress): CellAddress {
  return { row: Math.min(Math.max(a.row, 0), MAX_ROWS - 1), column: Math.min(Math.max(a.column, 0), MAX_COLUMNS - 1) };
}

/** "A", "Z", "AA", … for a zero-based column index. */
export function columnName(index: number): string {
  let n = index + 1;
  let name = "";
  while (n > 0) {
    const remainder = (n - 1) % 26;
    name = String.fromCharCode(65 + remainder) + name;
    n = Math.floor((n - 1) / 26);
  }
  return name;
}

/** Zero-based column index for "A", "aa", …; null for anything else. */
export function columnIndex(name: string): number | null {
  if (!name || name.length > 3) return null;
  let value = 0;
  for (const ch of name.toUpperCase()) {
    const code = ch.charCodeAt(0);
    if (code < 65 || code > 90) return null;
    value = value * 26 + (code - 64);
  }
  const index = value - 1;
  return index < MAX_COLUMNS ? index : null;
}

/** "B7" */
export const a1 = (a: CellAddress) => columnName(a.column) + String(a.row + 1);

/** Parses "B7" or "$B$7". */
export function parseA1(text: string): CellAddress | null {
  const m = /^([A-Za-z]{1,3})(\d{1,7})$/.exec(text.replace(/\$/g, ""));
  if (!m) return null;
  const column = columnIndex(m[1]);
  const row = Number(m[2]);
  if (column === null || row < 1 || row > MAX_ROWS) return null;
  return { row: row - 1, column };
}

/** An inclusive rectangle of cells, always normalized (start ≤ end). */
export interface CellRange {
  start: CellAddress;
  end: CellAddress;
}

export function range(a: CellAddress, b: CellAddress = a): CellRange {
  return {
    start: { row: Math.min(a.row, b.row), column: Math.min(a.column, b.column) },
    end: { row: Math.max(a.row, b.row), column: Math.max(a.column, b.column) },
  };
}

export const rangeRC = (r1: number, c1: number, r2: number, c2: number) => range({ row: r1, column: c1 }, { row: r2, column: c2 });

export const rowCount = (r: CellRange) => r.end.row - r.start.row + 1;
export const columnCount = (r: CellRange) => r.end.column - r.start.column + 1;
export const cellCount = (r: CellRange) => rowCount(r) * columnCount(r);
export const isSingleCell = (r: CellRange) => sameAddress(r.start, r.end);
export const isWholeColumns = (r: CellRange) => r.start.row === 0 && r.end.row === MAX_ROWS - 1;
export const isWholeRows = (r: CellRange) => r.start.column === 0 && r.end.column === MAX_COLUMNS - 1;
export const wholeColumns = (c1: number, c2: number) => rangeRC(0, c1, MAX_ROWS - 1, c2);
export const wholeRows = (r1: number, r2: number) => rangeRC(r1, 0, r2, MAX_COLUMNS - 1);
export const ALL_CELLS = rangeRC(0, 0, MAX_ROWS - 1, MAX_COLUMNS - 1);

export const rangeContains = (r: CellRange, a: CellAddress) =>
  a.row >= r.start.row && a.row <= r.end.row && a.column >= r.start.column && a.column <= r.end.column;
export const rangeContainsRange = (r: CellRange, o: CellRange) => rangeContains(r, o.start) && rangeContains(r, o.end);
export const rangesIntersect = (a: CellRange, b: CellRange) =>
  a.start.row <= b.end.row && b.start.row <= a.end.row && a.start.column <= b.end.column && b.start.column <= a.end.column;
export const sameRange = (a: CellRange, b: CellRange) => sameAddress(a.start, b.start) && sameAddress(a.end, b.end);

export function intersection(a: CellRange, b: CellRange): CellRange | null {
  if (!rangesIntersect(a, b)) return null;
  return rangeRC(Math.max(a.start.row, b.start.row), Math.max(a.start.column, b.start.column), Math.min(a.end.row, b.end.row), Math.min(a.end.column, b.end.column));
}

export function union(a: CellRange, b: CellRange): CellRange {
  return rangeRC(Math.min(a.start.row, b.start.row), Math.min(a.start.column, b.start.column), Math.max(a.end.row, b.end.row), Math.max(a.end.column, b.end.column));
}

export const offsetRange = (r: CellRange, rows: number, columns: number) =>
  rangeRC(r.start.row + rows, r.start.column + columns, r.end.row + rows, r.end.column + columns);

/** Calls `body` for each cell, row by row. */
export function forEachCell(r: CellRange, body: (row: number, column: number) => void) {
  for (let row = r.start.row; row <= r.end.row; row++) for (let column = r.start.column; column <= r.end.column; column++) body(row, column);
}

/** "A1:C4", "A:A", "3:5" or "B2". */
export function rangeA1(r: CellRange): string {
  if (isWholeColumns(r) && !isWholeRows(r)) return columnName(r.start.column) + ":" + columnName(r.end.column);
  if (isWholeRows(r) && !isWholeColumns(r)) return `${r.start.row + 1}:${r.end.row + 1}`;
  return isSingleCell(r) ? a1(r.start) : a1(r.start) + ":" + a1(r.end);
}

/** Parses "A1", "A1:C4", "A:C" or "2:9" (dollar signs allowed). */
export function parseRange(text: string): CellRange | null {
  const parts = text.replace(/\$/g, "").split(":");
  if (parts.length === 1) {
    const a = parseA1(parts[0]);
    return a ? range(a) : null;
  }
  if (parts.length !== 2) return null;
  const a = parseA1(parts[0]), b = parseA1(parts[1]);
  if (a && b) return range(a, b);
  const c1 = columnIndex(parts[0]), c2 = columnIndex(parts[1]);
  if (c1 !== null && c2 !== null) return wholeColumns(Math.min(c1, c2), Math.max(c1, c2));
  if (/^\d+$/.test(parts[0]) && /^\d+$/.test(parts[1])) {
    const r1 = Number(parts[0]), r2 = Number(parts[1]);
    if (r1 >= 1 && r2 >= 1 && r1 <= MAX_ROWS && r2 <= MAX_ROWS) return wholeRows(Math.min(r1, r2) - 1, Math.max(r1, r2) - 1);
  }
  return null;
}

const isLetter = (ch: string) => /\p{L}/u.test(ch);
const isLetterOrNumber = (ch: string) => /[\p{L}\p{N}]/u.test(ch);

/** Quotes a sheet name for use in a formula when it needs it: `'My Sheet'!A1`. */
export function quotedSheetName(name: string): string {
  const chars = [...name];
  const plain = chars.length > 0 && (isLetter(chars[0]) || chars[0] === "_")
    && chars.every((c) => isLetterOrNumber(c) || c === "_" || c === ".")
    && parseRange(name) === null;
  return plain ? name : "'" + name.replace(/'/g, "''") + "'";
}
