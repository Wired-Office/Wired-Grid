import { columnName } from "../../model/address";
import { FormulaError, type CellValue } from "../../model/values";
import { cellKey } from "../../model/address";
import { columnWidth, numberFormatOf, sheetIndexNamed, styleAt } from "../../model/workbook";
import { catchFormula, register, VARIADIC, type FunctionCall } from "../calculator";
import { asBool, compareValues, Matrix, matrixValue, scalar, type FValue } from "../fvalue";

const V = VARIADIC;
const L = "Logical" as const;
const I = "Information" as const;

register("IF", L, "IF(logical_test, [value_if_true], [value_if_false])", "Checks whether a condition is met, and returns one value if TRUE and another if FALSE.", [1, 3], (c) => {
  const test = c.value(0);
  const ev = c.evaluator;
  if (ev.isSingle(test)) {
    const condition = ev.scalar(test);
    if (condition instanceof FormulaError) throw condition;
    if (asBool(condition)) return c.isMissing(1) ? scalar(c.count > 1 ? 0 : true) : c.value(1);
    return c.count > 2 ? (c.isMissing(2) ? scalar(0) : c.value(2)) : scalar(false);
  }
  // Array condition: choose element by element.
  const mask = ev.matrix(test);
  const yes = c.count > 1 ? ev.matrix(c.value(1)) : Matrix.filled(1, 1, true);
  const no = c.count > 2 ? ev.matrix(c.value(2)) : Matrix.filled(1, 1, false);
  const result = mask.copy();
  const pick = (m: Matrix, r: number, col: number) => m.get(m.rows === 1 ? 0 : Math.min(r, m.rows - 1), m.columns === 1 ? 0 : Math.min(col, m.columns - 1));
  for (let r = 0; r < mask.rows; r++) {
    for (let col = 0; col < mask.columns; col++) {
      const condition = mask.get(r, col);
      if (condition instanceof FormulaError) { result.set(r, col, condition); continue; }
      const flag = catchFormula(() => asBool(condition), () => false);
      result.set(r, col, flag ? pick(yes, r, col) : pick(no, r, col));
    }
  }
  return matrixValue(result);
});
register("IFS", L, "IFS(logical_test1, value_if_true1, …)", "Checks conditions in order and returns the value for the first TRUE one.", [2, V], (c) => {
  if (c.count % 2 !== 0) throw FormulaError.value;
  for (let i = 0; i < c.count; i += 2) if (asBool(c.strictScalar(i))) return c.value(i + 1);
  throw FormulaError.na;
});
const replaceErrors = (c: FunctionCall, matches: (e: FormulaError) => boolean): FValue => {
  let value: FValue;
  try {
    value = c.value(0);
  } catch (e) {
    if (e instanceof FormulaError && matches(e)) return c.value(1);
    throw e;
  }
  if (c.evaluator.isSingle(value)) {
    const v = c.evaluator.scalar(value);
    return v instanceof FormulaError && matches(v) ? c.value(1) : value;
  }
  const fallback = c.evaluator.scalar(c.value(1));
  const m = c.evaluator.matrix(value).copy();
  for (let i = 0; i < m.values.length; i++) {
    const v = m.values[i];
    if (v instanceof FormulaError && matches(v)) m.values[i] = fallback;
  }
  return matrixValue(m);
};
register("IFERROR", L, "IFERROR(value, value_if_error)", "Returns value_if_error if the expression is an error, otherwise the value.", [2, 2], (c) => replaceErrors(c, () => true));
register("IFNA", L, "IFNA(value, value_if_na)", "Returns value_if_na if the expression resolves to #N/A.", [2, 2], (c) => replaceErrors(c, (e) => e === FormulaError.na));
const logicalValues = (c: FunctionCall): boolean[] => {
  const result: boolean[] = [];
  for (let i = 0; i < c.count; i++) {
    if (c.isMissing(i)) continue;
    const value = c.value(i);
    if (value.k === "scalar") {
      if (value.v instanceof FormulaError) throw value.v;
      result.push(asBool(value.v));
      continue;
    }
    for (const element of c.evaluator.matrix(value).values) {
      if (typeof element === "boolean") result.push(element);
      else if (typeof element === "number") result.push(element !== 0);
      else if (element instanceof FormulaError) throw element;
    }
  }
  if (!result.length) throw FormulaError.value;
  return result;
};
register("AND", L, "AND(logical1, [logical2], …)", "Returns TRUE if all arguments are TRUE.", [1, V], (c) => scalar(logicalValues(c).every(Boolean)));
register("OR", L, "OR(logical1, [logical2], …)", "Returns TRUE if any argument is TRUE.", [1, V], (c) => scalar(logicalValues(c).some(Boolean)));
register("XOR", L, "XOR(logical1, [logical2], …)", "Returns TRUE if an odd number of arguments are TRUE.", [1, V], (c) =>
  scalar(logicalValues(c).filter(Boolean).length % 2 === 1));
register("NOT", L, "NOT(logical)", "Reverses the logic of its argument.", [1, 1], (c) =>
  c.lift(0, (v) => (v instanceof FormulaError ? v : !asBool(v))));
register("TRUE", L, "TRUE()", "Returns the logical value TRUE.", [0, 0], () => scalar(true));
register("FALSE", L, "FALSE()", "Returns the logical value FALSE.", [0, 0], () => scalar(false));
register("SWITCH", L, "SWITCH(expression, value1, result1, …, [default])", "Evaluates an expression against a list of values and returns the first match's result.", [3, V], (c) => {
  const target = c.strictScalar(0);
  let i = 1;
  for (; i + 1 < c.count; i += 2) if (compareValues(target, c.scalar(i)) === 0) return c.value(i + 1);
  if (i < c.count) return c.value(i);
  throw FormulaError.na;
});
register("LET", L, "LET(name1, value1, [name2, value2], …, calculation)", "Assigns names to calculation results for use inside the formula.", [3, V], (c) => {
  if (c.count % 2 !== 1) throw FormulaError.value;
  return c.evaluator.withScope(() => {
    for (let i = 0; i + 1 < c.count; i += 2) {
      const arg = c.args[i];
      if (arg.e !== "name") throw FormulaError.value;
      c.evaluator.bind(arg.name, c.evaluator.evaluate(c.args[i + 1]));
    }
    return c.evaluator.evaluate(c.args[c.count - 1]);
  });
});

// MARK: Information

function test(name: string, summary: string, predicate: (v: CellValue) => boolean) {
  register(name, I, `${name}(value)`, summary, [1, 1], (c) => {
    let value: FValue;
    try {
      value = c.value(0);
    } catch (e) {
      if (e instanceof FormulaError) return scalar(predicate(e));
      throw e;
    }
    return c.evaluator.map(value, predicate);
  });
}
test("ISBLANK", "Returns TRUE if the value is empty.", (v) => v === null);
test("ISNUMBER", "Returns TRUE if the value is a number.", (v) => typeof v === "number");
test("ISTEXT", "Returns TRUE if the value is text.", (v) => typeof v === "string");
test("ISNONTEXT", "Returns TRUE if the value is not text.", (v) => typeof v !== "string");
test("ISLOGICAL", "Returns TRUE if the value is a logical value.", (v) => typeof v === "boolean");
test("ISERROR", "Returns TRUE if the value is any error value.", (v) => v instanceof FormulaError);
test("ISERR", "Returns TRUE if the value is any error except #N/A.", (v) => v instanceof FormulaError && v !== FormulaError.na);
test("ISNA", "Returns TRUE if the value is the #N/A error.", (v) => v === FormulaError.na);

register("ISEVEN", I, "ISEVEN(number)", "Returns TRUE if the number is even.", [1, 1], (c) => scalar(Math.trunc(c.number(0)) % 2 === 0));
register("ISODD", I, "ISODD(number)", "Returns TRUE if the number is odd.", [1, 1], (c) => scalar(Math.trunc(c.number(0)) % 2 !== 0));
register("ISREF", I, "ISREF(value)", "Returns TRUE if the value is a reference.", [1, 1], (c) => scalar(catchFormula(() => c.isReference(0), () => false)));
register("ISFORMULA", I, "ISFORMULA(reference)", "Returns TRUE if the referenced cell contains a formula.", [1, 1], (c) => {
  const { sheet, range } = c.reference(0);
  return scalar(c.evaluator.workbook.sheets[sheet].cells.get(cellKey(range.start.row, range.start.column))?.formula !== undefined);
});
register("FORMULATEXT", I, "FORMULATEXT(reference)", "Returns the formula in a cell as text.", [1, 1], (c) => {
  const { sheet, range } = c.reference(0);
  const formula = c.evaluator.workbook.sheets[sheet].cells.get(cellKey(range.start.row, range.start.column))?.formula;
  if (formula === undefined) throw FormulaError.na;
  return scalar("=" + formula);
});
register("N", I, "N(value)", "Returns a value converted to a number.", [1, 1], (c) => {
  const v = c.scalar(0);
  if (typeof v === "number") return scalar(v);
  if (typeof v === "boolean") return scalar(v ? 1 : 0);
  if (v instanceof FormulaError) throw v;
  return scalar(0);
});
register("NA", I, "NA()", "Returns the error value #N/A.", [0, 0], () => scalar(FormulaError.na));
register("TYPE", I, "TYPE(value)", "Returns a number indicating the data type of a value.", [1, 1], (c) => {
  const value = c.value(0);
  if (!c.evaluator.isSingle(value)) return scalar(64);
  const v = c.evaluator.scalar(value);
  if (typeof v === "number" || v === null) return scalar(1);
  if (typeof v === "string") return scalar(2);
  if (typeof v === "boolean") return scalar(4);
  return scalar(16);
});
register("ERROR.TYPE", I, "ERROR.TYPE(error_val)", "Returns a number corresponding to an error type.", [1, 1], (c) => {
  const v = catchFormula<CellValue>(() => c.scalar(0), (e) => e);
  if (!(v instanceof FormulaError)) throw FormulaError.na;
  return scalar(v.typeNumber);
});
register("SHEET", I, "SHEET([value])", "Returns the sheet number of the referenced sheet.", [0, 1], (c) => {
  if (c.isMissing(0)) return scalar(c.evaluator.sheet + 1);
  const v = c.value(0);
  if (v.k === "ref") return scalar(v.sheet + 1);
  const index = sheetIndexNamed(c.evaluator.workbook, c.text(0));
  if (index < 0) throw FormulaError.na;
  return scalar(index + 1);
});
register("SHEETS", I, "SHEETS([reference])", "Returns the number of sheets in the workbook.", [0, 1], (c) =>
  scalar(c.isMissing(0) ? c.evaluator.workbook.sheets.length : 1));
register("CELL", I, "CELL(info_type, [reference])", "Returns information about the formatting, location or contents of a cell.", [1, 2], (c) => {
  const info = c.text(0).toLowerCase();
  const target = c.isMissing(1) ? { sheet: c.evaluator.sheet, range: { start: c.evaluator.origin, end: c.evaluator.origin } } : c.reference(1);
  const sheet = c.evaluator.workbook.sheets[target.sheet];
  const a = target.range.start;
  switch (info) {
    case "address": return scalar("$" + columnName(a.column) + "$" + String(a.row + 1));
    case "row": return scalar(a.row + 1);
    case "col": return scalar(a.column + 1);
    case "contents": return scalar(c.evaluator.calculator.value(target.sheet, a.row, a.column));
    case "type": {
      const v = c.evaluator.calculator.value(target.sheet, a.row, a.column);
      return scalar(v === null ? "b" : typeof v === "string" ? "l" : "v");
    }
    case "format": return scalar(numberFormatOf(styleAt(sheet, a.row, a.column)));
    case "width": return scalar(Math.round(columnWidth(sheet, a.column) / 7));
    case "filename": return scalar(sheet.name);
    default: throw FormulaError.value;
  }
});
