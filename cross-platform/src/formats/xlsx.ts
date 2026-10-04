import { a1, cellKey, columnName, isSingleCell, isValidAddress, keyAddress, parseA1, parseRange, quotedSheetName, range, rangeA1, type CellAddress, type CellRange } from "../model/address";
import { mixColors, normalizeColor } from "../model/color";
import { FormulaError } from "../model/values";
import {
  DEFAULT_COLUMN_WIDTH, DEFAULT_FONT_NAME, DEFAULT_FONT_SIZE, isPlainStyle, isRowHidden, newSheet, normalizeStyle, numberFormatOf, styleAt,
  styleKey, uniqueSheetName, usedRange, uuid,
  type BorderLine, type BorderLineStyle, type Cell, type CellBorders, type CellStyle, type Color, type ConditionalFormat, type HighlightFormat,
  type Rule, type Sheet, type Workbook,
} from "../model/workbook";
import { Calculator } from "../formula";
import { tokenize } from "../formula/lexer";
import { FORMATS } from "../formula/numberFormat";
import { serialFromDate } from "../formula/dateSerial";
import { numberFromText } from "../formula/valueParser";
import { shiftFormula } from "../formula/rewriter";
import { WorkbookController } from "../engine/controller";
import { settings } from "../settings";
import { FileFormatError } from "./native";
import { readZip, utf8, writeZip } from "./zip";

/** Office Open XML measurement conversions between Wired Grid points and Excel units. */
export const ExcelUnits = {
  /** Excel's default column (8.43 characters) is Wired Grid's 80 pt column. */
  columnCharacters: (points: number) => Math.round((points / DEFAULT_COLUMN_WIDTH) * 8.43 * 100) / 100,
  pointsFromCharacters: (characters: number) => (characters / 8.43) * DEFAULT_COLUMN_WIDTH,
  /** Excel's default 15 pt row is Wired Grid's 21 pt row. */
  excelRowHeight: (points: number) => Math.round(((points * 15) / 21) * 4) / 4,
  pointsFromRowHeight: (height: number) => (height * 21) / 15,
};

export const stripPrefixes = (formula: string) => formula.replace(/_xlfn\._xlws\./g, "").replace(/_xlfn\./g, "").replace(/_xlws\./g, "");

// MARK: - XML helpers

const children = (el: Element | null | undefined, name: string): Element[] =>
  el ? Array.from(el.children).filter((c) => c.localName === name) : [];
const child = (el: Element | null | undefined, name: string): Element | null => children(el, name)[0] ?? null;
function attr(el: Element | null | undefined, name: string): string | null {
  if (!el) return null;
  const direct = el.getAttribute(name);
  if (direct !== null) return direct;
  // Match by local name when the attribute carries a different prefix.
  const local = name.split(":").pop()!;
  for (const a of Array.from(el.attributes)) if (a.localName === local) return a.value;
  return null;
}
const intAttr = (el: Element | null | undefined, name: string): number | null => {
  const v = attr(el, name);
  if (v === null || v.trim() === "") return null;
  const n = Number(v);
  return Number.isFinite(n) ? Math.trunc(n) : null;
};
const numAttr = (el: Element | null | undefined, name: string): number | null => {
  const v = attr(el, name);
  if (v === null || v.trim() === "") return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
};

function parseXML(bytes: Uint8Array | undefined): Element | null {
  if (!bytes) return null;
  const doc = new DOMParser().parseFromString(utf8(bytes), "application/xml");
  if (doc.getElementsByTagName("parsererror").length) return null;
  return doc.documentElement;
}

// MARK: - Reading

/**
 * Reads `.xlsx` workbooks written by Excel, Google Sheets, LibreOffice and
 * others: values, formulas (including shared formulas), styles, column widths,
 * row heights, merges, frozen panes, filters, conditional formats and names.
 */
export function readXLSX(bytes: Uint8Array): Workbook {
  let entries: Map<string, Uint8Array>;
  try {
    entries = readZip(bytes);
  } catch {
    throw new FileFormatError("The file isn't a valid Excel workbook.");
  }
  const part = (path: string) => parseXML(entries.get(path) ?? entries.get(path.startsWith("/") ? path.slice(1) : "/" + path));
  const workbookXML = part("xl/workbook.xml");
  if (!workbookXML) throw new FileFormatError("The workbook part is missing.");

  // Relationships: rId → target path.
  const targets = new Map<string, string>();
  for (const rel of children(part("xl/_rels/workbook.xml.rels"), "Relationship")) {
    const id = attr(rel, "Id");
    let target = attr(rel, "Target");
    if (!id || !target) continue;
    target = target.startsWith("/") ? target.slice(1) : "xl/" + target;
    targets.set(id, target);
  }

  const sharedStrings = children(part("xl/sharedStrings.xml"), "si").map(richText);
  const theme = readTheme(part("xl/theme/theme1.xml"));
  const styles = new StyleReader(part("xl/styles.xml"), theme);

  const workbook: Workbook = { sheets: [], activeSheetIndex: 0, names: [], author: "", created: new Date() };
  for (const element of children(child(workbookXML, "sheets"), "sheet")) {
    const name = attr(element, "name") ?? `Sheet${workbook.sheets.length + 1}`;
    const rid = attr(element, "r:id") ?? "";
    const path = targets.get(rid) ?? `xl/worksheets/sheet${workbook.sheets.length + 1}.xml`;
    const sheet = newSheet(uniqueSheetName(workbook, name));
    const xml = part(path);
    if (xml) readWorksheet(xml, sheet, sharedStrings, styles, theme);
    workbook.sheets.push(sheet);
  }
  if (!workbook.sheets.length) workbook.sheets = [newSheet("Sheet1")];
  const active = intAttr(child(child(workbookXML, "bookViews"), "workbookView"), "activeTab");
  if (active !== null) workbook.activeSheetIndex = Math.min(Math.max(active, 0), workbook.sheets.length - 1);

  for (const element of children(child(workbookXML, "definedNames"), "definedName")) {
    const name = attr(element, "name");
    const body = element.textContent ?? "";
    if (!name) continue;
    if (name.startsWith("_xlnm.")) {
      const local = intAttr(element, "localSheetId");
      const bang = body.lastIndexOf("!");
      if (name === "_xlnm.Print_Area" && local !== null && local < workbook.sheets.length && bang >= 0) {
        const r = parseRange(body.slice(bang + 1));
        if (r) workbook.sheets[local].pageSetup.printArea = r;
      }
      continue;
    }
    if (!WorkbookController.isValidName(name) || attr(element, "localSheetId") !== null) continue;
    workbook.names.push({ name, formula: stripPrefixes(body), comment: "" });
  }
  const core = part("docProps/core.xml");
  const creator = core ? Array.from(core.children).find((c) => c.localName === "creator")?.textContent : null;
  if (creator) workbook.author = creator;
  return workbook;
}

/** The text of an `<si>` or `<is>` element (plain or rich runs; phonetic runs skipped). */
function richText(element: Element): string {
  const t = child(element, "t");
  if (t) return t.textContent ?? "";
  return children(element, "r").map((r) => child(r, "t")?.textContent ?? "").join("");
}

function readTheme(root: Element | null): Color[] {
  // Default Office palette in theme index order: lt1, dk1, lt2, dk2, accent1…6.
  const palette = ["#FFFFFF", "#000000", "#E7E6E6", "#44546A", "#4472C4", "#ED7D31", "#A5A5A5", "#FFC000", "#5B9BD5", "#70AD47"];
  const scheme = child(child(root, "themeElements"), "clrScheme");
  if (!scheme) return palette;
  ["lt1", "dk1", "lt2", "dk2", "accent1", "accent2", "accent3", "accent4", "accent5", "accent6"].forEach((name, i) => {
    const element = child(scheme, name);
    const color = normalizeColor(attr(child(element, "srgbClr"), "val")) ?? normalizeColor(attr(child(element, "sysClr"), "lastClr"));
    if (color) palette[i] = color;
  });
  return palette;
}

function readWorksheet(root: Element, sheet: Sheet, strings: string[], styles: StyleReader, theme: Color[]) {
  const tab = child(child(root, "sheetPr"), "tabColor");
  if (tab) sheet.tabColor = styleColor(tab, theme) ?? undefined;
  const view = child(child(root, "sheetViews"), "sheetView");
  if (view) {
    if (attr(view, "showGridLines") === "0") sheet.showGridlines = false;
    if (attr(view, "showRowColHeaders") === "0") sheet.showHeadings = false;
    const zoom = numAttr(view, "zoomScale");
    if (zoom && zoom > 0) sheet.zoom = Math.min(Math.max(zoom / 100, 0.1), 4);
    const pane = child(view, "pane");
    if (pane && (attr(pane, "state") === "frozen" || attr(pane, "state") === "frozenSplit")) {
      sheet.frozenColumns = Math.trunc(numAttr(pane, "xSplit") ?? 0);
      sheet.frozenRows = Math.trunc(numAttr(pane, "ySplit") ?? 0);
    }
  }
  const defaultRowHeight = numAttr(child(root, "sheetFormatPr"), "defaultRowHeight") ?? 15;

  for (const col of children(child(root, "cols"), "col")) {
    const min = intAttr(col, "min"), max = intAttr(col, "max");
    if (min === null || max === null || min < 1 || max < min) continue;
    const upper = Math.min(max, min + 300); // Ignore absurd whole-sheet ranges beyond what matters.
    const width = numAttr(col, "width");
    const style = styles.style(intAttr(col, "style") ?? -1);
    for (let column = min - 1; column <= upper - 1; column++) {
      if (width !== null && (attr(col, "customWidth") === "1" || Math.abs(width - 8.43) > 0.3)) {
        const points = ExcelUnits.pointsFromCharacters(width);
        if (Math.abs(points - DEFAULT_COLUMN_WIDTH) > 0.5) sheet.columnWidths.set(column, points);
      }
      if (attr(col, "hidden") === "1") sheet.hiddenColumns.add(column);
      if (style && !isPlainStyle(style) && max - min < 300) sheet.columnStyles.set(column, style);
    }
  }

  const sharedFormulas = new Map<string, { formula: string; origin: CellAddress }>();
  let nextRow = 0;
  for (const rowElement of children(child(root, "sheetData"), "row")) {
    const row = (intAttr(rowElement, "r") ?? nextRow + 1) - 1;
    nextRow = row + 1;
    if (row < 0 || row >= 1_048_576) continue;
    const height = numAttr(rowElement, "ht");
    if (height !== null && (attr(rowElement, "customHeight") === "1" || Math.abs(height - defaultRowHeight) > 0.3)) {
      const points = ExcelUnits.pointsFromRowHeight(height);
      if (Math.abs(points - 21) > 0.5) sheet.rowHeights.set(row, points);
    }
    if (attr(rowElement, "hidden") === "1") sheet.hiddenRows.add(row);
    if (attr(rowElement, "customFormat") === "1") {
      const style = styles.style(intAttr(rowElement, "s") ?? -1);
      if (style && !isPlainStyle(style)) sheet.rowStyles.set(row, style);
    }
    let nextColumn = 0;
    for (const c of children(rowElement, "c")) {
      const ref = attr(c, "r");
      const address = (ref ? parseA1(ref) : null) ?? { row, column: nextColumn };
      nextColumn = address.column + 1;
      const cell: Cell = { value: null };
      const style = styles.style(intAttr(c, "s") ?? -1);
      if (style && !isPlainStyle(style)) cell.style = style;
      const type = attr(c, "t") ?? "n";
      const raw = child(c, "v")?.textContent ?? null;
      switch (type) {
        case "s": {
          const index = raw === null ? -1 : Number(raw);
          if (index >= 0 && index < strings.length) cell.value = strings[index];
          break;
        }
        case "inlineStr": {
          const inline = child(c, "is");
          if (inline) cell.value = richText(inline);
          break;
        }
        case "str": cell.value = raw ?? ""; break;
        case "b": cell.value = raw === "1" || raw?.toLowerCase() === "true"; break;
        case "e": cell.value = FormulaError.fromCode(raw ?? "") ?? FormulaError.value; break;
        case "d": {
          const date = raw ? new Date(raw) : null;
          if (date && !Number.isNaN(date.getTime())) cell.value = serialFromDate(date) + date.getTimezoneOffset() / 1440;
          break;
        }
        default:
          if (raw !== null && raw.trim() !== "" && Number.isFinite(Number(raw))) cell.value = Number(raw);
      }
      const f = child(c, "f");
      if (f) {
        const text = f.textContent ?? "";
        const si = attr(f, "si");
        if (attr(f, "t") === "shared" && si !== null) {
          if (text) {
            sharedFormulas.set(si, { formula: text, origin: address });
            cell.formula = stripPrefixes(text);
          } else {
            const master = sharedFormulas.get(si);
            if (master) cell.formula = stripPrefixes(shiftFormula(master.formula, address.row - master.origin.row, address.column - master.origin.column));
          }
        } else if (text && attr(f, "t") !== "dataTable") {
          cell.formula = stripPrefixes(text).replace(/_xlpm\./g, "");
        }
        if (cell.formula?.startsWith("@")) cell.formula = cell.formula.slice(1);
      }
      if (isValidAddress(address) && (cell.formula !== undefined || cell.value !== null || cell.style)) sheet.cells.set(cellKey(address.row, address.column), cell);
    }
  }

  for (const merge of children(child(root, "mergeCells"), "mergeCell")) {
    const r = parseRange(attr(merge, "ref") ?? "");
    if (r && !isSingleCell(r)) sheet.merges.push(r);
  }
  const filterElement = child(root, "autoFilter");
  const filterRange = parseRange(attr(filterElement, "ref") ?? "");
  if (filterElement && filterRange) {
    const criteria = new Map<number, { type: "values"; values: string[] }>();
    for (const column of children(filterElement, "filterColumn")) {
      const id = intAttr(column, "colId");
      const filters = child(column, "filters");
      if (id === null || !filters) continue;
      const allowed = children(filters, "filter").map((f) => attr(f, "val")).filter((v): v is string => v !== null);
      if (attr(filters, "blank") === "1") allowed.push("");
      criteria.set(filterRange.start.column + id, { type: "values", values: allowed });
    }
    // Rows Excel hid for the filter are the filtered rows.
    const hiddenRows = new Set<number>();
    if (criteria.size) {
      for (const row of sheet.hiddenRows) if (row > filterRange.start.row && row <= filterRange.end.row) hiddenRows.add(row);
      for (const row of hiddenRows) sheet.hiddenRows.delete(row);
    }
    sheet.filter = { range: filterRange, criteria, hiddenRows };
  }
  for (const block of children(root, "conditionalFormatting")) {
    const ranges = (attr(block, "sqref") ?? "").split(" ").map(parseRange).filter((r): r is CellRange => !!r);
    for (const ruleElement of children(block, "cfRule")) {
      const parsed = conditionalRule(ruleElement, styles, theme);
      if (!parsed) continue;
      for (const r of ranges) sheet.conditionalFormats.push({ id: uuid(), range: r, rule: parsed[0], format: parsed[1] });
    }
  }
  const options = child(root, "printOptions");
  if (options) {
    sheet.pageSetup.printGridlines = attr(options, "gridLines") === "1";
    sheet.pageSetup.printHeadings = attr(options, "headings") === "1";
    sheet.pageSetup.centerHorizontally = attr(options, "horizontalCentered") === "1";
  }
  const setup = child(root, "pageSetup");
  if (setup) {
    if (attr(setup, "orientation") === "landscape") sheet.pageSetup.orientation = "landscape";
    if (attr(setup, "fitToHeight") === "0" && attr(setup, "fitToWidth") === "1") sheet.pageSetup.scaling = "fitWidth";
  }
}

const LIGHT_RED: HighlightFormat = { fill: "#FFC7CE", text: "#9C0006", bold: false, italic: false };

function conditionalRule(rule: Element, styles: StyleReader, theme: Color[]): [Rule, HighlightFormat] | null {
  const format = styles.differential(intAttr(rule, "dxfId") ?? -1) ?? LIGHT_RED;
  const formulas = children(rule, "formula").map((f) => f.textContent ?? "");
  const number = (i: number) => (i < formulas.length && formulas[i].trim() !== "" && Number.isFinite(Number(formulas[i])) ? Number(formulas[i]) : null);
  const text = (i: number) => {
    if (i >= formulas.length) return null;
    let t = formulas[i];
    if (t.startsWith('"') && t.endsWith('"') && t.length >= 2) t = t.slice(1, -1).replace(/""/g, '"');
    return t;
  };
  const value = (r: Rule | null): [Rule, HighlightFormat] | null => (r ? [r, format] : null);
  switch (attr(rule, "type")) {
    case "cellIs": {
      const a = number(0), b = number(1), t = text(0);
      switch (attr(rule, "operator")) {
        case "greaterThan": return value(a !== null ? { type: "greaterThan", value: a } : null);
        case "greaterThanOrEqual": return value(a !== null ? { type: "greaterThan", value: a - 1e-9 } : null);
        case "lessThan": return value(a !== null ? { type: "lessThan", value: a } : null);
        case "lessThanOrEqual": return value(a !== null ? { type: "lessThan", value: a + 1e-9 } : null);
        case "between": return value(a !== null && b !== null ? { type: "between", low: a, high: b } : null);
        case "equal": return value(t !== null ? { type: "equalTo", text: t } : null);
        case "notEqual": return value(t !== null ? { type: "notEqualTo", text: t } : null);
        default: return null;
      }
    }
    case "containsText": return value(attr(rule, "text") !== null ? { type: "textContains", text: attr(rule, "text")! } : null);
    case "beginsWith": return value(attr(rule, "text") !== null ? { type: "beginsWith", text: attr(rule, "text")! } : null);
    case "endsWith": return value(attr(rule, "text") !== null ? { type: "endsWith", text: attr(rule, "text")! } : null);
    case "containsBlanks": return value({ type: "blanks" });
    case "notContainsBlanks": return value({ type: "noBlanks" });
    case "duplicateValues": return value({ type: "duplicates" });
    case "uniqueValues": return value({ type: "uniques" });
    case "top10": {
      const count = intAttr(rule, "rank") ?? 10;
      const percent = attr(rule, "percent") === "1";
      return value(attr(rule, "bottom") === "1" ? { type: "bottom", count, percent } : { type: "top", count, percent });
    }
    case "aboveAverage": return value({ type: attr(rule, "aboveAverage") === "0" ? "belowAverage" : "aboveAverage" });
    case "expression": return value(formulas.length ? { type: "formula", formula: stripPrefixes(formulas[0]) } : null);
    case "colorScale": {
      const colors = children(child(rule, "colorScale"), "color").map((c) => styleColor(c, theme)).filter((c): c is Color => !!c);
      return colors.length >= 2 ? [{ type: "colorScale", colors }, format] : null;
    }
    case "dataBar": {
      const color = styleColor(child(child(rule, "dataBar"), "color"), theme) ?? "#638EC6";
      return [{ type: "dataBar", color }, format];
    }
    case "iconSet": {
      const name = attr(child(rule, "iconSet"), "iconSet") ?? "3TrafficLights1";
      const set = name.includes("Arrow") ? "arrows" : name.includes("Flag") ? "flags" : name.includes("Star") ? "stars" : "trafficLights";
      return [{ type: "iconSet", set }, format];
    }
    default:
      return null;
  }
}

const BUILTIN_FORMATS: Record<number, string> = {
  0: "General", 1: "0", 2: "0.00", 3: "#,##0", 4: "#,##0.00", 5: "$#,##0_);($#,##0)", 6: "$#,##0_);[Red]($#,##0)",
  7: "$#,##0.00_);($#,##0.00)", 8: "$#,##0.00_);[Red]($#,##0.00)", 9: "0%", 10: "0.00%", 11: "0.00E+00", 12: "# ?/?",
  13: "# ??/??", 14: "m/d/yyyy", 15: "d-mmm-yy", 16: "d-mmm", 17: "mmm-yy", 18: "h:mm AM/PM", 19: "h:mm:ss AM/PM",
  20: "h:mm", 21: "h:mm:ss", 22: "m/d/yyyy h:mm", 37: "#,##0 ;(#,##0)", 38: "#,##0 ;[Red](#,##0)", 39: "#,##0.00;(#,##0.00)",
  40: "#,##0.00;[Red](#,##0.00)", 44: FORMATS.accounting, 45: "mm:ss", 46: "[h]:mm:ss", 47: "mmss.0", 48: "##0.0E+0", 49: "@",
};

const INDEXED_COLORS = [
  0x000000, 0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0xFF00FF, 0x00FFFF,
  0x000000, 0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0xFF00FF, 0x00FFFF,
  0x800000, 0x008000, 0x000080, 0x808000, 0x800080, 0x008080, 0xC0C0C0, 0x808080,
  0x9999FF, 0x993366, 0xFFFFCC, 0xCCFFFF, 0x660066, 0xFF8080, 0x0066CC, 0xCCCCFF,
  0x000080, 0xFF00FF, 0xFFFF00, 0x00FFFF, 0x800080, 0x800000, 0x008080, 0x0000FF,
  0x00CCFF, 0xCCFFFF, 0xCCFFCC, 0xFFFF99, 0x99CCFF, 0xFF99CC, 0xCC99FF, 0xFFCC99,
  0x3366FF, 0x33CCCC, 0x99CC00, 0xFFCC00, 0xFF9900, 0xFF6600, 0x666699, 0x969696,
  0x003366, 0x339966, 0x003300, 0x333300, 0x993300, 0x993366, 0x333399, 0x333333,
];

function styleColor(element: Element | null, theme: Color[]): Color | null {
  if (!element) return null;
  let color: Color | null = null;
  const rgb = normalizeColor(attr(element, "rgb"));
  const t = intAttr(element, "theme"), indexed = intAttr(element, "indexed");
  if (rgb) color = rgb;
  else if (t !== null && t >= 0 && t < theme.length) color = theme[t];
  else if (indexed !== null) {
    if (indexed >= INDEXED_COLORS.length) return null;
    color = "#" + INDEXED_COLORS[indexed].toString(16).padStart(6, "0").toUpperCase();
  }
  if (!color) return null;
  const tint = numAttr(element, "tint");
  if (tint) color = tint > 0 ? mixColors(color, "#FFFFFF", tint) : mixColors(color, "#000000", -tint);
  return color;
}

/** Drops locale tags Wired Grid doesn't use (e.g. `[$-409]`). */
const cleanFormat = (code: string) => code.replace(/\[\$-[0-9A-Fa-f]+\]/g, "") || "General";

interface FontRecord { name?: string; size?: number; bold: boolean; italic: boolean; underline: boolean; doubleUnderline: boolean; strike: boolean; color?: Color }

class StyleReader {
  private styles: CellStyle[] = [];
  private dxfs: HighlightFormat[] = [];

  constructor(root: Element | null, theme: Color[]) {
    if (!root) return;
    const formats: Record<number, string> = { ...BUILTIN_FORMATS };
    for (const numFmt of children(child(root, "numFmts"), "numFmt")) {
      const id = intAttr(numFmt, "numFmtId"), code = attr(numFmt, "formatCode");
      if (id !== null && code !== null) formats[id] = cleanFormat(code);
    }
    const flag = (f: Element, name: string) => {
      const e = child(f, name);
      return !!e && attr(e, "val") !== "0" && attr(e, "val") !== "false";
    };
    const fonts: FontRecord[] = children(child(root, "fonts"), "font").map((f) => {
      const font: FontRecord = { bold: flag(f, "b"), italic: flag(f, "i"), underline: false, doubleUnderline: false, strike: flag(f, "strike") };
      font.name = attr(child(f, "name"), "val") ?? undefined;
      font.size = numAttr(child(f, "sz"), "val") ?? undefined;
      const u = child(f, "u");
      if (u) {
        const val = attr(u, "val") ?? "single";
        font.underline = val === "single" || val === "singleAccounting";
        font.doubleUnderline = val === "double" || val === "doubleAccounting";
      }
      const c = child(f, "color");
      if (c) {
        const color = styleColor(c, theme);
        // Theme text color 1 is the default "automatic" black.
        if (!(attr(c, "theme") === "1" && attr(c, "tint") === null) && attr(c, "auto") !== "1" && color && color !== "#000000") font.color = color;
      }
      return font;
    });
    const fills: (Color | null)[] = children(child(root, "fills"), "fill").map((f) => {
      const pattern = child(f, "patternFill");
      const type = attr(pattern, "patternType");
      if (!pattern || !type || type === "none" || type === "gray125") return null;
      return styleColor(child(pattern, "fgColor"), theme) ?? styleColor(child(pattern, "bgColor"), theme);
    });
    const borders: CellBorders[] = children(child(root, "borders"), "border").map((b) => {
      const line = (name: string): BorderLine | undefined => {
        const edge = child(b, name);
        const style = attr(edge, "style");
        if (!edge || !style || style === "none") return undefined;
        let lineStyle: BorderLineStyle = "thin";
        if (["medium", "mediumDashed", "mediumDashDot", "mediumDashDotDot", "slantDashDot"].includes(style)) lineStyle = "medium";
        else if (style === "thick") lineStyle = "thick";
        else if (["dashed", "dashDot", "dashDotDot"].includes(style)) lineStyle = "dashed";
        else if (style === "dotted") lineStyle = "dotted";
        else if (style === "double") lineStyle = "double";
        else if (style === "hair") lineStyle = "hair";
        return { style: lineStyle, color: styleColor(child(edge, "color"), theme) ?? "#000000" };
      };
      const result: CellBorders = {};
      const top = line("top"), left = line("left") ?? line("start"), bottom = line("bottom"), right = line("right") ?? line("end");
      if (top) result.top = top;
      if (left) result.left = left;
      if (bottom) result.bottom = bottom;
      if (right) result.right = right;
      return result;
    });
    const defaultFont = fonts[0];
    // Excel's default is 11 pt; Wired Grid's is 12 pt. Keep sizes relative to the default.
    const sizeOffset = DEFAULT_FONT_SIZE - (defaultFont?.size ?? 11);
    for (const xf of children(child(root, "cellXfs"), "xf")) {
      const style: CellStyle = {};
      const numFmt = intAttr(xf, "numFmtId");
      if (numFmt !== null) style.numberFormat = formats[numFmt] ?? "General";
      const fontId = intAttr(xf, "fontId");
      if (fontId !== null && fontId < fonts.length) {
        const font = fonts[fontId];
        Object.assign(style, { bold: font.bold, italic: font.italic, underline: font.underline, doubleUnderline: font.doubleUnderline, strikethrough: font.strike });
        if (font.color) style.textColor = font.color;
        // Only record fonts that differ from the workbook default.
        if (font.name !== defaultFont?.name && font.name) style.fontName = font.name;
        if (font.size !== defaultFont?.size && font.size !== undefined) style.fontSize = font.size + sizeOffset;
      }
      const fillId = intAttr(xf, "fillId");
      if (fillId !== null && fills[fillId]) style.fillColor = fills[fillId]!;
      const borderId = intAttr(xf, "borderId");
      if (borderId !== null && borderId < borders.length) style.borders = borders[borderId];
      const alignment = child(xf, "alignment");
      if (alignment) {
        const h = attr(alignment, "horizontal");
        const hMap: Record<string, CellStyle["horizontal"]> = { left: "left", center: "center", right: "right", fill: "fill", justify: "justify", distributed: "justify", centerContinuous: "centerAcross" };
        if (h && hMap[h]) style.horizontal = hMap[h];
        const v = attr(alignment, "vertical");
        if (v === "top") style.vertical = "top";
        else if (v === "center" || v === "justify" || v === "distributed") style.vertical = "middle";
        style.wrap = attr(alignment, "wrapText") === "1" || attr(alignment, "wrapText") === "true";
        style.shrinkToFit = attr(alignment, "shrinkToFit") === "1";
        style.indent = intAttr(alignment, "indent") ?? 0;
        const rotation = intAttr(alignment, "textRotation");
        if (rotation) style.rotation = rotation <= 90 ? rotation : 90 - rotation;
      }
      this.styles.push(normalizeStyle(style));
    }
    for (const dxf of children(child(root, "dxfs"), "dxf")) {
      const format: HighlightFormat = { bold: false, italic: false };
      const font = child(dxf, "font");
      if (font) {
        format.bold = !!child(font, "b");
        format.italic = !!child(font, "i");
        const text = styleColor(child(font, "color"), theme);
        if (text) format.text = text;
      }
      const pattern = child(child(dxf, "fill"), "patternFill");
      if (pattern) {
        const fill = styleColor(child(pattern, "bgColor"), theme) ?? styleColor(child(pattern, "fgColor"), theme);
        if (fill) format.fill = fill;
      }
      const edge = child(child(dxf, "border"), "left");
      if (edge && attr(edge, "style") !== null) format.border = styleColor(child(edge, "color"), theme) ?? "#000000";
      this.dxfs.push(format);
    }
  }

  style(index: number): CellStyle | null {
    return index >= 0 && index < this.styles.length ? this.styles[index] : null;
  }

  differential(index: number): HighlightFormat | null {
    return index >= 0 && index < this.dxfs.length ? this.dxfs[index] : null;
  }
}

// MARK: - Writing

/** Functions newer than Excel 2010 need the `_xlfn.` prefix in files. */
const FUTURE_FUNCTIONS = new Set([
  "XLOOKUP", "XMATCH", "FILTER", "SORT", "SORTBY", "UNIQUE", "SEQUENCE", "RANDARRAY", "LET", "TEXTJOIN", "CONCAT",
  "IFS", "SWITCH", "MAXIFS", "MINIFS", "IFNA", "XOR", "DAYS", "ISOWEEKNUM", "STDEV.S", "STDEV.P", "VAR.S", "VAR.P",
  "MODE.SNGL", "PERCENTILE.INC", "PERCENTILE.EXC", "QUARTILE.INC", "QUARTILE.EXC", "RANK.EQ", "RANK.AVG",
  "NORM.DIST", "NORM.S.DIST", "NORM.INV", "NORM.S.INV", "CEILING.MATH", "FLOOR.MATH", "TEXTBEFORE", "TEXTAFTER",
  "TEXTSPLIT", "VSTACK", "HSTACK", "TAKE", "DROP", "CHOOSECOLS", "CHOOSEROWS", "TOCOL", "TOROW", "FORECAST.LINEAR",
  "COVARIANCE.P", "COVARIANCE.S", "BINOM.DIST", "POISSON.DIST", "EXPON.DIST", "CONFIDENCE.NORM", "UNICHAR", "UNICODE",
  "NUMBERVALUE", "SHEET", "SHEETS", "FORMULATEXT", "ISFORMULA", "COMBINA", "ARABIC", "BASE", "DECIMAL", "COT", "CSC",
  "SEC", "AGGREGATE", "PERCENTRANK.INC", "RRI", "PDURATION",
]);

export function excelFormula(formula: string): string {
  let tokens;
  try {
    tokens = tokenize(formula);
  } catch {
    return formula;
  }
  return tokens.map((t) => (t.kind.t === "function" && FUTURE_FUNCTIONS.has(t.kind.name) ? "_xlfn." + t.text : t.text)).join("");
}

export function escapeXML(s: string): string {
  let out = "";
  for (const ch of s) {
    const code = ch.codePointAt(0)!;
    if (ch === "&") out += "&amp;";
    else if (ch === "<") out += "&lt;";
    else if (ch === ">") out += "&gt;";
    else if (ch === '"') out += "&quot;";
    // Control characters aren't allowed in XML 1.0.
    else if (code < 32 && ch !== "\n" && ch !== "\t" && ch !== "\r") continue;
    else out += ch;
  }
  return out;
}

const xmlNumber = (n: number) => (n === Math.round(n) && Math.abs(n) < 1e15 ? String(n) : String(n));
const argb = (color: Color) => "FF" + color.replace("#", "").toUpperCase();
const absolute = (r: CellRange) => {
  const abs = (a: CellAddress) => "$" + columnName(a.column) + "$" + String(a.row + 1);
  return isSingleCell(r) ? abs(r.start) : abs(r.start) + ":" + abs(r.end);
};
const isoNoMillis = (d: Date) => d.toISOString().replace(/\.\d{3}Z$/, "Z");

/**
 * Writes `.xlsx` workbooks: values, formulas (with cached results), styles,
 * column widths, row heights, merges, frozen panes, filters, conditional
 * formatting, defined names and page setup.
 */
export function writeXLSX(workbook: Workbook): Uint8Array {
  const calculator = new Calculator(workbook);
  calculator.recalculate();
  const strings = new SharedStrings();
  const styles = new StyleTable();
  const sheets = workbook.sheets.map((sheet, index) => worksheet(sheet, index, index === workbook.activeSheetIndex, calculator, strings, styles));
  const n = workbook.sheets.length;
  const head = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n';

  let contentTypes = head + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>';
  for (let i = 0; i < n; i++) contentTypes += `<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`;
  contentTypes += "</Types>";

  let rels = head + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">';
  for (let i = 0; i < n; i++) rels += `<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>`;
  rels += `<Relationship Id="rId${n + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>`;
  rels += `<Relationship Id="rId${n + 2}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>`;
  rels += "</Relationships>";

  const entries: [string, string][] = [
    ["[Content_Types].xml", contentTypes],
    ["_rels/.rels", head + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>'],
    ["docProps/app.xml", head + '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>Wired Grid</Application></Properties>'],
    ["docProps/core.xml", head + `<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:creator>${escapeXML(workbook.author)}</dc:creator><dcterms:created xsi:type="dcterms:W3CDTF">${isoNoMillis(workbook.created)}</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">${isoNoMillis(new Date())}</dcterms:modified></cp:coreProperties>`],
    ["xl/workbook.xml", workbookXML(workbook)],
    ["xl/_rels/workbook.xml.rels", rels],
    ["xl/styles.xml", styles.xml()],
    ["xl/sharedStrings.xml", strings.xml()],
    ...sheets.map((xml, i): [string, string] => [`xl/worksheets/sheet${i + 1}.xml`, xml]),
  ];
  return writeZip(entries);
}

function workbookXML(workbook: Workbook): string {
  let xml = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><bookViews><workbookView activeTab="${workbook.activeSheetIndex}"/></bookViews><sheets>`;
  workbook.sheets.forEach((sheet, i) => { xml += `<sheet name="${escapeXML(sheet.name)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>`; });
  xml += "</sheets>";
  const names = workbook.names.map((n) => `<definedName name="${escapeXML(n.name)}">${escapeXML(excelFormula(n.formula))}</definedName>`);
  workbook.sheets.forEach((sheet, i) => {
    if (sheet.filter) names.push(`<definedName name="_xlnm._FilterDatabase" localSheetId="${i}" hidden="1">${escapeXML(quotedSheetName(sheet.name))}!${absolute(sheet.filter.range)}</definedName>`);
    if (sheet.pageSetup.printArea) names.push(`<definedName name="_xlnm.Print_Area" localSheetId="${i}">${escapeXML(quotedSheetName(sheet.name))}!${absolute(sheet.pageSetup.printArea)}</definedName>`);
  });
  if (names.length) xml += "<definedNames>" + names.join("") + "</definedNames>";
  return xml + '<calcPr calcId="191029" fullCalcOnLoad="1"/></workbook>';
}

function worksheet(sheet: Sheet, index: number, active: boolean, calculator: Calculator, strings: SharedStrings, styles: StyleTable): string {
  let xml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">';
  if (sheet.tabColor) xml += `<sheetPr><tabColor rgb="${argb(sheet.tabColor)}"/></sheetPr>`;
  const used = usedRange(sheet);
  xml += `<dimension ref="${used ? rangeA1(range({ row: 0, column: 0 }, used.end)) : "A1"}"/>`;
  let view = '<sheetView workbookViewId="0"';
  if (active) view += ' tabSelected="1"';
  if (!sheet.showGridlines) view += ' showGridLines="0"';
  if (!sheet.showHeadings) view += ' showRowColHeaders="0"';
  if (sheet.zoom !== 1) view += ` zoomScale="${Math.round(sheet.zoom * 100)}"`;
  view += ">";
  if (sheet.frozenRows > 0 || sheet.frozenColumns > 0) {
    const topLeft = a1({ row: sheet.frozenRows, column: sheet.frozenColumns });
    const pane = sheet.frozenRows > 0 && sheet.frozenColumns > 0 ? "bottomRight" : sheet.frozenRows > 0 ? "bottomLeft" : "topRight";
    view += "<pane";
    if (sheet.frozenColumns > 0) view += ` xSplit="${sheet.frozenColumns}"`;
    if (sheet.frozenRows > 0) view += ` ySplit="${sheet.frozenRows}"`;
    view += ` topLeftCell="${topLeft}" activePane="${pane}" state="frozen"/>`;
  }
  view += "</sheetView>";
  xml += `<sheetViews>${view}</sheetViews><sheetFormatPr defaultRowHeight="15"/>`;

  const customColumns = [...new Set([...sheet.columnWidths.keys(), ...sheet.hiddenColumns, ...sheet.columnStyles.keys()])].sort((a, b) => a - b);
  if (customColumns.length) {
    xml += "<cols>";
    for (const column of customColumns) {
      let col = `<col min="${column + 1}" max="${column + 1}" width="${ExcelUnits.columnCharacters(sheet.columnWidths.get(column) ?? DEFAULT_COLUMN_WIDTH)}" customWidth="1"`;
      if (sheet.hiddenColumns.has(column)) col += ' hidden="1"';
      const style = sheet.columnStyles.get(column);
      if (style) col += ` style="${styles.index(style)}"`;
      xml += col + "/>";
    }
    xml += "</cols>";
  }

  // Cells, row by row.
  const rows = new Map<number, [number, Cell][]>();
  for (const [key, cell] of sheet.cells) {
    const { row, column } = keyAddress(key);
    if (!rows.has(row)) rows.set(row, []);
    rows.get(row)!.push([column, cell]);
  }
  const rowIndices = [...new Set([...rows.keys(), ...sheet.rowHeights.keys(), ...sheet.hiddenRows, ...sheet.rowStyles.keys(), ...(sheet.filter?.hiddenRows ?? [])])].sort((a, b) => a - b);
  const parts: string[] = ["<sheetData>"];
  for (const row of rowIndices) {
    let rowXML = `<row r="${row + 1}"`;
    const height = sheet.rowHeights.get(row);
    if (height !== undefined) rowXML += ` ht="${ExcelUnits.excelRowHeight(height)}" customHeight="1"`;
    if (isRowHidden(sheet, row)) rowXML += ' hidden="1"';
    const rowStyle = sheet.rowStyles.get(row);
    if (rowStyle) rowXML += ` s="${styles.index(rowStyle)}" customFormat="1"`;
    rowXML += ">";
    for (const [column, cell] of (rows.get(row) ?? []).sort((a, b) => a[0] - b[0])) {
      const style = styleAt(sheet, row, column);
      const styleIndex = isPlainStyle(style) ? 0 : styles.index(style);
      let c = `<c r="${a1({ row, column })}"`;
      if (styleIndex !== 0) c += ` s="${styleIndex}"`;
      if (cell.formula !== undefined) {
        const f = `<f>${escapeXML(excelFormula(cell.formula))}</f>`;
        const v = calculator.value(index, row, column);
        if (typeof v === "string") c += ` t="str">${f}<v>${escapeXML(v)}</v></c>`;
        else if (typeof v === "boolean") c += ` t="b">${f}<v>${v ? 1 : 0}</v></c>`;
        else if (v instanceof FormulaError) c += ` t="e">${f}<v>${escapeXML(v === FormulaError.circular ? "#REF!" : v.code)}</v></c>`;
        else if (typeof v === "number") c += `>${f}<v>${xmlNumber(v)}</v></c>`;
        else c += `>${f}</c>`;
      } else {
        const v = cell.value;
        if (v === null) c += "/>";
        else if (typeof v === "number") c += `><v>${xmlNumber(v)}</v></c>`;
        else if (typeof v === "string") c += ` t="s"><v>${strings.index(v)}</v></c>`;
        else if (typeof v === "boolean") c += ` t="b"><v>${v ? 1 : 0}</v></c>`;
        else c += ` t="e"><v>${escapeXML(v.code)}</v></c>`;
      }
      rowXML += c;
    }
    parts.push(rowXML + "</row>");
  }
  parts.push("</sheetData>");
  xml += parts.join("");

  if (sheet.filter) {
    const filter = sheet.filter;
    xml += `<autoFilter ref="${rangeA1(filter.range)}">`;
    for (const [column, criterion] of [...filter.criteria].sort((a, b) => a[0] - b[0])) {
      if (criterion.type !== "values") continue;
      xml += `<filterColumn colId="${column - filter.range.start.column}"><filters${criterion.values.includes("") ? ' blank="1"' : ""}>`;
      for (const value of [...criterion.values].sort()) if (value) xml += `<filter val="${escapeXML(value)}"/>`;
      xml += "</filters></filterColumn>";
    }
    xml += "</autoFilter>";
  }
  if (sheet.merges.length) xml += `<mergeCells count="${sheet.merges.length}">` + sheet.merges.map((m) => `<mergeCell ref="${rangeA1(m)}"/>`).join("") + "</mergeCells>";
  let priority = 1;
  for (const cf of sheet.conditionalFormats) {
    const rule = conditionalRuleXML(cf, priority, styles);
    if (rule) {
      xml += `<conditionalFormatting sqref="${rangeA1(cf.range)}">${rule}</conditionalFormatting>`;
      priority++;
    }
  }
  const setup = sheet.pageSetup;
  if (setup.printGridlines || setup.printHeadings || setup.centerHorizontally) {
    xml += "<printOptions" + (setup.printGridlines ? ' gridLines="1"' : "") + (setup.printHeadings ? ' headings="1"' : "") + (setup.centerHorizontally ? ' horizontalCentered="1"' : "") + "/>";
  }
  const margin = setup.margin / 72;
  xml += `<pageMargins left="${margin}" right="${margin}" top="${margin}" bottom="${margin}" header="0.3" footer="0.3"/>`;
  let page = `<pageSetup orientation="${setup.orientation}"`;
  if (setup.scaling === "fitWidth") page += ' fitToWidth="1" fitToHeight="0"';
  if (setup.scaling === "fitPage") page += ' fitToWidth="1" fitToHeight="1"';
  xml += page + "/></worksheet>";
  return xml;
}

function conditionalRuleXML(cf: ConditionalFormat, priority: number, styles: StyleTable): string | null {
  const dxf = () => styles.differential(cf.format);
  const cellIs = (op: string, formulas: string[]) =>
    `<cfRule type="cellIs" dxfId="${dxf()}" priority="${priority}" operator="${op}">` + formulas.map((f) => `<formula>${escapeXML(f)}</formula>`).join("") + "</cfRule>";
  const quoted = (text: string) => (numberFromText(text) !== null ? text : '"' + text.replace(/"/g, '""') + '"');
  const first = a1(cf.range.start);
  const rule = cf.rule;
  switch (rule.type) {
    case "greaterThan": return cellIs("greaterThan", [xmlNumber(rule.value)]);
    case "lessThan": return cellIs("lessThan", [xmlNumber(rule.value)]);
    case "between": return cellIs("between", [xmlNumber(rule.low), xmlNumber(rule.high)]);
    case "equalTo": return cellIs("equal", [quoted(rule.text)]);
    case "notEqualTo": return cellIs("notEqual", [quoted(rule.text)]);
    case "textContains":
      return `<cfRule type="containsText" dxfId="${dxf()}" priority="${priority}" operator="containsText" text="${escapeXML(rule.text)}"><formula>NOT(ISERROR(SEARCH(${escapeXML(quoted(rule.text))},${first})))</formula></cfRule>`;
    case "beginsWith":
      return `<cfRule type="beginsWith" dxfId="${dxf()}" priority="${priority}" operator="beginsWith" text="${escapeXML(rule.text)}"><formula>LEFT(${first},${[...rule.text].length})=${escapeXML(quoted(rule.text))}</formula></cfRule>`;
    case "endsWith":
      return `<cfRule type="endsWith" dxfId="${dxf()}" priority="${priority}" operator="endsWith" text="${escapeXML(rule.text)}"><formula>RIGHT(${first},${[...rule.text].length})=${escapeXML(quoted(rule.text))}</formula></cfRule>`;
    case "blanks": return `<cfRule type="containsBlanks" dxfId="${dxf()}" priority="${priority}"><formula>LEN(TRIM(${first}))=0</formula></cfRule>`;
    case "noBlanks": return `<cfRule type="notContainsBlanks" dxfId="${dxf()}" priority="${priority}"><formula>LEN(TRIM(${first}))&gt;0</formula></cfRule>`;
    case "duplicates": return `<cfRule type="duplicateValues" dxfId="${dxf()}" priority="${priority}"/>`;
    case "uniques": return `<cfRule type="uniqueValues" dxfId="${dxf()}" priority="${priority}"/>`;
    case "top": return `<cfRule type="top10" dxfId="${dxf()}" priority="${priority}" rank="${rule.count}"${rule.percent ? ' percent="1"' : ""}/>`;
    case "bottom": return `<cfRule type="top10" dxfId="${dxf()}" priority="${priority}" rank="${rule.count}" bottom="1"${rule.percent ? ' percent="1"' : ""}/>`;
    case "aboveAverage": return `<cfRule type="aboveAverage" dxfId="${dxf()}" priority="${priority}"/>`;
    case "belowAverage": return `<cfRule type="aboveAverage" dxfId="${dxf()}" priority="${priority}" aboveAverage="0"/>`;
    case "formula": return `<cfRule type="expression" dxfId="${dxf()}" priority="${priority}"><formula>${escapeXML(excelFormula(rule.formula))}</formula></cfRule>`;
    case "colorScale": {
      if (rule.colors.length < 2) return null;
      const values = rule.colors.length === 3 ? '<cfvo type="min"/><cfvo type="percentile" val="50"/><cfvo type="max"/>' : '<cfvo type="min"/><cfvo type="max"/>';
      return `<cfRule type="colorScale" priority="${priority}"><colorScale>${values}` + rule.colors.map((c) => `<color rgb="${argb(c)}"/>`).join("") + "</colorScale></cfRule>";
    }
    case "dataBar":
      return `<cfRule type="dataBar" priority="${priority}"><dataBar><cfvo type="min"/><cfvo type="max"/><color rgb="${argb(rule.color)}"/></dataBar></cfRule>`;
    case "iconSet": {
      const name = { arrows: "3Arrows", trafficLights: "3TrafficLights1", flags: "3Flags", stars: "3Stars" }[rule.set];
      return `<cfRule type="iconSet" priority="${priority}"><iconSet iconSet="${name}"><cfvo type="percent" val="0"/><cfvo type="percent" val="33"/><cfvo type="percent" val="67"/></iconSet></cfRule>`;
    }
  }
}

class SharedStrings {
  private indices = new Map<string, number>();
  private strings: string[] = [];
  private total = 0;

  index(s: string): number {
    this.total++;
    const existing = this.indices.get(s);
    if (existing !== undefined) return existing;
    this.indices.set(s, this.strings.length);
    this.strings.push(s);
    return this.strings.length - 1;
  }

  xml(): string {
    const parts = [`<?xml version="1.0" encoding="UTF-8" standalone="yes"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="${this.total}" uniqueCount="${this.strings.length}">`];
    for (const s of this.strings) {
      const preserve = s.startsWith(" ") || s.endsWith(" ") || s.includes("\n");
      parts.push(`<si><t${preserve ? ' xml:space="preserve"' : ""}>${escapeXML(s)}</t></si>`);
    }
    return parts.join("") + "</sst>";
  }
}

const BUILTIN_FORMAT_IDS: Record<string, number> = {
  General: 0, "0": 1, "0.00": 2, "#,##0": 3, "#,##0.00": 4, "0%": 9, "0.00%": 10, "0.00E+00": 11,
  "# ?/?": 12, "# ??/??": 13, "m/d/yyyy": 14, "d-mmm-yy": 15, "d-mmm": 16, "mmm-yy": 17, "h:mm AM/PM": 18,
  "h:mm:ss AM/PM": 19, "h:mm": 20, "h:mm:ss": 21, "m/d/yyyy h:mm": 22, "@": 49,
};

class StyleTable {
  private xfs: CellStyle[] = [{}];
  private xfIndex = new Map<string, number>([[styleKey({}), 0]]);
  private dxfs: HighlightFormat[] = [];

  index(style: CellStyle): number {
    const key = styleKey(style);
    const existing = this.xfIndex.get(key);
    if (existing !== undefined) return existing;
    this.xfIndex.set(key, this.xfs.length);
    this.xfs.push(normalizeStyle(style));
    return this.xfs.length - 1;
  }

  differential(format: HighlightFormat): number {
    const key = JSON.stringify([format.fill, format.text, format.bold, format.italic, format.border]);
    const existing = this.dxfs.findIndex((d) => JSON.stringify([d.fill, d.text, d.bold, d.italic, d.border]) === key);
    if (existing >= 0) return existing;
    this.dxfs.push(format);
    return this.dxfs.length - 1;
  }

  xml(): string {
    const customFormats = new Map<string, number>();
    let nextFormatId = 164;
    for (const style of this.xfs) {
      const code = numberFormatOf(style);
      if (BUILTIN_FORMAT_IDS[code] === undefined && !customFormats.has(code)) customFormats.set(code, nextFormatId++);
    }
    const formatId = (code: string) => BUILTIN_FORMAT_IDS[code] ?? customFormats.get(code) ?? 0;

    const fonts: string[] = [], fontIndex = new Map<string, number>();
    const fills: Color[] = [], fillIndex = new Map<string, number>();
    const borders: CellBorders[] = [{}], borderIndex = new Map<string, number>([[JSON.stringify({}), 0]]);
    const defaults = settings();
    const font = (s: CellStyle) => {
      const key = JSON.stringify([s.fontName ?? defaults.defaultFontName ?? DEFAULT_FONT_NAME, s.fontSize ?? defaults.defaultFontSize ?? DEFAULT_FONT_SIZE, !!s.bold, !!s.italic, !!s.underline, !!s.doubleUnderline, !!s.strikethrough, s.textColor ?? null]);
      let i = fontIndex.get(key);
      if (i === undefined) {
        i = fonts.length;
        fontIndex.set(key, i);
        fonts.push(key);
      }
      return i;
    };
    const fill = (s: CellStyle) => {
      if (!s.fillColor) return 0;
      let i = fillIndex.get(s.fillColor);
      if (i === undefined) {
        i = fills.length + 2;
        fillIndex.set(s.fillColor, i);
        fills.push(s.fillColor);
      }
      return i;
    };
    const border = (s: CellStyle) => {
      const b = s.borders ?? {};
      const key = JSON.stringify([b.top, b.left, b.bottom, b.right]);
      const plainKey = JSON.stringify([undefined, undefined, undefined, undefined]);
      if (key === plainKey) return 0;
      let i = borderIndex.get(key);
      if (i === undefined) {
        i = borders.length;
        borderIndex.set(key, i);
        borders.push(b);
      }
      return i;
    };
    const H: Record<string, string> = { left: "left", center: "center", right: "right", fill: "fill", justify: "justify", centerAcross: "centerContinuous" };
    const records = this.xfs.map((style) => {
      const f = font(style), fl = fill(style), b = border(style), n = formatId(numberFormatOf(style));
      let record = `<xf numFmtId="${n}" fontId="${f}" fillId="${fl}" borderId="${b}" xfId="0"`;
      if (n !== 0) record += ' applyNumberFormat="1"';
      if (f !== 0) record += ' applyFont="1"';
      if (fl !== 0) record += ' applyFill="1"';
      if (b !== 0) record += ' applyBorder="1"';
      let alignment = "";
      if (style.horizontal && style.horizontal !== "general") alignment += ` horizontal="${H[style.horizontal]}"`;
      if (style.vertical && style.vertical !== "bottom") alignment += ` vertical="${style.vertical === "top" ? "top" : "center"}"`;
      if (style.wrap) alignment += ' wrapText="1"';
      if (style.shrinkToFit) alignment += ' shrinkToFit="1"';
      if (style.indent) alignment += ` indent="${style.indent}"`;
      if (style.rotation) alignment += ` textRotation="${style.rotation > 0 ? style.rotation : 90 - style.rotation}"`;
      return alignment ? record + ` applyAlignment="1"><alignment${alignment}/></xf>` : record + "/>";
    });

    let xml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">';
    if (customFormats.size) {
      xml += `<numFmts count="${customFormats.size}">`;
      for (const [code, id] of [...customFormats].sort((a, b) => a[1] - b[1])) xml += `<numFmt numFmtId="${id}" formatCode="${escapeXML(code)}"/>`;
      xml += "</numFmts>";
    }
    xml += `<fonts count="${fonts.length}">`;
    for (const key of fonts) {
      const [name, size, bold, italic, underline, doubleUnderline, strike, color] = JSON.parse(key) as [string, number, boolean, boolean, boolean, boolean, boolean, string | null];
      xml += "<font>" + (bold ? "<b/>" : "") + (italic ? "<i/>" : "") + (strike ? "<strike/>" : "") + (underline ? "<u/>" : "") + (doubleUnderline ? '<u val="double"/>' : "");
      xml += `<sz val="${xmlNumber(size)}"/>` + (color ? `<color rgb="${argb(color)}"/>` : '<color theme="1"/>') + `<name val="${escapeXML(name)}"/><family val="2"/></font>`;
    }
    xml += "</fonts>";
    xml += `<fills count="${fills.length + 2}"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>`;
    for (const color of fills) xml += `<fill><patternFill patternType="solid"><fgColor rgb="${argb(color)}"/><bgColor indexed="64"/></patternFill></fill>`;
    xml += `</fills><borders count="${borders.length}">`;
    for (const b of borders) {
      const edge = (name: string, line?: BorderLine) => (line ? `<${name} style="${line.style}"><color rgb="${argb(line.color)}"/></${name}>` : `<${name}/>`);
      xml += "<border>" + edge("left", b.left) + edge("right", b.right) + edge("top", b.top) + edge("bottom", b.bottom) + "<diagonal/></border>";
    }
    xml += '</borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>';
    xml += `<cellXfs count="${records.length}">` + records.join("") + "</cellXfs>";
    xml += '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>';
    xml += `<dxfs count="${this.dxfs.length}">`;
    for (const d of this.dxfs) {
      xml += "<dxf>";
      if (d.bold || d.italic || d.text) xml += "<font>" + (d.bold ? "<b/>" : "") + (d.italic ? "<i/>" : "") + (d.text ? `<color rgb="${argb(d.text)}"/>` : "") + "</font>";
      if (d.fill) xml += `<fill><patternFill><bgColor rgb="${argb(d.fill)}"/></patternFill></fill>`;
      if (d.border) {
        const e = (n: string) => `<${n} style="thin"><color rgb="${argb(d.border!)}"/></${n}>`;
        xml += "<border>" + e("left") + e("right") + e("top") + e("bottom") + "</border>";
      }
      xml += "</dxf>";
    }
    return xml + '</dxfs><tableStyles count="0"/></styleSheet>';
  }
}

export type { BorderLineStyle };
