import { contentExtent, type Color, type ConditionalFormat, type HighlightFormat, type IconSet, type Rule, type Sheet } from "../model/workbook";
import { cellCount, forEachCell, isWholeColumns, isWholeRows, rangeContains, rangeRC, type CellAddress } from "../model/address";
import { FormulaError, type CellValue } from "../model/values";
import { mixColors } from "../model/color";
import { general, plainText } from "../formula/numberFormat";
import { numberFromText } from "../formula/valueParser";
import { shiftFormula } from "../formula/rewriter";
import { asBool } from "../formula/fvalue";
import type { Calculator } from "../formula/calculator";

/** Range-wide statistics some rules need (averages, top-N thresholds, duplicates). */
export class ConditionalStats {
  minimum = 0;
  maximum = 0;
  average = 0;
  sortedNumbers: number[];
  textCounts = new Map<string, number>();

  constructor(values: CellValue[]) {
    this.sortedNumbers = values.filter((v): v is number => typeof v === "number").sort((a, b) => a - b);
    const n = this.sortedNumbers;
    this.minimum = n[0] ?? 0;
    this.maximum = n[n.length - 1] ?? 0;
    this.average = n.length ? n.reduce((a, b) => a + b, 0) / n.length : 0;
    for (const v of values) {
      if (v === null) continue;
      const key = plainText(v).toLowerCase();
      this.textCounts.set(key, (this.textCounts.get(key) ?? 0) + 1);
    }
  }

  threshold(top: boolean, count: number, percent: boolean): number | null {
    const n = this.sortedNumbers;
    if (!n.length) return null;
    const k = percent ? Math.max(1, Math.floor((n.length * count) / 100)) : count;
    if (k <= 0) return null;
    const clamped = Math.min(k, n.length);
    return top ? n[n.length - clamped] : n[clamped - 1];
  }
}

/** What conditional formatting changes about one cell. */
export interface ConditionalLook {
  fill?: Color;
  text?: Color;
  bold: boolean;
  italic: boolean;
  border?: Color;
  /** Fraction of the cell width, and color. */
  dataBar?: [number, Color];
  icon?: [IconSet, number];
}

const sameText = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

export function ruleMatches(rule: Rule, value: CellValue, stats: ConditionalStats | null): boolean {
  const number = typeof value === "number" ? value : null;
  switch (rule.type) {
    case "greaterThan": return number !== null && number > rule.value;
    case "lessThan": return number !== null && number < rule.value;
    case "between": return number !== null && number >= Math.min(rule.low, rule.high) && number <= Math.max(rule.low, rule.high);
    case "equalTo": {
      const t = numberFromText(rule.text);
      if (number !== null && t !== null) return number === t;
      return sameText(plainText(value), rule.text);
    }
    case "notEqualTo": {
      const t = numberFromText(rule.text);
      if (number !== null && t !== null) return number !== t;
      return !sameText(plainText(value), rule.text);
    }
    case "textContains": return rule.text !== "" && plainText(value).toLowerCase().includes(rule.text.toLowerCase());
    case "beginsWith": return plainText(value).toLowerCase().startsWith(rule.text.toLowerCase());
    case "endsWith": return plainText(value).toLowerCase().endsWith(rule.text.toLowerCase());
    case "blanks": return value === null || value === "";
    case "noBlanks": return !(value === null || value === "");
    case "duplicates": return value !== null && !!stats && (stats.textCounts.get(plainText(value).toLowerCase()) ?? 0) > 1;
    case "uniques": return value !== null && !!stats && (stats.textCounts.get(plainText(value).toLowerCase()) ?? 0) === 1;
    case "top": {
      const t = stats?.threshold(true, rule.count, rule.percent);
      return number !== null && t !== null && t !== undefined && number >= t;
    }
    case "bottom": {
      const t = stats?.threshold(false, rule.count, rule.percent);
      return number !== null && t !== null && t !== undefined && number <= t;
    }
    case "aboveAverage": return number !== null && !!stats && number > stats.average;
    case "belowAverage": return number !== null && !!stats && number < stats.average;
    default: return false;
  }
}

export function ruleSummary(rule: Rule): string {
  const n = (v: number) => general(v);
  switch (rule.type) {
    case "greaterThan": return `Cell value > ${n(rule.value)}`;
    case "lessThan": return `Cell value < ${n(rule.value)}`;
    case "between": return `Cell value between ${n(rule.low)} and ${n(rule.high)}`;
    case "equalTo": return `Cell value = ${rule.text}`;
    case "notEqualTo": return `Cell value ≠ ${rule.text}`;
    case "textContains": return `Text contains “${rule.text}”`;
    case "beginsWith": return `Text begins with “${rule.text}”`;
    case "endsWith": return `Text ends with “${rule.text}”`;
    case "blanks": return "Blank cells";
    case "noBlanks": return "Cells that aren't blank";
    case "duplicates": return "Duplicate values";
    case "uniques": return "Unique values";
    case "top": return `Top ${rule.count}${rule.percent ? "%" : ""}`;
    case "bottom": return `Bottom ${rule.count}${rule.percent ? "%" : ""}`;
    case "aboveAverage": return "Above average";
    case "belowAverage": return "Below average";
    case "formula": return `Formula: =${rule.formula}`;
    case "colorScale": return `${rule.colors.length}-color scale`;
    case "dataBar": return "Data bar";
    case "iconSet": return `Icon set: ${({ arrows: "3 Arrows", trafficLights: "3 Traffic Lights", flags: "3 Flags", stars: "3 Stars" } as const)[rule.set]}`;
  }
}

/** Evaluates a sheet's conditional formats, caching range statistics per calculation. */
export class ConditionalFormatter {
  private statsCache = new Map<string, ConditionalStats>();
  private cacheKey = "";

  constructor(private calculator: Calculator) {}

  look(a: CellAddress, sheetIndex: number, revision: number): ConditionalLook | null {
    const sheet = this.calculator.workbook.sheets[sheetIndex];
    if (!sheet?.conditionalFormats.length) return null;
    const key = `${revision}:${sheetIndex}:${this.calculator.generation}`;
    if (key !== this.cacheKey) {
      this.statsCache.clear();
      this.cacheKey = key;
    }
    const look: ConditionalLook = { bold: false, italic: false };
    let matched = false;
    // Earlier rules take priority, so apply from last to first.
    for (let i = sheet.conditionalFormats.length - 1; i >= 0; i--) {
      const format = sheet.conditionalFormats[i];
      if (!rangeContains(format.range, a)) continue;
      const value = this.calculator.value(sheetIndex, a.row, a.column);
      const stats = this.stats(format, sheet, sheetIndex);
      const rule = format.rule;
      switch (rule.type) {
        case "colorScale": {
          const colors = rule.colors;
          if (typeof value !== "number" || colors.length < 2 || !(stats.maximum > stats.minimum)) {
            if (typeof value === "number" && colors.length) {
              look.fill = colors.length === 3 ? colors[1] : colors[0];
              matched = true;
            }
            continue;
          }
          const t = (value - stats.minimum) / (stats.maximum - stats.minimum);
          look.fill = colors.length === 2 ? mixColors(colors[0], colors[1], t) : t < 0.5 ? mixColors(colors[0], colors[1], t * 2) : mixColors(colors[1], colors[2], (t - 0.5) * 2);
          matched = true;
          break;
        }
        case "dataBar": {
          if (typeof value !== "number") continue;
          const low = Math.min(stats.minimum, 0), high = Math.max(stats.maximum, 0);
          const fraction = high > low ? (value - low) / (high - low) : 1;
          look.dataBar = [Math.max(0.02, Math.min(1, fraction)), rule.color];
          matched = true;
          break;
        }
        case "iconSet": {
          if (typeof value !== "number") continue;
          const span = stats.maximum - stats.minimum;
          const t = span > 0 ? (value - stats.minimum) / span : 1;
          look.icon = [rule.set, t >= 0.67 ? 2 : t >= 0.33 ? 1 : 0];
          matched = true;
          break;
        }
        case "formula": {
          // Relative references are written for the range's top-left cell.
          const shifted = shiftFormula(rule.formula, a.row - format.range.start.row, a.column - format.range.start.column);
          const result = this.calculator.evaluate(shifted, sheetIndex, a);
          let truthy = false;
          if (!(result instanceof FormulaError)) {
            try { truthy = asBool(result); } catch { truthy = false; }
          }
          if (truthy) { apply(format.format, look); matched = true; }
          break;
        }
        default:
          if (ruleMatches(rule, value, stats)) {
            apply(format.format, look);
            matched = true;
          }
      }
    }
    return matched ? look : null;
  }

  private stats(format: ConditionalFormat, sheet: Sheet, sheetIndex: number): ConditionalStats {
    const cached = this.statsCache.get(format.id);
    if (cached) return cached;
    let r = format.range;
    if (isWholeColumns(r) || isWholeRows(r)) {
      const extent = contentExtent(sheet);
      r = rangeRC(r.start.row, r.start.column, Math.max(r.start.row, Math.min(r.end.row, extent.row)), Math.max(r.start.column, Math.min(r.end.column, extent.column)));
    }
    const values: CellValue[] = [];
    if (cellCount(r) <= 1_000_000) forEachCell(r, (row, column) => values.push(this.calculator.value(sheetIndex, row, column)));
    const stats = new ConditionalStats(values);
    this.statsCache.set(format.id, stats);
    return stats;
  }
}

function apply(format: HighlightFormat, look: ConditionalLook) {
  if (format.fill) look.fill = format.fill;
  if (format.text) look.text = format.text;
  if (format.bold) look.bold = true;
  if (format.italic) look.italic = true;
  if (format.border) look.border = format.border;
}
