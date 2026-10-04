import { FormulaError } from "../../model/values";
import { register, VARIADIC, type FunctionCall } from "../calculator";
import { asNumber, Criterion, Matrix, matrixValue, numberResult, scalar } from "../fvalue";
import { criteriaMask, logGamma, resized, Statistics } from "./shared";
import { numberFromText } from "../valueParser";
import { excelRound } from "../numberFormat";

const V = VARIADIC;
const sum = (x: number[]) => x.reduce((a, b) => a + b, 0);

const S = "Statistical" as const;

register("AVERAGE", S, "AVERAGE(number1, [number2], …)", "Returns the average (arithmetic mean) of its arguments.", [1, V], (c) => {
  const x = c.numbers();
  if (!x.length) throw FormulaError.div0;
  return numberResult(Statistics.mean(x));
});
register("AVERAGEA", S, "AVERAGEA(value1, [value2], …)", "Returns the average, counting text as 0 and TRUE as 1.", [1, V], (c) => {
  const x = c.numbers(0, c.count, true);
  if (!x.length) throw FormulaError.div0;
  return numberResult(Statistics.mean(x));
});
register("AVERAGEIF", S, "AVERAGEIF(range, criteria, [average_range])", "Averages the cells that meet a condition.", [2, 3], (c) => {
  const r = c.matrix(0);
  const criterion = new Criterion(c.strictScalar(1));
  const values = c.isMissing(2) ? r : resized(c, 2, r);
  const x: number[] = [];
  for (let i = 0; i < r.count; i++) {
    const v = values.values[i];
    if (criterion.matches(r.values[i]) && typeof v === "number") x.push(v);
  }
  if (!x.length) throw FormulaError.div0;
  return numberResult(Statistics.mean(x));
});
register("AVERAGEIFS", S, "AVERAGEIFS(average_range, criteria_range1, criteria1, …)", "Averages the cells that meet multiple conditions.", [3, V], (c) => {
  const values = c.matrix(0);
  const mask = criteriaMask(c, 1, values);
  const x = values.values.filter((v, i): v is number => mask[i] && typeof v === "number");
  if (!x.length) throw FormulaError.div0;
  return numberResult(Statistics.mean(x));
});
register("COUNT", S, "COUNT(value1, [value2], …)", "Counts how many cells contain numbers.", [1, V], (c) => {
  let n = 0;
  for (let i = 0; i < c.count; i++) {
    if (c.isMissing(i)) continue;
    const v = c.value(i);
    if (v.k === "scalar") {
      const s = v.v;
      if (typeof s === "number" || typeof s === "boolean" || (typeof s === "string" && numberFromText(s) !== null)) n++;
    } else {
      n += c.evaluator.matrix(v).values.filter((x) => typeof x === "number").length;
    }
  }
  return scalar(n);
});
register("COUNTA", S, "COUNTA(value1, [value2], …)", "Counts how many cells are not empty.", [1, V], (c) => {
  let n = 0;
  for (let i = 0; i < c.count; i++) if (!c.isMissing(i)) n += c.flat(i).filter((v) => v !== null).length;
  return scalar(n);
});
register("COUNTBLANK", S, "COUNTBLANK(range)", "Counts the empty cells in a range.", [1, 1], (c) =>
  scalar(c.flat(0).filter((v) => v === null || v === "").length));
register("COUNTIF", S, "COUNTIF(range, criteria)", "Counts the cells that meet a condition.", [2, 2], (c) => {
  const criterion = new Criterion(c.strictScalar(1));
  return scalar(c.flat(0).filter((v) => criterion.matches(v)).length);
});
register("COUNTIFS", S, "COUNTIFS(criteria_range1, criteria1, …)", "Counts the cells that meet multiple conditions.", [2, V], (c) =>
  scalar(criteriaMask(c, 0, c.matrix(0)).filter(Boolean).length));
const extreme = (x: number[], pick: (...v: number[]) => number) => (x.length ? x.reduce((a, b) => pick(a, b)) : 0);
register("MAX", S, "MAX(number1, [number2], …)", "Returns the largest value in a set of values.", [1, V], (c) => scalar(extreme(c.numbers(), Math.max)));
register("MIN", S, "MIN(number1, [number2], …)", "Returns the smallest value in a set of values.", [1, V], (c) => scalar(extreme(c.numbers(), Math.min)));
register("MAXA", S, "MAXA(value1, [value2], …)", "Returns the largest value, including text and logicals.", [1, V], (c) =>
  scalar(extreme(c.numbers(0, c.count, true), Math.max)));
register("MINA", S, "MINA(value1, [value2], …)", "Returns the smallest value, including text and logicals.", [1, V], (c) =>
  scalar(extreme(c.numbers(0, c.count, true), Math.min)));
const maskedNumbers = (c: FunctionCall) => {
  const values = c.matrix(0);
  const mask = criteriaMask(c, 1, values);
  return values.values.filter((v, i): v is number => mask[i] && typeof v === "number");
};
register("MAXIFS", S, "MAXIFS(max_range, criteria_range1, criteria1, …)", "Returns the maximum among cells that meet conditions.", [3, V], (c) =>
  scalar(extreme(maskedNumbers(c), Math.max)));
register("MINIFS", S, "MINIFS(min_range, criteria_range1, criteria1, …)", "Returns the minimum among cells that meet conditions.", [3, V], (c) =>
  scalar(extreme(maskedNumbers(c), Math.min)));
register("MEDIAN", S, "MEDIAN(number1, [number2], …)", "Returns the median of the given numbers.", [1, V], (c) => numberResult(Statistics.median(c.numbers())));
for (const name of ["MODE", "MODE.SNGL"]) {
  register(name, S, `${name}(number1, [number2], …)`, "Returns the most frequently occurring value.", [1, V], (c) => numberResult(Statistics.mode(c.numbers())));
}
for (const [name, sample, summary] of [
  ["STDEV", true, "Estimates standard deviation based on a sample."],
  ["STDEV.S", true, "Estimates standard deviation based on a sample."],
  ["STDEVP", false, "Calculates standard deviation based on the entire population."],
  ["STDEV.P", false, "Calculates standard deviation based on the entire population."],
] as const) {
  register(name, S, `${name}(number1, [number2], …)`, summary, [1, V], (c) => numberResult(Math.sqrt(Statistics.variance(c.numbers(), sample))));
}
for (const [name, sample, summary] of [
  ["VAR", true, "Estimates variance based on a sample."],
  ["VAR.S", true, "Estimates variance based on a sample."],
  ["VARP", false, "Calculates variance based on the entire population."],
  ["VAR.P", false, "Calculates variance based on the entire population."],
] as const) {
  register(name, S, `${name}(number1, [number2], …)`, summary, [1, V], (c) => numberResult(Statistics.variance(c.numbers(), sample)));
}
register("LARGE", S, "LARGE(array, k)", "Returns the k-th largest value in a data set.", [2, 2], (c) => {
  const x = c.numbers(0, 1).sort((a, b) => b - a);
  const k = c.int(1);
  if (k < 1 || k > x.length) throw FormulaError.num;
  return scalar(x[k - 1]);
});
register("SMALL", S, "SMALL(array, k)", "Returns the k-th smallest value in a data set.", [2, 2], (c) => {
  const x = c.numbers(0, 1).sort((a, b) => a - b);
  const k = c.int(1);
  if (k < 1 || k > x.length) throw FormulaError.num;
  return scalar(x[k - 1]);
});
for (const name of ["RANK", "RANK.EQ", "RANK.AVG"]) {
  register(name, S, `${name}(number, ref, [order])`, "Returns the rank of a number in a list of numbers.", [2, 3], (c) => {
    const n = c.number(0);
    const x = c.numbers(1, 2);
    const ascending = c.number(2, 0) !== 0;
    if (!x.includes(n)) throw FormulaError.na;
    const better = x.filter((v) => (ascending ? v < n : v > n)).length;
    if (name === "RANK.AVG") {
      const ties = x.filter((v) => v === n).length;
      return scalar(better + (ties + 1) / 2);
    }
    return scalar(better + 1);
  });
}
for (const [name, exclusive] of [["PERCENTILE", false], ["PERCENTILE.INC", false], ["PERCENTILE.EXC", true]] as const) {
  register(name, S, `${name}(array, k)`, "Returns the k-th percentile of values in a range.", [2, 2], (c) =>
    numberResult(Statistics.percentile(c.numbers(0, 1).sort((a, b) => a - b), c.number(1), exclusive)));
}
for (const [name, exclusive] of [["QUARTILE", false], ["QUARTILE.INC", false], ["QUARTILE.EXC", true]] as const) {
  register(name, S, `${name}(array, quart)`, "Returns the quartile of a data set.", [2, 2], (c) => {
    const q = c.int(1);
    if (q < 0 || q > 4) throw FormulaError.num;
    return numberResult(Statistics.percentile(c.numbers(0, 1).sort((a, b) => a - b), q / 4, exclusive));
  });
}
for (const name of ["PERCENTRANK", "PERCENTRANK.INC"]) {
  register(name, S, `${name}(array, x, [significance])`, "Returns the rank of a value as a percentage of the data set.", [2, 3], (c) => {
    const x = c.numbers(0, 1).sort((a, b) => a - b);
    const value = c.number(1);
    const digits = c.int(2, 3);
    if (!(x.length > 1 && value >= x[0] && value <= x[x.length - 1])) throw FormulaError.na;
    const below = x.filter((v) => v < value).length;
    let rank: number;
    if (x.includes(value)) {
      rank = below / (x.length - 1);
    } else {
      let i = -1;
      for (let k = x.length - 1; k >= 0; k--) if (x[k] < value) { i = k; break; }
      const fraction = (value - x[i]) / (x[i + 1] - x[i]);
      rank = (i + fraction) / (x.length - 1);
    }
    return scalar(excelRound(rank, digits, "towardZero"));
  });
}
for (const name of ["CORREL", "PEARSON"]) {
  register(name, S, `${name}(array1, array2)`, "Returns the correlation coefficient between two data sets.", [2, 2], (c) => {
    const [x, y] = Statistics.pairs(c, 0, 1);
    return numberResult(Statistics.correlation(x, y));
  });
}
register("RSQ", S, "RSQ(known_y's, known_x's)", "Returns the square of the Pearson correlation coefficient.", [2, 2], (c) => {
  const [y, x] = Statistics.pairs(c, 0, 1);
  const r = Statistics.correlation(x, y);
  return numberResult(r * r);
});
for (const [name, sample] of [["COVAR", false], ["COVARIANCE.P", false], ["COVARIANCE.S", true]] as const) {
  register(name, S, `${name}(array1, array2)`, "Returns covariance, the average of the products of paired deviations.", [2, 2], (c) => {
    const [x, y] = Statistics.pairs(c, 0, 1);
    return numberResult(Statistics.covariance(x, y, sample));
  });
}
register("SLOPE", S, "SLOPE(known_y's, known_x's)", "Returns the slope of the linear regression line.", [2, 2], (c) => {
  const [y, x] = Statistics.pairs(c, 0, 1);
  return numberResult(Statistics.regression(y, x).slope);
});
register("INTERCEPT", S, "INTERCEPT(known_y's, known_x's)", "Returns the intercept of the linear regression line.", [2, 2], (c) => {
  const [y, x] = Statistics.pairs(c, 0, 1);
  return numberResult(Statistics.regression(y, x).intercept);
});
for (const name of ["FORECAST", "FORECAST.LINEAR"]) {
  register(name, S, `${name}(x, known_y's, known_x's)`, "Predicts a value along a linear trend.", [3, 3], (c) => {
    const target = c.number(0);
    const [y, x] = Statistics.pairs(c, 1, 2);
    const fit = Statistics.regression(y, x);
    return numberResult(fit.intercept + fit.slope * target);
  });
}
register("TREND", S, "TREND(known_y's, [known_x's], [new_x's])", "Returns values along a linear trend.", [1, 3], (c) => {
  const ys = c.numbers(0, 1);
  const xs = c.isMissing(1) ? ys.map((_, i) => i + 1) : c.numbers(1, 2);
  if (xs.length !== ys.length) throw FormulaError.ref;
  const fit = Statistics.regression(ys, xs);
  const targets = !c.isMissing(2) ? c.matrix(2) : !c.isMissing(1) ? c.matrix(1) : Matrix.column(xs);
  const result = targets.copy();
  for (let i = 0; i < targets.count; i++) {
    let x = 0;
    try { x = asNumber(targets.values[i]); } catch { x = 0; }
    result.values[i] = fit.intercept + fit.slope * x;
  }
  return matrixValue(result);
});
register("GEOMEAN", S, "GEOMEAN(number1, [number2], …)", "Returns the geometric mean.", [1, V], (c) => {
  const x = c.numbers();
  if (!x.length || !x.every((v) => v > 0)) throw FormulaError.num;
  return numberResult(Math.exp(sum(x.map(Math.log)) / x.length));
});
register("HARMEAN", S, "HARMEAN(number1, [number2], …)", "Returns the harmonic mean.", [1, V], (c) => {
  const x = c.numbers();
  if (!x.length || !x.every((v) => v > 0)) throw FormulaError.num;
  return numberResult(x.length / sum(x.map((v) => 1 / v)));
});
register("AVEDEV", S, "AVEDEV(number1, [number2], …)", "Returns the average of absolute deviations from the mean.", [1, V], (c) => {
  const x = c.numbers();
  if (!x.length) throw FormulaError.num;
  const m = Statistics.mean(x);
  return numberResult(sum(x.map((v) => Math.abs(v - m))) / x.length);
});
register("DEVSQ", S, "DEVSQ(number1, [number2], …)", "Returns the sum of squares of deviations.", [1, V], (c) => {
  const x = c.numbers();
  if (!x.length) throw FormulaError.num;
  const m = Statistics.mean(x);
  return numberResult(sum(x.map((v) => (v - m) * (v - m))));
});
register("SKEW", S, "SKEW(number1, [number2], …)", "Returns the skewness of a distribution.", [1, V], (c) => {
  const x = c.numbers();
  const n = x.length;
  if (n < 3) throw FormulaError.div0;
  const m = Statistics.mean(x), s = Math.sqrt(Statistics.variance(x, true));
  if (!(s > 0)) throw FormulaError.div0;
  return numberResult((n / ((n - 1) * (n - 2))) * sum(x.map((v) => Math.pow((v - m) / s, 3))));
});
register("KURT", S, "KURT(number1, [number2], …)", "Returns the kurtosis of a data set.", [1, V], (c) => {
  const x = c.numbers();
  const n = x.length;
  if (n < 4) throw FormulaError.div0;
  const m = Statistics.mean(x), s = Math.sqrt(Statistics.variance(x, true));
  if (!(s > 0)) throw FormulaError.div0;
  const total = sum(x.map((v) => Math.pow((v - m) / s, 4)));
  return numberResult(((n * (n + 1)) / ((n - 1) * (n - 2) * (n - 3))) * total - (3 * (n - 1) * (n - 1)) / ((n - 2) * (n - 3)));
});
register("STANDARDIZE", S, "STANDARDIZE(x, mean, standard_dev)", "Returns a normalized value.", [3, 3], (c) => {
  const sd = c.number(2);
  if (!(sd > 0)) throw FormulaError.num;
  return numberResult((c.number(0) - c.number(1)) / sd);
});
for (const name of ["NORM.DIST", "NORMDIST"]) {
  register(name, S, `${name}(x, mean, standard_dev, cumulative)`, "Returns the normal distribution.", [4, 4], (c) => {
    const x = c.number(0), m = c.number(1), sd = c.number(2), cumulative = c.bool(3);
    if (!(sd > 0)) throw FormulaError.num;
    const z = (x - m) / sd;
    return numberResult(cumulative ? Statistics.normalCDF(z) : Statistics.normalPDF(z) / sd);
  });
}
register("NORM.S.DIST", S, "NORM.S.DIST(z, cumulative)", "Returns the standard normal distribution.", [2, 2], (c) => {
  const z = c.number(0);
  return numberResult(c.bool(1) ? Statistics.normalCDF(z) : Statistics.normalPDF(z));
});
register("NORMSDIST", S, "NORMSDIST(z)", "Returns the standard normal cumulative distribution.", [1, 1], (c) => numberResult(Statistics.normalCDF(c.number(0))));
for (const name of ["NORM.INV", "NORMINV"]) {
  register(name, S, `${name}(probability, mean, standard_dev)`, "Returns the inverse of the normal cumulative distribution.", [3, 3], (c) => {
    const sd = c.number(2);
    if (!(sd > 0)) throw FormulaError.num;
    return numberResult(Statistics.inverseNormal(c.number(0)) * sd + c.number(1));
  });
}
for (const name of ["NORM.S.INV", "NORMSINV"]) {
  register(name, S, `${name}(probability)`, "Returns the inverse of the standard normal distribution.", [1, 1], (c) =>
    numberResult(Statistics.inverseNormal(c.number(0))));
}
register("CONFIDENCE.NORM", S, "CONFIDENCE.NORM(alpha, standard_dev, size)", "Returns the confidence interval for a population mean.", [3, 3], (c) => {
  const alpha = c.number(0), sd = c.number(1), n = c.number(2);
  if (!(alpha > 0 && alpha < 1 && sd > 0 && n >= 1)) throw FormulaError.num;
  return numberResult((Statistics.inverseNormal(1 - alpha / 2) * sd) / Math.sqrt(n));
});
for (const name of ["BINOM.DIST", "BINOMDIST"]) {
  register(name, S, `${name}(number_s, trials, probability_s, cumulative)`, "Returns the binomial distribution probability.", [4, 4], (c) => {
    const k = c.int(0), n = c.int(1), p = c.number(2), cumulative = c.bool(3);
    if (!(k >= 0 && n >= k && p >= 0 && p <= 1)) throw FormulaError.num;
    const pmf = (i: number) => Statistics.binomial(n, i) * Math.pow(p, i) * Math.pow(1 - p, n - i);
    if (!cumulative) return numberResult(pmf(k));
    let total = 0;
    for (let i = 0; i <= k; i++) total += pmf(i);
    return numberResult(total);
  });
}
for (const name of ["POISSON.DIST", "POISSON"]) {
  register(name, S, `${name}(x, mean, cumulative)`, "Returns the Poisson distribution.", [3, 3], (c) => {
    const k = c.int(0), m = c.number(1), cumulative = c.bool(2);
    if (!(k >= 0 && m >= 0)) throw FormulaError.num;
    const pmf = (i: number) => Math.exp(i * Math.log(Math.max(m, Number.MIN_VALUE)) - m - logGamma(i + 1));
    if (!cumulative) return numberResult(pmf(k));
    let total = 0;
    for (let i = 0; i <= k; i++) total += pmf(i);
    return numberResult(total);
  });
}
for (const name of ["EXPON.DIST", "EXPONDIST"]) {
  register(name, S, `${name}(x, lambda, cumulative)`, "Returns the exponential distribution.", [3, 3], (c) => {
    const x = c.number(0), lambda = c.number(1), cumulative = c.bool(2);
    if (!(x >= 0 && lambda > 0)) throw FormulaError.num;
    return numberResult(cumulative ? 1 - Math.exp(-lambda * x) : lambda * Math.exp(-lambda * x));
  });
}
register("FREQUENCY", S, "FREQUENCY(data_array, bins_array)", "Counts how often values occur within ranges of values.", [2, 2], (c) => {
  const data = c.numbers(0, 1);
  const bins = c.numbers(1, 2);
  const sortedBins = [...bins].sort((a, b) => a - b);
  const counts = new Array<number>(bins.length + 1).fill(0);
  for (const value of data) {
    const index = sortedBins.findIndex((b) => value <= b);
    counts[index < 0 ? bins.length : index]++;
  }
  // Report counts in the order the bins were given.
  const result = bins.map((bin) => counts[sortedBins.indexOf(bin)]);
  result.push(counts[bins.length]);
  return matrixValue(Matrix.column(result));
});
