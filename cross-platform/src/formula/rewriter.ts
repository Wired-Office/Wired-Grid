import { MAX_COLUMNS, MAX_ROWS, isValidAddress, isWholeColumns, isWholeRows, quotedSheetName, rangeContains, rangeContainsRange, rangeRC, sameRange, type CellAddress, type CellRange } from "../model/address";
import { sameName } from "../model/workbook";
import { rangeReferenceText, referenceRange, referenceText, tokenize, type CellReference, type TokenKind } from "./lexer";

/** A row/column insertion or deletion on one sheet. */
export type StructuralChange =
  | { kind: "insertRows"; at: number; count: number }
  | { kind: "deleteRows"; at: number; count: number }
  | { kind: "insertColumns"; at: number; count: number }
  | { kind: "deleteColumns"; at: number; count: number };

export const affectsRows = (c: StructuralChange) => c.kind === "insertRows" || c.kind === "deleteRows";
const isInsert = (c: StructuralChange) => c.kind === "insertRows" || c.kind === "insertColumns";

/** Where an index along the changed axis moves to; null if it was deleted. */
export function mapIndex(c: StructuralChange, index: number): number | null {
  if (isInsert(c)) return index >= c.at ? index + c.count : index;
  if (index < c.at) return index;
  if (index < c.at + c.count) return null;
  return index - c.count;
}

function mapSpan(c: StructuralChange, low: number, high: number): [number, number] | null {
  if (isInsert(c)) return [low >= c.at ? low + c.count : low, high >= c.at ? high + c.count : high];
  const newLow = low < c.at ? low : low < c.at + c.count ? c.at : low - c.count;
  const newHigh = high < c.at ? high : high < c.at + c.count ? c.at - 1 : high - c.count;
  return newHigh >= newLow ? [newLow, newHigh] : null;
}

export function mapAddress(c: StructuralChange, a: CellAddress): CellAddress | null {
  if (affectsRows(c)) {
    const row = mapIndex(c, a.row);
    return row === null ? null : { row, column: a.column };
  }
  const column = mapIndex(c, a.column);
  return column === null ? null : { row: a.row, column };
}

/** A range after the change: it grows, shrinks or disappears. */
export function mapRange(c: StructuralChange, r: CellRange): CellRange | null {
  if (affectsRows(c)) {
    if (!isWholeRows(r) && isWholeColumns(r)) return r;
    const span = mapSpan(c, r.start.row, r.end.row);
    if (!span || span[0] >= MAX_ROWS) return null;
    return rangeRC(span[0], r.start.column, Math.min(span[1], MAX_ROWS - 1), r.end.column);
  }
  if (!isWholeColumns(r) && isWholeRows(r)) return r;
  const span = mapSpan(c, r.start.column, r.end.column);
  if (!span || span[0] >= MAX_COLUMNS) return null;
  return rangeRC(r.start.row, span[0], r.end.row, Math.min(span[1], MAX_COLUMNS - 1));
}

/** Replaces every cell or range token using `transform`, which returns new text (or null to keep it). */
export function rewrite(formula: string, transform: (kind: Extract<TokenKind, { t: "cell" } | { t: "range" }>) => string | null): string {
  let tokens;
  try {
    tokens = tokenize(formula);
  } catch {
    return formula;
  }
  let result = "";
  for (const token of tokens) {
    if (token.kind.t === "cell" || token.kind.t === "range") result += transform(token.kind) ?? token.text;
    else result += token.text;
  }
  return result;
}

const refError = (sheet: string | undefined) => (sheet !== undefined ? quotedSheetName(sheet) + "!" : "") + "#REF!";

/** Copying a formula: relative references move by the offset. */
export function shiftFormula(formula: string, rows: number, columns: number): string {
  if (rows === 0 && columns === 0) return formula;
  return rewrite(formula, (kind) => {
    if (kind.t === "cell") {
      const r = { ...kind.ref };
      if (!r.rowAbsolute) r.row += rows;
      if (!r.columnAbsolute) r.column += columns;
      if (!isValidAddress(r)) return refError(r.sheet);
      return referenceText(r);
    }
    const r = { ...kind.ref, start: { ...kind.ref.start }, end: { ...kind.ref.end } };
    switch (r.kind) {
      case "cells":
        if (!r.start.rowAbsolute) r.start.row += rows;
        if (!r.start.columnAbsolute) r.start.column += columns;
        if (!r.end.rowAbsolute) r.end.row += rows;
        if (!r.end.columnAbsolute) r.end.column += columns;
        if (!isValidAddress(r.start) || !isValidAddress(r.end)) return refError(r.sheet);
        break;
      case "columns":
        if (!r.start.columnAbsolute) r.start.column += columns;
        if (!r.end.columnAbsolute) r.end.column += columns;
        if (r.start.column < 0 || r.end.column < 0 || r.start.column >= MAX_COLUMNS || r.end.column >= MAX_COLUMNS) return refError(r.sheet);
        break;
      case "rows":
        if (!r.start.rowAbsolute) r.start.row += rows;
        if (!r.end.rowAbsolute) r.end.row += rows;
        if (r.start.row < 0 || r.end.row < 0 || r.start.row >= MAX_ROWS || r.end.row >= MAX_ROWS) return refError(r.sheet);
        break;
    }
    return rangeReferenceText(r);
  });
}

const applies = (referenced: string | undefined, formulaSheet: string, targetSheet: string) => sameName(referenced ?? formulaSheet, targetSheet);

/** Inserting or deleting rows/columns on `targetSheet`, for a formula living on `formulaSheet`. */
export function adjustFormula(formula: string, formulaSheet: string, targetSheet: string, change: StructuralChange): string {
  return rewrite(formula, (kind) => {
    if (kind.t === "cell") {
      const r = kind.ref;
      if (!applies(r.sheet, formulaSheet, targetSheet)) return null;
      const moved = mapAddress(change, r);
      if (!moved) return refError(r.sheet);
      if (moved.row === r.row && moved.column === r.column) return null;
      return referenceText({ ...r, row: moved.row, column: moved.column });
    }
    const r = kind.ref;
    if (!applies(r.sheet, formulaSheet, targetSheet)) return null;
    if (r.kind === "columns" && affectsRows(change)) return null;
    if (r.kind === "rows" && !affectsRows(change)) return null;
    const original = referenceRange(r);
    const moved = mapRange(change, original);
    if (!moved) return refError(r.sheet);
    if (sameRange(moved, original)) return null;
    const start = { ...r.start }, end = { ...r.end };
    if (r.kind !== "columns") { start.row = moved.start.row; end.row = moved.end.row; }
    if (r.kind !== "rows") { start.column = moved.start.column; end.column = moved.end.column; }
    return rangeReferenceText({ ...r, start, end });
  });
}

/** Cut and paste: references into `source` on `sheet` follow the cells to their new place. */
export function moveFormula(formula: string, formulaSheet: string, sheet: string, source: CellRange, rows: number, columns: number): string {
  return rewrite(formula, (kind) => {
    if (kind.t === "cell") {
      const r = kind.ref;
      if (!applies(r.sheet, formulaSheet, sheet) || !rangeContains(source, r)) return null;
      return referenceText({ ...r, row: r.row + rows, column: r.column + columns });
    }
    const r = kind.ref;
    if (r.kind !== "cells" || !applies(r.sheet, formulaSheet, sheet) || !rangeContainsRange(source, referenceRange(r))) return null;
    return rangeReferenceText({
      ...r,
      start: { ...r.start, row: r.start.row + rows, column: r.start.column + columns },
      end: { ...r.end, row: r.end.row + rows, column: r.end.column + columns },
    });
  });
}

/** Renaming a sheet updates every reference to it. */
export function renameSheetInFormula(formula: string, oldName: string, newName: string): string {
  return rewrite(formula, (kind) => {
    const r = kind.ref;
    if (r.sheet === undefined || !sameName(r.sheet, oldName)) return null;
    if (kind.t === "cell") return referenceText({ ...kind.ref, sheet: newName });
    return rangeReferenceText({ ...kind.ref, sheet: newName, start: { ...kind.ref.start, sheet: newName }, end: { ...kind.ref.end, sheet: newName } });
  });
}

/** Deleting a sheet turns references to it into #REF!. */
export function removeSheetFromFormula(formula: string, name: string): string {
  return rewrite(formula, (kind) => (kind.ref.sheet !== undefined && sameName(kind.ref.sheet, name) ? "#REF!" : null));
}

/** Cycles the reference under the caret through $A$1 → A$1 → $A1 → A1 (the F4 key). */
export function toggleAbsolute(formula: string, caret: number): { text: string; start: number; length: number } | null {
  let tokens;
  try {
    tokens = tokenize(formula);
  } catch {
    return null;
  }
  const cycle = (r: CellReference): CellReference => {
    if (!r.columnAbsolute && !r.rowAbsolute) return { ...r, columnAbsolute: true, rowAbsolute: true };
    if (r.columnAbsolute && r.rowAbsolute) return { ...r, columnAbsolute: false, rowAbsolute: true };
    if (!r.columnAbsolute && r.rowAbsolute) return { ...r, columnAbsolute: true, rowAbsolute: false };
    return { ...r, columnAbsolute: false, rowAbsolute: false };
  };
  for (const token of tokens) {
    if (!(token.start <= caret && caret <= token.start + token.length)) continue;
    let replacement: string;
    if (token.kind.t === "cell") {
      replacement = referenceText(cycle(token.kind.ref));
    } else if (token.kind.t === "range") {
      const start = cycle(token.kind.ref.start);
      const end = { ...token.kind.ref.end, columnAbsolute: start.columnAbsolute, rowAbsolute: start.rowAbsolute };
      replacement = rangeReferenceText({ ...token.kind.ref, start, end });
    } else {
      continue;
    }
    return { text: formula.slice(0, token.start) + replacement + formula.slice(token.start + token.length), start: token.start, length: replacement.length };
  }
  return null;
}
