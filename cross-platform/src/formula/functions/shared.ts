import { rangeRC } from "../../model/address";
import { FormulaError } from "../../model/values";
import type { FunctionCall } from "../calculator";
import { Criterion, Matrix, numberResult, scalar, type FValue } from "../fvalue";

const sum = (x: number[]) => x.reduce((a, b) => a + b, 0);

/** A range the same shape as `like`, starting at the top-left of argument `index`. */
export function resized(c: FunctionCall, index: number, like: Matrix): Matrix {
  const v = c.value(index);
  if (v.k === "ref") {
    const s = v.range.start;
    return c.evaluator.matrixOf(v.sheet, rangeRC(s.row, s.column, s.row + like.rows - 1, s.column + like.columns - 1));
  }
  const m = c.matrix(index);
  if (m.rows !== like.rows || m.columns !== like.columns) throw FormulaError.value;
  return m;
}

/** For the *IFS functions: which cells meet every (range, criterion) pair starting at `from`. */
export function criteriaMask(c: FunctionCall, from: number, size: Matrix): boolean[] {
  if ((c.count - from) % 2 !== 0) throw FormulaError.value;
  const mask = new Array<boolean>(size.count).fill(true);
  for (let index = from; index < c.count; index += 2) {
    const r = c.matrix(index);
    if (r.rows !== size.rows || r.columns !== size.columns) throw FormulaError.value;
    const criterion = new Criterion(c.strictScalar(index + 1));
    for (let i = 0; i < r.count; i++) if (mask[i] && !criterion.matches(r.values[i])) mask[i] = false;
  }
  return mask;
}

/** ln Γ(x) by the Lanczos approximation (g = 7, n = 9). */
export function logGamma(x: number): number {
  if (x < 0.5) return Math.log(Math.PI / Math.abs(Math.sin(Math.PI * x))) - logGamma(1 - x);
  const p = [0.99999999999980993, 676.5203681218851, -1259.1392167224028, 771.32342877765313, -176.61502916214059,
    12.507343278686905, -0.13857109526572012, 9.9843695780195716e-6, 1.5056327351493116e-7];
  const z = x - 1;
  let a = p[0];
  const t = z + 7.5;
  for (let i = 1; i < 9; i++) a += p[i] / (z + i);
  return 0.5 * Math.log(2 * Math.PI) + (z + 0.5) * Math.log(t) - t + Math.log(a);
}

/** The complementary error function, accurate to about 1e-14. */
export function erfc(x: number): number {
  if (x < 0) return 2 - erfc(-x);
  if (x < 3) {
    // Taylor series of erf.
    let term = x, total = x;
    const x2 = x * x;
    for (let n = 1; n < 200; n++) {
      term *= -x2 / n;
      const next = term / (2 * n + 1);
      total += next;
      if (Math.abs(next) < 1e-17 * Math.abs(total)) break;
    }
    return 1 - (2 / Math.sqrt(Math.PI)) * total;
  }
  // Continued fraction, evaluated with the modified Lentz method.
  const tiny = 1e-300;
  let f = x, C = x, D = 0;
  for (let n = 1; n < 300; n++) {
    const a = n / 2;
    D = x + a * D;
    D = Math.abs(D) < tiny ? tiny : D;
    C = x + a / C;
    C = Math.abs(C) < tiny ? tiny : C;
    D = 1 / D;
    const delta = C * D;
    f *= delta;
    if (Math.abs(delta - 1) < 1e-16) break;
  }
  return Math.exp(-x * x) / (f * Math.sqrt(Math.PI));
}

/** Shared statistics used by several functions. */
export const Statistics = {
  mean: (x: number[]) => sum(x) / x.length,

  variance(x: number[], sample: boolean): number {
    const n = x.length;
    if (!(n > (sample ? 1 : 0))) throw FormulaError.div0;
    const m = Statistics.mean(x);
    return x.reduce((a, v) => a + (v - m) * (v - m), 0) / (sample ? n - 1 : n);
  },

  median(x: number[]): number {
    if (!x.length) throw FormulaError.num;
    const s = [...x].sort((a, b) => a - b);
    const h = Math.floor(s.length / 2);
    return s.length % 2 === 1 ? s[h] : (s[h - 1] + s[h]) / 2;
  },

  percentile(sorted: number[], k: number, exclusive: boolean): number {
    const n = sorted.length;
    if (!n) throw FormulaError.num;
    let rank: number;
    if (exclusive) {
      if (!(k > 0 && k < 1)) throw FormulaError.num;
      rank = k * (n + 1) - 1;
      if (!(rank >= 0 && rank <= n - 1)) throw FormulaError.num;
    } else {
      if (!(k >= 0 && k <= 1)) throw FormulaError.num;
      rank = k * (n - 1);
    }
    const lower = Math.floor(rank);
    const fraction = rank - lower;
    if (lower + 1 >= n) return sorted[n - 1];
    return sorted[lower] + fraction * (sorted[lower + 1] - sorted[lower]);
  },

  mode(x: number[]): number {
    const counts = new Map<number, number>();
    const order: number[] = [];
    for (const v of x) {
      if (!counts.has(v)) order.push(v);
      counts.set(v, (counts.get(v) ?? 0) + 1);
    }
    let best = 0;
    for (const v of order) best = Math.max(best, counts.get(v)!);
    if (best <= 1) throw FormulaError.na;
    return order.find((v) => counts.get(v) === best)!;
  },

  /** SUBTOTAL/AGGREGATE function numbers 1–13. */
  aggregate(fn: number, values: number[], countA: number): FValue {
    switch (fn) {
      case 1: if (!values.length) throw FormulaError.div0; return numberResult(Statistics.mean(values));
      case 2: return scalar(values.length);
      case 3: return scalar(countA);
      case 4: return scalar(values.length ? Math.max(...values) : 0);
      case 5: return scalar(values.length ? Math.min(...values) : 0);
      case 6: return numberResult(values.length ? values.reduce((a, b) => a * b, 1) : 0);
      case 7: return numberResult(Math.sqrt(Statistics.variance(values, true)));
      case 8: return numberResult(Math.sqrt(Statistics.variance(values, false)));
      case 9: return numberResult(sum(values));
      case 10: return numberResult(Statistics.variance(values, true));
      case 11: return numberResult(Statistics.variance(values, false));
      case 12: return numberResult(Statistics.median(values));
      case 13: return numberResult(Statistics.mode(values));
      default: throw FormulaError.value;
    }
  },

  normalCDF: (z: number) => 0.5 * erfc(-z / Math.SQRT2),
  normalPDF: (z: number) => Math.exp((-z * z) / 2) / Math.sqrt(2 * Math.PI),

  /** Acklam's rational approximation of the inverse normal CDF, refined by one Newton step. */
  inverseNormal(p: number): number {
    if (!(p > 0 && p < 1)) throw FormulaError.num;
    const a = [-3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02, 1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00];
    const b = [-5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02, 6.680131188771972e+01, -1.328068155288572e+01];
    const c = [-7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00, -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00];
    const d = [7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00, 3.754408661907416e+00];
    const low = 0.02425, high = 1 - low;
    let x: number;
    if (p < low) {
      const q = Math.sqrt(-2 * Math.log(p));
      x = (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1);
    } else if (p <= high) {
      const q = p - 0.5, r = q * q;
      x = ((((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q) / (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1);
    } else {
      const q = Math.sqrt(-2 * Math.log(1 - p));
      x = -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1);
    }
    const e = Statistics.normalCDF(x) - p;
    const u = e * Math.sqrt(2 * Math.PI) * Math.exp((x * x) / 2);
    x -= u / (1 + (x * u) / 2);
    return x;
  },

  binomial: (n: number, k: number) => Math.exp(logGamma(n + 1) - logGamma(k + 1) - logGamma(n - k + 1)),

  pairs(c: FunctionCall, a: number, b: number): [number[], number[]] {
    const x = c.matrix(a), y = c.matrix(b);
    if (x.count !== y.count) throw FormulaError.na;
    const xs: number[] = [], ys: number[] = [];
    for (let i = 0; i < x.count; i++) {
      const p = x.values[i], q = y.values[i];
      if (p instanceof FormulaError) throw p;
      if (q instanceof FormulaError) throw q;
      if (typeof p === "number" && typeof q === "number") { xs.push(p); ys.push(q); }
    }
    return [xs, ys];
  },

  covariance(x: number[], y: number[], sample: boolean): number {
    if (!(x.length > (sample ? 1 : 0))) throw FormulaError.div0;
    const mx = Statistics.mean(x), my = Statistics.mean(y);
    let s = 0;
    for (let i = 0; i < x.length; i++) s += (x[i] - mx) * (y[i] - my);
    return s / (sample ? x.length - 1 : x.length);
  },

  correlation(x: number[], y: number[]): number {
    const sx = Math.sqrt(Statistics.variance(x, false)), sy = Math.sqrt(Statistics.variance(y, false));
    if (!(sx > 0 && sy > 0)) throw FormulaError.div0;
    return Statistics.covariance(x, y, false) / (sx * sy);
  },

  /** Least-squares slope and intercept of y on x. */
  regression(ys: number[], xs: number[]): { slope: number; intercept: number } {
    if (!xs.length) throw FormulaError.div0;
    const mx = Statistics.mean(xs), my = Statistics.mean(ys);
    let num = 0, den = 0;
    for (let i = 0; i < xs.length; i++) {
      num += (xs[i] - mx) * (ys[i] - my);
      den += (xs[i] - mx) * (xs[i] - mx);
    }
    if (den === 0) throw FormulaError.div0;
    const slope = num / den;
    return { slope, intercept: my - slope * mx };
  },
};

