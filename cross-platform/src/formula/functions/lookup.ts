import { MAX_COLUMNS, MAX_ROWS, columnCount, columnName, isValidAddress, isWholeColumns, isWholeRows, quotedSheetName, range, rangeRC, rowCount } from "../../model/address";
import { FormulaError, type CellValue } from "../../model/values";
import { definedName } from "../../model/workbook";
import { catchFormula, register, VARIADIC, type FunctionCall } from "../calculator";
import { compareValues, Matrix, matrixValue, scalar, wildcardRegex, type FValue } from "../fvalue";
import { plainText } from "../numberFormat";
import { parseFormula, type Expr } from "../parser";

const V = VARIADIC;
const LR = "Lookup & Reference" as const;

type MatchMode = "exact" | "wildcard" | "exactOrSmaller" | "exactOrLarger";
type SearchMode = "forward" | "backward" | "binaryAscending" | "binaryDescending";

function equalForLookup(a: CellValue, b: CellValue): boolean {
  if (typeof a === "number" && typeof b === "number") return a === b;
  if (typeof a === "string" && typeof b === "string") return a.toLowerCase() === b.toLowerCase();
  if (typeof a === "boolean" && typeof b === "boolean") return a === b;
  if (a === null && b === null) return true;
  if (typeof a === "string" && b === null) return a === "";
  if (a === null && typeof b === "string") return b === "";
  return false;
}

const sameKind = (a: CellValue, b: CellValue) =>
  (typeof a === "number" || typeof a === "string" || typeof a === "boolean") && typeof a === typeof b;

/** Finds `lookup` in `values`, returning the zero-based index or -1. */
function findIndex(lookup: CellValue, values: CellValue[], match: MatchMode, search: SearchMode): number {
  if (search === "binaryAscending" || search === "binaryDescending") {
    // Sorted data: scan in order and stop once past the lookup value, as a binary search would.
    if (match === "exact" || match === "wildcard") return findIndex(lookup, values, match, "forward");
    const descending = search === "binaryDescending";
    let best = -1;
    for (let i = 0; i < values.length; i++) {
      const v = values[i];
      if (!sameKind(v, lookup)) continue;
      const c = compareValues(v, lookup);
      if (!descending && match === "exactOrSmaller") { if (c <= 0) best = i; else return best; }
      else if (!descending) { if (c >= 0) return i; }
      else if (match === "exactOrLarger") { if (c >= 0) best = i; else return best; }
      else if (c <= 0) return i;
    }
    return best;
  }
  const pattern = match === "wildcard" && typeof lookup === "string" ? wildcardRegex(lookup) : null;
  let best = -1;
  const n = values.length;
  for (let k = 0; k < n; k++) {
    const i = search === "forward" ? k : n - 1 - k;
    const v = values[i];
    if (pattern) {
      if (typeof v === "string" && pattern.test(plainText(v))) return i;
      continue;
    }
    if (equalForLookup(v, lookup)) return i;
    if (!sameKind(v, lookup)) continue;
    const c = compareValues(v, lookup);
    if (match === "exactOrSmaller" && c < 0) {
      if (best < 0 || compareValues(v, values[best]) > 0) best = i;
    } else if (match === "exactOrLarger" && c > 0) {
      if (best < 0 || compareValues(v, values[best]) < 0) best = i;
    }
  }
  return best;
}

const wantsWildcard = (lookup: CellValue) => typeof lookup === "string" && /[*?]/.test(lookup);

register("VLOOKUP", LR, "VLOOKUP(lookup_value, table_array, col_index_num, [range_lookup])", "Looks for a value in the first column of a table and returns a value in the same row from another column.", [3, 4], (c) => {
  const lookup = c.strictScalar(0);
  const table = c.matrix(1);
  const column = c.int(2);
  const approximate = c.bool(3, true);
  if (column < 1) throw FormulaError.value;
  if (column > table.columns) throw FormulaError.ref;
  const keys = table.column(0);
  const index = approximate
    ? findIndex(lookup, keys, "exactOrSmaller", "binaryAscending")
    : findIndex(lookup, keys, wantsWildcard(lookup) ? "wildcard" : "exact", "forward");
  if (index < 0) throw FormulaError.na;
  return scalar(table.get(index, column - 1));
});
register("HLOOKUP", LR, "HLOOKUP(lookup_value, table_array, row_index_num, [range_lookup])", "Looks for a value in the top row of a table and returns a value in the same column from another row.", [3, 4], (c) => {
  const lookup = c.strictScalar(0);
  const table = c.matrix(1);
  const row = c.int(2);
  const approximate = c.bool(3, true);
  if (row < 1) throw FormulaError.value;
  if (row > table.rows) throw FormulaError.ref;
  const keys = table.row(0);
  const index = approximate
    ? findIndex(lookup, keys, "exactOrSmaller", "binaryAscending")
    : findIndex(lookup, keys, wantsWildcard(lookup) ? "wildcard" : "exact", "forward");
  if (index < 0) throw FormulaError.na;
  return scalar(table.get(row - 1, index));
});
const MATCH_MODES: Record<number, MatchMode> = { 0: "exact", [-1]: "exactOrSmaller", 1: "exactOrLarger", 2: "wildcard" };
const SEARCH_MODES: Record<number, SearchMode> = { 1: "forward", [-1]: "backward", 2: "binaryAscending", [-2]: "binaryDescending" };
register("XLOOKUP", LR, "XLOOKUP(lookup_value, lookup_array, return_array, [if_not_found], [match_mode], [search_mode])", "Searches a range for a match and returns the corresponding item from another range.", [3, 6], (c) => {
  const lookupArray = c.matrix(1);
  if (!lookupArray.isVector) throw FormulaError.value;
  const returnArray = c.value(2);
  const returnMatrix = c.evaluator.matrix(returnArray);
  const match = MATCH_MODES[c.int(4, 0)];
  const search = SEARCH_MODES[c.int(5, 1)];
  if (!match || !search) throw FormulaError.value;
  const vertical = lookupArray.columns === 1;
  const keys = lookupArray.values;
  const lookupValue = c.value(0);
  const resolve = (lookup: CellValue): FValue => {
    const index = findIndex(lookup, keys, match, search);
    if (index < 0) {
      if (c.count > 3 && !c.isMissing(3)) return c.value(3);
      throw FormulaError.na;
    }
    if (vertical) {
      if (index >= returnMatrix.rows) throw FormulaError.value;
      if (returnArray.k === "ref") {
        const r = returnArray.range;
        return { k: "ref", sheet: returnArray.sheet, range: rangeRC(r.start.row + index, r.start.column, r.start.row + index, r.end.column) };
      }
      return returnMatrix.columns === 1 ? scalar(returnMatrix.get(index, 0)) : matrixValue(Matrix.row(returnMatrix.row(index)));
    }
    if (index >= returnMatrix.columns) throw FormulaError.value;
    if (returnArray.k === "ref") {
      const r = returnArray.range;
      return { k: "ref", sheet: returnArray.sheet, range: rangeRC(r.start.row, r.start.column + index, r.end.row, r.start.column + index) };
    }
    return returnMatrix.rows === 1 ? scalar(returnMatrix.get(0, index)) : matrixValue(Matrix.column(returnMatrix.column(index)));
  };
  if (c.evaluator.isSingle(lookupValue)) {
    const lookup = c.evaluator.scalar(lookupValue);
    if (lookup instanceof FormulaError) throw lookup;
    return resolve(lookup);
  }
  // Several lookup values: one result each.
  const lookups = c.evaluator.matrix(lookupValue).copy();
  for (let i = 0; i < lookups.values.length; i++) {
    const v = lookups.values[i];
    lookups.values[i] = catchFormula(() => c.evaluator.scalar(resolve(v)), (e) => e);
  }
  return matrixValue(lookups);
});
register("MATCH", LR, "MATCH(lookup_value, lookup_array, [match_type])", "Returns the relative position of an item in an array.", [2, 3], (c) => {
  const lookup = c.strictScalar(0);
  const array = c.matrix(1);
  if (!array.isVector) throw FormulaError.na;
  const type = c.int(2, 1);
  const index = type === 0
    ? findIndex(lookup, array.values, wantsWildcard(lookup) ? "wildcard" : "exact", "forward")
    : type >= 1
      ? findIndex(lookup, array.values, "exactOrSmaller", "binaryAscending")
      : findIndex(lookup, array.values, "exactOrLarger", "binaryDescending");
  if (index < 0) throw FormulaError.na;
  return scalar(index + 1);
});
register("XMATCH", LR, "XMATCH(lookup_value, lookup_array, [match_mode], [search_mode])", "Returns the relative position of an item in an array.", [2, 4], (c) => {
  const lookup = c.strictScalar(0);
  const array = c.matrix(1);
  if (!array.isVector) throw FormulaError.value;
  const match = MATCH_MODES[c.int(2, 0)] ?? "exact";
  const search = SEARCH_MODES[c.int(3, 1)] ?? "forward";
  const index = findIndex(lookup, array.values, match, search);
  if (index < 0) throw FormulaError.na;
  return scalar(index + 1);
});
register("LOOKUP", LR, "LOOKUP(lookup_value, lookup_vector, [result_vector])", "Looks up a value in a vector and returns the matching value from another vector.", [2, 3], (c) => {
  const lookup = c.strictScalar(0);
  const m = c.matrix(1);
  let keys: CellValue[], results: CellValue[];
  if (c.count > 2) {
    keys = m.values;
    results = c.flat(2);
  } else if (m.isVector) {
    keys = m.values;
    results = keys;
  } else if (m.columns >= m.rows) {
    keys = m.row(0);
    results = m.row(m.rows - 1);
  } else {
    keys = m.column(0);
    results = m.column(m.columns - 1);
  }
  const index = findIndex(lookup, keys, "exactOrSmaller", "binaryAscending");
  if (index < 0 || index >= results.length) throw FormulaError.na;
  return scalar(results[index]);
});
register("INDEX", LR, "INDEX(array, row_num, [column_num])", "Returns a value or reference from a position in a range.", [2, 3], (c) => {
  const source = c.value(0);
  const m = c.evaluator.matrix(source);
  let row = c.int(1);
  let column = c.int(2, 0);
  if (m.rows === 1 && c.count === 2) { column = row; row = 0; }
  if (m.columns === 1 && c.count === 2) column = 1;
  if (row < 0 || column < 0 || row > m.rows || column > m.columns) throw FormulaError.ref;
  if (source.k === "ref") {
    const r = source.range;
    const r1 = row === 0 ? r.start.row : r.start.row + row - 1, r2 = row === 0 ? r.end.row : r1;
    const c1 = column === 0 ? r.start.column : r.start.column + column - 1, c2 = column === 0 ? r.end.column : c1;
    return { k: "ref", sheet: source.sheet, range: rangeRC(r1, c1, r2, c2) };
  }
  if (row === 0) return matrixValue(Matrix.column(m.column(Math.max(column, 1) - 1)));
  if (column === 0) return m.columns === 1 ? scalar(m.get(row - 1, 0)) : matrixValue(Matrix.row(m.row(row - 1)));
  return scalar(m.get(row - 1, column - 1));
});
register("CHOOSE", LR, "CHOOSE(index_num, value1, [value2], …)", "Chooses a value from a list based on an index number.", [2, V], (c) => {
  const index = c.int(0);
  if (index < 1 || index >= c.count) throw FormulaError.value;
  return c.value(index);
});
register("OFFSET", LR, "OFFSET(reference, rows, cols, [height], [width])", "Returns a reference offset from a given reference.", [3, 5], (c) => {
  const { sheet, range: r } = c.reference(0);
  const rows = c.int(1), columns = c.int(2);
  const height = c.int(3, rowCount(r)), width = c.int(4, columnCount(r));
  if (height < 1 || width < 1) throw FormulaError.ref;
  const start = { row: r.start.row + rows, column: r.start.column + columns };
  const end = { row: start.row + height - 1, column: start.column + width - 1 };
  if (!isValidAddress(start) || !isValidAddress(end)) throw FormulaError.ref;
  return { k: "ref", sheet, range: range(start, end) };
});
register("INDIRECT", LR, "INDIRECT(ref_text, [a1])", "Returns the reference specified by a text string.", [1, 2], (c) => {
  const text = c.text(0).trim();
  let expression: Expr;
  try {
    expression = parseFormula(text);
  } catch {
    throw FormulaError.ref;
  }
  if (expression.e === "cell" || expression.e === "range") return c.evaluator.evaluate(expression);
  if (expression.e === "name") {
    if (!definedName(c.evaluator.workbook, expression.name)) throw FormulaError.ref;
    return c.evaluator.evaluate(expression);
  }
  throw FormulaError.ref;
});
register("ROW", LR, "ROW([reference])", "Returns the row number of a reference.", [0, 1], (c) => {
  if (c.isMissing(0)) return scalar(c.evaluator.origin.row + 1);
  const { range: r } = c.reference(0);
  if (rowCount(r) === 1 || isWholeColumns(r)) return scalar(r.start.row + 1);
  return matrixValue(Matrix.column(Array.from({ length: rowCount(r) }, (_, i) => r.start.row + i + 1)));
});
register("COLUMN", LR, "COLUMN([reference])", "Returns the column number of a reference.", [0, 1], (c) => {
  if (c.isMissing(0)) return scalar(c.evaluator.origin.column + 1);
  const { range: r } = c.reference(0);
  if (columnCount(r) === 1 || isWholeRows(r)) return scalar(r.start.column + 1);
  return matrixValue(Matrix.row(Array.from({ length: columnCount(r) }, (_, i) => r.start.column + i + 1)));
});
register("ROWS", LR, "ROWS(array)", "Returns the number of rows in a reference or array.", [1, 1], (c) => {
  const v = c.value(0);
  return scalar(v.k === "ref" ? rowCount(v.range) : c.matrix(0).rows);
});
register("COLUMNS", LR, "COLUMNS(array)", "Returns the number of columns in a reference or array.", [1, 1], (c) => {
  const v = c.value(0);
  return scalar(v.k === "ref" ? columnCount(v.range) : c.matrix(0).columns);
});
register("ADDRESS", LR, "ADDRESS(row_num, column_num, [abs_num], [a1], [sheet_text])", "Returns a reference as text.", [2, 5], (c) => {
  const row = c.int(0), column = c.int(1), kind = c.int(2, 1);
  if (row < 1 || column < 1 || row > MAX_ROWS || column > MAX_COLUMNS) throw FormulaError.value;
  let text: string;
  if (c.bool(3, true)) {
    const absColumn = kind === 1 || kind === 3, absRow = kind === 1 || kind === 2;
    text = (absColumn ? "$" : "") + columnName(column - 1) + (absRow ? "$" : "") + String(row);
  } else {
    text = kind === 1 ? `R${row}C${column}` : kind === 2 ? `R${row}C[${column}]` : kind === 3 ? `R[${row}]C${column}` : `R[${row}]C[${column}]`;
  }
  if (!c.isMissing(4)) text = quotedSheetName(c.text(4)) + "!" + text;
  return scalar(text);
});
register("TRANSPOSE", LR, "TRANSPOSE(array)", "Returns the transpose of an array.", [1, 1], (c) => matrixValue(c.matrix(0).transposed));
register("SORT", LR, "SORT(array, [sort_index], [sort_order], [by_col])", "Sorts the contents of a range or array.", [1, 4], (c) => {
  const m = c.matrix(0);
  const index = c.int(1, 1);
  const descending = c.int(2, 1) === -1;
  const byColumn = c.bool(3, false);
  const source = byColumn ? m.transposed : m;
  if (index < 1 || index > source.columns) throw FormulaError.value;
  const rows = source.rowArrays.sort((a, b) => {
    const order = compareValues(a[index - 1], b[index - 1]);
    return descending ? -order : order;
  });
  const sorted = Matrix.fromRows(rows);
  return matrixValue(byColumn ? sorted.transposed : sorted);
});
register("SORTBY", LR, "SORTBY(array, by_array1, [sort_order1], …)", "Sorts a range based on the values in a corresponding range.", [2, V], (c) => {
  const m = c.matrix(0);
  const keys: [CellValue[], boolean][] = [];
  for (let i = 1; i < c.count; i += 2) {
    const key = c.flat(i);
    if (key.length !== m.rows) throw FormulaError.value;
    const descending = i + 1 < c.count ? c.int(i + 1, 1) === -1 : false;
    keys.push([key, descending]);
  }
  const order = Array.from({ length: m.rows }, (_, i) => i).sort((a, b) => {
    for (const [key, descending] of keys) {
      const r = compareValues(key[a], key[b]);
      if (r !== 0) return descending ? -r : r;
    }
    return a - b;
  });
  return matrixValue(Matrix.fromRows(order.map((r) => m.row(r))));
});
register("UNIQUE", LR, "UNIQUE(array, [by_col], [exactly_once])", "Returns the unique values from a range or array.", [1, 3], (c) => {
  const m = c.matrix(0);
  const byColumn = c.bool(1, false);
  const exactlyOnce = c.bool(2, false);
  const source = byColumn ? m.transposed : m;
  const rows = source.rowArrays;
  const key = (row: CellValue[]) => row.map((v) => plainText(v).toLowerCase()).join("\u001F");
  const counts = new Map<string, number>();
  for (const row of rows) counts.set(key(row), (counts.get(key(row)) ?? 0) + 1);
  const seen = new Set<string>();
  const result: CellValue[][] = [];
  for (const row of rows) {
    const k = key(row);
    if (exactlyOnce && counts.get(k) !== 1) continue;
    if (!seen.has(k)) {
      seen.add(k);
      result.push(row);
    }
  }
  if (!result.length) throw FormulaError.calc;
  const unique = Matrix.fromRows(result);
  return matrixValue(byColumn ? unique.transposed : unique);
});
register("FILTER", LR, "FILTER(array, include, [if_empty])", "Filters a range of data based on criteria you define.", [2, 3], (c) => {
  const m = c.matrix(0);
  const include = c.matrix(1);
  const keep = (v: CellValue) => {
    if (v instanceof FormulaError) throw v;
    return catchFormula(() => {
      if (typeof v === "boolean") return v;
      if (typeof v === "number") return v !== 0;
      if (typeof v === "string") return v.toUpperCase() === "TRUE";
      return false;
    }, () => false);
  };
  let result: Matrix | null = null;
  if (include.rows === m.rows && include.columns === 1) {
    const rows: CellValue[][] = [];
    for (let r = 0; r < m.rows; r++) if (keep(include.get(r, 0))) rows.push(m.row(r));
    if (rows.length) result = Matrix.fromRows(rows);
  } else if (include.columns === m.columns && include.rows === 1) {
    const columns: CellValue[][] = [];
    for (let col = 0; col < m.columns; col++) if (keep(include.get(0, col))) columns.push(m.column(col));
    if (columns.length) result = Matrix.fromRows(columns).transposed;
  } else {
    throw FormulaError.value;
  }
  if (result) return matrixValue(result);
  if (c.count > 2) return c.value(2);
  throw FormulaError.calc;
});
const span = (count: number, total: number, fromStart: boolean): [number, number] =>
  fromStart ? (count >= 0 ? [0, Math.min(count, total)] : [Math.max(total + count, 0), total]) : count >= 0 ? [Math.min(count, total), total] : [0, Math.max(total + count, 0)];
const slice = (m: Matrix, rows: [number, number], columns: [number, number]) => {
  if (rows[1] <= rows[0] || columns[1] <= columns[0]) throw FormulaError.calc;
  const out: CellValue[][] = [];
  for (let r = rows[0]; r < rows[1]; r++) out.push(m.row(r).slice(columns[0], columns[1]));
  return matrixValue(Matrix.fromRows(out));
};
register("TAKE", LR, "TAKE(array, rows, [columns])", "Returns rows or columns from the start or end of an array.", [2, 3], (c) => {
  const m = c.matrix(0);
  const rows = c.isMissing(1) ? m.rows : c.int(1);
  const columns = c.isMissing(2) ? m.columns : c.int(2);
  return slice(m, span(rows, m.rows, true), span(columns, m.columns, true));
});
register("DROP", LR, "DROP(array, rows, [columns])", "Excludes rows or columns from the start or end of an array.", [2, 3], (c) => {
  const m = c.matrix(0);
  return slice(m, span(c.int(1, 0), m.rows, false), span(c.int(2, 0), m.columns, false));
});
const picks = (c: FunctionCall, total: number) =>
  Array.from({ length: c.count - 1 }, (_, k) => {
    const n = c.int(k + 1);
    const index = n > 0 ? n - 1 : total + n;
    if (index < 0 || index >= total) throw FormulaError.value;
    return index;
  });
register("CHOOSECOLS", LR, "CHOOSECOLS(array, col_num1, [col_num2], …)", "Returns the specified columns from an array.", [2, V], (c) => {
  const m = c.matrix(0);
  const chosen = picks(c, m.columns);
  return matrixValue(Matrix.fromRows(Array.from({ length: m.rows }, (_, r) => chosen.map((col) => m.get(r, col)))));
});
register("CHOOSEROWS", LR, "CHOOSEROWS(array, row_num1, [row_num2], …)", "Returns the specified rows from an array.", [2, V], (c) => {
  const m = c.matrix(0);
  return matrixValue(Matrix.fromRows(picks(c, m.rows).map((r) => m.row(r))));
});
register("VSTACK", LR, "VSTACK(array1, [array2], …)", "Stacks arrays vertically.", [1, V], (c) => {
  const arrays = Array.from({ length: c.count }, (_, i) => c.matrix(i));
  const width = arrays.reduce((w, m) => Math.max(w, m.columns), 0);
  const rows: CellValue[][] = [];
  for (const m of arrays) for (const r of m.rowArrays) rows.push([...r, ...new Array(width - r.length).fill(FormulaError.na)]);
  return matrixValue(Matrix.fromRows(rows));
});
register("HSTACK", LR, "HSTACK(array1, [array2], …)", "Stacks arrays horizontally.", [1, V], (c) => {
  const arrays = Array.from({ length: c.count }, (_, i) => c.matrix(i).transposed);
  const height = arrays.reduce((h, m) => Math.max(h, m.columns), 0);
  const columns: CellValue[][] = [];
  for (const m of arrays) for (const r of m.rowArrays) columns.push([...r, ...new Array(height - r.length).fill(FormulaError.na)]);
  return matrixValue(Matrix.fromRows(columns).transposed);
});
const ignoring = (c: FunctionCall) => {
  const ignore = c.int(1, 0);
  return c.flat(0).filter((v) => !(((ignore === 1 || ignore === 3) && v === null) || ((ignore === 2 || ignore === 3) && v instanceof FormulaError)));
};
register("TOCOL", LR, "TOCOL(array, [ignore])", "Returns the array as one column.", [1, 2], (c) => matrixValue(Matrix.column(ignoring(c))));
register("TOROW", LR, "TOROW(array, [ignore])", "Returns the array as one row.", [1, 2], (c) => matrixValue(Matrix.row(ignoring(c))));
