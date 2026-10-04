import { cellKey, isValidAddress, keyAddress, rangeRC, type CellRange } from "../model/address";
import { normalizeColor } from "../model/color";
import { FormulaError, type CellValue } from "../model/values";
import {
  CHART_KINDS, TABLE_STYLES, defaultPageSetup, newSheet, normalizeStyle, styleKey, uuid,
  type AutoFilter, type CellBorders, type CellStyle, type ChartObject, type ChartPalette, type ConditionalFormat, type DefinedName,
  type FilterCriterion, type HighlightFormat, type IconSet, type PageSetup, type Rule, type Sheet, type TableObject, type Workbook,
} from "../model/workbook";
import { readZip, toUTF8, utf8, writeZip } from "./zip";

/**
 * `.grid` files: a ZIP holding a `mimetype` entry and `Workbook.json`.
 *
 * The JSON matches what Wired Grid for Mac writes with Swift's `Codable`
 * (sorted keys, ISO 8601 dates, enums with associated values as
 * `{"case": {"_0": …}}`), so workbooks move freely between the two apps.
 * Every field is read tolerantly.
 */
export const GRID_MIME_TYPE = "application/vnd.wiredgrid.grid";
export const FORMAT_VERSION = 1;

export class FileFormatError extends Error {}

export function readGrid(bytes: Uint8Array): Workbook {
  let json: string;
  try {
    const entries = readZip(bytes);
    const mime = entries.get("mimetype");
    if (mime && utf8(mime) !== GRID_MIME_TYPE) throw new FileFormatError("The file is not a Wired Grid workbook.");
    const data = entries.get("Workbook.json");
    if (!data) throw new FileFormatError("The workbook data is missing.");
    json = utf8(data);
  } catch (e) {
    if (e instanceof FileFormatError) throw e;
    // Plain JSON is accepted too.
    json = utf8(bytes);
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(json);
  } catch {
    throw new FileFormatError("The file is not a valid Wired Grid workbook.");
  }
  try {
    return decodeWorkbook(parsed);
  } catch {
    throw new FileFormatError("The workbook data is damaged.");
  }
}

export function writeGrid(workbook: Workbook): Uint8Array {
  const json = stringifySorted(encodeWorkbook(workbook));
  return writeZip([["mimetype", GRID_MIME_TYPE], ["Workbook.json", toUTF8(json)]], ["mimetype"]);
}

/** JSON with object keys sorted, like Swift's `.sortedKeys`. */
export function stringifySorted(value: unknown): string {
  return JSON.stringify(sortKeys(value));
}

function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const key of Object.keys(value).sort()) out[key] = sortKeys((value as Record<string, unknown>)[key]);
    return out;
  }
  return value;
}

// MARK: - Encoding

type Json = Record<string, unknown>;

const swiftDate = (d: Date) => (Number.isNaN(d.getTime()) ? new Date() : d).toISOString().replace(/\.\d{3}Z$/, "Z");
const encodeNumber = (n: number): number | string => (Number.isFinite(n) ? n : Number.isNaN(n) ? "nan" : n > 0 ? "inf" : "-inf");

export function encodeWorkbook(workbook: Workbook): Json {
  const out: Json = {
    formatVersion: FORMAT_VERSION,
    sheets: workbook.sheets.map(encodeSheet),
    activeSheetIndex: workbook.activeSheetIndex,
    created: swiftDate(workbook.created),
  };
  if (workbook.names.length) out.names = workbook.names.map((n) => ({ name: n.name, formula: n.formula, comment: n.comment ?? "" }));
  if (workbook.author) out.author = workbook.author;
  return out;
}

function encodeValue(v: CellValue): Json {
  if (v === null) return {};
  if (typeof v === "number") return { n: encodeNumber(v) };
  if (typeof v === "string") return { s: v };
  if (typeof v === "boolean") return { b: v };
  return { e: v.code };
}

const encodeRange = (r: CellRange) => ({ start: { row: r.start.row, column: r.start.column }, end: { row: r.end.row, column: r.end.column } });

function encodeStyle(style: CellStyle): Json {
  const s = normalizeStyle(style) as Json;
  if (s.borders) {
    const borders: Json = {};
    for (const [side, line] of Object.entries(s.borders as CellBorders)) if (line) borders[side] = { style: line.style, color: line.color };
    s.borders = borders;
  }
  return s;
}

const intKeyed = <T>(map: Map<number, T>, encode: (v: T) => unknown) => {
  const out: Json = {};
  for (const [k, v] of map) out[String(k)] = encode(v);
  return out;
};

function encodeSheet(sheet: Sheet): Json {
  const styles: Json[] = [];
  const styleIndex = new Map<string, number>();
  const cells: Json[] = [];
  for (const key of [...sheet.cells.keys()].sort((a, b) => a - b)) {
    const cell = sheet.cells.get(key)!;
    const { row, column } = keyAddress(key);
    const stored: Json = { r: row, c: column };
    if (cell.value !== null) stored.v = encodeValue(cell.value);
    if (cell.formula !== undefined) stored.f = cell.formula;
    if (cell.style) {
      const k = styleKey(cell.style);
      let index = styleIndex.get(k);
      if (index === undefined) {
        index = styles.length;
        styleIndex.set(k, index);
        styles.push(encodeStyle(cell.style));
      }
      stored.s = index;
    }
    if (cell.link !== undefined) stored.l = cell.link;
    cells.push(stored);
  }
  const out: Json = { id: sheet.id, name: sheet.name, cells };
  if (styles.length) out.styles = styles;
  if (sheet.columnWidths.size) out.columnWidths = intKeyed(sheet.columnWidths, encodeNumber);
  if (sheet.rowHeights.size) out.rowHeights = intKeyed(sheet.rowHeights, encodeNumber);
  if (sheet.hiddenColumns.size) out.hiddenColumns = [...sheet.hiddenColumns].sort((a, b) => a - b);
  if (sheet.hiddenRows.size) out.hiddenRows = [...sheet.hiddenRows].sort((a, b) => a - b);
  if (sheet.columnStyles.size) out.columnStyles = intKeyed(sheet.columnStyles, encodeStyle);
  if (sheet.rowStyles.size) out.rowStyles = intKeyed(sheet.rowStyles, encodeStyle);
  if (sheet.merges.length) out.merges = sheet.merges.map(encodeRange);
  if (sheet.frozenRows > 0) out.frozenRows = sheet.frozenRows;
  if (sheet.frozenColumns > 0) out.frozenColumns = sheet.frozenColumns;
  if (sheet.notes.size) {
    out.notes = [...sheet.notes.keys()].sort((a, b) => a - b).map((key) => {
      const { row, column } = keyAddress(key);
      return { r: row, c: column, text: sheet.notes.get(key)! };
    });
  }
  if (sheet.conditionalFormats.length) out.conditionalFormats = sheet.conditionalFormats.map(encodeConditionalFormat);
  if (sheet.charts.length) out.charts = sheet.charts.map(encodeChart);
  if (sheet.filter) out.filter = encodeFilter(sheet.filter);
  if (sheet.tables.length) out.tables = sheet.tables.map((t) => ({ ...t, range: encodeRange(t.range) }));
  if (sheet.tabColor) out.tabColor = sheet.tabColor;
  if (!sheet.showGridlines) out.showGridlines = false;
  if (!sheet.showHeadings) out.showHeadings = false;
  if (sheet.zoom !== 1) out.zoom = sheet.zoom;
  const setup = encodePageSetup(sheet.pageSetup);
  if (JSON.stringify(setup) !== JSON.stringify(encodePageSetup(defaultPageSetup()))) out.pageSetup = setup;
  return out;
}

function encodePageSetup(p: PageSetup): Json {
  const out: Json = {
    orientation: p.orientation, scaling: p.scaling, margin: p.margin, printGridlines: p.printGridlines, printHeadings: p.printHeadings,
    centerHorizontally: p.centerHorizontally, header: p.header, footer: p.footer,
  };
  if (p.printArea) out.printArea = encodeRange(p.printArea);
  return out;
}

export function encodeRule(rule: Rule): Json {
  switch (rule.type) {
    case "greaterThan": case "lessThan": return { [rule.type]: { _0: rule.value } };
    case "between": return { between: { _0: rule.low, _1: rule.high } };
    case "equalTo": case "notEqualTo": case "textContains": case "beginsWith": case "endsWith": return { [rule.type]: { _0: rule.text } };
    case "blanks": case "noBlanks": case "duplicates": case "uniques": case "aboveAverage": case "belowAverage": return { [rule.type]: {} };
    case "top": case "bottom": return { [rule.type]: { _0: rule.count, percent: rule.percent } };
    case "formula": return { formula: { _0: rule.formula } };
    case "colorScale": return { colorScale: { _0: rule.colors } };
    case "dataBar": return { dataBar: { _0: rule.color } };
    case "iconSet": return { iconSet: { _0: rule.set } };
  }
}

function encodeHighlight(f: HighlightFormat): Json {
  const out: Json = { bold: f.bold, italic: f.italic };
  if (f.fill) out.fill = f.fill;
  if (f.text) out.text = f.text;
  if (f.border) out.border = f.border;
  return out;
}

const encodeConditionalFormat = (cf: ConditionalFormat): Json => ({ id: cf.id, range: encodeRange(cf.range), rule: encodeRule(cf.rule), format: encodeHighlight(cf.format) });

function encodeFilter(filter: AutoFilter): Json {
  const criteria: Json = {};
  for (const [column, criterion] of filter.criteria) {
    criteria[String(column)] = criterion.type === "values" ? { values: { _0: criterion.values } } : { condition: { _0: encodeRule(criterion.rule) } };
  }
  return { range: encodeRange(filter.range), criteria, hiddenRows: [...filter.hiddenRows].sort((a, b) => a - b) };
}

function encodeChart(c: ChartObject): Json {
  return {
    id: c.id, kind: c.kind, dataRange: encodeRange(c.dataRange), title: c.title,
    frame: [[c.frame.x, c.frame.y], [c.frame.width, c.frame.height]],
    seriesInColumns: c.seriesInColumns, showLegend: c.showLegend, showDataLabels: c.showDataLabels, showGridlines: c.showGridlines,
    palette: c.palette, xAxisTitle: c.xAxisTitle, yAxisTitle: c.yAxisTitle,
  };
}

// MARK: - Decoding

const obj = (v: unknown): Json | null => (v && typeof v === "object" && !Array.isArray(v) ? (v as Json) : null);
const arr = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);
const str = (v: unknown, fallback = ""): string => (typeof v === "string" ? v : fallback);
const bool = (v: unknown, fallback: boolean): boolean => (typeof v === "boolean" ? v : fallback);
const num = (v: unknown, fallback = 0): number => {
  if (typeof v === "number") return v;
  if (v === "inf") return Infinity;
  if (v === "-inf") return -Infinity;
  if (v === "nan") return NaN;
  return fallback;
};
const int = (v: unknown, fallback = 0) => (typeof v === "number" && Number.isFinite(v) ? Math.trunc(v) : fallback);

export function decodeWorkbook(json: unknown): Workbook {
  const root = obj(json);
  if (!root) throw new FileFormatError("Not a workbook");
  let sheets = arr(root.sheets).map(decodeSheet).filter((s): s is Sheet => !!s);
  if (!sheets.length) sheets = [newSheet("Sheet1")];
  const created = typeof root.created === "string" ? new Date(root.created) : typeof root.created === "number" ? new Date((root.created + 978307200) * 1000) : new Date();
  return {
    sheets,
    activeSheetIndex: Math.min(Math.max(int(root.activeSheetIndex), 0), sheets.length - 1),
    names: arr(root.names).flatMap((n): DefinedName[] => {
      const o = obj(n);
      return o && typeof o.name === "string" && typeof o.formula === "string" ? [{ name: o.name, formula: o.formula, comment: str(o.comment) }] : [];
    }),
    author: str(root.author),
    created: Number.isNaN(created.getTime()) ? new Date() : created,
  };
}

function decodeValue(v: unknown): CellValue {
  const o = obj(v);
  if (!o) return null;
  if ("n" in o) return num(o.n);
  if (typeof o.s === "string") return o.s;
  if (typeof o.b === "boolean") return o.b;
  if (typeof o.e === "string") return FormulaError.fromCode(o.e) ?? FormulaError.value;
  return null;
}

function decodeRange(v: unknown): CellRange | null {
  const o = obj(v);
  const s = obj(o?.start), e = obj(o?.end);
  if (!s || !e) return null;
  const r = rangeRC(int(s.row), int(s.column), int(e.row), int(e.column));
  return isValidAddress(r.start) && isValidAddress(r.end) ? r : null;
}

const HORIZONTAL = ["general", "left", "center", "right", "fill", "justify", "centerAcross"];
const VERTICAL = ["top", "middle", "bottom"];
const LINE_STYLES = ["thin", "medium", "thick", "dashed", "dotted", "double", "hair"];

export function decodeStyle(v: unknown): CellStyle {
  const o = obj(v) ?? {};
  const style: CellStyle = {};
  if (typeof o.fontName === "string") style.fontName = o.fontName;
  if (typeof o.fontSize === "number") style.fontSize = o.fontSize;
  for (const key of ["bold", "italic", "underline", "doubleUnderline", "strikethrough", "wrap", "shrinkToFit", "locked"] as const) {
    if (typeof o[key] === "boolean") style[key] = o[key] as boolean;
  }
  const text = normalizeColor(str(o.textColor));
  if (text) style.textColor = text;
  const fill = normalizeColor(str(o.fillColor));
  if (fill) style.fillColor = fill;
  if (HORIZONTAL.includes(str(o.horizontal))) style.horizontal = o.horizontal as CellStyle["horizontal"];
  if (VERTICAL.includes(str(o.vertical))) style.vertical = o.vertical as CellStyle["vertical"];
  if (typeof o.indent === "number") style.indent = Math.trunc(o.indent);
  if (typeof o.rotation === "number") style.rotation = Math.trunc(o.rotation);
  if (typeof o.numberFormat === "string") style.numberFormat = o.numberFormat;
  const borders = obj(o.borders);
  if (borders) {
    const b: CellBorders = {};
    for (const side of ["top", "left", "bottom", "right"] as const) {
      const line = obj(borders[side]);
      if (line) b[side] = { style: (LINE_STYLES.includes(str(line.style)) ? line.style : "thin") as "thin", color: normalizeColor(str(line.color)) ?? "#000000" };
    }
    style.borders = b;
  }
  return normalizeStyle(style);
}

const intKeyedMap = <T>(v: unknown, decode: (x: unknown) => T | null): Map<number, T> => {
  const map = new Map<number, T>();
  const o = obj(v);
  if (!o) return map;
  for (const [k, x] of Object.entries(o)) {
    const index = Number(k);
    const value = decode(x);
    if (Number.isInteger(index) && index >= 0 && value !== null) map.set(index, value);
  }
  return map;
};

function decodeSheet(v: unknown): Sheet | null {
  const o = obj(v);
  if (!o) return null;
  const sheet = newSheet(str(o.name, "Sheet"));
  if (typeof o.id === "string" && o.id) sheet.id = o.id.toUpperCase();
  const styles = arr(o.styles).map(decodeStyle);
  for (const item of arr(o.cells)) {
    const c = obj(item);
    if (!c) continue;
    const row = int(c.r, -1), column = int(c.c, -1);
    if (!isValidAddress({ row, column })) continue;
    const style = typeof c.s === "number" ? styles[c.s] : undefined;
    const cell = { value: decodeValue(c.v), formula: typeof c.f === "string" ? c.f : undefined, style, link: typeof c.l === "string" ? c.l : undefined };
    if (cell.formula === undefined && cell.value === null && cell.style === undefined && cell.link === undefined) continue;
    sheet.cells.set(cellKey(row, column), cell);
  }
  sheet.columnWidths = intKeyedMap(o.columnWidths, (x) => (typeof x === "number" ? x : null));
  sheet.rowHeights = intKeyedMap(o.rowHeights, (x) => (typeof x === "number" ? x : null));
  sheet.hiddenColumns = new Set(arr(o.hiddenColumns).filter((x): x is number => typeof x === "number"));
  sheet.hiddenRows = new Set(arr(o.hiddenRows).filter((x): x is number => typeof x === "number"));
  sheet.columnStyles = intKeyedMap(o.columnStyles, decodeStyle);
  sheet.rowStyles = intKeyedMap(o.rowStyles, decodeStyle);
  sheet.merges = arr(o.merges).map(decodeRange).filter((r): r is CellRange => !!r);
  sheet.frozenRows = Math.max(0, int(o.frozenRows));
  sheet.frozenColumns = Math.max(0, int(o.frozenColumns));
  for (const item of arr(o.notes)) {
    const n = obj(item);
    if (n && typeof n.text === "string" && isValidAddress({ row: int(n.r), column: int(n.c) })) sheet.notes.set(cellKey(int(n.r), int(n.c)), n.text);
  }
  sheet.conditionalFormats = arr(o.conditionalFormats).map(decodeConditionalFormat).filter((c): c is ConditionalFormat => !!c);
  sheet.charts = arr(o.charts).map(decodeChart).filter((c): c is ChartObject => !!c);
  sheet.filter = decodeFilter(o.filter) ?? undefined;
  sheet.tables = arr(o.tables).map(decodeTable).filter((t): t is TableObject => !!t);
  sheet.tabColor = normalizeColor(str(o.tabColor)) ?? undefined;
  sheet.showGridlines = bool(o.showGridlines, true);
  sheet.showHeadings = bool(o.showHeadings, true);
  sheet.zoom = typeof o.zoom === "number" && o.zoom > 0 ? o.zoom : 1;
  sheet.pageSetup = decodePageSetup(o.pageSetup);
  return sheet;
}

function decodePageSetup(v: unknown): PageSetup {
  const setup = defaultPageSetup();
  const o = obj(v);
  if (!o) return setup;
  if (o.orientation === "landscape" || o.orientation === "portrait") setup.orientation = o.orientation;
  if (o.scaling === "actual" || o.scaling === "fitWidth" || o.scaling === "fitPage") setup.scaling = o.scaling;
  if (typeof o.margin === "number") setup.margin = o.margin;
  setup.printGridlines = bool(o.printGridlines, false);
  setup.printHeadings = bool(o.printHeadings, false);
  setup.centerHorizontally = bool(o.centerHorizontally, false);
  setup.header = str(o.header);
  setup.footer = str(o.footer, setup.footer);
  const area = decodeRange(o.printArea);
  if (area) setup.printArea = area;
  return setup;
}

export function decodeRule(v: unknown): Rule | null {
  const o = obj(v);
  if (!o) return null;
  const [type] = Object.keys(o);
  const payload = obj(o[type]) ?? {};
  const first = payload._0;
  switch (type) {
    case "greaterThan": case "lessThan": return typeof first === "number" ? { type, value: first } : null;
    case "between": return typeof first === "number" && typeof payload._1 === "number" ? { type, low: first, high: payload._1 } : null;
    case "equalTo": case "notEqualTo": case "textContains": case "beginsWith": case "endsWith": return { type, text: str(first) };
    case "blanks": case "noBlanks": case "duplicates": case "uniques": case "aboveAverage": case "belowAverage": return { type };
    case "top": case "bottom": return { type, count: int(first, 10), percent: bool(payload.percent, false) };
    case "formula": return typeof first === "string" ? { type, formula: first } : null;
    case "colorScale": {
      const colors = arr(first).map((c) => normalizeColor(str(c))).filter((c): c is string => !!c);
      return colors.length >= 2 ? { type, colors } : null;
    }
    case "dataBar": return { type, color: normalizeColor(str(first)) ?? "#638EC6" };
    case "iconSet": {
      const set = str(first) as IconSet;
      return { type, set: ["arrows", "trafficLights", "flags", "stars"].includes(set) ? set : "trafficLights" };
    }
    default: return null;
  }
}

function decodeHighlight(v: unknown): HighlightFormat {
  const o = obj(v) ?? {};
  const f: HighlightFormat = { bold: bool(o.bold, false), italic: bool(o.italic, false) };
  const fill = normalizeColor(str(o.fill)), text = normalizeColor(str(o.text)), border = normalizeColor(str(o.border));
  if (fill) f.fill = fill;
  if (text) f.text = text;
  if (border) f.border = border;
  return f;
}

function decodeConditionalFormat(v: unknown): ConditionalFormat | null {
  const o = obj(v);
  const r = decodeRange(o?.range);
  const rule = decodeRule(o?.rule);
  if (!o || !r || !rule) return null;
  return { id: str(o.id) || uuid(), range: r, rule, format: o.format ? decodeHighlight(o.format) : { fill: "#FFC7CE", text: "#9C0006", bold: false, italic: false } };
}

function decodeFilter(v: unknown): AutoFilter | null {
  const o = obj(v);
  const r = decodeRange(o?.range);
  if (!o || !r) return null;
  const criteria = intKeyedMap<FilterCriterion>(o.criteria, (x) => {
    const c = obj(x);
    if (!c) return null;
    const values = obj(c.values);
    if (values) return { type: "values", values: arr(values._0).filter((s): s is string => typeof s === "string") };
    const condition = obj(c.condition);
    const rule = condition ? decodeRule(condition._0) : null;
    return rule ? { type: "condition", rule } : null;
  });
  return { range: r, criteria, hiddenRows: new Set(arr(o.hiddenRows).filter((x): x is number => typeof x === "number")) };
}

function decodeTable(v: unknown): TableObject | null {
  const o = obj(v);
  const r = decodeRange(o?.range);
  if (!o || !r) return null;
  const style = TABLE_STYLES.includes(o.style as never) ? (o.style as TableObject["style"]) : "green";
  return {
    id: str(o.id) || uuid(), name: str(o.name, "Table1"), range: r, style,
    showHeader: bool(o.showHeader, true), bandedRows: bool(o.bandedRows, true), showTotals: bool(o.showTotals, false),
  };
}

function decodeChart(v: unknown): ChartObject | null {
  const o = obj(v);
  const r = decodeRange(o?.dataRange);
  if (!o || !r) return null;
  let frame = { x: 0, y: 0, width: 480, height: 300 };
  const f = arr(o.frame);
  if (f.length === 2) {
    const origin = arr(f[0]), size = arr(f[1]);
    frame = { x: num(origin[0]), y: num(origin[1]), width: num(size[0], 480), height: num(size[1], 300) };
  } else if (obj(o.frame)) {
    const fo = obj(o.frame)!;
    frame = { x: num(fo.x), y: num(fo.y), width: num(fo.width, 480), height: num(fo.height, 300) };
  }
  const palettes: ChartPalette[] = ["grid", "ocean", "sunset", "mono", "vivid"];
  return {
    id: str(o.id) || uuid(),
    kind: CHART_KINDS.includes(o.kind as never) ? (o.kind as ChartObject["kind"]) : "column",
    dataRange: r, title: str(o.title), frame,
    seriesInColumns: bool(o.seriesInColumns, true), showLegend: bool(o.showLegend, true), showDataLabels: bool(o.showDataLabels, false),
    showGridlines: bool(o.showGridlines, true), palette: palettes.includes(o.palette as never) ? (o.palette as ChartPalette) : "grid",
    xAxisTitle: str(o.xAxisTitle), yAxisTitle: str(o.yAxisTitle),
  };
}
