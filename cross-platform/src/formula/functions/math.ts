import { FormulaError } from "../../model/values";
import { cellKey } from "../../model/address";
import { register, VARIADIC } from "../calculator";
import { Criterion, Matrix, matrixValue, numberResult, scalar } from "../fvalue";
import { excelRound } from "../numberFormat";
import { criteriaMask, resized, Statistics } from "./shared";

const V = VARIADIC;

function factorial(n: number): number {
  if (n < 0) return NaN;
  if (n > 170) return Infinity;
  let r = 1;
  for (let i = 2; i <= n; i++) r *= i;
  return r;
}

const gcd = (a: number, b: number): number => (b === 0 ? Math.abs(a) : gcd(b, a % b));

const fail = (e: FormulaError): never => { throw e; };

register("SUM", "Math & Trig", "SUM(number1, [number2], …)", "Adds all the numbers in a range of cells.", [1, V], (c) =>
  numberResult(c.numbers().reduce((a, b) => a + b, 0)));
register("SUMSQ", "Math & Trig", "SUMSQ(number1, [number2], …)", "Returns the sum of the squares of the arguments.", [1, V], (c) =>
  numberResult(c.numbers().reduce((a, b) => a + b * b, 0)));
register("PRODUCT", "Math & Trig", "PRODUCT(number1, [number2], …)", "Multiplies all the numbers given as arguments.", [1, V], (c) => {
  const numbers = c.numbers();
  return numberResult(numbers.length ? numbers.reduce((a, b) => a * b, 1) : 0);
});
register("ABS", "Math & Trig", "ABS(number)", "Returns the absolute value of a number.", [1, 1], (c) => c.liftNumber(0, Math.abs));
register("SIGN", "Math & Trig", "SIGN(number)", "Returns the sign of a number: 1, 0 or -1.", [1, 1], (c) => c.liftNumber(0, (n) => (n > 0 ? 1 : n < 0 ? -1 : 0)));
register("SQRT", "Math & Trig", "SQRT(number)", "Returns a positive square root.", [1, 1], (c) =>
  c.liftNumber(0, (n) => (n >= 0 ? Math.sqrt(n) : fail(FormulaError.num))));
register("SQRTPI", "Math & Trig", "SQRTPI(number)", "Returns the square root of (number × π).", [1, 1], (c) =>
  c.liftNumber(0, (n) => (n >= 0 ? Math.sqrt(n * Math.PI) : fail(FormulaError.num))));
register("POWER", "Math & Trig", "POWER(number, power)", "Returns the result of a number raised to a power.", [2, 2], (c) => {
  const b = c.number(0), e = c.number(1);
  if (b === 0 && e < 0) throw FormulaError.div0;
  return numberResult(Math.pow(b, e));
});
register("EXP", "Math & Trig", "EXP(number)", "Returns e raised to the power of a given number.", [1, 1], (c) => c.liftNumber(0, Math.exp));
register("LN", "Math & Trig", "LN(number)", "Returns the natural logarithm of a number.", [1, 1], (c) =>
  c.liftNumber(0, (n) => (n > 0 ? Math.log(n) : fail(FormulaError.num))));
register("LOG10", "Math & Trig", "LOG10(number)", "Returns the base-10 logarithm of a number.", [1, 1], (c) =>
  c.liftNumber(0, (n) => (n > 0 ? Math.log10(n) : fail(FormulaError.num))));
register("LOG", "Math & Trig", "LOG(number, [base])", "Returns the logarithm of a number to the base you specify.", [1, 2], (c) => {
  const n = c.number(0), b = c.number(1, 10);
  if (!(n > 0 && b > 0 && b !== 1)) throw FormulaError.num;
  return numberResult(Math.log(n) / Math.log(b));
});
register("MOD", "Math & Trig", "MOD(number, divisor)", "Returns the remainder after a number is divided by a divisor.", [2, 2], (c) => {
  const n = c.number(0), d = c.number(1);
  if (d === 0) throw FormulaError.div0;
  return numberResult(n - d * Math.floor(n / d));
});
register("QUOTIENT", "Math & Trig", "QUOTIENT(numerator, denominator)", "Returns the integer portion of a division.", [2, 2], (c) => {
  const n = c.number(0), d = c.number(1);
  if (d === 0) throw FormulaError.div0;
  return numberResult(Math.trunc(n / d));
});
register("INT", "Math & Trig", "INT(number)", "Rounds a number down to the nearest integer.", [1, 1], (c) => c.liftNumber(0, Math.floor));
register("TRUNC", "Math & Trig", "TRUNC(number, [num_digits])", "Truncates a number to an integer or to a number of digits.", [1, 2], (c) => {
  const digits = c.int(1, 0);
  return c.liftNumber(0, (n) => excelRound(n, digits, "towardZero"));
});
register("ROUND", "Math & Trig", "ROUND(number, num_digits)", "Rounds a number to a specified number of digits.", [2, 2], (c) => {
  const digits = c.int(1);
  return c.liftNumber(0, (n) => excelRound(n, digits));
});
register("ROUNDUP", "Math & Trig", "ROUNDUP(number, num_digits)", "Rounds a number up, away from zero.", [2, 2], (c) => {
  const digits = c.int(1);
  return c.liftNumber(0, (n) => excelRound(n, digits, "awayFromZero"));
});
register("ROUNDDOWN", "Math & Trig", "ROUNDDOWN(number, num_digits)", "Rounds a number down, toward zero.", [2, 2], (c) => {
  const digits = c.int(1);
  return c.liftNumber(0, (n) => excelRound(n, digits, "towardZero"));
});
register("MROUND", "Math & Trig", "MROUND(number, multiple)", "Returns a number rounded to the desired multiple.", [2, 2], (c) => {
  const n = c.number(0), m = c.number(1);
  if (m === 0) return scalar(0);
  if (n * m < 0) throw FormulaError.num;
  return numberResult(excelRound(n / m, 0) * m);
});
const ceiling = (n: number, s: number) => {
  if (s === 0) return 0;
  if (n > 0 && s < 0) throw FormulaError.num;
  return Math.ceil(n / s) * s;
};
register("CEILING", "Math & Trig", "CEILING(number, significance)", "Rounds a number up to the nearest multiple of significance.", [2, 2], (c) =>
  numberResult(ceiling(c.number(0), c.number(1))));
register("CEILING.MATH", "Math & Trig", "CEILING.MATH(number, [significance], [mode])", "Rounds a number up to the nearest integer or multiple.", [1, 3], (c) => {
  const n = c.number(0), s = Math.abs(c.number(1, 1)), mode = c.number(2, 0);
  if (s === 0) return scalar(0);
  if (n < 0 && mode !== 0) return numberResult(Math.floor(n / s) * s);
  return numberResult(Math.ceil(n / s) * s);
});
register("FLOOR", "Math & Trig", "FLOOR(number, significance)", "Rounds a number down toward zero to a multiple of significance.", [2, 2], (c) => {
  const n = c.number(0), s = c.number(1);
  if (s === 0) throw FormulaError.div0;
  if (n > 0 && s < 0) throw FormulaError.num;
  return numberResult(Math.floor(n / s) * s);
});
register("FLOOR.MATH", "Math & Trig", "FLOOR.MATH(number, [significance], [mode])", "Rounds a number down to the nearest integer or multiple.", [1, 3], (c) => {
  const n = c.number(0), s = Math.abs(c.number(1, 1)), mode = c.number(2, 0);
  if (s === 0) return scalar(0);
  if (n < 0 && mode !== 0) return numberResult(Math.ceil(n / s) * s);
  return numberResult(Math.floor(n / s) * s);
});
register("EVEN", "Math & Trig", "EVEN(number)", "Rounds a number up to the nearest even integer.", [1, 1], (c) =>
  c.liftNumber(0, (n) => {
    const r = Math.ceil(Math.abs(n) / 2) * 2;
    return n < 0 ? -r : r;
  }));
register("ODD", "Math & Trig", "ODD(number)", "Rounds a number up to the nearest odd integer.", [1, 1], (c) =>
  c.liftNumber(0, (n) => {
    let r = Math.ceil(Math.abs(n));
    if (r % 2 === 0) r += 1;
    return n < 0 ? -r : r;
  }));
register("PI", "Math & Trig", "PI()", "Returns the value of π.", [0, 0], () => scalar(Math.PI));
register("RAND", "Math & Trig", "RAND()", "Returns a random number between 0 and 1.", [0, 0], () => scalar(Math.random()));
const randomInt = (low: number, high: number) => low + Math.floor(Math.random() * (high - low + 1));
register("RANDBETWEEN", "Math & Trig", "RANDBETWEEN(bottom, top)", "Returns a random integer between the numbers you specify.", [2, 2], (c) => {
  const low = Math.ceil(c.number(0)), high = Math.floor(c.number(1));
  if (low > high) throw FormulaError.num;
  return scalar(randomInt(low, high));
});
register("RANDARRAY", "Math & Trig", "RANDARRAY([rows], [columns], [min], [max], [integer])", "Returns an array of random numbers.", [0, 5], (c) => {
  const rows = c.int(0, 1), columns = c.int(1, 1);
  const low = c.number(2, 0), high = c.number(3, 1);
  const integer = c.bool(4, false);
  if (!(rows > 0 && columns > 0 && rows * columns <= 1_000_000 && low <= high)) throw FormulaError.value;
  const values = Array.from({ length: rows * columns }, () => (integer ? randomInt(Math.trunc(low), Math.trunc(high)) : low + Math.random() * (high - low)));
  return matrixValue(new Matrix(rows, columns, values));
});
register("SEQUENCE", "Math & Trig", "SEQUENCE(rows, [columns], [start], [step])", "Generates a list of sequential numbers in an array.", [1, 4], (c) => {
  const rows = c.int(0), columns = c.int(1, 1);
  const start = c.number(2, 1), step = c.number(3, 1);
  if (!(rows > 0 && columns > 0 && rows * columns <= 1_000_000)) throw FormulaError.value;
  return matrixValue(new Matrix(rows, columns, Array.from({ length: rows * columns }, (_, i) => start + i * step)));
});
register("FACT", "Math & Trig", "FACT(number)", "Returns the factorial of a number.", [1, 1], (c) => {
  const n = c.number(0);
  if (n < 0) throw FormulaError.num;
  return numberResult(factorial(Math.trunc(n)));
});
register("FACTDOUBLE", "Math & Trig", "FACTDOUBLE(number)", "Returns the double factorial of a number.", [1, 1], (c) => {
  const n = Math.trunc(c.number(0));
  if (n < -1) throw FormulaError.num;
  let r = 1;
  for (let k = n; k > 1; k -= 2) r *= k;
  return numberResult(r);
});
register("COMBIN", "Math & Trig", "COMBIN(number, number_chosen)", "Returns the number of combinations for a given number of items.", [2, 2], (c) => {
  const n = Math.trunc(c.number(0)), k = Math.trunc(c.number(1));
  if (n < 0 || k < 0 || k > n) throw FormulaError.num;
  let r = 1;
  for (let i = 0; i < Math.min(k, n - k); i++) r = (r * (n - i)) / (i + 1);
  return numberResult(Math.round(r));
});
register("COMBINA", "Math & Trig", "COMBINA(number, number_chosen)", "Returns the number of combinations with repetitions.", [2, 2], (c) => {
  const n = Math.trunc(c.number(0)), k = Math.trunc(c.number(1));
  if (n < 0 || k < 0) throw FormulaError.num;
  if (n === 0 && k === 0) return scalar(1);
  const total = n + k - 1;
  let r = 1;
  for (let i = 0; i < Math.min(k, total - k); i++) r = (r * (total - i)) / (i + 1);
  return numberResult(Math.round(r));
});
register("PERMUT", "Math & Trig", "PERMUT(number, number_chosen)", "Returns the number of permutations for a given number of objects.", [2, 2], (c) => {
  const n = Math.trunc(c.number(0)), k = Math.trunc(c.number(1));
  if (n < 0 || k < 0 || k > n) throw FormulaError.num;
  let r = 1;
  for (let i = 0; i < k; i++) r *= n - i;
  return numberResult(r);
});
register("GCD", "Math & Trig", "GCD(number1, [number2], …)", "Returns the greatest common divisor.", [1, V], (c) => {
  const numbers = c.numbers().map(Math.trunc);
  if (numbers.some((n) => n < 0)) throw FormulaError.num;
  return scalar(numbers.reduce(gcd, 0));
});
register("LCM", "Math & Trig", "LCM(number1, [number2], …)", "Returns the least common multiple.", [1, V], (c) => {
  const numbers = c.numbers().map(Math.trunc);
  if (numbers.some((n) => n < 0)) throw FormulaError.num;
  if (numbers.includes(0)) return scalar(0);
  return numberResult(numbers.reduce((a, b) => (a / gcd(a, b)) * b, 1));
});
register("DEGREES", "Math & Trig", "DEGREES(angle)", "Converts radians to degrees.", [1, 1], (c) => c.liftNumber(0, (n) => (n * 180) / Math.PI));
register("RADIANS", "Math & Trig", "RADIANS(angle)", "Converts degrees to radians.", [1, 1], (c) => c.liftNumber(0, (n) => (n * Math.PI) / 180));
const trig: [string, string, (n: number) => number][] = [
  ["SIN", "Returns the sine of an angle.", Math.sin],
  ["COS", "Returns the cosine of an angle.", Math.cos],
  ["TAN", "Returns the tangent of an angle.", Math.tan],
  ["ASIN", "Returns the arcsine of a number.", (n) => (Math.abs(n) <= 1 ? Math.asin(n) : fail(FormulaError.num))],
  ["ACOS", "Returns the arccosine of a number.", (n) => (Math.abs(n) <= 1 ? Math.acos(n) : fail(FormulaError.num))],
  ["ATAN", "Returns the arctangent of a number.", Math.atan],
  ["SINH", "Returns the hyperbolic sine of a number.", Math.sinh],
  ["COSH", "Returns the hyperbolic cosine of a number.", Math.cosh],
  ["TANH", "Returns the hyperbolic tangent of a number.", Math.tanh],
  ["ASINH", "Returns the inverse hyperbolic sine of a number.", Math.asinh],
  ["ACOSH", "Returns the inverse hyperbolic cosine of a number.", (n) => (n >= 1 ? Math.acosh(n) : fail(FormulaError.num))],
  ["ATANH", "Returns the inverse hyperbolic tangent of a number.", (n) => (Math.abs(n) < 1 ? Math.atanh(n) : fail(FormulaError.num))],
  ["COT", "Returns the cotangent of an angle.", (n) => (n !== 0 ? 1 / Math.tan(n) : fail(FormulaError.div0))],
  ["CSC", "Returns the cosecant of an angle.", (n) => (n !== 0 ? 1 / Math.sin(n) : fail(FormulaError.div0))],
  ["SEC", "Returns the secant of an angle.", (n) => 1 / Math.cos(n)],
];
for (const [name, summary, f] of trig) register(name, "Math & Trig", `${name}(number)`, summary, [1, 1], (c) => c.liftNumber(0, f));
register("ATAN2", "Math & Trig", "ATAN2(x_num, y_num)", "Returns the arctangent from x- and y-coordinates.", [2, 2], (c) => {
  const x = c.number(0), y = c.number(1);
  if (x === 0 && y === 0) throw FormulaError.div0;
  return numberResult(Math.atan2(y, x));
});
register("SUMPRODUCT", "Math & Trig", "SUMPRODUCT(array1, [array2], …)", "Returns the sum of the products of corresponding array components.", [1, V], (c) => {
  const arrays = Array.from({ length: c.count }, (_, i) => c.matrix(i));
  const first = arrays[0];
  if (!first || !arrays.every((a) => a.rows === first.rows && a.columns === first.columns)) throw FormulaError.value;
  let total = 0;
  for (let i = 0; i < first.count; i++) {
    let product = 1;
    for (const array of arrays) {
      const v = array.values[i];
      if (typeof v === "number") product *= v;
      else if (v instanceof FormulaError) throw v;
      else product = 0;
    }
    total += product;
  }
  return numberResult(total);
});
register("SUMIF", "Math & Trig", "SUMIF(range, criteria, [sum_range])", "Adds the cells specified by a given condition.", [2, 3], (c) => {
  const r = c.matrix(0);
  const criterion = new Criterion(c.strictScalar(1));
  const sums = c.isMissing(2) ? r : resized(c, 2, r);
  let total = 0;
  for (let i = 0; i < r.count; i++) {
    if (!criterion.matches(r.values[i])) continue;
    const v = sums.values[i];
    if (typeof v === "number") total += v;
  }
  return numberResult(total);
});
register("SUMIFS", "Math & Trig", "SUMIFS(sum_range, criteria_range1, criteria1, …)", "Adds the cells that meet multiple conditions.", [3, V], (c) => {
  const sums = c.matrix(0);
  const mask = criteriaMask(c, 1, sums);
  let total = 0;
  for (let i = 0; i < sums.count; i++) {
    const v = sums.values[i];
    if (mask[i] && typeof v === "number") total += v;
  }
  return numberResult(total);
});
register("SUBTOTAL", "Math & Trig", "SUBTOTAL(function_num, ref1, [ref2], …)", "Returns a subtotal, ignoring rows hidden by filters.", [2, V], (c) => {
  const code = c.int(0);
  const ignoreManual = code > 100;
  const fn = code % 100;
  const values: number[] = [];
  let countA = 0;
  for (let index = 1; index < c.count; index++) {
    const { sheet: sheetIndex, range: r } = c.reference(index);
    const sheet = c.evaluator.workbook.sheets[sheetIndex];
    const t = c.evaluator.trimmed(r, sheetIndex);
    for (let row = t.start.row; row <= t.end.row; row++) {
      if (sheet.filter?.hiddenRows.has(row)) continue;
      if (ignoreManual && sheet.hiddenRows.has(row)) continue;
      for (let column = t.start.column; column <= t.end.column; column++) {
        // Skip nested SUBTOTALs, as Excel does.
        const formula = sheet.cells.get(cellKey(row, column))?.formula;
        if (formula && formula.toUpperCase().includes("SUBTOTAL(")) continue;
        const v = c.evaluator.calculator.value(sheetIndex, row, column);
        if (v instanceof FormulaError) throw v;
        if (v !== null) countA++;
        if (typeof v === "number") values.push(v);
      }
    }
  }
  return Statistics.aggregate(fn, values, countA);
});
register("AGGREGATE", "Math & Trig", "AGGREGATE(function_num, options, ref1, …)", "Returns an aggregate, optionally ignoring errors and hidden rows.", [3, V], (c) => {
  const fn = c.int(0);
  const options = c.int(1);
  const ignoreErrors = [2, 3, 6, 7].includes(options);
  const values: number[] = [];
  let countA = 0;
  for (let index = 2; index < c.count; index++) {
    for (const v of c.flat(index)) {
      if (typeof v === "number") { values.push(v); countA++; }
      else if (v instanceof FormulaError) { if (!ignoreErrors) throw v; }
      else if (v !== null) countA++;
    }
  }
  if (fn >= 14 && fn <= 19 && c.count > 3) {
    const k = c.number(3);
    const sorted = [...values].sort((a, b) => a - b);
    if (!sorted.length) throw FormulaError.num;
    switch (fn) {
      case 14: if (!(k >= 1 && Math.trunc(k) <= sorted.length)) throw FormulaError.num; return scalar(sorted[sorted.length - Math.trunc(k)]);
      case 15: if (!(k >= 1 && Math.trunc(k) <= sorted.length)) throw FormulaError.num; return scalar(sorted[Math.trunc(k) - 1]);
      case 16: case 18: return numberResult(Statistics.percentile(sorted, k, fn === 18));
      default: return numberResult(Statistics.percentile(sorted, k / 4, fn === 19));
    }
  }
  return Statistics.aggregate(fn, values, countA);
});
register("ROMAN", "Math & Trig", "ROMAN(number)", "Converts an Arabic numeral to Roman, as text.", [1, 2], (c) => {
  let n = c.int(0);
  if (n < 0 || n >= 4000) throw FormulaError.value;
  const table: [number, string][] = [[1000, "M"], [900, "CM"], [500, "D"], [400, "CD"], [100, "C"], [90, "XC"],
    [50, "L"], [40, "XL"], [10, "X"], [9, "IX"], [5, "V"], [4, "IV"], [1, "I"]];
  let result = "";
  for (const [value, numeral] of table) while (n >= value) { result += numeral; n -= value; }
  return scalar(result);
});
register("ARABIC", "Math & Trig", "ARABIC(text)", "Converts a Roman numeral to Arabic.", [1, 1], (c) => {
  const text = c.text(0).toUpperCase().trim();
  const values: Record<string, number> = { I: 1, V: 5, X: 10, L: 50, C: 100, D: 500, M: 1000 };
  let total = 0, previous = 0;
  for (const ch of [...text].reverse()) {
    const value = values[ch];
    if (!value) throw FormulaError.value;
    total += value < previous ? -value : value;
    previous = Math.max(previous, value);
  }
  return scalar(total);
});
register("BASE", "Math & Trig", "BASE(number, radix, [min_length])", "Converts a number into text in the given base.", [2, 3], (c) => {
  const n = c.int(0), radix = c.int(1), length = c.int(2, 0);
  if (n < 0 || radix < 2 || radix > 36) throw FormulaError.num;
  let s = n.toString(radix).toUpperCase();
  if (s.length < length) s = "0".repeat(length - s.length) + s;
  return scalar(s);
});
register("DECIMAL", "Math & Trig", "DECIMAL(text, radix)", "Converts text in a given base to a decimal number.", [2, 2], (c) => {
  const text = c.text(0), radix = c.int(1);
  if (radix < 2 || radix > 36) throw FormulaError.num;
  const digits = "0123456789abcdefghijklmnopqrstuvwxyz".slice(0, radix);
  const body = text.replace(/^[+-]/, "").toLowerCase();
  if (!body || ![...body].every((ch) => digits.includes(ch))) throw FormulaError.num;
  const n = parseInt(text, radix);
  if (Number.isNaN(n)) throw FormulaError.num;
  return scalar(n);
});
register("MMULT", "Math & Trig", "MMULT(array1, array2)", "Returns the matrix product of two arrays.", [2, 2], (c) => {
  const a = c.matrix(0), b = c.matrix(1);
  if (a.columns !== b.rows) throw FormulaError.value;
  const result = Matrix.filled(a.rows, b.columns);
  for (let i = 0; i < a.rows; i++) {
    for (let j = 0; j < b.columns; j++) {
      let sum = 0;
      for (let k = 0; k < a.columns; k++) {
        const x = a.get(i, k), y = b.get(k, j);
        if (typeof x !== "number" || typeof y !== "number") throw FormulaError.value;
        sum += x * y;
      }
      result.set(i, j, sum);
    }
  }
  return matrixValue(result);
});
