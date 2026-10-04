/** Spreadsheet error values, displayed exactly as Excel shows them. */
export type ErrorCode = "#NULL!" | "#DIV/0!" | "#VALUE!" | "#REF!" | "#NAME?" | "#NUM!" | "#N/A" | "#SPILL!" | "#CALC!" | "#CIRCULAR!";

const TYPE_NUMBERS: Record<ErrorCode, number> = {
  "#NULL!": 1, "#DIV/0!": 2, "#VALUE!": 3, "#REF!": 4, "#NAME?": 5, "#NUM!": 6, "#N/A": 7, "#SPILL!": 9, "#CALC!": 14, "#CIRCULAR!": 8,
};

const EXPLANATIONS: Record<ErrorCode, string> = {
  "#NULL!": "The ranges don't intersect.",
  "#DIV/0!": "The formula divides by zero or an empty cell.",
  "#VALUE!": "An argument has the wrong type of value.",
  "#REF!": "The formula refers to a cell that isn't valid.",
  "#NAME?": "The formula uses a name or function that isn't recognized.",
  "#NUM!": "The formula produces a number that is too large, too small or invalid.",
  "#N/A": "A value isn't available to the formula.",
  "#SPILL!": "The result can't spill because cells in its way aren't empty.",
  "#CALC!": "The calculation produced an empty result.",
  "#CIRCULAR!": "The formula refers to its own cell, directly or indirectly.",
};

/**
 * An error value. There is one instance per code, so errors compare with `===`.
 * Formula code also throws them to propagate an error out of a calculation.
 */
export class FormulaError {
  private constructor(readonly code: ErrorCode) {}

  get typeNumber() { return TYPE_NUMBERS[this.code]; }
  get explanation() { return EXPLANATIONS[this.code]; }
  toString() { return this.code; }

  static readonly null = new FormulaError("#NULL!");
  static readonly div0 = new FormulaError("#DIV/0!");
  static readonly value = new FormulaError("#VALUE!");
  static readonly ref = new FormulaError("#REF!");
  static readonly name = new FormulaError("#NAME?");
  static readonly num = new FormulaError("#NUM!");
  static readonly na = new FormulaError("#N/A");
  static readonly spill = new FormulaError("#SPILL!");
  static readonly calc = new FormulaError("#CALC!");
  static readonly circular = new FormulaError("#CIRCULAR!");

  static readonly all: FormulaError[] = [
    FormulaError.null, FormulaError.div0, FormulaError.value, FormulaError.ref, FormulaError.name,
    FormulaError.num, FormulaError.na, FormulaError.spill, FormulaError.calc, FormulaError.circular,
  ];

  static fromCode(code: string): FormulaError | null {
    const upper = code.toUpperCase();
    return FormulaError.all.find((e) => e.code === upper) ?? null;
  }
}

export const ERR = FormulaError;

/** A computed or literal cell value. `null` is an empty cell. */
export type CellValue = null | number | string | boolean | FormulaError;

export const isError = (v: CellValue): v is FormulaError => v instanceof FormulaError;
export const isEmpty = (v: CellValue): v is null => v === null;
export const isNumber = (v: CellValue): v is number => typeof v === "number";
export const isText = (v: CellValue): v is string => typeof v === "string";
export const isBool = (v: CellValue): v is boolean => typeof v === "boolean";

/** Rank used by comparisons and sorting: numbers < text < logical < errors < blanks. */
export function sortRank(v: CellValue): number {
  if (typeof v === "number") return 0;
  if (typeof v === "string") return 1;
  if (typeof v === "boolean") return 2;
  if (v instanceof FormulaError) return 3;
  return 4;
}

const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" });

/** Natural, case-insensitive text order (like Finder): "Item 2" before "Item 10". */
export const compareText = (a: string, b: string) => collator.compare(a, b);

/** Excel's ordering for sorting: numbers < text < logical < errors < blanks. */
export function sortOrder(a: CellValue, b: CellValue): number {
  const ra = sortRank(a), rb = sortRank(b);
  if (ra !== rb) return ra - rb;
  if (typeof a === "number" && typeof b === "number") return a < b ? -1 : a > b ? 1 : 0;
  if (typeof a === "string" && typeof b === "string") return compareText(a, b);
  if (typeof a === "boolean" && typeof b === "boolean") return a === b ? 0 : a ? 1 : -1;
  return 0;
}

export function valuesEqual(a: CellValue, b: CellValue): boolean {
  return a === b;
}
