import {
  MAX_COLUMNS, MAX_ROWS, cellKey, keyAddress, rangeContains, rangeContainsRange, rangeRC, rangesIntersect, union,
  type CellAddress, type CellRange,
} from "./address";
import type { CellValue } from "./values";

// MARK: - Styles

/** "#RRGGBB" */
export type Color = string;

export type HorizontalAlignment = "general" | "left" | "center" | "right" | "fill" | "justify" | "centerAcross";
export type VerticalAlignment = "top" | "middle" | "bottom";
export type BorderLineStyle = "thin" | "medium" | "thick" | "dashed" | "dotted" | "double" | "hair";

export const BORDER_WIDTHS: Record<BorderLineStyle, number> = { hair: 0.5, thin: 1, dashed: 1, dotted: 1, medium: 2, thick: 3, double: 3 };

export interface BorderLine {
  style: BorderLineStyle;
  color: Color;
}

export interface CellBorders {
  top?: BorderLine;
  left?: BorderLine;
  bottom?: BorderLine;
  right?: BorderLine;
}

/**
 * Everything about how a cell looks. Stored sparsely: a missing field has its
 * default value (see `PLAIN_STYLE`), so `{}` is an unformatted cell.
 */
export interface CellStyle {
  fontName?: string;
  fontSize?: number;
  bold?: boolean;
  italic?: boolean;
  underline?: boolean;
  doubleUnderline?: boolean;
  strikethrough?: boolean;
  textColor?: Color;
  fillColor?: Color;
  horizontal?: HorizontalAlignment;
  vertical?: VerticalAlignment;
  wrap?: boolean;
  shrinkToFit?: boolean;
  indent?: number;
  rotation?: number;
  numberFormat?: string;
  borders?: CellBorders;
  locked?: boolean;
}

/** Default values for every style field. */
export const STYLE_DEFAULTS = {
  bold: false, italic: false, underline: false, doubleUnderline: false, strikethrough: false,
  horizontal: "general", vertical: "bottom", wrap: false, shrinkToFit: false, indent: 0, rotation: 0,
  numberFormat: "General", locked: true,
} as const;

export const DEFAULT_FONT_NAME = "Helvetica Neue";
export const DEFAULT_FONT_SIZE = 12;

/** Removes fields that hold their default value, so equal styles have equal shapes. */
export function normalizeStyle(style: CellStyle): CellStyle {
  const out: CellStyle = {};
  const defaults = STYLE_DEFAULTS as Record<string, unknown>;
  for (const [key, value] of Object.entries(style) as [keyof CellStyle, unknown][]) {
    if (value === undefined || value === null) continue;
    if (key in defaults && defaults[key] === value) continue;
    if (key === "borders") {
      const b = value as CellBorders;
      const borders: CellBorders = {};
      for (const side of ["top", "left", "bottom", "right"] as const) if (b[side]) borders[side] = { style: b[side]!.style, color: b[side]!.color };
      if (Object.keys(borders).length) out.borders = borders;
      continue;
    }
    (out as Record<string, unknown>)[key] = value;
  }
  return out;
}

export const isPlainStyle = (style: CellStyle) => Object.keys(normalizeStyle(style)).length === 0;

/** A stable key for comparing and pooling styles. */
export function styleKey(style: CellStyle): string {
  const n = normalizeStyle(style);
  return JSON.stringify(n, Object.keys(n).sort().concat(["top", "left", "bottom", "right", "style", "color"]));
}

export const sameStyle = (a: CellStyle | undefined, b: CellStyle | undefined) => styleKey(a ?? {}) === styleKey(b ?? {});

export const numberFormatOf = (style: CellStyle) => style.numberFormat ?? "General";

// MARK: - Cells and sheets

/** One cell's stored contents: a literal value or a formula, plus formatting. */
export interface Cell {
  /** The literal value. For formula cells this is the last computed value (used for files). */
  value: CellValue;
  /** Formula text without the leading "=". */
  formula?: string;
  /** Explicit formatting; undefined inherits the row or column style. */
  style?: CellStyle;
  link?: string;
}

export const isVacant = (c: Cell) => c.formula === undefined && c.value === null && c.style === undefined && c.link === undefined;
export const hasContent = (c: Cell | undefined) => !!c && (c.formula !== undefined || c.value !== null);

export interface PageSetup {
  orientation: "portrait" | "landscape";
  scaling: "actual" | "fitWidth" | "fitPage";
  margin: number;
  printGridlines: boolean;
  printHeadings: boolean;
  printArea?: CellRange;
  centerHorizontally: boolean;
  header: string;
  footer: string;
}

export const defaultPageSetup = (): PageSetup => ({
  orientation: "portrait", scaling: "actual", margin: 36, printGridlines: false, printHeadings: false,
  centerHorizontally: false, header: "", footer: "Page &P of &N",
});

/** A defined name such as `TaxRate` → `Sheet1!$B$2`. */
export interface DefinedName {
  name: string;
  /** A formula body such as "Sheet1!$B$2" or "0.07". */
  formula: string;
  comment: string;
}

// MARK: Conditional formatting

export type IconSet = "arrows" | "trafficLights" | "flags" | "stars";
export const ICON_SET_TITLES: Record<IconSet, string> = { arrows: "3 Arrows", trafficLights: "3 Traffic Lights", flags: "3 Flags", stars: "3 Stars" };

export type Rule =
  | { type: "greaterThan"; value: number }
  | { type: "lessThan"; value: number }
  | { type: "between"; low: number; high: number }
  | { type: "equalTo"; text: string }
  | { type: "notEqualTo"; text: string }
  | { type: "textContains"; text: string }
  | { type: "beginsWith"; text: string }
  | { type: "endsWith"; text: string }
  | { type: "blanks" }
  | { type: "noBlanks" }
  | { type: "duplicates" }
  | { type: "uniques" }
  | { type: "top"; count: number; percent: boolean }
  | { type: "bottom"; count: number; percent: boolean }
  | { type: "aboveAverage" }
  | { type: "belowAverage" }
  | { type: "formula"; formula: string }
  | { type: "colorScale"; colors: Color[] }
  | { type: "dataBar"; color: Color }
  | { type: "iconSet"; set: IconSet };

export const isVisualization = (r: Rule) => r.type === "colorScale" || r.type === "dataBar" || r.type === "iconSet";

/** The look applied by a highlight rule. */
export interface HighlightFormat {
  fill?: Color;
  text?: Color;
  bold: boolean;
  italic: boolean;
  border?: Color;
}

export const HIGHLIGHT_PRESETS: [string, HighlightFormat][] = [
  ["Light Red Fill with Dark Red Text", { fill: "#FFC7CE", text: "#9C0006", bold: false, italic: false }],
  ["Yellow Fill with Dark Yellow Text", { fill: "#FFEB9C", text: "#9C5700", bold: false, italic: false }],
  ["Green Fill with Dark Green Text", { fill: "#C6EFCE", text: "#006100", bold: false, italic: false }],
  ["Light Red Fill", { fill: "#FFC7CE", bold: false, italic: false }],
  ["Red Text", { text: "#9C0006", bold: false, italic: false }],
  ["Red Border", { border: "#C00000", bold: false, italic: false }],
];

export interface ConditionalFormat {
  id: string;
  range: CellRange;
  rule: Rule;
  format: HighlightFormat;
}

// MARK: AutoFilter

export type FilterCriterion = { type: "values"; values: string[] } | { type: "condition"; rule: Rule };

/** Filter buttons on a header row, and the criteria applied to each column. */
export interface AutoFilter {
  /** Header row plus the data beneath it. */
  range: CellRange;
  /** Keyed by absolute column index. */
  criteria: Map<number, FilterCriterion>;
  /** Rows hidden by the criteria, captured when the filter was last applied. */
  hiddenRows: Set<number>;
}

// MARK: Tables

export type TableStyle = "green" | "blue" | "orange" | "gray" | "purple" | "teal";
export const TABLE_STYLES: TableStyle[] = ["green", "blue", "orange", "gray", "purple", "teal"];
export const TABLE_HEADER_COLORS: Record<TableStyle, Color> = {
  green: "#1E7B4A", blue: "#2F5DA8", orange: "#C8621B", gray: "#505A64", purple: "#6B4AA8", teal: "#137A86",
};

export interface TableObject {
  id: string;
  name: string;
  range: CellRange;
  style: TableStyle;
  showHeader: boolean;
  bandedRows: boolean;
  showTotals: boolean;
}

// MARK: Charts

export type ChartKind = "column" | "stackedColumn" | "bar" | "line" | "area" | "pie" | "doughnut" | "scatter";
export const CHART_KINDS: ChartKind[] = ["column", "stackedColumn", "bar", "line", "area", "pie", "doughnut", "scatter"];
export const CHART_KIND_TITLES: Record<ChartKind, string> = {
  column: "Column", stackedColumn: "Stacked Column", bar: "Bar", line: "Line", area: "Area", pie: "Pie", doughnut: "Doughnut", scatter: "Scatter",
};

export type ChartPalette = "grid" | "ocean" | "sunset" | "mono" | "vivid";
export const CHART_PALETTES: Record<ChartPalette, Color[]> = {
  grid: ["#1E8E5A", "#2F6FDB", "#F29D38", "#D9534F", "#8E5BD6", "#17A2B8", "#6C757D", "#E83E8C"],
  ocean: ["#0B4F6C", "#01BAEF", "#20BF55", "#757575", "#145C9E", "#7FDBDA", "#3D5A80", "#98C1D9"],
  sunset: ["#F94144", "#F3722C", "#F8961E", "#F9C74F", "#90BE6D", "#43AA8B", "#577590", "#277DA1"],
  mono: ["#1B4332", "#2D6A4F", "#40916C", "#52B788", "#74C69D", "#95D5B2", "#B7E4C7", "#D8F3DC"],
  vivid: ["#7400B8", "#5E60CE", "#4EA8DE", "#48BFE3", "#56CFE1", "#64DFDF", "#72EFDD", "#80FFDB"],
};

export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

/** A chart floating over the grid, drawn from a data range. */
export interface ChartObject {
  id: string;
  kind: ChartKind;
  /** The data range on the chart's own sheet. */
  dataRange: CellRange;
  title: string;
  /** Position in sheet content coordinates at 100% zoom (origin at A1's top-left). */
  frame: Rect;
  seriesInColumns: boolean;
  showLegend: boolean;
  showDataLabels: boolean;
  showGridlines: boolean;
  palette: ChartPalette;
  xAxisTitle: string;
  yAxisTitle: string;
}

// MARK: Sheet

export const DEFAULT_COLUMN_WIDTH = 80;
export const DEFAULT_ROW_HEIGHT = 21;

/** The worksheet: a sparse map of cells plus row/column geometry and features. */
export interface Sheet {
  id: string;
  name: string;
  /** Keyed by `cellKey(row, column)`. */
  cells: Map<number, Cell>;
  /** Custom sizes in points at 100% zoom. Missing entries use the defaults. */
  columnWidths: Map<number, number>;
  rowHeights: Map<number, number>;
  hiddenColumns: Set<number>;
  hiddenRows: Set<number>;
  columnStyles: Map<number, CellStyle>;
  rowStyles: Map<number, CellStyle>;
  merges: CellRange[];
  frozenRows: number;
  frozenColumns: number;
  notes: Map<number, string>;
  conditionalFormats: ConditionalFormat[];
  charts: ChartObject[];
  filter?: AutoFilter;
  tables: TableObject[];
  tabColor?: Color;
  showGridlines: boolean;
  showHeadings: boolean;
  zoom: number;
  pageSetup: PageSetup;
}

export function uuid(): string {
  return (typeof crypto !== "undefined" && "randomUUID" in crypto
    ? crypto.randomUUID()
    : "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
        const r = (Math.random() * 16) | 0;
        return (c === "x" ? r : (r & 0x3) | 0x8).toString(16);
      })).toUpperCase();
}

export function newSheet(name: string): Sheet {
  return {
    id: uuid(), name, cells: new Map(), columnWidths: new Map(), rowHeights: new Map(), hiddenColumns: new Set(), hiddenRows: new Set(),
    columnStyles: new Map(), rowStyles: new Map(), merges: [], frozenRows: 0, frozenColumns: 0, notes: new Map(),
    conditionalFormats: [], charts: [], tables: [], showGridlines: true, showHeadings: true, zoom: 1, pageSetup: defaultPageSetup(),
  };
}

export const getCell = (sheet: Sheet, row: number, column: number) => sheet.cells.get(cellKey(row, column));

/** Stores a cell, removing it when it holds nothing. */
export function setCell(sheet: Sheet, row: number, column: number, cell: Cell | undefined) {
  const key = cellKey(row, column);
  if (cell && !isVacant(cell)) sheet.cells.set(key, cell);
  else sheet.cells.delete(key);
}

export function styleAt(sheet: Sheet, row: number, column: number): CellStyle {
  return sheet.cells.get(cellKey(row, column))?.style ?? sheet.rowStyles.get(row) ?? sheet.columnStyles.get(column) ?? {};
}

export function updateStyle(sheet: Sheet, row: number, column: number, change: (style: CellStyle) => CellStyle) {
  const style = normalizeStyle(change({ ...styleAt(sheet, row, column) }));
  const cell: Cell = { ...(getCell(sheet, row, column) ?? { value: null }) };
  cell.style = isPlainStyle(style) && !sheet.rowStyles.has(row) && !sheet.columnStyles.has(column) ? undefined : style;
  setCell(sheet, row, column, cell);
}

/** The smallest range holding every non-vacant cell, or null for an empty sheet. */
export function usedRange(sheet: Sheet): CellRange | null {
  if (sheet.cells.size === 0) return null;
  let minRow = Infinity, minColumn = Infinity, maxRow = 0, maxColumn = 0;
  for (const key of sheet.cells.keys()) {
    const { row, column } = keyAddress(key);
    if (row < minRow) minRow = row;
    if (row > maxRow) maxRow = row;
    if (column < minColumn) minColumn = column;
    if (column > maxColumn) maxColumn = column;
  }
  return rangeRC(minRow, minColumn, maxRow, maxColumn);
}

/** Used range anchored at A1 (what Excel calls the "last cell"). */
export function contentExtent(sheet: Sheet): CellAddress {
  return usedRange(sheet)?.end ?? { row: 0, column: 0 };
}

export function columnWidth(sheet: Sheet, column: number): number {
  if (sheet.hiddenColumns.has(column)) return 0;
  return sheet.columnWidths.get(column) ?? DEFAULT_COLUMN_WIDTH;
}

export function isRowHidden(sheet: Sheet, row: number): boolean {
  return sheet.hiddenRows.has(row) || !!sheet.filter?.hiddenRows.has(row);
}

export function rowHeight(sheet: Sheet, row: number): number {
  if (isRowHidden(sheet, row)) return 0;
  return sheet.rowHeights.get(row) ?? DEFAULT_ROW_HEIGHT;
}

export function mergeContaining(sheet: Sheet, a: CellAddress): CellRange | undefined {
  return sheet.merges.find((m) => rangeContains(m, a));
}

/** Expands a range so it fully includes every merge it touches. */
export function expandedToMerges(sheet: Sheet, r: CellRange): CellRange {
  let result = r;
  let changed = true;
  while (changed) {
    changed = false;
    for (const merge of sheet.merges) {
      if (rangesIntersect(merge, result) && !rangeContainsRange(result, merge)) {
        result = union(result, merge);
        changed = true;
      }
    }
  }
  return result;
}

export const cellHasContent = (sheet: Sheet, row: number, column: number) => hasContent(sheet.cells.get(cellKey(row, column)));

/** The contiguous block of content around a cell (Excel's "current region"). */
export function currentRegion(sheet: Sheet, a: CellAddress): CellRange {
  let r = rangeRC(a.row, a.column, a.row, a.column);
  let grew = true;
  const has = (row: number, column: number) => cellHasContent(sheet, row, column);
  while (grew) {
    grew = false;
    const c1 = Math.max(r.start.column - 1, 0), c2 = r.end.column + 1;
    const r1 = Math.max(r.start.row - 1, 0), r2 = r.end.row + 1;
    const anyInRow = (row: number) => { for (let c = c1; c <= c2; c++) if (has(row, c)) return true; return false; };
    const anyInColumn = (column: number) => { for (let row = r1; row <= r2; row++) if (has(row, column)) return true; return false; };
    if (r.start.row > 0 && anyInRow(r.start.row - 1)) { r = rangeRC(r.start.row - 1, r.start.column, r.end.row, r.end.column); grew = true; }
    if (anyInRow(r.end.row + 1)) { r = rangeRC(r.start.row, r.start.column, r.end.row + 1, r.end.column); grew = true; }
    if (r.start.column > 0 && anyInColumn(r.start.column - 1)) { r = rangeRC(r.start.row, r.start.column - 1, r.end.row, r.end.column); grew = true; }
    if (anyInColumn(r.end.column + 1)) { r = rangeRC(r.start.row, r.start.column, r.end.row, r.end.column + 1); grew = true; }
  }
  return r;
}

/** Where Ctrl+Arrow lands: the edge of the current data block, or the next block. */
export function dataEdge(sheet: Sheet, from: CellAddress, rowStep: number, columnStep: number): CellAddress {
  const limitRow = MAX_ROWS - 1, limitColumn = MAX_COLUMNS - 1;
  const valid = (a: CellAddress) => a.row >= 0 && a.column >= 0 && a.row <= limitRow && a.column <= limitColumn;
  const has = (a: CellAddress) => cellHasContent(sheet, a.row, a.column);
  const step = (a: CellAddress) => ({ row: a.row + rowStep, column: a.column + columnStep });
  const extent = contentExtent(sheet);
  let current = from;
  let next = step(current);
  if (!valid(next)) return current;
  if (has(current) && has(next)) {
    while (valid(next) && has(next)) {
      current = next;
      next = step(current);
    }
    return current;
  }
  current = next;
  while (!has(current)) {
    const candidate = step(current);
    const beyond = (rowStep > 0 && current.row > extent.row) || (columnStep > 0 && current.column > extent.column);
    if (!valid(candidate) || beyond) {
      if (rowStep > 0) return { row: limitRow, column: current.column };
      if (columnStep > 0) return { row: current.row, column: limitColumn };
      return valid(candidate) ? candidate : current;
    }
    current = candidate;
  }
  return current;
}

// MARK: Workbook

export interface Workbook {
  sheets: Sheet[];
  activeSheetIndex: number;
  names: DefinedName[];
  author: string;
  created: Date;
}

export function newWorkbook(sheetCount = 1): Workbook {
  return {
    sheets: Array.from({ length: Math.max(1, sheetCount) }, (_, i) => newSheet(`Sheet${i + 1}`)),
    activeSheetIndex: 0, names: [], author: "", created: new Date(),
  };
}

export const sameName = (a: string, b: string) => a.localeCompare(b, undefined, { sensitivity: "accent" }) === 0 || a.toUpperCase() === b.toUpperCase();

export function sheetIndexNamed(workbook: Workbook, name: string): number {
  return workbook.sheets.findIndex((s) => sameName(s.name, name));
}

export function definedName(workbook: Workbook, name: string): DefinedName | undefined {
  return workbook.names.find((n) => sameName(n.name, name));
}

/** "Sheet4", or the next free number. */
export function nextSheetName(workbook: Workbook, base = "Sheet"): string {
  let n = workbook.sheets.length + 1;
  while (sheetIndexNamed(workbook, `${base}${n}`) >= 0) n++;
  return `${base}${n}`;
}

export function uniqueSheetName(workbook: Workbook, proposed: string): string {
  if (sheetIndexNamed(workbook, proposed) < 0) return proposed;
  let n = 2;
  while (sheetIndexNamed(workbook, `${proposed} (${n})`) >= 0) n++;
  return `${proposed} (${n})`;
}

// MARK: Copying

export function cloneSheet(s: Sheet): Sheet {
  return {
    ...s,
    cells: new Map(s.cells),
    columnWidths: new Map(s.columnWidths),
    rowHeights: new Map(s.rowHeights),
    hiddenColumns: new Set(s.hiddenColumns),
    hiddenRows: new Set(s.hiddenRows),
    columnStyles: new Map(s.columnStyles),
    rowStyles: new Map(s.rowStyles),
    merges: [...s.merges],
    notes: new Map(s.notes),
    conditionalFormats: s.conditionalFormats.map((c) => ({ ...c })),
    charts: s.charts.map((c) => ({ ...c, frame: { ...c.frame } })),
    filter: s.filter && { range: s.filter.range, criteria: new Map(s.filter.criteria), hiddenRows: new Set(s.filter.hiddenRows) },
    tables: s.tables.map((t) => ({ ...t })),
    pageSetup: { ...s.pageSetup },
  };
}

/**
 * A copy that can be changed without affecting the original. Cells, styles and
 * ranges are treated as immutable values everywhere, so the copy shares them.
 */
export function cloneWorkbook(w: Workbook): Workbook {
  return { ...w, sheets: w.sheets.map(cloneSheet), names: w.names.map((n) => ({ ...n })) };
}
