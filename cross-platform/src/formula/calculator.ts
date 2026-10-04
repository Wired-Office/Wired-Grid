import {
  MAX_COLUMNS, cellKey, columnCount, isSingleCell, isValidAddress, isWholeColumns, isWholeRows, keyAddress, range, rangeContains,
  rangeRC, rangesIntersect, rowCount, sameRange, union, type CellAddress, type CellRange,
} from "../model/address";
import { FormulaError, type CellValue } from "../model/values";
import { contentExtent, definedName, hasContent, sheetIndexNamed, type Workbook } from "../model/workbook";
import { asNumber, asText, compareValues, EMPTY, Matrix, matrixValue, scalar, type FValue } from "./fvalue";
import { referenceRange } from "./lexer";
import { parseFormula, type Expr } from "./parser";

/** Thrown when evaluation nests too deeply; the calculator evaluates the deferred cell first and retries. */
const DEFER = { deferred: true };
const MAX_DEPTH = 120;

/** A number key for a cell on a sheet. */
const SHEET_STRIDE = 2 ** 35;
export const calcKey = (sheet: number, row: number, column: number) => sheet * SHEET_STRIDE + cellKey(row, column);
const keySheet = (key: number) => Math.floor(key / SHEET_STRIDE);
const keyCell = (key: number) => keyAddress(key % SHEET_STRIDE);

/** Runs `body`; a FormulaError it throws goes to `onError`. Everything else keeps propagating. */
export function catchFormula<T>(body: () => T, onError: (e: FormulaError) => T): T {
  try {
    return body();
  } catch (e) {
    if (e instanceof FormulaError) return onError(e);
    throw e;
  }
}

/**
 * Evaluates every formula in a workbook and caches the results.
 *
 * A full recalculation runs after each change. Formula cells are visited in
 * row-major order so the common top-down chains resolve without deep
 * recursion; long bottom-up chains are evaluated in segments (see `DEFER`).
 * Dynamic-array results "spill" into the cells beside them.
 */
export class Calculator {
  private cache = new Map<number, CellValue>();
  private inProgress = new Set<number>();
  private parsed = new Map<number, { text: string; result: Expr | FormulaError }>();
  spillValues = new Map<number, CellValue>();
  spillRanges = new Map<number, CellRange>();
  private previousSpillRanges = new Map<number, CellRange>();
  private depth = 0;
  private deferredKey: number | null = null;
  generation = 0;
  /** NOW() and TODAY() are fixed for the length of one recalculation. */
  now = new Date();

  constructor(public workbook: Workbook) {}

  setWorkbook(workbook: Workbook) {
    this.workbook = workbook;
  }

  // MARK: Recalculation

  recalculate() {
    this.now = new Date();
    for (let pass = 0; pass < 2; pass++) {
      this.previousSpillRanges = this.spillRanges;
      this.cache = new Map();
      this.spillValues = new Map();
      this.spillRanges = new Map();
      this.workbook.sheets.forEach((sheet, index) => {
        const formulas: number[] = [];
        for (const [key, cell] of sheet.cells) if (cell.formula !== undefined) formulas.push(key);
        formulas.sort((a, b) => a - b);
        for (const key of formulas) this.resolve(index * SHEET_STRIDE + key);
      });
      // New or moved spills can change cells computed before them; one more pass settles it.
      if (sameSpills(this.spillRanges, this.previousSpillRanges)) break;
    }
    this.generation++;
  }

  /** Computes a cell, evaluating long dependency chains in segments instead of one deep recursion. */
  private resolve(key: number) {
    const pending = [key];
    while (pending.length) {
      const next = pending[pending.length - 1];
      this.deferredKey = null;
      try {
        const { row, column } = keyCell(next);
        this.value(keySheet(next), row, column);
        pending.pop();
      } catch (e) {
        if (e !== DEFER || this.deferredKey === null || pending.length > 200_000) throw e;
        pending.push(this.deferredKey);
      }
    }
  }

  // MARK: Values

  value(sheet: number, row: number, column: number): CellValue {
    const s = this.workbook.sheets[sheet];
    if (!s) return FormulaError.ref;
    const key = calcKey(sheet, row, column);
    const cell = s.cells.get(cellKey(row, column));
    if (cell?.formula !== undefined) {
      const cached = this.cache.get(key);
      if (cached !== undefined) return cached;
      if (this.inProgress.has(key)) return FormulaError.circular;
      if (this.depth >= MAX_DEPTH) {
        this.deferredKey = key;
        throw DEFER;
      }
      this.inProgress.add(key);
      this.depth++;
      let result: CellValue;
      try {
        result = this.evaluateFormulaCell(key, sheet, { row, column }, cell.formula);
      } finally {
        this.depth--;
        this.inProgress.delete(key);
      }
      this.cache.set(key, result);
      return result;
    }
    if (cell && hasContent(cell)) return cell.value;
    const spilled = this.spillValues.get(key);
    if (spilled !== undefined) return spilled;
    if (this.previousSpillRanges.size) {
      // This cell may belong to a spill whose anchor hasn't been computed yet.
      for (const [anchor, r] of this.previousSpillRanges) {
        if (keySheet(anchor) !== sheet || anchor === key || !rangeContains(r, { row, column })) continue;
        const a = keyCell(anchor);
        this.value(sheet, a.row, a.column);
        const v = this.spillValues.get(key);
        if (v !== undefined) return v;
      }
    }
    return null;
  }

  /** The parsed formula of a cell, if it has one and it parses. */
  expression(sheet: number, a: CellAddress): Expr | null {
    const formula = this.workbook.sheets[sheet]?.cells.get(cellKey(a.row, a.column))?.formula;
    if (formula === undefined) return null;
    const result = this.parse(calcKey(sheet, a.row, a.column), formula);
    return result instanceof FormulaError ? null : result;
  }

  /** The spill range anchored at a cell, if its result spilled. */
  spillRange(sheet: number, anchor: CellAddress): CellRange | undefined {
    return this.spillRanges.get(calcKey(sheet, anchor.row, anchor.column));
  }

  /** The anchor of the spill covering a cell, if any. */
  spillAnchor(sheet: number, a: CellAddress): CellAddress | null {
    for (const [anchor, r] of this.spillRanges) if (keySheet(anchor) === sheet && rangeContains(r, a)) return keyCell(anchor);
    return null;
  }

  /** Evaluates a formula as if it were in the given cell, without storing it. */
  evaluate(formula: string, sheet: number, at: CellAddress): CellValue {
    let expression: Expr;
    try {
      expression = parseFormula(formula);
    } catch (e) {
      return e instanceof FormulaError ? e : FormulaError.name;
    }
    for (let attempt = 0; attempt < 100_000; attempt++) {
      this.deferredKey = null;
      try {
        const evaluator = new Evaluator(this, sheet, at);
        const v = evaluator.scalar(evaluator.evaluate(expression));
        return v === null ? 0 : v;
      } catch (e) {
        if (e instanceof FormulaError) return e;
        if (e !== DEFER || this.deferredKey === null) return e instanceof RangeError ? FormulaError.calc : FormulaError.value;
        this.resolve(this.deferredKey);
      }
    }
    return FormulaError.calc;
  }

  // MARK: Formula cells

  private parse(key: number, formula: string): Expr | FormulaError {
    const existing = this.parsed.get(key);
    if (existing && existing.text === formula) return existing.result;
    let result: Expr | FormulaError;
    try {
      result = parseFormula(formula);
    } catch (e) {
      result = e instanceof FormulaError ? e : FormulaError.name;
    }
    this.parsed.set(key, { text: formula, result });
    return result;
  }

  private evaluateFormulaCell(key: number, sheet: number, origin: CellAddress, formula: string): CellValue {
    const expression = this.parse(key, formula);
    if (expression instanceof FormulaError) return expression;
    const evaluator = new Evaluator(this, sheet, origin);
    let result: FValue;
    try {
      result = evaluator.evaluate(expression);
    } catch (e) {
      if (e instanceof FormulaError) return e;
      if (e instanceof RangeError) return FormulaError.calc;
      throw e;
    }
    switch (result.k) {
      case "scalar":
        return result.v === null ? 0 : result.v;
      case "ref": {
        if (isSingleCell(result.range)) {
          const v = this.value(result.sheet, result.range.start.row, result.range.start.column);
          return v === null ? 0 : v;
        }
        return this.spill(evaluator.matrix(result), key, sheet, origin);
      }
      case "matrix": {
        const m = result.m;
        if (m.rows === 1 && m.columns === 1) return m.values[0] === null ? 0 : m.values[0];
        if (m.count === 0) return FormulaError.calc;
        return this.spill(m, key, sheet, origin);
      }
    }
  }

  private spill(matrix: Matrix, key: number, sheet: number, anchor: CellAddress): CellValue {
    const end = { row: anchor.row + matrix.rows - 1, column: anchor.column + matrix.columns - 1 };
    if (!isValidAddress(end)) return FormulaError.spill;
    const target = range(anchor, end);
    const s = this.workbook.sheets[sheet];
    for (let r = target.start.row; r <= target.end.row; r++) {
      for (let c = target.start.column; c <= target.end.column; c++) {
        if ((r !== anchor.row || c !== anchor.column) && hasContent(s.cells.get(cellKey(r, c)))) return FormulaError.spill;
      }
    }
    for (const [other, r] of this.spillRanges) {
      if (keySheet(other) === sheet && other !== key && rangesIntersect(r, target)) return FormulaError.spill;
    }
    this.spillRanges.set(key, target);
    for (let r = 0; r < matrix.rows; r++) {
      for (let c = 0; c < matrix.columns; c++) {
        if (r === 0 && c === 0) continue;
        const v = matrix.get(r, c);
        this.spillValues.set(calcKey(sheet, anchor.row + r, anchor.column + c), v === null ? 0 : v);
      }
    }
    return matrix.values[0] === null ? 0 : matrix.values[0];
  }
}

function sameSpills(a: Map<number, CellRange>, b: Map<number, CellRange>): boolean {
  if (a.size !== b.size) return false;
  for (const [key, r] of a) {
    const other = b.get(key);
    if (!other || !sameRange(r, other)) return false;
  }
  return true;
}

// MARK: - Evaluator

/** Evaluates one expression in the context of a cell. */
export class Evaluator {
  private scopes: Map<string, FValue>[] = [];

  constructor(readonly calculator: Calculator, readonly sheet: number, readonly origin: CellAddress) {}

  get workbook() { return this.calculator.workbook; }

  sheetIndex(name: string | undefined): number {
    if (name === undefined) return this.sheet;
    const index = sheetIndexNamed(this.workbook, name);
    if (index < 0) throw FormulaError.ref;
    return index;
  }

  evaluate(x: Expr): FValue {
    switch (x.e) {
      case "number": return scalar(x.value);
      case "string": return scalar(x.value);
      case "bool": return scalar(x.value);
      case "error": return scalar(x.value);
      case "missing": return EMPTY;
      case "cell": return { k: "ref", sheet: this.sheetIndex(x.ref.sheet), range: range({ row: x.ref.row, column: x.ref.column }) };
      case "range": return { k: "ref", sheet: this.sheetIndex(x.ref.sheet), range: referenceRange(x.ref) };
      case "name": return this.resolveName(x.name);
      case "unary": {
        const negate = x.op === "-";
        return this.map(this.evaluate(x.operand), (v) => {
          if (v instanceof FormulaError) return v;
          const n = asNumber(v);
          return negate ? -n : n;
        });
      }
      case "percent":
        return this.map(this.evaluate(x.operand), (v) => (v instanceof FormulaError ? v : asNumber(v) / 100));
      case "binary": {
        if (x.op === ":") {
          const a = this.evaluate(x.left), b = this.evaluate(x.right);
          if (a.k !== "ref" || b.k !== "ref" || a.sheet !== b.sheet) throw FormulaError.value;
          return { k: "ref", sheet: a.sheet, range: union(a.range, b.range) };
        }
        return this.binary(x.op, this.evaluate(x.left), this.evaluate(x.right));
      }
      case "call": return this.call(x.name, x.args);
      case "array": return matrixValue(Matrix.fromRows(x.rows.map((row) => row.map((item) => this.scalar(this.evaluate(item))))));
    }
  }

  // MARK: Names and LET

  withScope<T>(body: () => T): T {
    this.scopes.push(new Map());
    try {
      return body();
    } finally {
      this.scopes.pop();
    }
  }

  bind(name: string, value: FValue) {
    if (!this.scopes.length) this.scopes.push(new Map());
    this.scopes[this.scopes.length - 1].set(name.toUpperCase(), value);
  }

  private resolveName(name: string): FValue {
    const key = name.toUpperCase();
    for (let i = this.scopes.length - 1; i >= 0; i--) {
      const v = this.scopes[i].get(key);
      if (v) return v;
    }
    const defined = definedName(this.workbook, name);
    if (defined) return this.evaluate(parseFormula(defined.formula));
    throw FormulaError.name;
  }

  // MARK: Functions

  private call(rawName: string, args: Expr[]): FValue {
    let name = rawName;
    for (const prefix of ["_XLFN._XLWS.", "_XLFN.", "_XLWS."]) {
      if (name.startsWith(prefix)) {
        name = name.slice(prefix.length);
        break;
      }
    }
    const spec = FUNCTIONS.get(name);
    if (!spec) throw FormulaError.name;
    if (args.length < spec.minArgs || args.length > spec.maxArgs) throw FormulaError.value;
    return spec.implementation(new FunctionCall(this, args));
  }

  // MARK: Materializing

  /** A reference's cells as values (whole rows/columns are trimmed to the used area). */
  matrixOf(sheet: number, r: CellRange): Matrix {
    const t = this.trimmed(r, sheet);
    const rows = rowCount(t), columns = columnCount(t);
    const values: CellValue[] = new Array(rows * columns);
    let i = 0;
    for (let row = t.start.row; row <= t.end.row; row++) {
      for (let column = t.start.column; column <= t.end.column; column++) values[i++] = this.calculator.value(sheet, row, column);
    }
    return new Matrix(rows, columns, values);
  }

  trimmed(r: CellRange, sheet: number): CellRange {
    if (!(isWholeColumns(r) || isWholeRows(r)) || !this.workbook.sheets[sheet]) return r;
    const extent = { ...contentExtent(this.workbook.sheets[sheet]) };
    for (const [anchor, spill] of this.calculator.spillRanges) {
      if (keySheet(anchor) !== sheet) continue;
      extent.row = Math.max(extent.row, spill.end.row);
      extent.column = Math.max(extent.column, spill.end.column);
    }
    const maxRow = isWholeColumns(r) ? Math.min(r.end.row, Math.max(extent.row, r.start.row)) : r.end.row;
    const maxColumn = isWholeRows(r) ? Math.min(r.end.column, Math.max(extent.column, r.start.column)) : r.end.column;
    return rangeRC(r.start.row, r.start.column, maxRow, Math.min(maxColumn, MAX_COLUMNS - 1));
  }

  matrix(value: FValue): Matrix {
    switch (value.k) {
      case "scalar": return new Matrix(1, 1, [value.v]);
      case "matrix": return value.m;
      case "ref": return this.matrixOf(value.sheet, value.range);
    }
  }

  /** A single value; multi-cell references use implicit intersection with the formula's row or column. */
  scalar(value: FValue): CellValue {
    switch (value.k) {
      case "scalar": return value.v;
      case "matrix": return value.m.values[0] ?? null;
      case "ref": {
        const r = value.range, s = value.sheet, o = this.origin;
        if (isSingleCell(r)) return this.calculator.value(s, r.start.row, r.start.column);
        if (columnCount(r) === 1 && o.row >= r.start.row && o.row <= r.end.row) return this.calculator.value(s, o.row, r.start.column);
        if (rowCount(r) === 1 && o.column >= r.start.column && o.column <= r.end.column) return this.calculator.value(s, r.start.row, o.column);
        return this.calculator.value(s, r.start.row, r.start.column);
      }
    }
  }

  isSingle(value: FValue): boolean {
    switch (value.k) {
      case "scalar": return true;
      case "matrix": return value.m.count === 1;
      case "ref": return isSingleCell(value.range);
    }
  }

  /** Applies `transform` to every element (or the single value); thrown errors become error values. */
  map(value: FValue, transform: (v: CellValue) => CellValue): FValue {
    const guarded = (v: CellValue) => catchFormula(() => transform(v), (e) => e);
    if (this.isSingle(value)) return scalar(guarded(this.scalar(value)));
    const m = this.matrix(value).copy();
    for (let i = 0; i < m.values.length; i++) m.values[i] = guarded(m.values[i]);
    return matrixValue(m);
  }

  // MARK: Operators

  binary(op: string, left: FValue, right: FValue): FValue {
    if (this.isSingle(left) && this.isSingle(right)) return scalar(applyOperator(op, this.scalar(left), this.scalar(right)));
    const a = this.matrix(left), b = this.matrix(right);
    const rows = Math.max(a.rows, b.rows), columns = Math.max(a.columns, b.columns);
    const element = (m: Matrix, r: number, c: number): CellValue => {
      const rr = m.rows === 1 ? 0 : r, cc = m.columns === 1 ? 0 : c;
      return rr < m.rows && cc < m.columns ? m.get(rr, cc) : FormulaError.na;
    };
    const result = Matrix.filled(rows, columns);
    for (let r = 0; r < rows; r++) for (let c = 0; c < columns; c++) result.set(r, c, applyOperator(op, element(a, r, c), element(b, r, c)));
    return matrixValue(result);
  }
}

export function applyOperator(op: string, a: CellValue, b: CellValue): CellValue {
  if (a instanceof FormulaError) return a;
  if (b instanceof FormulaError) return b;
  switch (op) {
    case "&":
      return asText(a) + asText(b);
    case "=": return compareValues(a, b) === 0;
    case "<>": return compareValues(a, b) !== 0;
    case "<": return compareValues(a, b) < 0;
    case ">": return compareValues(a, b) > 0;
    case "<=": return compareValues(a, b) <= 0;
    case ">=": return compareValues(a, b) >= 0;
  }
  let x: number, y: number;
  try {
    x = asNumber(a);
    y = asNumber(b);
  } catch {
    return FormulaError.value;
  }
  let result: number;
  switch (op) {
    case "+": result = x + y; break;
    case "-": result = x - y; break;
    case "*": result = x * y; break;
    case "/":
      if (y === 0) return FormulaError.div0;
      result = x / y;
      break;
    case "^":
      if (x === 0 && y < 0) return FormulaError.div0;
      result = Math.pow(x, y);
      break;
    default: return FormulaError.value;
  }
  return Number.isFinite(result) ? result : FormulaError.num;
}

// MARK: - Functions

export type FunctionCategory = "Math & Trig" | "Statistical" | "Logical" | "Text" | "Date & Time" | "Lookup & Reference" | "Financial" | "Information";
export const FUNCTION_CATEGORIES: FunctionCategory[] = ["Math & Trig", "Statistical", "Logical", "Text", "Date & Time", "Lookup & Reference", "Financial", "Information"];

/** A built-in worksheet function: its implementation plus the help shown in the UI. */
export interface FunctionSpec {
  name: string;
  category: FunctionCategory;
  /** e.g. "SUM(number1, [number2], …)" */
  syntax: string;
  summary: string;
  minArgs: number;
  maxArgs: number;
  implementation: (call: FunctionCall) => FValue;
}

export const VARIADIC = 255;
export const FUNCTIONS = new Map<string, FunctionSpec>();

export function register(name: string, category: FunctionCategory, syntax: string, summary: string, args: [number, number], implementation: (c: FunctionCall) => FValue) {
  FUNCTIONS.set(name, { name, category, syntax, summary, minArgs: args[0], maxArgs: args[1], implementation });
}

/** Argument names parsed from the syntax, for the signature hint. */
export function functionParameters(spec: FunctionSpec): string[] {
  const open = spec.syntax.indexOf("("), close = spec.syntax.lastIndexOf(")");
  if (open < 0 || close <= open) return [];
  return spec.syntax.slice(open + 1, close).split(",").map((s) => s.trim()).filter(Boolean);
}

export const POPULAR_FUNCTIONS = ["SUM", "AVERAGE", "IF", "COUNT", "MAX", "MIN", "VLOOKUP", "XLOOKUP", "COUNTIF", "SUMIF",
  "ROUND", "CONCAT", "TODAY", "NOW", "INDEX", "MATCH", "IFERROR", "AND", "OR", "LEFT", "RIGHT",
  "LEN", "TEXT", "DATE", "PMT", "FILTER", "SORT", "UNIQUE"];

export function functionCompletions(prefix: string): FunctionSpec[] {
  const upper = prefix.toUpperCase();
  if (!upper) return [];
  const rank = (name: string) => {
    const i = POPULAR_FUNCTIONS.indexOf(name);
    return i < 0 ? Infinity : i;
  };
  return [...FUNCTIONS.values()].filter((f) => f.name.startsWith(upper)).sort((a, b) => rank(a.name) - rank(b.name) || (a.name < b.name ? -1 : 1));
}

/** The arguments of one function call, with Excel-style coercion helpers. */
export class FunctionCall {
  private evaluated = new Map<number, FValue>();

  constructor(readonly evaluator: Evaluator, readonly args: Expr[]) {}

  get count() { return this.args.length; }

  isMissing(index: number): boolean {
    return index >= this.args.length || this.args[index].e === "missing";
  }

  /** Evaluates an argument once (lazily, so IF only evaluates the branch it takes). */
  value(index: number): FValue {
    if (index >= this.args.length) return EMPTY;
    let result = this.evaluated.get(index);
    if (!result) {
      result = this.evaluator.evaluate(this.args[index]);
      this.evaluated.set(index, result);
    }
    return result;
  }

  /** A single value; errors are returned, not thrown. */
  scalar(index: number): CellValue {
    return this.evaluator.scalar(this.value(index));
  }

  /** A single value, throwing if it's an error. */
  strictScalar(index: number): CellValue {
    const v = this.scalar(index);
    if (v instanceof FormulaError) throw v;
    return v;
  }

  number(index: number, fallback?: number): number {
    if (fallback !== undefined && this.isMissing(index)) return fallback;
    return asNumber(this.scalar(index));
  }

  int(index: number, fallback?: number): number {
    if (fallback !== undefined && this.isMissing(index)) return fallback;
    const n = this.number(index);
    if (!Number.isFinite(n) || Math.abs(n) >= 1e15) throw FormulaError.num;
    return Math.trunc(n);
  }

  text(index: number, fallback?: string): string {
    if (fallback !== undefined && this.isMissing(index)) return fallback;
    return asText(this.scalar(index));
  }

  bool(index: number, fallback?: boolean): boolean {
    if (fallback !== undefined && this.isMissing(index)) return fallback;
    const v = this.scalar(index);
    if (typeof v === "boolean") return v;
    if (typeof v === "number") return v !== 0;
    if (v === null) return false;
    if (v instanceof FormulaError) throw v;
    const upper = v.toUpperCase();
    if (upper === "TRUE") return true;
    if (upper === "FALSE") return false;
    throw FormulaError.value;
  }

  matrix(index: number): Matrix {
    return this.evaluator.matrix(this.value(index));
  }

  reference(index: number): { sheet: number; range: CellRange } {
    const v = this.value(index);
    if (v.k !== "ref") throw FormulaError.value;
    return { sheet: v.sheet, range: v.range };
  }

  isReference(index: number): boolean {
    return this.value(index).k === "ref";
  }

  /** Every value in the argument as a flat list, row by row. */
  flat(index: number): CellValue[] {
    return this.matrix(index).values;
  }

  /**
   * Numbers the way SUM and AVERAGE collect them: references and arrays
   * contribute only numbers (errors propagate); values typed directly as
   * arguments are coerced.
   */
  numbers(from = 0, to = this.count, includeTextAndLogicals = false): number[] {
    const result: number[] = [];
    for (let index = from; index < to; index++) {
      if (this.isMissing(index)) continue;
      const v = this.value(index);
      if (v.k === "scalar") {
        const s = v.v;
        if (s instanceof FormulaError) throw s;
        if (s === null) { if (includeTextAndLogicals) result.push(0); continue; }
        result.push(asNumber(s));
        continue;
      }
      for (const element of this.evaluator.matrix(v).values) {
        if (typeof element === "number") result.push(element);
        else if (element instanceof FormulaError) throw element;
        else if (typeof element === "boolean") { if (includeTextAndLogicals) result.push(element ? 1 : 0); }
        else if (typeof element === "string") { if (includeTextAndLogicals) result.push(0); }
      }
    }
    return result;
  }

  /** A lifted one-argument function: applied to each element of an array argument. */
  lift(index: number, transform: (v: CellValue) => CellValue): FValue {
    return this.evaluator.map(this.value(index), transform);
  }

  /** Lifts a numeric function over an argument. */
  liftNumber(index: number, transform: (n: number) => number): FValue {
    return this.lift(index, (v) => {
      if (v instanceof FormulaError) return v;
      const result = transform(asNumber(v));
      return Number.isFinite(result) ? result : FormulaError.num;
    });
  }

  liftText(index: number, transform: (s: string) => CellValue): FValue {
    return this.lift(index, (v) => (v instanceof FormulaError ? v : transform(asText(v))));
  }
}

export { keyCell as calcKeyAddress, keySheet as calcKeySheet };
