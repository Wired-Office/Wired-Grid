import type { CellRange } from "../model/address";
import { FormulaError, type CellValue } from "../model/values";
import { general, plainText } from "./numberFormat";
import { numberFromText } from "./valueParser";

/** A 2-D block of values, row-major. */
export class Matrix {
  constructor(public rows: number, public columns: number, public values: CellValue[]) {}

  static filled(rows: number, columns: number, fill: CellValue = null) {
    return new Matrix(rows, columns, new Array(rows * columns).fill(fill));
  }

  static column(values: CellValue[]) { return new Matrix(values.length, 1, values); }
  static row(values: CellValue[]) { return new Matrix(1, values.length, values); }

  /** Ragged rows are padded with empty values. */
  static fromRows(grid: CellValue[][]) {
    const width = grid.reduce((w, r) => Math.max(w, r.length), 0);
    const values: CellValue[] = [];
    for (const line of grid) {
      values.push(...line);
      for (let i = line.length; i < width; i++) values.push(null);
    }
    return new Matrix(grid.length, width, values);
  }

  get(r: number, c: number): CellValue { return this.values[r * this.columns + c]; }
  set(r: number, c: number, v: CellValue) { this.values[r * this.columns + c] = v; }
  row(r: number): CellValue[] { return this.values.slice(r * this.columns, (r + 1) * this.columns); }
  column(c: number): CellValue[] {
    const out: CellValue[] = [];
    for (let r = 0; r < this.rows; r++) out.push(this.get(r, c));
    return out;
  }
  get rowArrays(): CellValue[][] {
    const out: CellValue[][] = [];
    for (let r = 0; r < this.rows; r++) out.push(this.row(r));
    return out;
  }
  get transposed(): Matrix {
    const result = Matrix.filled(this.columns, this.rows);
    for (let r = 0; r < this.rows; r++) for (let c = 0; c < this.columns; c++) result.set(c, r, this.get(r, c));
    return result;
  }
  get isVector() { return this.rows === 1 || this.columns === 1; }
  get count() { return this.values.length; }
  copy() { return new Matrix(this.rows, this.columns, [...this.values]); }
}

/** What evaluating an expression produces: a single value, an array, or a reference. */
export type FValue =
  | { k: "scalar"; v: CellValue }
  | { k: "matrix"; m: Matrix }
  | { k: "ref"; sheet: number; range: CellRange };

export const scalar = (v: CellValue): FValue => ({ k: "scalar", v });
export const matrixValue = (m: Matrix): FValue => ({ k: "matrix", m });
export const EMPTY: FValue = { k: "scalar", v: null };
/** A number, with infinities and NaN turned into #NUM!. */
export const numberResult = (v: number): FValue => ({ k: "scalar", v: Number.isFinite(v) ? v : FormulaError.num });

// MARK: - Coercion

/** Numeric value with Excel's coercions; throws the error to propagate. */
export function asNumber(v: CellValue): number {
  if (typeof v === "number") return v;
  if (typeof v === "boolean") return v ? 1 : 0;
  if (v === null) return 0;
  if (typeof v === "string") {
    const parsed = numberFromText(v);
    if (parsed !== null) return parsed;
    throw FormulaError.value;
  }
  throw v;
}

export function asText(v: CellValue): string {
  if (typeof v === "number") return general(v, 20);
  if (typeof v === "boolean") return v ? "TRUE" : "FALSE";
  if (v === null) return "";
  if (typeof v === "string") return v;
  throw v;
}

export function asBool(v: CellValue): boolean {
  if (typeof v === "boolean") return v;
  if (typeof v === "number") return v !== 0;
  if (v === null) return false;
  if (typeof v === "string") {
    const upper = v.toUpperCase();
    if (upper === "TRUE") return true;
    if (upper === "FALSE") return false;
    throw FormulaError.value;
  }
  throw v;
}

/** Excel comparison: numbers < text < booleans; text ignores case. Returns -1, 0 or 1. */
export function compareValues(a: CellValue, b: CellValue): number {
  const normalized = (v: CellValue, other: CellValue): CellValue => {
    if (v !== null) return v;
    if (typeof other === "string") return "";
    if (typeof other === "boolean") return false;
    return 0;
  };
  const x = normalized(a, b), y = normalized(b, a);
  const rank = (v: CellValue) => (typeof v === "number" || v === null ? 0 : typeof v === "string" ? 1 : typeof v === "boolean" ? 2 : 3);
  const rx = rank(x), ry = rank(y);
  if (rx !== ry) return rx < ry ? -1 : 1;
  if (typeof x === "number" && typeof y === "number") return x < y ? -1 : x > y ? 1 : 0;
  if (typeof x === "string" && typeof y === "string") {
    const p = x.toLowerCase(), q = y.toLowerCase();
    return p < q ? -1 : p > q ? 1 : 0;
  }
  if (typeof x === "boolean" && typeof y === "boolean") return x === y ? 0 : !x ? -1 : 1;
  return 0;
}

// MARK: - Criteria (COUNTIF, SUMIF, …)

export function wildcardRegex(text: string): RegExp {
  let regex = "^";
  let escape = false;
  for (const ch of text) {
    if (escape) { regex += escapeRegex(ch); escape = false; continue; }
    if (ch === "~") escape = true;
    else if (ch === "*") regex += ".*";
    else if (ch === "?") regex += ".";
    else regex += escapeRegex(ch);
  }
  return new RegExp(regex + "$", "is");
}

export const escapeRegex = (s: string) => s.replace(/[.*+?^${}()|[\]\\/]/g, "\\$&");

type CriterionOp = "eq" | "ne" | "lt" | "le" | "gt" | "ge";

/** A parsed criterion such as `">=10"`, `"<>apple"` or `"a*"`. */
export class Criterion {
  private op: CriterionOp = "eq";
  private number: number | null = null;
  private text = "";
  private pattern: RegExp | null = null;

  constructor(value: CellValue) {
    if (typeof value === "number") { this.number = value; this.text = general(value); return; }
    if (typeof value === "boolean") { this.text = value ? "TRUE" : "FALSE"; return; }
    if (value === null) return;
    if (value instanceof FormulaError) { this.text = value.code; return; }
    let rest = value;
    for (const [prefix, op] of [["<=", "le"], [">=", "ge"], ["<>", "ne"], ["<", "lt"], [">", "gt"], ["=", "eq"]] as const) {
      if (rest.startsWith(prefix)) {
        this.op = op;
        rest = rest.slice(prefix.length);
        break;
      }
    }
    this.text = rest;
    this.number = numberFromText(rest);
    if (this.number === null && /[*?]/.test(rest) && (this.op === "eq" || this.op === "ne")) this.pattern = wildcardRegex(rest);
  }

  matches(value: CellValue): boolean {
    const op = this.op;
    if (this.pattern) {
      const hit = this.pattern.test(plainText(value));
      return op === "eq" ? hit : !hit;
    }
    if (this.text === "") {
      const blank = value === null || value === "";
      if (op === "eq") return blank;
      if (op === "ne") return !blank;
      return false;
    }
    if (this.number !== null) {
      let n: number | null = null;
      if (typeof value === "number") n = value;
      else if (typeof value === "string" && (op === "eq" || op === "ne")) n = numberFromText(value);
      if (n === null) return op === "ne";
      return compareOp(op, n < this.number ? -1 : n > this.number ? 1 : 0);
    }
    if (typeof value === "number") return op === "ne";
    const c = compareValues(value === null ? "" : plainText(value), this.text);
    return compareOp(op, c);
  }
}

function compareOp(op: CriterionOp, c: number): boolean {
  switch (op) {
    case "eq": return c === 0;
    case "ne": return c !== 0;
    case "lt": return c < 0;
    case "le": return c <= 0;
    case "gt": return c > 0;
    case "ge": return c >= 0;
  }
}
