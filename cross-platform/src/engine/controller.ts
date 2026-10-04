import {
  ALL_CELLS, MAX_COLUMNS, MAX_ROWS, a1, cellCount, cellKey, clampAddress, columnCount, columnName, forEachCell, isSingleCell, isValidAddress,
  isWholeColumns, isWholeRows, keyAddress, offsetRange, parseRange, quotedSheetName, range, rangeA1, rangeContains, rangeContainsRange, rangeRC,
  rangesIntersect, rowCount, sameAddress, sameRange, union, wholeColumns, wholeRows, type CellAddress, type CellRange,
} from "../model/address";
import { FormulaError, type CellValue } from "../model/values";
import {
  DEFAULT_COLUMN_WIDTH, DEFAULT_ROW_HEIGHT, cellHasContent, cloneSheet, cloneWorkbook, columnWidth, contentExtent, currentRegion, dataEdge,
  definedName, expandedToMerges, getCell, hasContent, isPlainStyle, isRowHidden, isVacant, mergeContaining, newSheet, nextSheetName,
  normalizeStyle, numberFormatOf, sameName, setCell, sheetIndexNamed, styleAt, uniqueSheetName, updateStyle, usedRange, uuid,
  type AutoFilter, type BorderLine, type Cell, type CellBorders, type CellStyle, type ChartKind, type ChartObject, type Color,
  type ConditionalFormat, type FilterCriterion, type HighlightFormat, type HorizontalAlignment, type PageSetup, type Rule, type Sheet,
  type TableObject, type TableStyle, type VerticalAlignment, type Workbook,
} from "../model/workbook";
import { Calculator } from "../formula";
import { compareValues } from "../formula/fvalue";
import { tokenize, rangeReferenceText, referenceText, referenceRange } from "../formula/lexer";
import { parseFormula } from "../formula/parser";
import { adjustingDecimals, formatNumber, formatValue, general, isDateFormat, isPercentFormat, isTimeFormat, plainText, FORMATS, GENERAL } from "../formula/numberFormat";
import { parseEntry } from "../formula/valueParser";
import { serialFromDate } from "../formula/dateSerial";
import {
  adjustFormula, affectsRows, mapAddress, mapIndex, mapRange, moveFormula, removeSheetFromFormula, renameSheetInFormula, rewrite, shiftFormula,
  type StructuralChange,
} from "../formula/rewriter";
import { settings } from "../settings";
import { extendFill } from "./autofill";
import { ruleMatches, type ConditionalStats } from "./conditional";
import {
  isMultipleSelection, isSingleSelection, primaryRange, sameSelection, selectedColumns, selectedRows, selectionAt, selectionOf, type Selection,
} from "./selection";

// MARK: - Supporting types

export type ChangeKind = "content" | "selection" | "geometry" | "sheets" | "editing" | "status" | "chart" | "scroll" | "marquee" | "load";

export interface Presenter {
  alert(message: string, info?: string): void;
  confirm(message: string, info: string, ok: string): Promise<boolean>;
}

/** Measures text for AutoFit and wrapping. The UI supplies a canvas-backed one. */
export interface TextMeasurer {
  width(text: string, style: CellStyle): number;
  lineHeight(style: CellStyle): number;
  wrappedHeight(text: string, style: CellStyle, width: number): number;
}

export const approximateMeasurer: TextMeasurer = {
  width: (text, style) => text.length * (style.fontSize ?? settings().defaultFontSize) * 0.55,
  lineHeight: (style) => (style.fontSize ?? settings().defaultFontSize) * 1.25,
  wrappedHeight(text, style, width) {
    const size = style.fontSize ?? settings().defaultFontSize;
    const perLine = Math.max(1, Math.floor(width / (size * 0.55)));
    const lines = text.split("\n").reduce((n, line) => n + Math.max(1, Math.ceil(line.length / perLine)), 0);
    return lines * size * 1.25;
  },
};

export type PasteMode = "all" | "formulas" | "values" | "formats" | "transpose" | "valuesAndNumberFormats" | "noBorders" | "columnWidths" | "link";

export const PASTE_TITLES: Record<PasteMode, string> = {
  all: "Paste", formulas: "Paste Formulas", values: "Paste Values", formats: "Paste Formatting", transpose: "Paste Transposed",
  valuesAndNumberFormats: "Paste Values & Number Formats", noBorders: "Paste Without Borders", columnWidths: "Paste Column Widths", link: "Paste Link",
};

/** Cells copied in this window, kept alongside the plain text put on the system clipboard. */
export interface ClipboardPayload {
  sheetId: string;
  sheetName: string;
  range: CellRange;
  cells: (Cell | undefined)[][];
  computed: CellValue[][];
  columnWidths: number[];
  isCut: boolean;
  text: string;
  html: string;
}

export type BorderPreset = "bottom" | "top" | "left" | "right" | "none" | "all" | "outside" | "thickOutside" | "doubleBottom" | "thickBottom" | "topAndBottom" | "topAndDoubleBottom" | "insideHorizontal" | "insideVertical";

export const BORDER_TITLES: Record<BorderPreset, string> = {
  bottom: "Bottom Border", top: "Top Border", left: "Left Border", right: "Right Border", none: "No Border", all: "All Borders",
  outside: "Outside Borders", thickOutside: "Thick Outside Borders", doubleBottom: "Bottom Double Border", thickBottom: "Thick Bottom Border",
  topAndBottom: "Top and Bottom Border", topAndDoubleBottom: "Top and Double Bottom Border", insideHorizontal: "Inside Horizontal Borders", insideVertical: "Inside Vertical Borders",
};

export type MergeMode = "mergeAndCenter" | "mergeAcross" | "merge" | "unmerge";

export type NamedCellStyle = "normal" | "good" | "bad" | "neutral" | "title" | "heading1" | "heading2" | "heading3" | "total" | "input" | "output" | "calculation" | "note" | "warning" | "accent";

export const NAMED_STYLE_TITLES: Record<NamedCellStyle, string> = {
  normal: "Normal", good: "Good", bad: "Bad", neutral: "Neutral", title: "Title", heading1: "Heading 1", heading2: "Heading 2", heading3: "Heading 3",
  total: "Total", input: "Input", output: "Output", calculation: "Calculation", note: "Note", warning: "Warning Text", accent: "Accent",
};

export function applyNamedStyleTo(named: NamedCellStyle, style: CellStyle): CellStyle {
  const s: CellStyle = { numberFormat: style.numberFormat };
  const box = (color: Color): CellBorders => {
    const line: BorderLine = { style: "thin", color };
    return { top: line, left: line, bottom: line, right: line };
  };
  switch (named) {
    case "normal": break;
    case "good": Object.assign(s, { fillColor: "#C6EFCE", textColor: "#006100" }); break;
    case "bad": Object.assign(s, { fillColor: "#FFC7CE", textColor: "#9C0006" }); break;
    case "neutral": Object.assign(s, { fillColor: "#FFEB9C", textColor: "#9C5700" }); break;
    case "title": Object.assign(s, { fontSize: 20, bold: true, textColor: "#1B4332" }); break;
    case "heading1": Object.assign(s, { fontSize: 15, bold: true, textColor: "#1B4332", borders: { bottom: { style: "thick", color: "#1E8E5A" } } }); break;
    case "heading2": Object.assign(s, { fontSize: 13, bold: true, textColor: "#1B4332", borders: { bottom: { style: "medium", color: "#74C69D" } } }); break;
    case "heading3": Object.assign(s, { bold: true, textColor: "#1B4332", borders: { bottom: { style: "thin", color: "#95D5B2" } } }); break;
    case "total": Object.assign(s, { bold: true, borders: { top: { style: "thin", color: "#1E8E5A" }, bottom: { style: "double", color: "#1E8E5A" } } }); break;
    case "input": Object.assign(s, { fillColor: "#FFCC99", textColor: "#3F3F76", borders: box("#7F7F7F") }); break;
    case "output": Object.assign(s, { fillColor: "#F2F2F2", textColor: "#3F3F3F", bold: true, borders: box("#3F3F3F") }); break;
    case "calculation": Object.assign(s, { fillColor: "#F2F2F2", textColor: "#FA7D00", bold: true, borders: box("#7F7F7F") }); break;
    case "note": Object.assign(s, { fillColor: "#FFFFCC", borders: box("#B2B2B2") }); break;
    case "warning": s.textColor = "#FF0000"; break;
    case "accent": Object.assign(s, { fillColor: "#1E8E5A", textColor: "#FFFFFF", bold: true }); break;
  }
  return s;
}

export interface SortKey {
  /** Absolute column index. */
  column: number;
  ascending: boolean;
}

export interface FindOptions {
  text: string;
  replacement: string;
  matchCase: boolean;
  entireCell: boolean;
  searchFormulas: boolean;
  wholeWorkbook: boolean;
}

export type SpecialTarget = "formulas" | "constants" | "blanks" | "notes" | "errors" | "conditionalFormats";

export interface SelectionSummary {
  sum?: number;
  average?: number;
  count: number;
  numericalCount: number;
  minimum?: number;
  maximum?: number;
}

/** Formatting captured by the Format Painter. */
export interface FormatPainter {
  styles: CellStyle[][];
  sticky: boolean;
}

interface UndoEntry {
  name: string;
  workbook: Workbook;
  selection: Selection;
  sheet: number;
}

export class InvalidFormulaError extends Error {}

const FONT_SIZES = [8, 9, 10, 11, 12, 14, 16, 18, 20, 22, 24, 26, 28, 36, 48, 72];

/**
 * The heart of an open workbook: the model, calculation, selection and every
 * editing command. Views subscribe to it; menus, the toolbar and the grid call
 * into it. All model changes go through `change`, which snapshots the workbook
 * for undo, recalculates and notifies the views.
 */
export class WorkbookController {
  workbook: Workbook;
  readonly calculator: Calculator;
  activeSheetIndex = 0;
  selection: Selection = selectionAt({ row: 0, column: 0 });
  /** Bumped after every change to cells or formatting. */
  revision = 0;
  /** Edits since the last save. */
  changeCount = 0;
  isEditing = false;
  showFormulas = false;
  /** The source of the last Copy/Cut, shown with marching ants. */
  clipboardMarquee: { sheetId: string; range: CellRange; isCut: boolean } | null = null;
  clipboard: ClipboardPayload | null = null;
  formatPainter: FormatPainter | null = null;
  statusMessage: string | null = null;
  selectedChartId: string | null = null;
  presenter: Presenter = { alert: () => {}, confirm: async () => true };
  measurer: TextMeasurer = approximateMeasurer;

  commitEditingHandler: (() => boolean) | null = null;
  cancelEditingHandler: (() => void) | null = null;
  /** Begins editing the active cell with text and an optional selected span. */
  beginEditingHandler: ((text: string, selection?: [number, number]) => void) | null = null;

  private undoStack: UndoEntry[] = [];
  private redoStack: UndoEntry[] = [];
  private selections = new Map<string, Selection>();
  private autoSizedRowsBySheet = new Map<string, Set<number>>();
  private listeners = new Set<(kind: ChangeKind) => void>();
  private statusTimer: ReturnType<typeof setTimeout> | null = null;

  constructor(workbook: Workbook) {
    this.workbook = workbook;
    this.calculator = new Calculator(workbook);
    this.activeSheetIndex = Math.min(Math.max(workbook.activeSheetIndex, 0), workbook.sheets.length - 1);
    this.calculator.recalculate();
  }

  subscribe(listener: (kind: ChangeKind) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  emit(kind: ChangeKind) {
    for (const listener of this.listeners) listener(kind);
  }

  // MARK: - Loading

  load(workbook: Workbook) {
    this.workbook = workbook;
    this.activeSheetIndex = Math.min(Math.max(workbook.activeSheetIndex, 0), workbook.sheets.length - 1);
    this.selections.clear();
    this.selection = selectionAt({ row: 0, column: 0 });
    this.undoStack = [];
    this.redoStack = [];
    this.changeCount = 0;
    this.clipboardMarquee = null;
    this.selectedChartId = null;
    this.recalculate();
    this.emit("load");
  }

  // MARK: - Sheets

  get sheet(): Sheet {
    return this.workbook.sheets[this.activeSheetIndex];
  }

  activateSheet(index: number) {
    if (index < 0 || index >= this.workbook.sheets.length || index === this.activeSheetIndex) return;
    this.commitEditingIfNeeded();
    if (this.sheet) this.selections.set(this.sheet.id, this.selection);
    this.activeSheetIndex = index;
    this.workbook.activeSheetIndex = index;
    this.selection = this.selections.get(this.workbook.sheets[index].id) ?? selectionAt({ row: 0, column: 0 });
    this.selectedChartId = null;
    this.revision++;
    this.emit("sheets");
    this.emit("geometry");
    this.emit("scroll");
  }

  // MARK: - Changes

  /** Applies a change to a copy of the workbook with undo support, then recalculates. */
  change(name: string, body: (workbook: Workbook) => void, geometry = false) {
    const before = this.workbook;
    const beforeSelection = this.selection;
    const beforeSheet = this.activeSheetIndex;
    const updated = cloneWorkbook(this.workbook);
    body(updated);
    this.finishChange(name, updated, { name, workbook: before, selection: beforeSelection, sheet: beforeSheet }, geometry);
  }

  /** Changes only the active sheet (cheaper: other sheets are shared with the undo snapshot). */
  changeSheet(name: string, body: (sheet: Sheet) => void, geometry = false) {
    const index = this.activeSheetIndex;
    const before = this.workbook;
    const updated: Workbook = { ...this.workbook, sheets: [...this.workbook.sheets] };
    updated.sheets[index] = cloneSheet(this.workbook.sheets[index]);
    body(updated.sheets[index]);
    this.finishChange(name, updated, { name, workbook: before, selection: this.selection, sheet: this.activeSheetIndex }, geometry);
  }

  private finishChange(name: string, updated: Workbook, undo: UndoEntry, geometry: boolean) {
    updated.activeSheetIndex = this.activeSheetIndex;
    this.undoStack.push(undo);
    if (this.undoStack.length > 100) this.undoStack.shift();
    this.redoStack = [];
    this.commit(updated, geometry);
    void name;
  }

  private commit(updated: Workbook, geometry: boolean) {
    this.workbook = updated;
    if (this.activeSheetIndex >= this.workbook.sheets.length) this.activeSheetIndex = this.workbook.sheets.length - 1;
    this.changeCount++;
    this.recalculate();
    if (geometry) this.emit("geometry");
  }

  get canUndo() { return this.undoStack.length > 0; }
  get canRedo() { return this.redoStack.length > 0; }
  get undoName() { return this.undoStack[this.undoStack.length - 1]?.name ?? ""; }
  get redoName() { return this.redoStack[this.redoStack.length - 1]?.name ?? ""; }

  undo() {
    const entry = this.undoStack.pop();
    if (!entry) return;
    this.redoStack.push({ name: entry.name, workbook: this.workbook, selection: this.selection, sheet: this.activeSheetIndex });
    this.restore(entry);
  }

  redo() {
    const entry = this.redoStack.pop();
    if (!entry) return;
    this.undoStack.push({ name: entry.name, workbook: this.workbook, selection: this.selection, sheet: this.activeSheetIndex });
    this.restore(entry);
  }

  private restore(entry: UndoEntry) {
    this.cancelEditing();
    const sheetChanged = entry.sheet !== this.activeSheetIndex || entry.workbook.sheets.length !== this.workbook.sheets.length;
    this.activeSheetIndex = Math.min(entry.sheet, entry.workbook.sheets.length - 1);
    this.workbook = { ...entry.workbook, activeSheetIndex: this.activeSheetIndex };
    this.changeCount++;
    this.recalculate();
    this.selection = entry.selection;
    this.emit("geometry");
    if (sheetChanged) this.emit("sheets");
    this.emit("selection");
    this.emit("scroll");
  }

  recalculate() {
    this.calculator.setWorkbook(this.workbook);
    this.calculator.recalculate();
    this.revision++;
    this.emit("content");
  }

  markSaved() {
    this.changeCount = 0;
    this.emit("status");
  }

  get isDirty() { return this.changeCount > 0; }

  /** Writes computed results into formula cells' cached values (used before saving). */
  workbookForSaving(): Workbook {
    const copy = cloneWorkbook(this.workbook);
    copy.activeSheetIndex = this.activeSheetIndex;
    copy.sheets.forEach((sheet, index) => {
      for (const [key, cell] of sheet.cells) {
        if (cell.formula === undefined) continue;
        const { row, column } = keyAddress(key);
        sheet.cells.set(key, { ...cell, value: this.calculator.value(index, row, column) });
      }
    });
    return copy;
  }

  /** Non-undoable view changes (zoom, gridlines) still mark the document edited. */
  private changeView(body: (sheet: Sheet) => void, geometry: boolean) {
    const sheets = [...this.workbook.sheets];
    const sheet = { ...sheets[this.activeSheetIndex] };
    body(sheet);
    sheets[this.activeSheetIndex] = sheet;
    this.workbook = { ...this.workbook, sheets };
    this.calculator.setWorkbook(this.workbook);
    this.changeCount++;
    this.revision++;
    this.emit("content");
    if (geometry) this.emit("geometry");
  }

  // MARK: - Values

  value(a: CellAddress): CellValue {
    return this.calculator.value(this.activeSheetIndex, a.row, a.column);
  }

  valueOn(sheet: number, a: CellAddress): CellValue {
    return this.calculator.value(sheet, a.row, a.column);
  }

  style(a: CellAddress): CellStyle {
    return styleAt(this.sheet, a.row, a.column);
  }

  get activeStyle(): CellStyle {
    return this.style(this.selection.active);
  }

  /** The text shown for a cell, after number formatting. */
  displayText(a: CellAddress): string {
    const formula = getCell(this.sheet, a.row, a.column)?.formula;
    if (this.showFormulas && formula !== undefined) return "=" + formula;
    return formatValue(this.value(a), numberFormatOf(this.style(a))).text;
  }

  /** What the formula bar and cell editor show for a cell. */
  inputText(a: CellAddress, sheetIndex = this.activeSheetIndex): string {
    const sheet = this.workbook.sheets[sheetIndex];
    const cell = getCell(sheet, a.row, a.column);
    if (!cell) return "";
    if (cell.formula !== undefined) return "=" + cell.formula;
    return WorkbookController.editingText(cell.value, numberFormatOf(styleAt(sheet, a.row, a.column)));
  }

  static editingText(value: CellValue, format: string): string {
    if (value === null) return "";
    if (typeof value === "boolean") return value ? "TRUE" : "FALSE";
    if (value instanceof FormulaError) return value.code;
    if (typeof value === "string") {
      // Text that would read back as a number keeps its apostrophe.
      if (format !== "@" && !value.startsWith("=") && parseEntry(value).value !== value) return "'" + value;
      return value;
    }
    if (isDateFormat(format)) {
      const hasTime = value !== Math.floor(value);
      if (isTimeFormat(format)) return formatNumber(value, value >= 1 ? "m/d/yyyy h:mm:ss AM/PM" : "h:mm:ss AM/PM").text;
      return formatNumber(value, hasTime ? "m/d/yyyy h:mm:ss AM/PM" : "m/d/yyyy").text;
    }
    if (isPercentFormat(format)) return general(value * 100, 17) + "%";
    return general(value, 17);
  }

  // MARK: - Selection

  setSelection(s: Selection, scroll = true) {
    const next = { ...s, active: clampAddress(s.active) };
    const changed = !sameSelection(next, this.selection);
    this.selection = next;
    this.selections.set(this.sheet.id, next);
    if (this.formatPainter && !this.isEditing) this.applyFormatPainter();
    if (changed) this.emit("selection");
    if (scroll) this.emit("scroll");
  }

  /** Selects one cell (expanded to its merge), optionally extending from the anchor or adding a range. */
  select(address: CellAddress, options: { extend?: boolean; add?: boolean; scroll?: boolean } = {}) {
    const a = clampAddress(address);
    const scroll = options.scroll ?? true;
    if (options.extend) {
      const s = { ...this.selection, ranges: [...this.selection.ranges] };
      s.ranges[s.ranges.length - 1] = expandedToMerges(this.sheet, range(s.anchor, a));
      this.setSelection(s, scroll);
      return;
    }
    const r = expandedToMerges(this.sheet, range(a));
    if (options.add) {
      this.setSelection({ active: r.start, anchor: a, ranges: [...this.selection.ranges, r] }, scroll);
    } else {
      this.setSelection({ active: r.start, anchor: a, ranges: [r] }, scroll);
    }
  }

  selectRange(r: CellRange, active?: CellAddress, scroll = true) {
    this.setSelection({ active: active ?? r.start, anchor: active ?? r.start, ranges: [r] }, scroll);
  }

  selectAll() {
    const region = currentRegion(this.sheet, this.selection.active);
    // Like Excel: the first Ctrl+A selects the data region, the second the whole sheet.
    if (!sameRange(primaryRange(this.selection), region) && !isSingleCell(region) && cellHasContent(this.sheet, this.selection.active.row, this.selection.active.column)) {
      this.selectRange(region, this.selection.active, false);
    } else {
      this.selectRange(ALL_CELLS, this.selection.active, false);
    }
  }

  selectColumns(c1: number, c2: number, add = false) {
    const r = wholeColumns(c1, c2);
    const active = { row: 0, column: c1 };
    this.setSelection({ active, anchor: active, ranges: add ? [...this.selection.ranges, r] : [r] }, false);
  }

  selectRows(r1: number, r2: number, add = false) {
    const r = wholeRows(r1, r2);
    const active = { row: r1, column: 0 };
    this.setSelection({ active, anchor: active, ranges: add ? [...this.selection.ranges, r] : [r] }, false);
  }

  /** Arrow keys: moves (or extends) by one cell, skipping hidden rows and columns. */
  moveSelection(rows: number, columns: number, extend: boolean) {
    if (extend) {
      const s = { ...this.selection, ranges: [...this.selection.ranges] };
      const r = primaryRange(s);
      const anchor = s.anchor;
      let corner = { row: anchor.row === r.start.row ? r.end.row : r.start.row, column: anchor.column === r.start.column ? r.end.column : r.start.column };
      corner = this.nextVisible(corner, rows, columns);
      s.ranges[s.ranges.length - 1] = expandedToMerges(this.sheet, range(anchor, corner));
      this.setSelection(s);
      return;
    }
    const start = { ...this.selection.active };
    // Leaving a merged cell moves from its edge.
    const merge = mergeContaining(this.sheet, start);
    if (merge) {
      if (rows > 0) start.row = merge.end.row;
      if (columns > 0) start.column = merge.end.column;
    }
    this.select(this.nextVisible(start, rows, columns));
  }

  private nextVisible(a: CellAddress, rows: number, columns: number): CellAddress {
    let next = clampAddress({ row: a.row + rows, column: a.column + columns });
    for (let guard = 0; (isRowHidden(this.sheet, next.row) || this.sheet.hiddenColumns.has(next.column)) && guard < 10_000; guard++) {
      const candidate = clampAddress({ row: next.row + Math.sign(rows), column: next.column + Math.sign(columns) });
      if (sameAddress(candidate, next)) break;
      next = candidate;
    }
    return next;
  }

  /** Ctrl+arrow: jumps to the edge of the data region. */
  jumpSelection(rows: number, columns: number, extend: boolean) {
    if (extend) {
      const s = { ...this.selection, ranges: [...this.selection.ranges] };
      const r = primaryRange(s);
      const anchor = s.anchor;
      const corner = { row: anchor.row === r.start.row ? r.end.row : r.start.row, column: anchor.column === r.start.column ? r.end.column : r.start.column };
      s.ranges[s.ranges.length - 1] = range(anchor, dataEdge(this.sheet, corner, rows, columns));
      this.setSelection(s);
    } else {
      this.select(dataEdge(this.sheet, this.selection.active, rows, columns));
    }
  }

  /** Enter/Tab inside a multi-cell selection cycle through its cells. */
  advanceWithinSelection(forward: boolean, vertical: boolean) {
    const r = primaryRange(this.selection);
    if (isSingleCell(r) || this.selection.ranges.length !== 1 || cellCount(r) >= 5_000_000) {
      const d = forward ? 1 : -1;
      this.moveSelection(vertical ? d : 0, vertical ? 0 : d, false);
      return;
    }
    const active = { ...this.selection.active };
    if (vertical) {
      active.row += forward ? 1 : -1;
      if (active.row > r.end.row) { active.row = r.start.row; active.column = active.column + 1 > r.end.column ? r.start.column : active.column + 1; }
      if (active.row < r.start.row) { active.row = r.end.row; active.column = active.column - 1 < r.start.column ? r.end.column : active.column - 1; }
    } else {
      active.column += forward ? 1 : -1;
      if (active.column > r.end.column) { active.column = r.start.column; active.row = active.row + 1 > r.end.row ? r.start.row : active.row + 1; }
      if (active.column < r.start.column) { active.column = r.end.column; active.row = active.row - 1 < r.start.row ? r.end.row : active.row - 1; }
    }
    this.setSelection({ ...this.selection, active });
  }

  /** Moves after Enter according to Settings ▸ Enter direction. */
  moveAfterEnter(reverse: boolean) {
    const direction = settings().enterDirection;
    if (direction === "none") return;
    const vertical = direction === "down" || direction === "up";
    const forward = (direction === "down" || direction === "right") !== reverse;
    this.advanceWithinSelection(forward, vertical);
  }

  /** The name box text: "B4" or "A1:C9" (or the defined name that matches). */
  get nameBoxText(): string {
    const r = primaryRange(this.selection);
    const target = quotedSheetName(this.sheet.name) + "!" + rangeA1(r);
    const name = this.workbook.names.find((n) => n.formula.replace(/\$/g, "") === target);
    if (name) return name.name;
    const merge = mergeContaining(this.sheet, this.selection.active);
    if (isSingleCell(r) || (merge && sameRange(merge, r))) return a1(this.selection.active);
    return rangeA1(r);
  }

  /** Goes to a reference or defined name typed into the name box. */
  goTo(text: string): boolean {
    const trimmed = text.trim();
    if (!trimmed) return false;
    let target = definedName(this.workbook, trimmed)?.formula ?? trimmed;
    let sheetIndex = this.activeSheetIndex;
    const bang = target.lastIndexOf("!");
    if (bang >= 0) {
      let sheetName = target.slice(0, bang);
      if (sheetName.startsWith("'") && sheetName.endsWith("'")) sheetName = sheetName.slice(1, -1).replace(/''/g, "'");
      const index = sheetIndexNamed(this.workbook, sheetName);
      if (index < 0) return false;
      sheetIndex = index;
      target = target.slice(bang + 1);
    }
    const r = parseRange(target);
    if (!r) return false;
    if (sheetIndex !== this.activeSheetIndex) this.activateSheet(sheetIndex);
    this.selectRange(r, r.start);
    return true;
  }

  // MARK: - Editing state

  commitEditingIfNeeded(): boolean {
    if (!this.isEditing) return true;
    return this.commitEditingHandler?.() ?? true;
  }

  cancelEditing() {
    if (this.isEditing) this.cancelEditingHandler?.();
  }

  setEditing(editing: boolean) {
    if (this.isEditing === editing) return;
    this.isEditing = editing;
    this.emit("editing");
  }

  // MARK: - Status bar

  /** Sum, average and count of the selection, for the status bar. */
  selectionSummary(): SelectionSummary {
    const summary: SelectionSummary = { count: 0, numericalCount: 0 };
    let total = 0, numbers = 0, min = Infinity, max = -Infinity;
    const visited = new Set<number>();
    const sheet = this.sheet;
    const accumulate = (row: number, column: number) => {
      const key = cellKey(row, column);
      if (visited.has(key)) return;
      visited.add(key);
      const v = this.calculator.value(this.activeSheetIndex, row, column);
      if (v === null) return;
      summary.count++;
      if (typeof v === "number") {
        numbers++;
        total += v;
        if (v < min) min = v;
        if (v > max) max = v;
      }
    };
    for (const r of this.selection.ranges) {
      const bounded = this.boundedToContent(r);
      if (cellCount(bounded) > 2_000_000) continue;
      if (cellCount(bounded) > sheet.cells.size * 2) {
        // Only visit cells that exist (or spill) to stay fast on huge selections.
        for (const key of sheet.cells.keys()) {
          const a = keyAddress(key);
          if (rangeContains(bounded, a) && !isRowHidden(sheet, a.row)) accumulate(a.row, a.column);
        }
        for (const [anchorKey, spill] of this.calculator.spillRanges) {
          if (Math.floor(anchorKey / 2 ** 35) !== this.activeSheetIndex) continue;
          forEachCell(spill, (row, column) => {
            if (rangeContains(bounded, { row, column }) && !sheet.cells.has(cellKey(row, column))) accumulate(row, column);
          });
        }
      } else {
        forEachCell(bounded, (row, column) => { if (!isRowHidden(sheet, row)) accumulate(row, column); });
      }
    }
    summary.numericalCount = numbers;
    if (numbers > 0) {
      summary.sum = total;
      summary.average = total / numbers;
      summary.minimum = min;
      summary.maximum = max;
    }
    return summary;
  }

  /** Clips whole-row/column ranges to the used area. */
  boundedToContent(r: CellRange): CellRange {
    if (!isWholeColumns(r) && !isWholeRows(r)) return r;
    const extent = { ...contentExtent(this.sheet) };
    for (const [key, spill] of this.calculator.spillRanges) {
      if (Math.floor(key / 2 ** 35) !== this.activeSheetIndex) continue;
      extent.row = Math.max(extent.row, spill.end.row);
      extent.column = Math.max(extent.column, spill.end.column);
    }
    return rangeRC(r.start.row, r.start.column, Math.min(r.end.row, Math.max(extent.row, r.start.row)), Math.min(r.end.column, Math.max(extent.column, r.start.column)));
  }

  /** Cells of the selection, bounded to content. */
  get selectedAddresses(): CellAddress[] {
    const result: CellAddress[] = [];
    const seen = new Set<number>();
    for (const r of this.selection.ranges) {
      const bounded = this.boundedToContent(r);
      if (cellCount(bounded) > 1_000_000) continue;
      forEachCell(bounded, (row, column) => {
        const key = cellKey(row, column);
        if (!seen.has(key)) {
          seen.add(key);
          result.push({ row, column });
        }
      });
    }
    return result;
  }

  flash(message: string) {
    this.statusMessage = message;
    this.emit("status");
    if (this.statusTimer) clearTimeout(this.statusTimer);
    this.statusTimer = setTimeout(() => {
      if (this.statusMessage === message) {
        this.statusMessage = null;
        this.emit("status");
      }
    }, 3000);
  }

  // MARK: - Typing

  /**
   * Normalizes formula text the way Excel does on entry: uppercase function
   * names and references, and closing any parentheses left open.
   */
  static normalizeFormula(body: string): string {
    let text = body;
    const open = (text.match(/\(/g)?.length ?? 0) - (text.match(/\)/g)?.length ?? 0);
    if (open > 0) text += ")".repeat(open);
    let tokens;
    try {
      tokens = tokenize(text);
      parseFormula(text);
    } catch {
      throw new InvalidFormulaError(text);
    }
    let result = "";
    for (const token of tokens) {
      const k = token.kind;
      if (k.t === "function") result += k.name;
      else if (k.t === "cell") result += referenceText(k.ref);
      else if (k.t === "range") result += rangeReferenceText(k.ref);
      else if (k.t === "bool") result += k.value ? "TRUE" : "FALSE";
      else result += token.text;
    }
    return result;
  }

  /** Builds the cell a typed entry produces, keeping existing formatting. Throws InvalidFormulaError. */
  cellForInput(text: string, existing: Cell | undefined, a: CellAddress, sheet: Sheet): Cell | undefined {
    const cell: Cell = { ...(existing ?? { value: null }) };
    const style = styleAt(sheet, a.row, a.column);
    const format = numberFormatOf(style);
    delete cell.formula;
    if (text === "") {
      cell.value = null;
      return isVacant(cell) ? undefined : cell;
    }
    if (text.startsWith("=") && text.length > 1 && format !== "@") {
      cell.formula = WorkbookController.normalizeFormula(text.slice(1));
      cell.value = null;
      return cell;
    }
    if (text.startsWith("+") && text.length > 1 && typeof parseEntry(text).value !== "number") {
      let parses = true;
      try { parseFormula(text.slice(1)); } catch { parses = false; }
      if (parses) {
        // "+A1+A2" is a formula in Excel too.
        cell.formula = WorkbookController.normalizeFormula(text.slice(1));
        cell.value = null;
        return cell;
      }
    }
    if (text.startsWith("'")) {
      cell.value = text.slice(1);
      return cell;
    }
    if (format === "@") {
      cell.value = text;
      return cell;
    }
    const parsed = parseEntry(text);
    cell.value = parsed.value;
    if (parsed.format && (format === GENERAL || isDateFormat(parsed.format) !== isDateFormat(format))) {
      cell.style = normalizeStyle({ ...style, numberFormat: parsed.format });
    }
    if (typeof parsed.value === "string" && parsed.value.includes("\n") && !style.wrap) {
      cell.style = { ...(cell.style ?? style), wrap: true };
    }
    if (typeof parsed.value === "string" && WorkbookController.looksLikeURL(parsed.value)) {
      const s = parsed.value;
      cell.link = s.includes("://") || s.startsWith("mailto:") ? s : "https://" + s;
    }
    return cell;
  }

  static looksLikeURL(s: string): boolean {
    if (s.includes(" ") || s.length <= 4) return false;
    return s.startsWith("http://") || s.startsWith("https://") || s.startsWith("www.") || s.startsWith("mailto:");
  }

  /** Commits typed text into a cell. With `fillSelection` (Ctrl+Enter) it fills every selected cell. */
  setInput(text: string, at: CellAddress, fillSelection = false): boolean {
    const targets = fillSelection ? this.selectedAddresses : [at];
    try {
      // Validate once before touching the model.
      this.cellForInput(text, getCell(this.sheet, at.row, at.column), at, this.sheet);
    } catch (e) {
      if (e instanceof InvalidFormulaError) {
        this.presenter.alert("There's a problem with this formula.", "Check that every parenthesis is closed, that function names are spelled correctly, and that text is in quotation marks.");
      }
      return false;
    }
    this.changeSheet(text.startsWith("=") ? "Enter Formula" : "Typing", (sheet) => {
      for (const target of targets) {
        let entry = text;
        if (fillSelection && text.startsWith("=") && !sameAddress(target, at)) {
          entry = "=" + shiftFormula(text.slice(1), target.row - at.row, target.column - at.column);
        }
        let cell: Cell | undefined;
        try { cell = this.cellForInput(entry, getCell(sheet, target.row, target.column), target, sheet); } catch { cell = undefined; }
        setCell(sheet, target.row, target.column, cell);
      }
      this.autoFitRowForWrap(sheet, new Set(targets.map((t) => t.row)));
    });
    return true;
  }

  private get autoSizedRows(): Set<number> {
    let set = this.autoSizedRowsBySheet.get(this.sheet.id);
    if (!set) {
      set = new Set();
      this.autoSizedRowsBySheet.set(this.sheet.id, set);
    }
    return set;
  }

  /** Grows rows with wrapped text to fit, unless their height was set by hand. */
  autoFitRowForWrap(sheet: Sheet, rows: Set<number>) {
    const auto = this.autoSizedRows;
    for (const row of rows) {
      if (sheet.rowHeights.has(row) && !auto.has(row)) continue;
      const needed = this.fittingHeight(row, sheet);
      if (needed > DEFAULT_ROW_HEIGHT + 0.5) {
        sheet.rowHeights.set(row, needed);
        auto.add(row);
      } else if (auto.has(row)) {
        sheet.rowHeights.delete(row);
      }
    }
  }

  /** The height a row needs for its wrapped or large text. */
  fittingHeight(row: number, sheet: Sheet): number {
    let height = DEFAULT_ROW_HEIGHT;
    const sheetIndex = this.workbook.sheets.findIndex((s) => s.id === sheet.id);
    for (const [key, cell] of sheet.cells) {
      const a = keyAddress(key);
      if (a.row !== row || !hasContent(cell)) continue;
      const style = styleAt(sheet, a.row, a.column);
      const v = cell.formula !== undefined && sheetIndex >= 0 ? this.calculator.value(sheetIndex, a.row, a.column) : cell.value;
      const text = formatValue(v, numberFormatOf(style)).text;
      if (style.wrap) {
        let width = columnWidth(sheet, a.column);
        const merge = mergeContaining(sheet, a);
        if (merge) {
          width = 0;
          for (let c = merge.start.column; c <= merge.end.column; c++) width += columnWidth(sheet, c);
        }
        height = Math.max(height, Math.ceil(this.measurer.wrappedHeight(text, style, Math.max(width - 6, 10))) + 6);
      } else {
        height = Math.max(height, this.measurer.lineHeight(style) + 6);
      }
    }
    return Math.min(height, 409);
  }

  /** Clears contents (not formatting) of the selection — the Delete key. */
  clearContents() {
    this.commitEditingIfNeeded();
    const ranges = this.selection.ranges;
    this.changeSheet("Clear Contents", (sheet) => {
      for (const [key, cell] of [...sheet.cells]) {
        const a = keyAddress(key);
        if (!ranges.some((r) => rangeContains(r, a))) continue;
        const cleared: Cell = { value: null, style: cell.style };
        setCell(sheet, a.row, a.column, cleared);
      }
    });
  }

  clearFormats() {
    this.commitEditingIfNeeded();
    const ranges = this.selection.ranges;
    this.changeSheet("Clear Formats", (sheet) => {
      for (const [key, cell] of [...sheet.cells]) {
        const a = keyAddress(key);
        if (ranges.some((r) => rangeContains(r, a))) setCell(sheet, a.row, a.column, { ...cell, style: undefined });
      }
      for (const r of ranges) {
        if (isWholeColumns(r)) for (let c = r.start.column; c <= r.end.column; c++) sheet.columnStyles.delete(c);
        if (isWholeRows(r)) for (const row of [...sheet.rowStyles.keys()]) if (row >= r.start.row && row <= r.end.row) sheet.rowStyles.delete(row);
      }
      sheet.merges = sheet.merges.filter((m) => !ranges.some((r) => rangeContainsRange(r, m)));
      sheet.conditionalFormats = sheet.conditionalFormats.filter((cf) => !ranges.some((r) => rangeContainsRange(r, cf.range)));
    }, true);
  }

  clearAll() {
    this.commitEditingIfNeeded();
    const ranges = this.selection.ranges;
    this.changeSheet("Clear All", (sheet) => {
      const inSelection = (key: number) => ranges.some((r) => rangeContains(r, keyAddress(key)));
      for (const key of [...sheet.cells.keys()]) if (inSelection(key)) sheet.cells.delete(key);
      for (const key of [...sheet.notes.keys()]) if (inSelection(key)) sheet.notes.delete(key);
      for (const r of ranges) {
        if (isWholeColumns(r)) for (let c = r.start.column; c <= r.end.column; c++) sheet.columnStyles.delete(c);
        if (isWholeRows(r)) for (const row of [...sheet.rowStyles.keys()]) if (row >= r.start.row && row <= r.end.row) sheet.rowStyles.delete(row);
      }
      sheet.merges = sheet.merges.filter((m) => !ranges.some((r) => rangeContainsRange(r, m)));
      sheet.conditionalFormats = sheet.conditionalFormats.filter((cf) => !ranges.some((r) => rangeContainsRange(r, cf.range)));
    }, true);
  }

  clearNotes() {
    const ranges = this.selection.ranges;
    this.changeSheet("Clear Notes", (sheet) => {
      for (const key of [...sheet.notes.keys()]) if (ranges.some((r) => rangeContains(r, keyAddress(key)))) sheet.notes.delete(key);
    });
  }

  clearHyperlinks() {
    const ranges = this.selection.ranges;
    this.changeSheet("Clear Hyperlinks", (sheet) => {
      for (const [key, cell] of [...sheet.cells]) {
        const a = keyAddress(key);
        if (cell.link !== undefined && ranges.some((r) => rangeContains(r, a))) setCell(sheet, a.row, a.column, { ...cell, link: undefined });
      }
    });
  }

  /** A value from the same column that starts with `prefix` (Excel's AutoComplete). */
  autoCompletion(prefix: string, at: CellAddress): string | null {
    if (!settings().autoComplete || !prefix || prefix.startsWith("=") || /^\d/.test(prefix)) return null;
    const matches = new Set<string>();
    let candidate: string | null = null;
    const lower = prefix.toLowerCase();
    for (const step of [-1, 1]) {
      let row = at.row + step;
      let blanks = 0;
      while (row >= 0 && row < at.row + 2000 && row > at.row - 2000 && blanks < 1) {
        const cell = getCell(this.sheet, row, at.column);
        const v = cell?.value ?? null;
        if (typeof v === "string" && cell?.formula === undefined) {
          if (v.length > prefix.length && v.toLowerCase().startsWith(lower)) {
            matches.add(v.toLowerCase());
            candidate = candidate ?? v;
          }
        } else if (v === null) {
          blanks++;
        }
        row += step;
      }
    }
    return matches.size === 1 ? candidate : null;
  }

  insertCurrentDate() {
    const today = Math.floor(serialFromDate(new Date()));
    const a = this.selection.active;
    this.changeSheet("Insert Date", (sheet) => {
      const cell = getCell(sheet, a.row, a.column);
      setCell(sheet, a.row, a.column, { ...(cell ?? { value: null }), formula: undefined, value: today });
      if (!isDateFormat(numberFormatOf(styleAt(sheet, a.row, a.column)))) updateStyle(sheet, a.row, a.column, (s) => ({ ...s, numberFormat: FORMATS.shortDate }));
    });
  }

  insertCurrentTime() {
    const now = serialFromDate(new Date());
    const a = this.selection.active;
    this.changeSheet("Insert Time", (sheet) => {
      const cell = getCell(sheet, a.row, a.column);
      setCell(sheet, a.row, a.column, { ...(cell ?? { value: null }), formula: undefined, value: now - Math.floor(now) });
      updateStyle(sheet, a.row, a.column, (s) => ({ ...s, numberFormat: "h:mm AM/PM" }));
    });
  }

  /** AutoSum: inserts =SUM() (or another function) over the numbers above or to the left. */
  autoSum(fn = "SUM") {
    this.commitEditingIfNeeded();
    const r = primaryRange(this.selection);
    if (!isSingleCell(r)) {
      // Totals under each column of a multi-cell selection.
      const bounded = this.boundedToContent(r);
      let lastRowEmpty = true;
      for (let c = bounded.start.column; c <= bounded.end.column; c++) if (cellHasContent(this.sheet, bounded.end.row, c)) lastRowEmpty = false;
      const targetRow = lastRowEmpty && rowCount(bounded) > 1 ? bounded.end.row : bounded.end.row + 1;
      const dataEnd = targetRow - 1;
      if (dataEnd < bounded.start.row) return;
      this.changeSheet("AutoSum", (sheet) => {
        for (let c = bounded.start.column; c <= bounded.end.column; c++) {
          const data = rangeRC(bounded.start.row, c, dataEnd, c);
          const cell = getCell(sheet, targetRow, c);
          setCell(sheet, targetRow, c, { ...(cell ?? { value: null }), formula: `${fn}(${rangeA1(data)})`, value: null });
        }
      });
      this.selectRange(rangeRC(targetRow, bounded.start.column, targetRow, bounded.end.column));
      return;
    }
    const guess = this.autoSumRange(this.selection.active);
    const text = `=${fn}(` + (guess ? rangeA1(guess) : "") + ")";
    this.beginEditingHandler?.(text, guess ? [fn.length + 2, rangeA1(guess).length] : undefined);
  }

  /** The numbers directly above (preferred) or to the left of a cell. */
  autoSumRange(a: CellAddress): CellRange | null {
    const isNumber = (p: CellAddress) => typeof this.value(p) === "number";
    const scan = (dr: number, dc: number): CellRange | null => {
      let current = { row: a.row + dr, column: a.column + dc };
      if (current.row < 0 || current.column < 0 || !isNumber(current)) return null;
      let last = current;
      while (current.row >= 0 && current.column >= 0 && isNumber(current)) {
        last = current;
        current = { row: current.row + dr, column: current.column + dc };
      }
      return range(last, { row: a.row + dr, column: a.column + dc });
    };
    return scan(-1, 0) ?? scan(0, -1);
  }

  // MARK: - Rows and columns

  insertRows(at: number, count: number) {
    this.applyStructural({ kind: "insertRows", at, count }, count === 1 ? "Insert Row" : "Insert Rows");
  }

  deleteRows(at: number, count: number) {
    this.applyStructural({ kind: "deleteRows", at, count }, count === 1 ? "Delete Row" : "Delete Rows");
  }

  insertColumns(at: number, count: number) {
    this.applyStructural({ kind: "insertColumns", at, count }, count === 1 ? "Insert Column" : "Insert Columns");
  }

  deleteColumns(at: number, count: number) {
    this.applyStructural({ kind: "deleteColumns", at, count }, count === 1 ? "Delete Column" : "Delete Columns");
  }

  /** Insert rows above / columns left of the selection. */
  insertSheetRows() {
    this.commitEditingIfNeeded();
    const r = primaryRange(this.selection);
    this.insertRows(r.start.row, isWholeColumns(r) ? 1 : rowCount(r));
  }

  insertSheetColumns() {
    this.commitEditingIfNeeded();
    const r = primaryRange(this.selection);
    this.insertColumns(r.start.column, isWholeRows(r) ? 1 : columnCount(r));
  }

  deleteSheetRows() {
    this.commitEditingIfNeeded();
    const r = primaryRange(this.selection);
    if (isWholeColumns(r)) return;
    this.deleteRows(r.start.row, rowCount(r));
    this.select({ row: r.start.row, column: this.selection.active.column });
  }

  deleteSheetColumns() {
    this.commitEditingIfNeeded();
    const r = primaryRange(this.selection);
    if (isWholeRows(r)) return;
    this.deleteColumns(r.start.column, columnCount(r));
    this.select({ row: this.selection.active.row, column: r.start.column });
  }

  /** The Insert/Delete commands pick rows, columns or cells from what's selected. */
  insertForSelection() {
    const r = primaryRange(this.selection);
    if (isWholeRows(r)) this.insertSheetRows();
    else if (isWholeColumns(r)) this.insertSheetColumns();
    else this.insertCells(true);
  }

  deleteForSelection() {
    const r = primaryRange(this.selection);
    if (isWholeRows(r)) this.deleteSheetRows();
    else if (isWholeColumns(r)) this.deleteSheetColumns();
    else this.deleteCells(true);
  }

  private applyStructural(change: StructuralChange, name: string) {
    const target = this.sheet.name;
    const index = this.activeSheetIndex;
    this.change(name, (workbook) => {
      rewriteFormulas(workbook, (formula, formulaSheet) => adjustFormula(formula, formulaSheet, target, change));
      for (const n of workbook.names) n.formula = adjustFormula(n.formula, target, target, change);
      remapSheet(workbook.sheets[index], change);
    }, true);
    const auto = new Set<number>();
    for (const row of this.autoSizedRows) {
      if (affectsRows(change)) {
        const moved = mapIndex(change, row);
        if (moved !== null) auto.add(moved);
      } else {
        auto.add(row);
      }
    }
    this.autoSizedRowsBySheet.set(this.sheet.id, auto);
  }

  insertCells(shiftDown: boolean) {
    this.commitEditingIfNeeded();
    this.shiftBlock(primaryRange(this.selection), true, shiftDown, "Insert Cells");
  }

  deleteCells(shiftUp: boolean) {
    this.commitEditingIfNeeded();
    this.shiftBlock(primaryRange(this.selection), false, shiftUp, "Delete Cells");
  }

  /** Inserts or deletes a block of cells, shifting the rest of the strip. */
  private shiftBlock(r: CellRange, insert: boolean, vertical: boolean, name: string) {
    const amount = vertical ? rowCount(r) : columnCount(r);
    const target = this.sheet.name;
    const index = this.activeSheetIndex;
    // Maps an address in the affected strip; null = deleted.
    const map = (a: CellAddress): CellAddress | null => {
      if (vertical) {
        if (a.column < r.start.column || a.column > r.end.column || a.row < r.start.row) return a;
        if (insert) return { row: a.row + amount, column: a.column };
        if (a.row <= r.end.row) return null;
        return { row: a.row - amount, column: a.column };
      }
      if (a.row < r.start.row || a.row > r.end.row || a.column < r.start.column) return a;
      if (insert) return { row: a.row, column: a.column + amount };
      if (a.column <= r.end.column) return null;
      return { row: a.row, column: a.column - amount };
    };
    const strip = vertical ? rangeRC(r.start.row, r.start.column, MAX_ROWS - 1, r.end.column) : rangeRC(r.start.row, r.start.column, r.end.row, MAX_COLUMNS - 1);
    this.change(name, (workbook) => {
      rewriteFormulas(workbook, (formula, formulaSheet) => rewrite(formula, (kind) => {
        if (kind.t === "cell") {
          const ref = kind.ref;
          if (!sameName(ref.sheet ?? formulaSheet, target)) return null;
          const moved = map(ref);
          if (!moved) return "#REF!";
          if (moved.row === ref.row && moved.column === ref.column) return null;
          return isValidAddress(moved) ? referenceText({ ...ref, row: moved.row, column: moved.column }) : "#REF!";
        }
        const ref = kind.ref;
        if (ref.kind !== "cells" || !sameName(ref.sheet ?? formulaSheet, target)) return null;
        // Only ranges inside the strip move with it.
        if (!rangeContainsRange(strip, referenceRange(ref))) return null;
        const a = map(ref.start) ?? (insert ? null : { row: ref.start.row, column: ref.start.column });
        const b = map(ref.end);
        if (!a || !b) return "#REF!";
        return rangeReferenceText({ ...ref, start: { ...ref.start, row: a.row, column: a.column }, end: { ...ref.end, row: b.row, column: b.column } });
      }));
      const sheet = workbook.sheets[index];
      const cells = new Map<number, Cell>();
      for (const [key, cell] of sheet.cells) {
        const moved = map(keyAddress(key));
        if (moved && isValidAddress(moved)) cells.set(cellKey(moved.row, moved.column), cell);
      }
      sheet.cells = cells;
      const notes = new Map<number, string>();
      for (const [key, note] of sheet.notes) {
        const moved = map(keyAddress(key));
        if (moved && isValidAddress(moved)) notes.set(cellKey(moved.row, moved.column), note);
      }
      sheet.notes = notes;
      sheet.merges = sheet.merges.flatMap((m) => {
        const a = map(m.start), b = map(m.end);
        return a && b ? [range(a, b)] : [];
      });
    }, true);
  }

  // MARK: Hide and unhide

  hideColumns() {
    const columns = this.selectedColumnIndices;
    this.changeSheet("Hide Columns", (sheet) => columns.forEach((c) => sheet.hiddenColumns.add(c)), true);
  }

  unhideColumns() {
    const r = primaryRange(this.selection);
    const low = Math.max(r.start.column - 1, 0), high = r.end.column + 1;
    this.changeSheet("Unhide Columns", (sheet) => {
      if (isWholeRows(r)) sheet.hiddenColumns.clear();
      else sheet.hiddenColumns = new Set([...sheet.hiddenColumns].filter((c) => c < low || c > high));
    }, true);
  }

  hideRows() {
    const rows = this.selectedRowIndices;
    this.changeSheet("Hide Rows", (sheet) => rows.forEach((r) => sheet.hiddenRows.add(r)), true);
  }

  unhideRows() {
    const r = primaryRange(this.selection);
    const low = Math.max(r.start.row - 1, 0), high = r.end.row + 1;
    this.changeSheet("Unhide Rows", (sheet) => {
      if (isWholeColumns(r)) sheet.hiddenRows.clear();
      else sheet.hiddenRows = new Set([...sheet.hiddenRows].filter((row) => row < low || row > high));
    }, true);
  }

  // MARK: Freeze panes

  freezePanes() {
    const active = this.selection.active;
    if (this.hasFrozenPanes) {
      this.unfreezePanes();
      return;
    }
    if (active.row === 0 && active.column === 0) {
      this.freezeTopRow();
      return;
    }
    this.changeSheet("Freeze Panes", (sheet) => {
      sheet.frozenRows = active.row;
      sheet.frozenColumns = active.column;
    }, true);
  }

  freezeTopRow() {
    this.changeSheet("Freeze Top Row", (sheet) => { sheet.frozenRows = 1; sheet.frozenColumns = 0; }, true);
  }

  freezeFirstColumn() {
    this.changeSheet("Freeze First Column", (sheet) => { sheet.frozenRows = 0; sheet.frozenColumns = 1; }, true);
  }

  unfreezePanes() {
    this.changeSheet("Unfreeze Panes", (sheet) => { sheet.frozenRows = 0; sheet.frozenColumns = 0; }, true);
  }

  get hasFrozenPanes() {
    return this.sheet.frozenRows > 0 || this.sheet.frozenColumns > 0;
  }

  // MARK: Sheets

  addSheet(after?: number) {
    this.commitEditingIfNeeded();
    const position = (after ?? this.activeSheetIndex) + 1;
    const name = nextSheetName(this.workbook);
    this.change("Insert Sheet", (workbook) => {
      workbook.sheets.splice(Math.min(position, workbook.sheets.length), 0, newSheet(name));
    }, true);
    this.emit("sheets");
    this.activateSheet(Math.min(position, this.workbook.sheets.length - 1));
  }

  async deleteSheet(index: number) {
    if (this.workbook.sheets.length <= 1 || index < 0 || index >= this.workbook.sheets.length) return;
    this.commitEditingIfNeeded();
    const name = this.workbook.sheets[index].name;
    if (this.workbook.sheets[index].cells.size > 0) {
      const ok = await this.presenter.confirm(`Delete “${name}”?`, "The sheet and everything on it will be removed. Formulas that refer to it will show #REF!.", "Delete");
      if (!ok) return;
    }
    const newActive = Math.min(index, this.workbook.sheets.length - 2);
    this.change("Delete Sheet", (workbook) => {
      workbook.sheets.splice(index, 1);
      rewriteFormulas(workbook, (formula) => removeSheetFromFormula(formula, name));
    }, true);
    this.activeSheetIndex = -1;
    this.activateSheet(Math.max(newActive, 0));
  }

  renameSheet(index: number, proposed: string): boolean {
    const name = proposed.trim();
    if (index < 0 || index >= this.workbook.sheets.length || !name || name.length > 31 || /[[\]:*?/\\]/.test(name)) {
      this.presenter.alert("That sheet name isn't valid.", "Names can be up to 31 characters and can't contain : \\ / ? * [ or ].");
      return false;
    }
    const old = this.workbook.sheets[index].name;
    if (old === name) return true;
    const existing = sheetIndexNamed(this.workbook, name);
    if (existing >= 0 && existing !== index) {
      this.presenter.alert(`A sheet named “${name}” already exists.`, "Choose a different name.");
      return false;
    }
    this.change("Rename Sheet", (workbook) => {
      workbook.sheets[index].name = name;
      rewriteFormulas(workbook, (formula) => renameSheetInFormula(formula, old, name));
      for (const n of workbook.names) n.formula = renameSheetInFormula(n.formula, old, name);
    });
    this.emit("sheets");
    return true;
  }

  duplicateSheet(index: number) {
    if (index < 0 || index >= this.workbook.sheets.length) return;
    this.commitEditingIfNeeded();
    const original = this.workbook.sheets[index];
    const copy = cloneSheet(original);
    copy.id = uuid();
    copy.name = uniqueSheetName(this.workbook, original.name);
    copy.charts = copy.charts.map((c) => ({ ...c, id: uuid() }));
    copy.conditionalFormats = copy.conditionalFormats.map((c) => ({ ...c, id: uuid() }));
    copy.tables = copy.tables.map((t) => ({ ...t, id: uuid() }));
    // References to the original sheet inside the copy point at the copy.
    for (const [key, cell] of copy.cells) {
      if (cell.formula !== undefined) copy.cells.set(key, { ...cell, formula: renameSheetInFormula(cell.formula, original.name, copy.name) });
    }
    this.change("Duplicate Sheet", (workbook) => workbook.sheets.splice(index + 1, 0, copy), true);
    this.emit("sheets");
    this.activateSheet(index + 1);
  }

  moveSheet(source: number, destination: number) {
    if (source === destination || source < 0 || source >= this.workbook.sheets.length) return;
    const activeId = this.sheet.id;
    this.change("Move Sheet", (workbook) => {
      const [moved] = workbook.sheets.splice(source, 1);
      workbook.sheets.splice(Math.min(Math.max(destination, 0), workbook.sheets.length), 0, moved);
    });
    const index = this.workbook.sheets.findIndex((s) => s.id === activeId);
    if (index >= 0) {
      this.activeSheetIndex = index;
      this.workbook.activeSheetIndex = index;
    }
    this.emit("sheets");
  }

  setTabColor(color: Color | undefined, index: number) {
    this.change("Tab Color", (workbook) => { workbook.sheets[index].tabColor = color; });
    this.emit("sheets");
  }

  // MARK: View options (stored per sheet, not undoable)

  setZoom(zoom: number) {
    const clamped = Math.min(Math.max(zoom, 0.1), 4);
    if (Math.abs(clamped - this.sheet.zoom) <= 0.001) return;
    this.changeView((sheet) => { sheet.zoom = clamped; }, true);
  }

  toggleGridlines() {
    this.changeView((sheet) => { sheet.showGridlines = !sheet.showGridlines; }, false);
  }

  toggleHeadings() {
    this.changeView((sheet) => { sheet.showHeadings = !sheet.showHeadings; }, true);
  }

  toggleShowFormulas() {
    this.showFormulas = !this.showFormulas;
    this.revision++;
    this.emit("content");
  }

  // MARK: - Clipboard

  /** Copies the selection; returns what to put on the system clipboard. */
  copySelection(cut = false): ClipboardPayload | null {
    this.commitEditingIfNeeded();
    if (this.selection.ranges.length !== 1) {
      this.presenter.alert("This action won't work on multiple selections.", "Select a single range and try again.");
      return null;
    }
    const r = this.boundedToContent(primaryRange(this.selection));
    if (cellCount(r) > 2_000_000) return null;
    const sheet = this.sheet;
    const cells: (Cell | undefined)[][] = [];
    const computed: CellValue[][] = [];
    const lines: string[] = [];
    let html = '<table style="border-collapse:collapse">';
    for (let row = r.start.row; row <= r.end.row; row++) {
      const cellRow: (Cell | undefined)[] = [];
      const valueRow: CellValue[] = [];
      const textRow: string[] = [];
      html += "<tr>";
      for (let column = r.start.column; column <= r.end.column; column++) {
        const a = { row, column };
        let cell = getCell(sheet, row, column);
        if (!cell && (sheet.rowStyles.has(row) || sheet.columnStyles.has(column))) cell = { value: null, style: styleAt(sheet, row, column) };
        cellRow.push(cell);
        valueRow.push(this.value(a));
        const text = this.displayText(a);
        textRow.push(/[\t\n]/.test(text) ? '"' + text.replace(/"/g, '""') + '"' : text);
        html += htmlCell(text, this.style(a));
      }
      cells.push(cellRow);
      computed.push(valueRow);
      lines.push(textRow.join("\t"));
      html += "</tr>";
    }
    html += "</table>";
    const payload: ClipboardPayload = {
      sheetId: sheet.id, sheetName: sheet.name, range: r, cells, computed,
      columnWidths: Array.from({ length: columnCount(r) }, (_, i) => columnWidth(sheet, r.start.column + i)),
      isCut: cut, text: lines.join("\n"), html,
    };
    this.clipboard = payload;
    this.clipboardMarquee = { sheetId: sheet.id, range: r, isCut: cut };
    this.emit("marquee");
    return payload;
  }

  clearMarquee() {
    if (!this.clipboardMarquee) return;
    this.clipboardMarquee = null;
    this.emit("marquee");
  }

  /** Pastes our own copied cells, or `systemText` when the clipboard holds something else. */
  paste(mode: PasteMode = "all", systemText?: string | null) {
    this.commitEditingIfNeeded();
    const payload = this.clipboard;
    const normalize = (s: string) => s.replace(/\r\n?/g, "\n").replace(/\n$/, "");
    if (payload && (systemText === undefined || systemText === null || normalize(systemText) === normalize(payload.text))) {
      this.pastePayload(payload, mode);
    } else if (systemText) {
      this.pasteText(systemText);
    }
  }

  private pastePayload(payload: ClipboardPayload, mode: PasteMode) {
    let cells = payload.cells, computed = payload.computed;
    if (mode === "transpose") {
      const rows = cells.length, columns = cells[0]?.length ?? 0;
      cells = Array.from({ length: columns }, (_, c) => Array.from({ length: rows }, (_, r) => payload.cells[r][c]));
      computed = Array.from({ length: columns }, (_, c) => Array.from({ length: rows }, (_, r) => payload.computed[r][c]));
    }
    const height = cells.length, width = cells[0]?.length ?? 0;
    if (!height || !width) return;

    // Tile the source over a larger selection that's a whole multiple of it.
    const target = primaryRange(this.selection);
    let destination = rangeRC(target.start.row, target.start.column, target.start.row + height - 1, target.start.column + width - 1);
    if (rowCount(target) % height === 0 && columnCount(target) % width === 0 && !isWholeColumns(target) && !isWholeRows(target)) destination = target;
    if (!isValidAddress(destination.end)) {
      this.presenter.alert("The content doesn't fit on the sheet.");
      return;
    }
    const sourceIndex = this.workbook.sheets.findIndex((s) => s.id === payload.sheetId);
    const isCut = payload.isCut && mode === "all" && sourceIndex >= 0;
    const sameSheet = payload.sheetId === this.sheet.id;
    const targetName = this.sheet.name;
    const index = this.activeSheetIndex;

    this.change(mode === "all" ? (isCut ? "Move" : "Paste") : PASTE_TITLES[mode], (workbook) => {
      const sheet = workbook.sheets[index];
      // Cut: clear the source first (it may overlap the destination).
      if (isCut) forEachCell(payload.range, (row, column) => workbook.sheets[sourceIndex].cells.delete(cellKey(row, column)));
      forEachCell(destination, (row, column) => {
        const r = (row - destination.start.row) % height;
        const c = (column - destination.start.column) % width;
        const original = cells[r][c];
        const computedValue = computed[r][c];
        const source = mode === "transpose"
          ? { row: payload.range.start.row + c, column: payload.range.start.column + r }
          : { row: payload.range.start.row + r, column: payload.range.start.column + c };
        let cell: Cell = { ...(getCell(sheet, row, column) ?? { value: null }) };
        switch (mode) {
          case "all": case "transpose": case "noBorders":
            cell = { ...(original ?? { value: null }) };
            if (original?.formula !== undefined && !isCut) cell.formula = shiftFormula(original.formula, row - source.row, column - source.column);
            if (mode === "noBorders" && cell.style) cell.style = normalizeStyle({ ...cell.style, borders: undefined });
            break;
          case "formulas":
            cell.value = original?.value ?? null;
            cell.formula = original?.formula !== undefined ? shiftFormula(original.formula, row - source.row, column - source.column) : undefined;
            break;
          case "values":
            cell.formula = undefined;
            cell.value = computedValue;
            break;
          case "valuesAndNumberFormats":
            cell.formula = undefined;
            cell.value = computedValue;
            cell.style = normalizeStyle({ ...(cell.style ?? styleAt(sheet, row, column)), numberFormat: original?.style?.numberFormat ?? GENERAL });
            break;
          case "formats":
            cell.style = original?.style;
            break;
          case "columnWidths":
            break;
          case "link":
            cell.formula = (sameSheet ? "" : quotedSheetName(payload.sheetName) + "!") + a1(source);
            cell.value = null;
            break;
        }
        setCell(sheet, row, column, cell);
      });
      if (mode === "columnWidths" || (mode === "all" && isWholeColumns(payload.range))) {
        for (let column = destination.start.column; column <= destination.end.column; column++) {
          const w = payload.columnWidths[(column - destination.start.column) % Math.max(payload.columnWidths.length, 1)];
          if (w === DEFAULT_COLUMN_WIDTH) sheet.columnWidths.delete(column);
          else sheet.columnWidths.set(column, w);
        }
      }
      // Merges inside the source come along.
      if (mode === "all" && sourceIndex >= 0) {
        const sourceMerges = workbook.sheets[sourceIndex].merges.filter((m) => rangeContainsRange(payload.range, m));
        for (const merge of sourceMerges) {
          const moved = offsetRange(merge, destination.start.row - payload.range.start.row, destination.start.column - payload.range.start.column);
          sheet.merges = sheet.merges.filter((m) => !rangesIntersect(m, moved));
          sheet.merges.push(moved);
        }
        if (isCut && sourceIndex === index) sheet.merges = sheet.merges.filter((m) => !(rangeContainsRange(payload.range, m) && !rangeContainsRange(destination, m)));
      }
      if (isCut && sameSheet) {
        // Formulas that pointed at the moved cells follow them.
        const dr = destination.start.row - payload.range.start.row, dc = destination.start.column - payload.range.start.column;
        rewriteFormulas(workbook, (formula, formulaSheet) => moveFormula(formula, formulaSheet, targetName, payload.range, dr, dc));
      }
    }, mode === "columnWidths" || mode === "all");
    if (isCut) {
      this.clipboard = null;
      this.clearMarquee();
    }
    this.selectRange(destination, destination.start);
  }

  /** Pastes plain text, splitting rows on newlines and columns on tabs. */
  pasteText(text: string) {
    const rows = WorkbookController.parseDelimited(text, "\t");
    if (!rows.length) return;
    const start = this.selection.active;
    const width = rows.reduce((w, r) => Math.max(w, r.length), 1);
    const destination = rangeRC(start.row, start.column, start.row + rows.length - 1, start.column + width - 1);
    if (!isValidAddress(destination.end)) return;
    this.changeSheet("Paste", (sheet) => {
      rows.forEach((row, r) => row.forEach((field, c) => {
        const a = { row: start.row + r, column: start.column + c };
        let cell: Cell | undefined;
        try { cell = this.cellForInput(field, getCell(sheet, a.row, a.column), a, sheet); } catch { cell = { value: field }; }
        setCell(sheet, a.row, a.column, cell);
      }));
    });
    this.selectRange(destination, start);
  }

  /** Splits delimited text (CSV/TSV), honouring quoted fields. */
  static parseDelimited(text: string, separator: string): string[][] {
    const rows: string[][] = [];
    let row: string[] = [];
    let field = "";
    let inQuotes = false;
    let atFieldStart = true;
    for (let i = 0; i < text.length; i++) {
      const ch = text[i];
      if (inQuotes) {
        if (ch === '"') {
          if (text[i + 1] === '"') { field += '"'; i++; }
          else inQuotes = false;
        } else {
          field += ch;
        }
        continue;
      }
      if (ch === '"' && atFieldStart) {
        inQuotes = true;
        atFieldStart = false;
      } else if (ch === separator) {
        row.push(field); field = ""; atFieldStart = true;
      } else if (ch === "\n" || ch === "\r") {
        if (ch === "\r" && text[i + 1] === "\n") i++;
        row.push(field); field = ""; atFieldStart = true;
        rows.push(row); row = [];
      } else {
        field += ch;
        atFieldStart = false;
      }
    }
    if (field !== "" || row.length) { row.push(field); rows.push(row); }
    return rows;
  }

  /** Drags the selection to a new place (or copies with Ctrl). */
  async moveCells(source: CellRange, destinationStart: CellAddress, copy: boolean) {
    const destination = rangeRC(destinationStart.row, destinationStart.column, destinationStart.row + rowCount(source) - 1, destinationStart.column + columnCount(source) - 1);
    if (!isValidAddress(destination.end) || sameRange(destination, source)) return;
    const dr = destination.start.row - source.start.row, dc = destination.start.column - source.start.column;
    let overwrites = false;
    forEachCell(destination, (row, column) => {
      if (!rangeContains(source, { row, column }) && cellHasContent(this.sheet, row, column)) overwrites = true;
    });
    if (overwrites && !(await this.presenter.confirm("There's already data here. Do you want to replace it?", "", "Replace"))) return;
    const sheetName = this.sheet.name;
    const index = this.activeSheetIndex;
    this.change(copy ? "Copy Cells" : "Move Cells", (workbook) => {
      const sheet = workbook.sheets[index];
      const moved: [CellAddress, Cell | undefined][] = [];
      forEachCell(source, (row, column) => {
        let cell = getCell(sheet, row, column);
        if (copy && cell?.formula !== undefined) cell = { ...cell, formula: shiftFormula(cell.formula, dr, dc) };
        moved.push([{ row: row + dr, column: column + dc }, cell]);
      });
      const notes: [CellAddress, string][] = [];
      if (!copy) {
        forEachCell(source, (row, column) => {
          sheet.cells.delete(cellKey(row, column));
          const note = sheet.notes.get(cellKey(row, column));
          if (note !== undefined) {
            sheet.notes.delete(cellKey(row, column));
            notes.push([{ row: row + dr, column: column + dc }, note]);
          }
        });
      }
      for (const [a, cell] of moved) setCell(sheet, a.row, a.column, cell);
      for (const [a, note] of notes) sheet.notes.set(cellKey(a.row, a.column), note);
      if (!copy) {
        sheet.merges = sheet.merges.map((m) => (rangeContainsRange(source, m) ? offsetRange(m, dr, dc) : m));
        rewriteFormulas(workbook, (formula, formulaSheet) => moveFormula(formula, formulaSheet, sheetName, source, dr, dc));
      }
    }, true);
    this.selectRange(destination);
  }

  // MARK: - Formatting

  /** Applies a style change to every selected cell (and to whole rows/columns). */
  applyStyle(name: string, transform: (style: CellStyle) => CellStyle, geometry = false) {
    this.commitEditingIfNeeded();
    const ranges = this.selection.ranges;
    const extent = contentExtent(this.sheet);
    this.changeSheet(name, (sheet) => {
      applyStyleToRanges(transform, ranges, sheet, extent);
      if (geometry) {
        const rows = new Set<number>();
        for (const r of ranges) if (rowCount(r) < 5000) for (let row = r.start.row; row <= r.end.row; row++) rows.add(row);
        this.autoFitRowForWrap(sheet, rows);
      }
    }, geometry);
  }

  toggleBold() {
    const on = !this.activeStyle.bold;
    this.applyStyle(on ? "Bold" : "Remove Bold", (s) => ({ ...s, bold: on }));
  }

  toggleItalic() {
    const on = !this.activeStyle.italic;
    this.applyStyle(on ? "Italic" : "Remove Italic", (s) => ({ ...s, italic: on }));
  }

  toggleUnderline() {
    const on = !this.activeStyle.underline;
    this.applyStyle(on ? "Underline" : "Remove Underline", (s) => ({ ...s, underline: on, doubleUnderline: false }));
  }

  toggleDoubleUnderline() {
    const on = !this.activeStyle.doubleUnderline;
    this.applyStyle("Double Underline", (s) => ({ ...s, doubleUnderline: on, underline: false }));
  }

  toggleStrikethrough() {
    const on = !this.activeStyle.strikethrough;
    this.applyStyle(on ? "Strikethrough" : "Remove Strikethrough", (s) => ({ ...s, strikethrough: on }));
  }

  setFontName(name: string) {
    this.applyStyle("Font", (s) => ({ ...s, fontName: name === settings().defaultFontName ? undefined : name }), true);
  }

  setFontSize(size: number) {
    const clamped = Math.min(Math.max(size, 1), 409);
    const rows = new Set<number>();
    for (const r of this.selection.ranges) {
      const bounded = this.boundedToContent(r);
      if (rowCount(bounded) < 5000) for (let row = bounded.start.row; row <= bounded.end.row; row++) rows.add(row);
    }
    this.commitEditingIfNeeded();
    const ranges = this.selection.ranges;
    const extent = contentExtent(this.sheet);
    const auto = this.autoSizedRows;
    this.changeSheet("Font Size", (sheet) => {
      applyStyleToRanges((s) => ({ ...s, fontSize: clamped === settings().defaultFontSize ? undefined : clamped }), ranges, sheet, extent);
      // Rows grow to fit bigger fonts (unless sized by hand).
      for (const row of rows) {
        if (sheet.rowHeights.has(row) && !auto.has(row)) continue;
        if (styleAt(sheet, row, 0).wrap) continue;
        let needed = DEFAULT_ROW_HEIGHT;
        for (const [key, cell] of sheet.cells) {
          const a = keyAddress(key);
          if (a.row === row && hasContent(cell)) needed = Math.max(needed, Math.ceil(this.measurer.lineHeight(styleAt(sheet, a.row, a.column))) + 7);
        }
        if (needed > DEFAULT_ROW_HEIGHT + 0.5) {
          sheet.rowHeights.set(row, needed);
          auto.add(row);
        } else {
          sheet.rowHeights.delete(row);
        }
      }
    }, true);
  }

  growFont(grow: boolean) {
    const current = this.activeStyle.fontSize ?? settings().defaultFontSize;
    const next = grow ? (FONT_SIZES.find((s) => s > current) ?? current + 12) : ([...FONT_SIZES].reverse().find((s) => s < current) ?? Math.max(current - 1, 1));
    this.setFontSize(next);
  }

  setTextColor(color: Color | undefined) {
    this.applyStyle("Font Color", (s) => ({ ...s, textColor: color }));
  }

  setFillColor(color: Color | undefined) {
    this.applyStyle("Fill Color", (s) => ({ ...s, fillColor: color }));
  }

  setHorizontalAlignment(alignment: HorizontalAlignment) {
    const target: HorizontalAlignment = (this.activeStyle.horizontal ?? "general") === alignment ? "general" : alignment;
    this.applyStyle("Alignment", (s) => ({ ...s, horizontal: target }));
  }

  setVerticalAlignment(alignment: VerticalAlignment) {
    this.applyStyle("Alignment", (s) => ({ ...s, vertical: alignment }));
  }

  toggleWrap() {
    const on = !this.activeStyle.wrap;
    this.applyStyle("Wrap Text", (s) => ({ ...s, wrap: on }), true);
  }

  changeIndent(delta: number) {
    this.applyStyle("Indent", (s) => {
      const indent = Math.max(0, Math.min(15, (s.indent ?? 0) + delta));
      const horizontal = indent > 0 && (!s.horizontal || s.horizontal === "general" || s.horizontal === "center") ? "left" : s.horizontal;
      return { ...s, indent, horizontal };
    });
  }

  setNumberFormat(code: string) {
    this.applyStyle("Number Format", (s) => ({ ...s, numberFormat: code }));
  }

  adjustDecimals(delta: number) {
    const format = numberFormatOf(this.activeStyle);
    const sample = this.value(this.selection.active);
    const adjusted = adjustingDecimals(format, delta, typeof sample === "number" ? sample : undefined);
    if (adjusted === format) return;
    this.applyStyle(delta > 0 ? "Increase Decimal" : "Decrease Decimal", (s) => ({ ...s, numberFormat: adjusted }));
  }

  setRotation(degrees: number) {
    this.applyStyle("Orientation", (s) => ({ ...s, rotation: degrees }), true);
  }

  applyNamedStyle(named: NamedCellStyle) {
    this.applyStyle("Cell Style", (s) => applyNamedStyleTo(named, s), true);
  }

  applyBorders(preset: BorderPreset, line: BorderLine = { style: "thin", color: "#000000" }) {
    this.commitEditingIfNeeded();
    const ranges = this.selection.ranges.map((r) => this.boundedToContent(r));
    this.changeSheet(BORDER_TITLES[preset], (sheet) => {
      const thick: BorderLine = { style: "thick", color: line.color };
      const double: BorderLine = { style: "double", color: line.color };
      const edit = (row: number, column: number, change: (b: CellBorders) => CellBorders) =>
        updateStyle(sheet, row, column, (s) => ({ ...s, borders: change({ ...(s.borders ?? {}) }) }));
      for (const r of ranges) {
        if (cellCount(r) > 1_000_000) continue;
        forEachCell(r, (row, column) => {
          const top = row === r.start.row, bottom = row === r.end.row, left = column === r.start.column, right = column === r.end.column;
          switch (preset) {
            case "all": edit(row, column, () => ({ top: line, left: line, bottom: line, right: line })); break;
            case "none": edit(row, column, () => ({})); break;
            case "outside": case "thickOutside": {
              const l = preset === "thickOutside" ? thick : line;
              if (top || bottom || left || right) edit(row, column, (b) => ({ ...b, ...(top ? { top: l } : {}), ...(bottom ? { bottom: l } : {}), ...(left ? { left: l } : {}), ...(right ? { right: l } : {}) }));
              break;
            }
            case "bottom": if (bottom) edit(row, column, (b) => ({ ...b, bottom: line })); break;
            case "top": if (top) edit(row, column, (b) => ({ ...b, top: line })); break;
            case "left": if (left) edit(row, column, (b) => ({ ...b, left: line })); break;
            case "right": if (right) edit(row, column, (b) => ({ ...b, right: line })); break;
            case "doubleBottom": if (bottom) edit(row, column, (b) => ({ ...b, bottom: double })); break;
            case "thickBottom": if (bottom) edit(row, column, (b) => ({ ...b, bottom: thick })); break;
            case "topAndBottom":
              if (top) edit(row, column, (b) => ({ ...b, top: line }));
              if (bottom) edit(row, column, (b) => ({ ...b, bottom: line }));
              break;
            case "topAndDoubleBottom":
              if (top) edit(row, column, (b) => ({ ...b, top: line }));
              if (bottom) edit(row, column, (b) => ({ ...b, bottom: double }));
              break;
            case "insideHorizontal": if (!bottom) edit(row, column, (b) => ({ ...b, bottom: line })); break;
            case "insideVertical": if (!right) edit(row, column, (b) => ({ ...b, right: line })); break;
          }
        });
        if (preset === "none") {
          // Clear the facing edges of neighbours too.
          const without = (row: number, column: number, side: keyof CellBorders) => {
            if (getCell(sheet, row, column)?.style?.borders?.[side]) edit(row, column, (b) => { const copy = { ...b }; delete copy[side]; return copy; });
          };
          for (let c = r.start.column; c <= r.end.column; c++) {
            if (r.start.row > 0) without(r.start.row - 1, c, "bottom");
            without(r.end.row + 1, c, "top");
          }
          for (let row = r.start.row; row <= r.end.row; row++) {
            if (r.start.column > 0) without(row, r.start.column - 1, "right");
            without(row, r.end.column + 1, "left");
          }
        }
      }
    });
  }

  async merge(mode: MergeMode) {
    this.commitEditingIfNeeded();
    const ranges = this.selection.ranges.filter((r) => !isSingleCell(r) && cellCount(r) < 1_000_000);
    const sheet = this.sheet;
    if (mode === "unmerge" || (mode === "mergeAndCenter" && ranges.length && ranges.every((r) => sheet.merges.some((m) => sameRange(m, r))))) {
      const selected = this.selection.ranges;
      this.changeSheet("Unmerge Cells", (s) => { s.merges = s.merges.filter((m) => !selected.some((r) => rangesIntersect(r, m))); }, true);
      return;
    }
    if (!ranges.length) return;
    // Warn when merging would discard values.
    const losesData = mode !== "mergeAcross" && ranges.some((r) => {
      let found = false;
      forEachCell(r, (row, column) => { if ((row !== r.start.row || column !== r.start.column) && cellHasContent(sheet, row, column)) found = true; });
      return found;
    });
    if (losesData && !(await this.presenter.confirm("Merging cells only keeps the upper-left value.", "The other values will be discarded.", "Merge"))) return;
    this.changeSheet(mode === "mergeAndCenter" ? "Merge & Center" : "Merge Cells", (s) => {
      const targets: CellRange[] = [];
      for (const r of ranges) {
        if (mode === "mergeAcross") for (let row = r.start.row; row <= r.end.row; row++) targets.push(rangeRC(row, r.start.column, row, r.end.column));
        else targets.push(r);
      }
      for (const t of targets) {
        if (isSingleCell(t)) continue;
        s.merges = s.merges.filter((m) => !rangesIntersect(m, t));
        s.merges.push(t);
        forEachCell(t, (row, column) => {
          if (row === t.start.row && column === t.start.column) return;
          const cell = getCell(s, row, column);
          if (cell) setCell(s, row, column, { ...cell, value: null, formula: undefined });
        });
        if (mode === "mergeAndCenter") updateStyle(s, t.start.row, t.start.column, (st) => ({ ...st, horizontal: "center" }));
      }
    }, true);
    if (ranges[0]) this.selectRange(ranges[0]);
  }

  get selectionIsMerged(): boolean {
    return this.sheet.merges.some((m) => sameRange(m, primaryRange(this.selection)));
  }

  captureFormatPainter(sticky: boolean) {
    const r = this.boundedToContent(primaryRange(this.selection));
    if (cellCount(r) > 10_000) return;
    const styles: CellStyle[][] = [];
    for (let row = r.start.row; row <= r.end.row; row++) {
      const line: CellStyle[] = [];
      for (let column = r.start.column; column <= r.end.column; column++) line.push(styleAt(this.sheet, row, column));
      styles.push(line);
    }
    this.formatPainter = { styles, sticky };
    this.emit("status");
  }

  applyFormatPainter() {
    const painter = this.formatPainter;
    if (!painter || !painter.styles[0]?.length) return;
    const target = primaryRange(this.selection);
    const height = painter.styles.length, width = painter.styles[0].length;
    const r = isSingleCell(target) ? rangeRC(target.start.row, target.start.column, target.start.row + height - 1, target.start.column + width - 1) : this.boundedToContent(target);
    if (!painter.sticky) this.formatPainter = null;
    this.changeSheet("Paste Formatting", (sheet) => {
      forEachCell(r, (row, column) => {
        const style = painter.styles[(row - r.start.row) % height][(column - r.start.column) % width];
        const cell = getCell(sheet, row, column);
        setCell(sheet, row, column, { ...(cell ?? { value: null }), style: isPlainStyle(style) ? undefined : style });
      });
    });
    this.emit("status");
  }

  cancelFormatPainter() {
    if (!this.formatPainter) return;
    this.formatPainter = null;
    this.emit("status");
  }

  // MARK: Sizes

  setColumnWidth(width: number, columns: number[]) {
    this.changeSheet("Column Width", (sheet) => {
      for (const column of columns) {
        if (width <= 0) {
          sheet.hiddenColumns.add(column);
          sheet.columnWidths.delete(column);
        } else {
          sheet.hiddenColumns.delete(column);
          if (Math.abs(width - DEFAULT_COLUMN_WIDTH) < 0.01) sheet.columnWidths.delete(column);
          else sheet.columnWidths.set(column, width);
        }
      }
    }, true);
  }

  setRowHeight(height: number, rows: number[]) {
    this.changeSheet("Row Height", (sheet) => {
      for (const row of rows) {
        if (height <= 0) {
          sheet.hiddenRows.add(row);
          sheet.rowHeights.delete(row);
        } else {
          sheet.hiddenRows.delete(row);
          if (Math.abs(height - DEFAULT_ROW_HEIGHT) < 0.01) sheet.rowHeights.delete(row);
          else sheet.rowHeights.set(row, height);
        }
      }
    }, true);
    const auto = this.autoSizedRows;
    rows.forEach((r) => auto.delete(r));
  }

  /** The width that fits a column's widest value. */
  fittingWidth(column: number): number {
    let width = 0;
    const sheet = this.sheet;
    for (const [key, cell] of sheet.cells) {
      const a = keyAddress(key);
      if (a.column !== column || !hasContent(cell) || mergeContaining(sheet, a)) continue;
      const style = styleAt(sheet, a.row, a.column);
      const text = formatValue(this.value(a), numberFormatOf(style)).text;
      const widest = text.split("\n").reduce((w, line) => Math.max(w, this.measurer.width(line, style)), 0);
      width = Math.max(width, widest + 10 + (style.indent ?? 0) * 9);
    }
    return width === 0 ? DEFAULT_COLUMN_WIDTH : Math.min(Math.max(width, 12), 1500);
  }

  autoFitColumns(columns: number[]) {
    const widths = columns.map((c) => [c, this.fittingWidth(c)] as const);
    this.changeSheet("AutoFit Column Width", (sheet) => {
      for (const [column, width] of widths) {
        if (Math.abs(width - DEFAULT_COLUMN_WIDTH) < 0.5) sheet.columnWidths.delete(column);
        else sheet.columnWidths.set(column, width);
        sheet.hiddenColumns.delete(column);
      }
    }, true);
  }

  autoFitRows(rows: number[]) {
    const heights = rows.map((r) => [r, this.fittingHeight(r, this.sheet)] as const);
    this.changeSheet("AutoFit Row Height", (sheet) => {
      for (const [row, height] of heights) {
        if (Math.abs(height - DEFAULT_ROW_HEIGHT) < 0.5) sheet.rowHeights.delete(row);
        else sheet.rowHeights.set(row, height);
        sheet.hiddenRows.delete(row);
      }
    }, true);
  }

  /** Columns touched by the selection (bounded to content for whole-row selections). */
  get selectedColumnIndices(): number[] {
    const set = new Set<number>();
    for (const r of this.selection.ranges) {
      const bounded = isWholeRows(r) ? this.boundedToContent(r) : r;
      if (columnCount(bounded) > 20_000) continue;
      for (let c = bounded.start.column; c <= bounded.end.column; c++) set.add(c);
    }
    return [...set].sort((a, b) => a - b);
  }

  get selectedRowIndices(): number[] {
    const set = new Set<number>();
    for (const r of this.selection.ranges) {
      const bounded = isWholeColumns(r) ? this.boundedToContent(r) : r;
      if (rowCount(bounded) > 200_000) continue;
      for (let row = bounded.start.row; row <= bounded.end.row; row++) set.add(row);
    }
    return [...set].sort((a, b) => a - b);
  }

  // MARK: - Data: AutoFill

  /** Fills `target` (which contains `source`) by extending the source pattern. */
  autoFill(source: CellRange, target: CellRange, copyOnly = false) {
    this.commitEditingIfNeeded();
    if (rangeContainsRange(source, target) && !sameRange(source, target)) {
      // Dragging the handle back over the selection clears the excess.
      this.changeSheet("Clear Contents", (sheet) => {
        forEachCell(source, (row, column) => {
          if (rangeContains(target, { row, column })) return;
          const cell = getCell(sheet, row, column);
          if (cell) setCell(sheet, row, column, { ...cell, value: null, formula: undefined });
        });
      });
      this.selectRange(target);
      return;
    }
    if (sameRange(source, target)) return;
    const vertical = rowCount(target) !== rowCount(source);
    const reverse = vertical ? target.start.row < source.start.row : target.start.column < source.start.column;
    const count = vertical ? rowCount(target) - rowCount(source) : columnCount(target) - columnCount(source);
    const snapshot = this.sheet;
    this.changeSheet("AutoFill", (sheet) => {
      const lines = vertical ? [source.start.column, source.end.column] : [source.start.row, source.end.row];
      for (let line = lines[0]; line <= lines[1]; line++) {
        const addresses: CellAddress[] = [];
        if (vertical) for (let row = source.start.row; row <= source.end.row; row++) addresses.push({ row, column: line });
        else for (let column = source.start.column; column <= source.end.column; column++) addresses.push({ row: line, column });
        const cells = addresses.map((a) => getCell(snapshot, a.row, a.column));
        const styles = addresses.map((a) => styleAt(snapshot, a.row, a.column));
        const generated = extendFill(cells, styles, count, reverse, vertical ? [1, 0] : [0, 1], copyOnly);
        generated.forEach((cell, k) => {
          const offset = k + 1;
          const a = vertical
            ? { row: reverse ? source.start.row - offset : source.end.row + offset, column: line }
            : { row: line, column: reverse ? source.start.column - offset : source.end.column + offset };
          if (isValidAddress(a)) setCell(sheet, a.row, a.column, cell);
        });
      }
    });
    this.selectRange(target, this.selection.active);
  }

  /** Ctrl+D / Ctrl+R: copies the first row (column) of the selection into the rest. */
  fill(down: boolean) {
    this.commitEditingIfNeeded();
    let r = this.boundedToContent(primaryRange(this.selection));
    if (down && rowCount(r) === 1) {
      if (r.start.row === 0) return;
      r = rangeRC(r.start.row - 1, r.start.column, r.end.row, r.end.column);
    } else if (!down && columnCount(r) === 1) {
      if (r.start.column === 0) return;
      r = rangeRC(r.start.row, r.start.column - 1, r.end.row, r.end.column);
    }
    const snapshot = this.sheet;
    this.changeSheet(down ? "Fill Down" : "Fill Right", (sheet) => {
      forEachCell(r, (row, column) => {
        const source = down ? { row: r.start.row, column } : { row, column: r.start.column };
        if (source.row === row && source.column === column) return;
        let cell = getCell(snapshot, source.row, source.column);
        if (cell?.formula !== undefined) cell = { ...cell, formula: shiftFormula(cell.formula, row - source.row, column - source.column) };
        setCell(sheet, row, column, cell);
      });
    });
  }

  /** Fills the selection with a linear series. */
  fillSeries(step: number, vertical: boolean) {
    const r = primaryRange(this.selection);
    const startValue = this.value(r.start);
    const start = typeof startValue === "number" ? startValue : 1;
    this.changeSheet("Fill Series", (sheet) => {
      const lines = vertical ? [r.start.column, r.end.column] : [r.start.row, r.end.row];
      for (let line = lines[0]; line <= lines[1]; line++) {
        const baseValue = vertical ? this.value({ row: r.start.row, column: line }) : this.value({ row: line, column: r.start.column });
        const base = typeof baseValue === "number" ? baseValue : start;
        const [from, to] = vertical ? [r.start.row, r.end.row] : [r.start.column, r.end.column];
        for (let k = 0; from + k <= to; k++) {
          const row = vertical ? from + k : line, column = vertical ? line : from + k;
          const cell = getCell(sheet, row, column);
          setCell(sheet, row, column, { ...(cell ?? { value: null }), formula: undefined, value: base + k * step });
        }
      }
    });
  }

  // MARK: Sorting

  /** The range a quick sort or filter acts on: the selection, or the data around the active cell. */
  get dataRangeForCommand(): CellRange {
    const primary = primaryRange(this.selection);
    if (!isSingleCell(primary)) return this.boundedToContent(primary);
    return currentRegion(this.sheet, this.selection.active);
  }

  /** Whether the first row of a range looks like a header row. */
  looksLikeHeader(r: CellRange): boolean {
    if (rowCount(r) <= 1) return false;
    const table = this.sheet.tables.find((t) => sameRange(t.range, r));
    if (table) return table.showHeader;
    if (this.sheet.filter && this.sheet.filter.range.start.row === r.start.row) return true;
    let headerText = 0, dataNumbers = 0;
    for (let column = r.start.column; column <= r.end.column; column++) {
      const top = this.value({ row: r.start.row, column });
      const next = this.value({ row: r.start.row + 1, column });
      if (typeof top === "string") headerText++;
      if (typeof next === "number") dataNumbers++;
      if (this.style({ row: r.start.row, column }).bold && !this.style({ row: r.start.row + 1, column }).bold) return true;
    }
    return headerText === columnCount(r) && dataNumbers > 0;
  }

  quickSort(ascending: boolean) {
    this.commitEditingIfNeeded();
    const r = this.dataRangeForCommand;
    this.sort(r, [{ column: this.selection.active.column, ascending }], this.looksLikeHeader(r));
  }

  sort(r: CellRange, keys: SortKey[], hasHeader: boolean) {
    if ((hasHeader && rowCount(r) <= 1) || !keys.length) return;
    const firstRow = hasHeader ? r.start.row + 1 : r.start.row;
    const dataRange = rangeRC(firstRow, r.start.column, Math.max(r.end.row, firstRow), r.end.column);
    const rows: number[] = [];
    for (let row = dataRange.start.row; row <= dataRange.end.row; row++) rows.push(row);
    const values = new Map<number, CellValue[]>(rows.map((row) => [row, keys.map((k) => this.value({ row, column: k.column }))]));
    const order = [...rows].sort((a, b) => {
      const x = values.get(a)!, y = values.get(b)!;
      for (let i = 0; i < keys.length; i++) {
        // Blanks always sort last.
        if ((x[i] === null) !== (y[i] === null)) return x[i] === null ? 1 : -1;
        const c = compareValues(x[i], y[i]);
        if (c !== 0) return keys[i].ascending ? c : -c;
      }
      return a - b;
    });
    if (order.every((row, i) => row === rows[i])) return;
    const snapshot = this.sheet;
    this.changeSheet("Sort", (sheet) => {
      order.forEach((sourceRow, offset) => {
        const targetRow = dataRange.start.row + offset;
        for (let column = dataRange.start.column; column <= dataRange.end.column; column++) {
          let cell = getCell(snapshot, sourceRow, column);
          if (cell?.formula !== undefined) cell = { ...cell, formula: shiftFormula(cell.formula, targetRow - sourceRow, 0) };
          setCell(sheet, targetRow, column, cell);
          const note = snapshot.notes.get(cellKey(sourceRow, column));
          if (note !== undefined) sheet.notes.set(cellKey(targetRow, column), note);
          else sheet.notes.delete(cellKey(targetRow, column));
        }
        if (snapshot.rowHeights.has(sourceRow) || snapshot.rowHeights.has(targetRow)) {
          const h = snapshot.rowHeights.get(sourceRow);
          if (h === undefined) sheet.rowHeights.delete(targetRow);
          else sheet.rowHeights.set(targetRow, h);
        }
      });
    });
    this.flash(`Sorted ${rows.length} rows`);
  }

  // MARK: Filtering

  toggleFilter() {
    this.commitEditingIfNeeded();
    if (this.sheet.filter) {
      this.changeSheet("Remove Filter", (sheet) => { sheet.filter = undefined; }, true);
      return;
    }
    const r = this.dataRangeForCommand;
    if (isSingleCell(r)) {
      this.presenter.alert("Select a range with data to filter.", "Filters go on the first row of the range.");
      return;
    }
    this.changeSheet("Filter", (sheet) => { sheet.filter = { range: r, criteria: new Map(), hiddenRows: new Set() }; }, true);
  }

  setFilterCriterion(criterion: FilterCriterion | undefined, column: number) {
    const current = this.sheet.filter;
    if (!current) return;
    const filter: AutoFilter = { range: current.range, criteria: new Map(current.criteria), hiddenRows: new Set() };
    if (criterion) filter.criteria.set(column, criterion);
    else filter.criteria.delete(column);
    filter.hiddenRows = this.hiddenRowsFor(filter);
    this.changeSheet("Filter", (sheet) => { sheet.filter = filter; }, true);
  }

  clearFilters() {
    const current = this.sheet.filter;
    if (!current) return;
    this.changeSheet("Clear Filter", (sheet) => { sheet.filter = { range: current.range, criteria: new Map(), hiddenRows: new Set() }; }, true);
  }

  reapplyFilter() {
    const current = this.sheet.filter;
    if (!current) return;
    let r = current.range;
    // Grow to include rows added under the data.
    const region = currentRegion(this.sheet, r.start);
    if (region.start.row === r.start.row) r = union(r, region);
    const filter: AutoFilter = { range: r, criteria: new Map(current.criteria), hiddenRows: new Set() };
    filter.hiddenRows = this.hiddenRowsFor(filter);
    this.changeSheet("Reapply Filter", (sheet) => { sheet.filter = filter; }, true);
  }

  hiddenRowsFor(filter: AutoFilter): Set<number> {
    const hidden = new Set<number>();
    if (filter.range.end.row <= filter.range.start.row || !filter.criteria.size) return hidden;
    for (let row = filter.range.start.row + 1; row <= filter.range.end.row; row++) {
      for (const [column, criterion] of filter.criteria) {
        const a = { row, column };
        if (!criterionMatches(criterion, this.value(a), this.displayText(a), null)) {
          hidden.add(row);
          break;
        }
      }
    }
    return hidden;
  }

  /** The distinct display texts in a filter column, with counts. */
  filterValues(column: number): { text: string; count: number }[] {
    const filter = this.sheet.filter;
    if (!filter || filter.range.end.row <= filter.range.start.row) return [];
    const counts = new Map<string, number>();
    const samples = new Map<string, CellValue>();
    for (let row = filter.range.start.row + 1; row <= filter.range.end.row; row++) {
      // Rows hidden by other columns' criteria don't contribute.
      if (filter.hiddenRows.has(row)) {
        let hiddenByOthers = false;
        for (const [c, criterion] of filter.criteria) {
          if (c !== column && !criterionMatches(criterion, this.value({ row, column: c }), this.displayText({ row, column: c }), null)) hiddenByOthers = true;
        }
        if (hiddenByOthers) continue;
      }
      const a = { row, column };
      const v = this.value(a);
      const text = v === null ? "" : this.displayText(a);
      counts.set(text, (counts.get(text) ?? 0) + 1);
      samples.set(text, v);
    }
    return [...counts.keys()].sort((a, b) => {
      if ((a === "") !== (b === "")) return a === "" ? 1 : -1;
      const c = compareValues(samples.get(a) ?? null, samples.get(b) ?? null);
      return c !== 0 ? c : a < b ? -1 : a > b ? 1 : 0;
    }).map((text) => ({ text, count: counts.get(text)! }));
  }

  // MARK: Data tools

  removeDuplicates(columns?: number[], hasHeader?: boolean) {
    this.commitEditingIfNeeded();
    const r = this.dataRangeForCommand;
    const header = hasHeader ?? this.looksLikeHeader(r);
    const keys = columns ?? Array.from({ length: columnCount(r) }, (_, i) => r.start.column + i);
    const dataRows: number[] = [];
    for (let row = header ? r.start.row + 1 : r.start.row; row <= r.end.row; row++) dataRows.push(row);
    const seen = new Set<string>();
    const keep: number[] = [];
    for (const row of dataRows) {
      const key = keys.map((c) => plainText(this.value({ row, column: c })).toLowerCase()).join("\u001F");
      if (!seen.has(key)) {
        seen.add(key);
        keep.push(row);
      }
    }
    const removed = dataRows.length - keep.length;
    if (removed <= 0) {
      this.presenter.alert("No duplicate values found.");
      return;
    }
    const snapshot = this.sheet;
    const firstRow = dataRows[0] ?? r.start.row;
    this.changeSheet("Remove Duplicates", (sheet) => {
      keep.forEach((sourceRow, offset) => {
        for (let column = r.start.column; column <= r.end.column; column++) {
          let cell = getCell(snapshot, sourceRow, column);
          if (cell?.formula !== undefined) cell = { ...cell, formula: shiftFormula(cell.formula, firstRow + offset - sourceRow, 0) };
          setCell(sheet, firstRow + offset, column, cell);
        }
      });
      for (let row = firstRow + keep.length; row < firstRow + dataRows.length; row++) {
        for (let column = r.start.column; column <= r.end.column; column++) sheet.cells.delete(cellKey(row, column));
      }
    });
    this.presenter.alert(`${removed} duplicate value${removed === 1 ? "" : "s"} found and removed; ${keep.length} unique value${keep.length === 1 ? "" : "s"} remain.`);
  }

  /** Splits the selected column into several at a delimiter. */
  textToColumns(delimiter: string) {
    this.commitEditingIfNeeded();
    if (!delimiter) return;
    const r = this.boundedToContent(primaryRange(this.selection));
    const column = r.start.column;
    this.changeSheet("Text to Columns", (sheet) => {
      for (let row = r.start.row; row <= r.end.row; row++) {
        const cell = getCell(sheet, row, column);
        if (!cell || cell.formula !== undefined || typeof cell.value !== "string") continue;
        cell.value.split(delimiter).forEach((part, offset) => {
          const target = { row, column: column + offset };
          let next: Cell | undefined;
          try { next = this.cellForInput(part.trim(), offset === 0 ? cell : getCell(sheet, target.row, target.column), target, sheet); } catch { next = undefined; }
          setCell(sheet, target.row, target.column, next);
        });
      }
    });
  }

  // MARK: Find and replace

  private cellMatches(a: CellAddress, sheetIndex: number, options: FindOptions): boolean {
    const sheet = this.workbook.sheets[sheetIndex];
    const formula = getCell(sheet, a.row, a.column)?.formula;
    const text = options.searchFormulas && formula !== undefined
      ? "=" + formula
      : formatValue(this.calculator.value(sheetIndex, a.row, a.column), numberFormatOf(styleAt(sheet, a.row, a.column))).text;
    if (options.entireCell) return options.matchCase ? text === options.text : text.toLowerCase() === options.text.toLowerCase();
    return options.matchCase ? text.includes(options.text) : text.toLowerCase().includes(options.text.toLowerCase());
  }

  private sortedKeys(sheetIndex: number, includeHidden = true): number[] {
    const sheet = this.workbook.sheets[sheetIndex];
    return [...sheet.cells.keys()].filter((k) => includeHidden || !isRowHidden(sheet, keyAddress(k).row)).sort((a, b) => a - b);
  }

  /** Selects the next match after the active cell. Returns false when there are none. */
  findNext(options: FindOptions, backwards = false): boolean {
    if (!options.text) return false;
    const count = this.workbook.sheets.length;
    const sheetOrder = options.wholeWorkbook ? [...Array(count).keys()].map((i) => (this.activeSheetIndex + i) % count) : [this.activeSheetIndex];
    const order = backwards ? [...sheetOrder].reverse() : sheetOrder;
    const start = cellKey(this.selection.active.row, this.selection.active.column);
    for (let position = 0; position < order.length; position++) {
      const sheetIndex = order[position];
      const keys = this.sortedKeys(sheetIndex, false);
      let candidates = backwards ? [...keys].reverse() : keys;
      if (sheetIndex === this.activeSheetIndex && position === 0) {
        const after = candidates.filter((k) => (backwards ? k < start : k > start));
        const before = candidates.filter((k) => (backwards ? k >= start : k <= start));
        candidates = order.length === 1 ? [...after, ...before] : after;
      }
      const match = candidates.find((k) => this.cellMatches(keyAddress(k), sheetIndex, options));
      if (match !== undefined) {
        if (sheetIndex !== this.activeSheetIndex) this.activateSheet(sheetIndex);
        this.select(keyAddress(match));
        return true;
      }
    }
    if (order.length > 1) {
      const match = this.sortedKeys(this.activeSheetIndex).find((k) => this.cellMatches(keyAddress(k), this.activeSheetIndex, options));
      if (match !== undefined) {
        this.select(keyAddress(match));
        return true;
      }
    }
    return false;
  }

  findAll(options: FindOptions): { sheet: number; address: CellAddress }[] {
    if (!options.text) return [];
    const indices = options.wholeWorkbook ? [...this.workbook.sheets.keys()] : [this.activeSheetIndex];
    const results: { sheet: number; address: CellAddress }[] = [];
    for (const index of indices) {
      for (const key of this.sortedKeys(index)) {
        const a = keyAddress(key);
        if (this.cellMatches(a, index, options)) results.push({ sheet: index, address: a });
      }
    }
    return results;
  }

  private replaced(text: string, options: FindOptions): string {
    if (options.entireCell) return options.replacement;
    if (options.matchCase) return text.split(options.text).join(options.replacement);
    return text.replace(new RegExp(options.text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "gi"), () => options.replacement);
  }

  /** Replaces the match in the active cell, then finds the next one. */
  replaceCurrent(options: FindOptions) {
    const a = this.selection.active;
    if (this.cellMatches(a, this.activeSheetIndex, options)) {
      const current = this.inputText(a);
      const updated = this.replaced(current, options);
      if (updated !== current) this.setInput(updated, a);
    }
    this.findNext(options);
  }

  replaceAll(options: FindOptions): number {
    const matches = this.findAll(options);
    if (!matches.length) return 0;
    let count = 0;
    this.change("Replace All", (workbook) => {
      for (const { sheet: index, address } of matches) {
        const current = this.inputText(address, index);
        const updated = this.replaced(current, options);
        if (updated === current) continue;
        const sheet = workbook.sheets[index];
        try {
          setCell(sheet, address.row, address.column, this.cellForInput(updated, getCell(sheet, address.row, address.column), address, sheet));
          count++;
        } catch {
          // Leave cells whose replacement isn't a valid formula.
        }
      }
    });
    return count;
  }

  // MARK: Go To Special

  selectSpecial(target: SpecialTarget) {
    const r = isSingleSelection(this.selection) ? (usedRange(this.sheet) ?? range({ row: 0, column: 0 })) : this.boundedToContent(primaryRange(this.selection));
    const matches: CellAddress[] = [];
    const sheet = this.sheet;
    try {
      forEachCell(r, (row, column) => {
        const cell = getCell(sheet, row, column);
        const a = { row, column };
        let hit = false;
        switch (target) {
          case "formulas": hit = cell?.formula !== undefined; break;
          case "constants": hit = cell?.formula === undefined && hasContent(cell); break;
          case "blanks": hit = !hasContent(cell); break;
          case "notes": hit = sheet.notes.has(cellKey(row, column)); break;
          case "errors": hit = this.value(a) instanceof FormulaError; break;
          case "conditionalFormats": hit = sheet.conditionalFormats.some((cf) => rangeContains(cf.range, a)); break;
        }
        if (hit) matches.push(a);
        if (matches.length > 5000) throw matches;
      });
    } catch (e) {
      if (e !== matches) throw e;
    }
    if (!matches.length) {
      this.presenter.alert("No cells were found.");
      return;
    }
    const [first, ...rest] = matches;
    this.setSelection({ active: first, anchor: first, ranges: [...rest.map((a) => range(a)), range(first)] });
  }

  // MARK: - Notes and links

  setNote(text: string | null, a: CellAddress) {
    const trimmed = text?.trim() ?? "";
    this.changeSheet(trimmed ? "Edit Note" : "Delete Note", (sheet) => {
      if (trimmed) sheet.notes.set(cellKey(a.row, a.column), trimmed);
      else sheet.notes.delete(cellKey(a.row, a.column));
    });
  }

  note(a: CellAddress): string | undefined {
    return this.sheet.notes.get(cellKey(a.row, a.column));
  }

  setLink(url: string | null, a: CellAddress, displayText?: string) {
    this.changeSheet("Hyperlink", (sheet) => {
      const cell: Cell = { ...(getCell(sheet, a.row, a.column) ?? { value: null }) };
      cell.link = url ? url : undefined;
      if (displayText && cell.formula === undefined) cell.value = displayText;
      else if (cell.value === null && url) cell.value = url;
      setCell(sheet, a.row, a.column, cell);
    });
  }

  /** The URL to open for a cell's link, after following links into the workbook ("#Sheet2!A1"). */
  followLink(a: CellAddress): string | null {
    const link = getCell(this.sheet, a.row, a.column)?.link;
    if (!link) return null;
    if (link.startsWith("#")) {
      this.goTo(link.slice(1));
      return null;
    }
    return link;
  }

  // MARK: - Charts

  /** Inserts a chart for the selection (or the data around the active cell). */
  insertChart(kind: ChartKind) {
    this.commitEditingIfNeeded();
    const r = this.dataRangeForCommand;
    if (cellCount(r) <= 1 && !cellHasContent(this.sheet, r.start.row, r.start.column)) {
      this.presenter.alert("Select the data you want to chart.", "Include column headers to name the series.");
      return;
    }
    // Place it beside the data.
    const chart: ChartObject = {
      id: uuid(), kind, dataRange: r, title: this.defaultChartTitle(r),
      frame: { x: this.columnOffset(r.end.column + 1) + 20, y: this.rowOffset(r.start.row), width: 480, height: 300 },
      seriesInColumns: true, showLegend: true, showDataLabels: false, showGridlines: true, palette: "grid", xAxisTitle: "", yAxisTitle: "",
    };
    this.changeSheet("Insert Chart", (sheet) => sheet.charts.push(chart));
    this.selectedChartId = chart.id;
    this.emit("chart");
  }

  private defaultChartTitle(r: CellRange): string {
    // A single series uses its header as the title.
    if (columnCount(r) === 2 && this.looksLikeHeader(r)) return plainText(this.value({ row: r.start.row, column: r.start.column + 1 }));
    return "Chart Title";
  }

  updateChart(chart: ChartObject, name = "Edit Chart") {
    this.changeSheet(name, (sheet) => {
      const index = sheet.charts.findIndex((c) => c.id === chart.id);
      if (index >= 0) sheet.charts[index] = chart;
    });
    this.emit("chart");
  }

  deleteChart(id: string) {
    this.changeSheet("Delete Chart", (sheet) => { sheet.charts = sheet.charts.filter((c) => c.id !== id); });
    if (this.selectedChartId === id) this.selectedChartId = null;
    this.emit("chart");
  }

  bringChartToFront(id: string) {
    this.changeSheet("Bring to Front", (sheet) => {
      const index = sheet.charts.findIndex((c) => c.id === id);
      if (index >= 0) sheet.charts.push(...sheet.charts.splice(index, 1));
    });
    this.emit("chart");
  }

  selectChart(id: string | null) {
    if (this.selectedChartId === id) return;
    this.selectedChartId = id;
    this.emit("chart");
  }

  columnOffset(column: number): number {
    const sheet = this.sheet;
    let x = column * DEFAULT_COLUMN_WIDTH;
    for (const [c, w] of sheet.columnWidths) if (c < column) x += w - DEFAULT_COLUMN_WIDTH;
    for (const c of sheet.hiddenColumns) if (c < column) x -= sheet.columnWidths.get(c) ?? DEFAULT_COLUMN_WIDTH;
    return x;
  }

  rowOffset(row: number): number {
    const sheet = this.sheet;
    let y = row * DEFAULT_ROW_HEIGHT;
    for (const [r, h] of sheet.rowHeights) if (r < row) y += h - DEFAULT_ROW_HEIGHT;
    for (const r of sheet.hiddenRows) if (r < row) y -= sheet.rowHeights.get(r) ?? DEFAULT_ROW_HEIGHT;
    return y;
  }

  // MARK: - Conditional formatting

  addConditionalFormat(rule: Rule, format: HighlightFormat = { fill: "#FFC7CE", text: "#9C0006", bold: false, italic: false }, target?: CellRange) {
    this.commitEditingIfNeeded();
    const cf: ConditionalFormat = { id: uuid(), range: target ?? this.boundedToContent(primaryRange(this.selection)), rule, format };
    this.changeSheet("Conditional Formatting", (sheet) => sheet.conditionalFormats.unshift(cf));
  }

  updateConditionalFormat(format: ConditionalFormat) {
    this.changeSheet("Edit Rule", (sheet) => {
      const index = sheet.conditionalFormats.findIndex((c) => c.id === format.id);
      if (index >= 0) sheet.conditionalFormats[index] = format;
    });
  }

  deleteConditionalFormat(id: string) {
    this.changeSheet("Delete Rule", (sheet) => { sheet.conditionalFormats = sheet.conditionalFormats.filter((c) => c.id !== id); });
  }

  clearConditionalFormats(selectionOnly: boolean) {
    const ranges = this.selection.ranges;
    this.changeSheet("Clear Rules", (sheet) => {
      sheet.conditionalFormats = selectionOnly ? sheet.conditionalFormats.filter((cf) => !ranges.some((r) => rangesIntersect(r, cf.range))) : [];
    });
  }

  // MARK: - Tables

  formatAsTable(style: TableStyle) {
    this.commitEditingIfNeeded();
    const r = this.dataRangeForCommand;
    if (isWholeColumns(r) || isWholeRows(r)) return;
    if (this.sheet.tables.some((t) => rangesIntersect(t.range, r))) {
      // Restyle the existing table.
      this.changeSheet("Table Style", (sheet) => {
        sheet.tables = sheet.tables.map((t) => (rangesIntersect(t.range, r) ? { ...t, style } : t));
      });
      return;
    }
    const all = this.workbook.sheets.flatMap((s) => s.tables);
    let number = this.sheet.tables.length + 1;
    while (all.some((t) => t.name === `Table${number}`)) number++;
    const hasHeader = this.looksLikeHeader(r) || rowCount(r) > 1;
    const table: TableObject = { id: uuid(), name: `Table${number}`, range: r, style, showHeader: hasHeader, bandedRows: true, showTotals: false };
    this.changeSheet("Format as Table", (sheet) => {
      sheet.tables.push(table);
      if (hasHeader && !sheet.filter) sheet.filter = { range: r, criteria: new Map(), hiddenRows: new Set() };
    }, true);
  }

  removeTable(a: CellAddress) {
    this.changeSheet("Convert to Range", (sheet) => {
      const table = sheet.tables.find((t) => rangeContains(t.range, a));
      if (!table) return;
      sheet.tables = sheet.tables.filter((t) => t.id !== table.id);
      if (sheet.filter && sameRange(sheet.filter.range, table.range)) sheet.filter = undefined;
    }, true);
  }

  updateTable(table: TableObject) {
    this.changeSheet("Table Options", (sheet) => {
      const index = sheet.tables.findIndex((t) => t.id === table.id);
      if (index < 0) return;
      const old = sheet.tables[index];
      sheet.tables[index] = table;
      if (table.showTotals === old.showTotals) return;
      // A totals row adds SUBTOTAL formulas under numeric columns.
      const totalRow = table.showTotals ? old.range.end.row + 1 : old.range.end.row;
      if (table.showTotals) {
        sheet.tables[index] = { ...table, range: rangeRC(old.range.start.row, old.range.start.column, totalRow, old.range.end.column) };
        const firstData = Math.min(old.range.start.row + (table.showHeader ? 1 : 0), old.range.end.row);
        for (let column = old.range.start.column; column <= old.range.end.column; column++) {
          let numeric = false;
          for (let row = firstData; row <= old.range.end.row; row++) if (typeof this.value({ row, column }) === "number") numeric = true;
          const cell: Cell = { ...(getCell(sheet, totalRow, column) ?? { value: null }) };
          if (column === old.range.start.column && !numeric) cell.value = "Total";
          else if (numeric) cell.formula = "SUBTOTAL(109," + rangeA1(rangeRC(firstData, column, old.range.end.row, column)) + ")";
          setCell(sheet, totalRow, column, cell);
        }
      } else {
        for (let column = old.range.start.column; column <= old.range.end.column; column++) sheet.cells.delete(cellKey(totalRow, column));
        sheet.tables[index] = { ...table, range: rangeRC(old.range.start.row, old.range.start.column, totalRow - 1, old.range.end.column) };
      }
    }, true);
  }

  // MARK: - Defined names

  static isValidName(name: string): boolean {
    if (!name || !/^[\p{L}_\\]/u.test(name)) return false;
    if (![...name].every((c) => /[\p{L}\p{N}_.]/u.test(c) || c === "\\")) return false;
    if (parseRange(name)) return false;
    return !["TRUE", "FALSE", "R", "C"].includes(name.toUpperCase());
  }

  defineName(name: string, formula: string, comment = "", replacing?: string): boolean {
    if (!WorkbookController.isValidName(name)) {
      this.presenter.alert(`The name “${name}” isn't valid.`, "Names must start with a letter or underscore, contain no spaces, and not look like a cell reference.");
      return false;
    }
    const existing = definedName(this.workbook, name);
    if (existing && !sameName(existing.name, replacing ?? "")) {
      this.presenter.alert(`The name “${existing.name}” already exists.`, "Choose a unique name.");
      return false;
    }
    let body = formula.trim();
    if (body.startsWith("=")) body = body.slice(1);
    try {
      parseFormula(body);
    } catch {
      this.presenter.alert("The reference isn't valid.");
      return false;
    }
    this.change("Define Name", (workbook) => {
      if (replacing) workbook.names = workbook.names.filter((n) => !sameName(n.name, replacing));
      workbook.names.push({ name, formula: body, comment });
      workbook.names.sort((a, b) => (a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1));
    });
    return true;
  }

  deleteName(name: string) {
    this.change("Delete Name", (workbook) => { workbook.names = workbook.names.filter((n) => !sameName(n.name, name)); });
  }

  /** A name for the selection, as the name box creates when you type a new name. */
  nameSelection(name: string): boolean {
    return this.defineName(name, quotedSheetName(this.sheet.name) + "!" + absoluteReference(primaryRange(this.selection)));
  }

  // MARK: - Page setup

  updatePageSetup(setup: PageSetup) {
    this.changeSheet("Page Setup", (sheet) => { sheet.pageSetup = setup; });
  }

  setPrintArea() {
    const r = this.boundedToContent(primaryRange(this.selection));
    this.changeSheet("Set Print Area", (sheet) => { sheet.pageSetup = { ...sheet.pageSetup, printArea: r }; });
  }

  clearPrintArea() {
    this.changeSheet("Clear Print Area", (sheet) => {
      const setup = { ...sheet.pageSetup };
      delete setup.printArea;
      sheet.pageSetup = setup;
    });
  }

  // Selection helpers re-exported for views.
  get isSingleCellSelected() { return isSingleSelection(this.selection); }
  get isMultipleSelected() { return isMultipleSelection(this.selection); }
  get selectedColumnSet() { return selectedColumns(this.selection); }
  get selectedRowSet() { return selectedRows(this.selection); }
}

// MARK: - Helpers

export function criterionMatches(criterion: FilterCriterion, value: CellValue, text: string, stats: ConditionalStats | null): boolean {
  if (criterion.type === "values") return criterion.values.includes(value === null ? "" : text);
  return ruleMatches(criterion.rule, value, stats);
}

export function absoluteReference(r: CellRange): string {
  const abs = (a: CellAddress) => "$" + columnName(a.column) + "$" + String(a.row + 1);
  if (isWholeColumns(r)) return "$" + columnName(r.start.column) + ":$" + columnName(r.end.column);
  if (isWholeRows(r)) return `$${r.start.row + 1}:$${r.end.row + 1}`;
  return isSingleCell(r) ? abs(r.start) : abs(r.start) + ":" + abs(r.end);
}

/** Applies `transform` to every formula in the workbook (and formula rules). */
export function rewriteFormulas(workbook: Workbook, transform: (formula: string, sheetName: string) => string) {
  for (const sheet of workbook.sheets) {
    for (const [key, cell] of sheet.cells) {
      if (cell.formula === undefined) continue;
      const updated = transform(cell.formula, sheet.name);
      if (updated !== cell.formula) sheet.cells.set(key, { ...cell, formula: updated });
    }
    sheet.conditionalFormats = sheet.conditionalFormats.map((cf) =>
      cf.rule.type === "formula" ? { ...cf, rule: { type: "formula", formula: transform(cf.rule.formula, sheet.name) } } : cf);
  }
}

/** Moves everything on a sheet for an insertion or deletion. */
export function remapSheet(sheet: Sheet, change: StructuralChange) {
  const cells = new Map<number, Cell>();
  for (const [key, cell] of sheet.cells) {
    const moved = mapAddress(change, keyAddress(key));
    if (moved && isValidAddress(moved)) cells.set(cellKey(moved.row, moved.column), cell);
  }
  sheet.cells = cells;
  const notes = new Map<number, string>();
  for (const [key, note] of sheet.notes) {
    const moved = mapAddress(change, keyAddress(key));
    if (moved && isValidAddress(moved)) notes.set(cellKey(moved.row, moved.column), note);
  }
  sheet.notes = notes;
  const remapMap = <T>(map: Map<number, T>) => {
    const result = new Map<number, T>();
    for (const [index, value] of map) {
      const moved = mapIndex(change, index);
      if (moved !== null) result.set(moved, value);
    }
    return result;
  };
  const remapSet = (set: Set<number>) => new Set([...set].map((i) => mapIndex(change, i)).filter((i): i is number => i !== null));
  if (affectsRows(change)) {
    sheet.rowHeights = remapMap(sheet.rowHeights);
    sheet.rowStyles = remapMap(sheet.rowStyles);
    sheet.hiddenRows = remapSet(sheet.hiddenRows);
  } else {
    sheet.columnWidths = remapMap(sheet.columnWidths);
    sheet.columnStyles = remapMap(sheet.columnStyles);
    sheet.hiddenColumns = remapSet(sheet.hiddenColumns);
  }
  sheet.merges = sheet.merges.map((m) => mapRange(change, m)).filter((m): m is CellRange => !!m && !isSingleCell(m));
  sheet.conditionalFormats = sheet.conditionalFormats.flatMap((cf) => {
    const r = mapRange(change, cf.range);
    return r ? [{ ...cf, range: r }] : [];
  });
  sheet.charts = sheet.charts.flatMap((chart) => {
    const r = mapRange(change, chart.dataRange);
    return r ? [{ ...chart, dataRange: r }] : [];
  });
  sheet.tables = sheet.tables.flatMap((table) => {
    const r = mapRange(change, table.range);
    return r ? [{ ...table, range: r }] : [];
  });
  if (sheet.filter) {
    const r = mapRange(change, sheet.filter.range);
    if (r) {
      const filter: AutoFilter = { range: r, criteria: new Map(sheet.filter.criteria), hiddenRows: new Set(sheet.filter.hiddenRows) };
      if (affectsRows(change)) filter.hiddenRows = remapSet(filter.hiddenRows);
      else filter.criteria = remapMap(filter.criteria);
      sheet.filter = filter;
    } else {
      sheet.filter = undefined;
    }
  }
  if (sheet.pageSetup.printArea) {
    const r = mapRange(change, sheet.pageSetup.printArea);
    sheet.pageSetup = { ...sheet.pageSetup, printArea: r ?? undefined };
    if (!r) delete sheet.pageSetup.printArea;
  }
}

/** Applies a style transform to ranges, including whole rows and columns. */
export function applyStyleToRanges(transform: (style: CellStyle) => CellStyle, ranges: CellRange[], sheet: Sheet, extent: CellAddress) {
  const restyle = (s: CellStyle | undefined) => normalizeStyle(transform({ ...(s ?? {}) }));
  for (const r of ranges) {
    if (isWholeColumns(r) || isWholeRows(r)) {
      if (isWholeColumns(r)) {
        const last = isWholeRows(r) ? Math.max(extent.column, 25) : r.end.column;
        for (let column = r.start.column; column <= last; column++) {
          const style = restyle(sheet.columnStyles.get(column));
          if (isPlainStyle(style)) sheet.columnStyles.delete(column);
          else sheet.columnStyles.set(column, style);
        }
      }
      if (isWholeRows(r) && !isWholeColumns(r)) {
        for (let row = r.start.row; row <= r.end.row; row++) {
          const style = restyle(sheet.rowStyles.get(row));
          if (isPlainStyle(style)) sheet.rowStyles.delete(row);
          else sheet.rowStyles.set(row, style);
        }
      }
      for (const key of [...sheet.cells.keys()]) {
        const a = keyAddress(key);
        if (rangeContains(r, a)) updateStyle(sheet, a.row, a.column, transform);
      }
      // Row styles override column styles, so restyle rows crossing the columns too.
      if (isWholeColumns(r)) {
        for (const [row, rowStyle] of sheet.rowStyles) {
          const style = restyle(rowStyle);
          const last = Math.min(r.end.column, Math.max(extent.column, 25));
          for (let column = r.start.column; column <= last; column++) {
            const cell = getCell(sheet, row, column);
            if (!cell?.style) setCell(sheet, row, column, { ...(cell ?? { value: null }), style });
          }
        }
      }
    } else {
      if (cellCount(r) > 2_000_000) continue;
      forEachCell(r, (row, column) => updateStyle(sheet, row, column, transform));
    }
  }
}

function htmlCell(text: string, style: CellStyle): string {
  let css = "";
  if (style.bold) css += "font-weight:bold;";
  if (style.italic) css += "font-style:italic;";
  if (style.underline) css += "text-decoration:underline;";
  if (style.textColor) css += `color:${style.textColor};`;
  if (style.fillColor) css += `background:${style.fillColor};`;
  if (style.fontSize) css += `font-size:${Math.round(style.fontSize)}pt;`;
  if (style.horizontal === "center") css += "text-align:center;";
  if (style.horizontal === "right") css += "text-align:right;";
  const escaped = text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  return `<td style="${css}">${escaped}</td>`;
}

export { selectionOf };
