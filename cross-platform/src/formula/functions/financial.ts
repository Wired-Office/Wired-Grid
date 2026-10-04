import { FormulaError } from "../../model/values";
import { register, VARIADIC } from "../calculator";
import { numberResult } from "../fvalue";
import { excelRound } from "../numberFormat";

const V = VARIADIC;
const F = "Financial" as const;

/** Time-value-of-money helpers shared by the financial functions. */
export const Finance = {
  pmt(r: number, n: number, pv: number, fv = 0, type = 0): number {
    if (r === 0) return -(pv + fv) / n;
    const f = Math.pow(1 + r, n);
    return -(r * (fv + pv * f)) / ((1 + r * type) * (f - 1));
  },
  fv(r: number, n: number, pmt: number, pv = 0, type = 0): number {
    if (r === 0) return -(pv + pmt * n);
    const f = Math.pow(1 + r, n);
    return -(pv * f + (pmt * (1 + r * type) * (f - 1)) / r);
  },
  pv(r: number, n: number, pmt: number, fv = 0, type = 0): number {
    if (r === 0) return -(fv + pmt * n);
    const f = Math.pow(1 + r, n);
    return -(fv + (pmt * (1 + r * type) * (f - 1)) / r) / f;
  },
  ipmt(r: number, per: number, n: number, pv: number, fv = 0, type = 0): number {
    const payment = Finance.pmt(r, n, pv, fv, type);
    if (per === 1) return type === 1 ? 0 : -pv * r;
    if (type === 1) return (Finance.fv(r, per - 2, payment, pv, 1) - payment) * r;
    return Finance.fv(r, per - 1, payment, pv, 0) * r;
  },
  /** Newton's method over several starting guesses. */
  solve(guess: number, f: (x: number) => number): number {
    for (const start of [guess, 0.1, 0.01, 0.5, -0.5, 1, -0.9]) {
      let x = start;
      for (let i = 0; i < 100; i++) {
        const y = f(x);
        if (Math.abs(y) < 1e-10) return x;
        const h = Math.max(Math.abs(x) * 1e-6, 1e-8);
        const slope = (f(x + h) - f(x - h)) / (2 * h);
        if (slope === 0 || !Number.isFinite(slope)) break;
        const next = x - y / slope;
        if (!Number.isFinite(next) || next <= -1) break;
        if (Math.abs(next - x) < 1e-12) return next;
        x = next;
      }
    }
    throw FormulaError.num;
  },
};

register("PMT", F, "PMT(rate, nper, pv, [fv], [type])", "Returns the periodic payment for a loan.", [3, 5], (c) => {
  const n = c.number(1);
  if (n === 0) throw FormulaError.num;
  return numberResult(Finance.pmt(c.number(0), n, c.number(2), c.number(3, 0), c.number(4, 0)));
});
register("FV", F, "FV(rate, nper, pmt, [pv], [type])", "Returns the future value of an investment.", [3, 5], (c) =>
  numberResult(Finance.fv(c.number(0), c.number(1), c.number(2), c.number(3, 0), c.number(4, 0))));
register("PV", F, "PV(rate, nper, pmt, [fv], [type])", "Returns the present value of an investment.", [3, 5], (c) =>
  numberResult(Finance.pv(c.number(0), c.number(1), c.number(2), c.number(3, 0), c.number(4, 0))));
register("NPER", F, "NPER(rate, pmt, pv, [fv], [type])", "Returns the number of periods for an investment.", [3, 5], (c) => {
  const r = c.number(0), pmt = c.number(1), pv = c.number(2);
  const fv = c.number(3, 0), type = c.number(4, 0);
  if (r === 0) {
    if (pmt === 0) throw FormulaError.num;
    return numberResult(-(pv + fv) / pmt);
  }
  const num = pmt * (1 + r * type) - fv * r;
  const den = pv * r + pmt * (1 + r * type);
  if (!(num / den > 0)) throw FormulaError.num;
  return numberResult(Math.log(num / den) / Math.log(1 + r));
});
register("RATE", F, "RATE(nper, pmt, pv, [fv], [type], [guess])", "Returns the interest rate per period of an annuity.", [3, 6], (c) => {
  const n = c.number(0), pmt = c.number(1), pv = c.number(2);
  const fv = c.number(3, 0), type = c.number(4, 0), guess = c.number(5, 0.1);
  return numberResult(Finance.solve(guess, (r) => {
    if (Math.abs(r) < 1e-12) return pv + pmt * n + fv;
    const f = Math.pow(1 + r, n);
    return pv * f + (pmt * (1 + r * type) * (f - 1)) / r + fv;
  }));
});
register("IPMT", F, "IPMT(rate, per, nper, pv, [fv], [type])", "Returns the interest payment for a given period.", [4, 6], (c) => {
  const per = c.number(1), n = c.number(2);
  if (!(per >= 1 && per <= n)) throw FormulaError.num;
  return numberResult(Finance.ipmt(c.number(0), per, n, c.number(3), c.number(4, 0), c.number(5, 0)));
});
register("PPMT", F, "PPMT(rate, per, nper, pv, [fv], [type])", "Returns the principal payment for a given period.", [4, 6], (c) => {
  const r = c.number(0), per = c.number(1), n = c.number(2), pv = c.number(3);
  const fv = c.number(4, 0), type = c.number(5, 0);
  if (!(per >= 1 && per <= n)) throw FormulaError.num;
  return numberResult(Finance.pmt(r, n, pv, fv, type) - Finance.ipmt(r, per, n, pv, fv, type));
});
register("CUMIPMT", F, "CUMIPMT(rate, nper, pv, start_period, end_period, type)", "Returns the cumulative interest paid between two periods.", [6, 6], (c) => {
  const r = c.number(0), n = c.number(1), pv = c.number(2);
  const start = c.int(3), end = c.int(4), type = c.number(5);
  if (!(r > 0 && n > 0 && pv > 0 && start >= 1 && end >= start && end <= n)) throw FormulaError.num;
  let total = 0;
  for (let p = start; p <= end; p++) total += Finance.ipmt(r, p, n, pv, 0, type);
  return numberResult(total);
});
register("CUMPRINC", F, "CUMPRINC(rate, nper, pv, start_period, end_period, type)", "Returns the cumulative principal paid between two periods.", [6, 6], (c) => {
  const r = c.number(0), n = c.number(1), pv = c.number(2);
  const start = c.int(3), end = c.int(4), type = c.number(5);
  if (!(r > 0 && n > 0 && pv > 0 && start >= 1 && end >= start && end <= n)) throw FormulaError.num;
  const payment = Finance.pmt(r, n, pv, 0, type);
  let total = 0;
  for (let p = start; p <= end; p++) total += payment - Finance.ipmt(r, p, n, pv, 0, type);
  return numberResult(total);
});
register("NPV", F, "NPV(rate, value1, [value2], …)", "Returns the net present value of periodic cash flows.", [2, V], (c) => {
  const r = c.number(0);
  const flows = c.numbers(1, c.count);
  return numberResult(flows.reduce((total, flow, i) => total + flow / Math.pow(1 + r, i + 1), 0));
});
register("XNPV", F, "XNPV(rate, values, dates)", "Returns the net present value of irregular cash flows.", [3, 3], (c) => {
  const r = c.number(0);
  const flows = c.numbers(1, 2), dates = c.numbers(2, 3);
  if (flows.length !== dates.length || !dates.length) throw FormulaError.num;
  return numberResult(flows.reduce((total, flow, i) => total + flow / Math.pow(1 + r, (dates[i] - dates[0]) / 365), 0));
});
register("IRR", F, "IRR(values, [guess])", "Returns the internal rate of return for periodic cash flows.", [1, 2], (c) => {
  const flows = c.numbers(0, 1);
  if (!flows.some((f) => f > 0) || !flows.some((f) => f < 0)) throw FormulaError.num;
  return numberResult(Finance.solve(c.number(1, 0.1), (r) => flows.reduce((total, flow, i) => total + flow / Math.pow(1 + r, i), 0)));
});
register("XIRR", F, "XIRR(values, dates, [guess])", "Returns the internal rate of return for irregular cash flows.", [2, 3], (c) => {
  const flows = c.numbers(0, 1), dates = c.numbers(1, 2);
  if (flows.length !== dates.length || !dates.length || !flows.some((f) => f > 0) || !flows.some((f) => f < 0)) throw FormulaError.num;
  return numberResult(Finance.solve(c.number(2, 0.1), (r) => flows.reduce((total, flow, i) => total + flow / Math.pow(1 + r, (dates[i] - dates[0]) / 365), 0)));
});
register("SLN", F, "SLN(cost, salvage, life)", "Returns straight-line depreciation for one period.", [3, 3], (c) => {
  const life = c.number(2);
  if (life === 0) throw FormulaError.div0;
  return numberResult((c.number(0) - c.number(1)) / life);
});
register("SYD", F, "SYD(cost, salvage, life, per)", "Returns sum-of-years' digits depreciation.", [4, 4], (c) => {
  const cost = c.number(0), salvage = c.number(1), life = c.number(2), per = c.number(3);
  if (!(life > 0 && per >= 1 && per <= life)) throw FormulaError.num;
  return numberResult(((cost - salvage) * (life - per + 1) * 2) / (life * (life + 1)));
});
register("DDB", F, "DDB(cost, salvage, life, period, [factor])", "Returns depreciation using the double-declining balance method.", [4, 5], (c) => {
  const cost = c.number(0), salvage = c.number(1), life = c.number(2), period = c.number(3);
  const factor = c.number(4, 2);
  if (!(life > 0 && period >= 1 && period <= life && cost >= 0 && salvage >= 0)) throw FormulaError.num;
  let value = cost, depreciation = 0;
  for (let i = 0; i < Math.ceil(period); i++) {
    depreciation = Math.min((value * factor) / life, Math.max(value - salvage, 0));
    value -= depreciation;
  }
  return numberResult(depreciation);
});
register("DB", F, "DB(cost, salvage, life, period, [month])", "Returns depreciation using the fixed-declining balance method.", [4, 5], (c) => {
  const cost = c.number(0), salvage = c.number(1), life = c.number(2), period = c.int(3);
  const month = c.number(4, 12);
  if (!(cost > 0 && life > 0 && period >= 1)) throw FormulaError.num;
  const rate = excelRound(1 - Math.pow(salvage / cost, 1 / life), 3);
  let total = 0, depreciation = 0;
  for (let p = 1; p <= period; p++) {
    if (p === 1) depreciation = (cost * rate * month) / 12;
    else if (p === life + 1) depreciation = ((cost - total) * rate * (12 - month)) / 12;
    else depreciation = (cost - total) * rate;
    total += depreciation;
  }
  return numberResult(depreciation);
});
register("EFFECT", F, "EFFECT(nominal_rate, npery)", "Returns the effective annual interest rate.", [2, 2], (c) => {
  const rate = c.number(0), n = c.int(1);
  if (!(rate > 0 && n >= 1)) throw FormulaError.num;
  return numberResult(Math.pow(1 + rate / n, n) - 1);
});
register("NOMINAL", F, "NOMINAL(effect_rate, npery)", "Returns the nominal annual interest rate.", [2, 2], (c) => {
  const rate = c.number(0), n = c.int(1);
  if (!(rate > 0 && n >= 1)) throw FormulaError.num;
  return numberResult(n * (Math.pow(1 + rate, 1 / n) - 1));
});
register("RRI", F, "RRI(nper, pv, fv)", "Returns an equivalent interest rate for the growth of an investment.", [3, 3], (c) => {
  const n = c.number(0), pv = c.number(1), fv = c.number(2);
  if (!(n > 0 && pv !== 0)) throw FormulaError.num;
  return numberResult(Math.pow(fv / pv, 1 / n) - 1);
});
register("PDURATION", F, "PDURATION(rate, pv, fv)", "Returns the number of periods required to reach a value.", [3, 3], (c) => {
  const r = c.number(0), pv = c.number(1), fv = c.number(2);
  if (!(r > 0 && pv > 0 && fv > 0)) throw FormulaError.num;
  return numberResult((Math.log(fv) - Math.log(pv)) / Math.log(1 + r));
});
