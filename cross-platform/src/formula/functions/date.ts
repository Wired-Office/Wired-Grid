import { FormulaError, type CellValue } from "../../model/values";
import { register, type FunctionCall } from "../calculator";
import { asNumber, scalar } from "../fvalue";
import { addMonths, dateComponents, dateSerial, daysInMonth, isLeapYear, serialFromDate, timeComponents, weekday } from "../dateSerial";
import { parseEntry } from "../valueParser";

const D = "Date & Time" as const;

const serialArgument = (v: CellValue): number => {
  if (typeof v === "string") {
    const parsed = parseEntry(v).value;
    if (typeof parsed !== "number") throw FormulaError.value;
    return parsed;
  }
  const n = asNumber(v);
  if (n < 0) throw FormulaError.num;
  return n;
};
const serialAt = (c: FunctionCall, i: number) => serialArgument(c.strictScalar(i));

export function isoWeek(serial: number): number {
  const day = Math.floor(serial);
  const wd = ((weekday(day) + 5) % 7) + 1; // Monday = 1
  const thursday = day - wd + 4;
  const { year } = dateComponents(thursday);
  const jan1 = dateSerial(year, 1, 1);
  return Math.trunc((thursday - jan1) / 7) + 1;
}

register("DATE", D, "DATE(year, month, day)", "Returns the serial number of a particular date.", [3, 3], (c) => {
  const y = c.int(0), m = c.int(1), d = c.int(2);
  if (y < 0 || y >= 10000) throw FormulaError.num;
  const serial = dateSerial(y, m, d);
  if (serial < 0) throw FormulaError.num;
  return scalar(serial);
});
register("TIME", D, "TIME(hour, minute, second)", "Returns the serial number of a particular time.", [3, 3], (c) => {
  const seconds = c.number(0) * 3600 + c.number(1) * 60 + c.number(2);
  if (seconds < 0) throw FormulaError.num;
  return scalar((seconds / 86400) % 1);
});
register("TODAY", D, "TODAY()", "Returns the serial number of today's date.", [0, 0], (c) => scalar(Math.floor(serialFromDate(c.evaluator.calculator.now))));
register("NOW", D, "NOW()", "Returns the serial number of the current date and time.", [0, 0], (c) => scalar(serialFromDate(c.evaluator.calculator.now)));

const part = (name: string, summary: string, extract: (serial: number) => number) =>
  register(name, D, `${name}(serial_number)`, summary, [1, 1], (c) =>
    c.lift(0, (v) => (v instanceof FormulaError ? v : extract(serialArgument(v)))));
part("YEAR", "Returns the year of a date.", (s) => dateComponents(s).year);
part("MONTH", "Returns the month of a date, from 1 to 12.", (s) => dateComponents(s).month);
part("DAY", "Returns the day of the month, from 1 to 31.", (s) => dateComponents(s).day);
part("HOUR", "Returns the hour of a time, from 0 to 23.", (s) => timeComponents(s).hour);
part("MINUTE", "Returns the minute of a time, from 0 to 59.", (s) => timeComponents(s).minute);
part("SECOND", "Returns the second of a time, from 0 to 59.", (s) => timeComponents(s).second);

register("WEEKDAY", D, "WEEKDAY(serial_number, [return_type])", "Returns the day of the week as a number.", [1, 2], (c) => {
  const serial = serialAt(c, 0);
  const type = c.int(1, 1);
  const day = weekday(serial); // 1 = Sunday
  if (type === 1 || type === 17) return scalar(day);
  if (type === 2 || type === 11) return scalar(((day + 5) % 7) + 1);
  if (type === 3) return scalar((day + 5) % 7);
  if (type >= 12 && type <= 16) return scalar(((day - (type - 10) + 7) % 7) + 1);
  throw FormulaError.num;
});
register("WEEKNUM", D, "WEEKNUM(serial_number, [return_type])", "Returns the week number of a date in the year.", [1, 2], (c) => {
  const serial = serialAt(c, 0);
  const type = c.int(1, 1);
  if (type === 21) return scalar(isoWeek(serial));
  const startDay = type === 2 || type === 11 ? 2 : 1;
  const { year } = dateComponents(serial);
  const jan1 = dateSerial(year, 1, 1);
  const offset = (weekday(jan1) - startDay + 7) % 7;
  return scalar(Math.trunc((Math.floor(serial) - jan1 + offset) / 7) + 1);
});
register("ISOWEEKNUM", D, "ISOWEEKNUM(date)", "Returns the ISO week number of the year.", [1, 1], (c) => scalar(isoWeek(serialAt(c, 0))));
register("EDATE", D, "EDATE(start_date, months)", "Returns the date that is a number of months before or after a date.", [2, 2], (c) =>
  scalar(addMonths(Math.floor(serialAt(c, 0)), c.int(1))));
register("EOMONTH", D, "EOMONTH(start_date, months)", "Returns the last day of the month a number of months away.", [2, 2], (c) => {
  const { year, month } = dateComponents(serialAt(c, 0));
  return scalar(dateSerial(year, month + c.int(1) + 1, 0));
});
register("DATEDIF", D, "DATEDIF(start_date, end_date, unit)", "Calculates the days, months or years between two dates.", [3, 3], (c) => {
  const start = Math.floor(serialAt(c, 0));
  const end = Math.floor(serialAt(c, 1));
  if (end < start) throw FormulaError.num;
  const a = dateComponents(start), b = dateComponents(end);
  let months = (b.year - a.year) * 12 + (b.month - a.month);
  if (b.day < a.day) months--;
  switch (c.text(2).toUpperCase()) {
    case "D": return scalar(end - start);
    case "M": return scalar(months);
    case "Y": return scalar(Math.trunc(months / 12));
    case "YM": return scalar(months % 12);
    case "MD": {
      let days = b.day - a.day;
      if (days < 0) days += daysInMonth(b.month === 1 ? b.year - 1 : b.year, b.month === 1 ? 12 : b.month - 1);
      return scalar(days);
    }
    case "YD": {
      let anniversary = dateSerial(b.year, a.month, a.day);
      if (anniversary > end) anniversary = dateSerial(b.year - 1, a.month, a.day);
      return scalar(end - anniversary);
    }
    default: throw FormulaError.num;
  }
});
register("DAYS", D, "DAYS(end_date, start_date)", "Returns the number of days between two dates.", [2, 2], (c) =>
  scalar(Math.floor(serialAt(c, 0)) - Math.floor(serialAt(c, 1))));
register("DAYS360", D, "DAYS360(start_date, end_date, [method])", "Days between two dates based on a 360-day year.", [2, 3], (c) => {
  const a = dateComponents(serialAt(c, 0)), b = dateComponents(serialAt(c, 1));
  let d1 = a.day, d2 = b.day;
  if (c.bool(2, false)) {
    d1 = Math.min(d1, 30);
    d2 = Math.min(d2, 30);
  } else {
    if (d1 === 31) d1 = 30;
    if (d2 === 31 && d1 >= 30) d2 = 30;
  }
  return scalar((b.year - a.year) * 360 + (b.month - a.month) * 30 + (d2 - d1));
});
const holidays = (c: FunctionCall, index: number): Set<number> => {
  if (c.isMissing(index)) return new Set();
  return new Set(c.flat(index).filter((v): v is number => typeof v === "number").map(Math.trunc));
};
const isWorkday = (day: number, skip: Set<number>) => {
  const wd = weekday(day);
  return wd !== 1 && wd !== 7 && !skip.has(day);
};
register("NETWORKDAYS", D, "NETWORKDAYS(start_date, end_date, [holidays])", "Returns the number of whole workdays between two dates.", [2, 3], (c) => {
  const a = Math.trunc(serialAt(c, 0)), b = Math.trunc(serialAt(c, 1));
  const skip = holidays(c, 2);
  const low = Math.min(a, b), high = Math.max(a, b);
  if (high - low + 1 >= 1_000_000) throw FormulaError.num;
  let count = 0;
  for (let day = low; day <= high; day++) if (isWorkday(day, skip)) count++;
  return scalar(a <= b ? count : -count);
});
register("WORKDAY", D, "WORKDAY(start_date, days, [holidays])", "Returns the date a number of workdays away.", [2, 3], (c) => {
  let day = Math.trunc(serialAt(c, 0));
  let remaining = c.int(1);
  const skip = holidays(c, 2);
  const step = remaining >= 0 ? 1 : -1;
  if (Math.abs(remaining) >= 1_000_000) throw FormulaError.num;
  while (remaining !== 0) {
    day += step;
    if (isWorkday(day, skip)) remaining -= step;
  }
  return scalar(day);
});
register("DATEVALUE", D, "DATEVALUE(date_text)", "Converts a date in the form of text to a serial number.", [1, 1], (c) => {
  const n = parseEntry(c.text(0)).value;
  if (typeof n !== "number") throw FormulaError.value;
  return scalar(Math.floor(n));
});
register("TIMEVALUE", D, "TIMEVALUE(time_text)", "Converts a time in the form of text to a serial number.", [1, 1], (c) => {
  const n = parseEntry(c.text(0)).value;
  if (typeof n !== "number") throw FormulaError.value;
  return scalar(n - Math.floor(n));
});
register("YEARFRAC", D, "YEARFRAC(start_date, end_date, [basis])", "Returns the fraction of the year between two dates.", [2, 3], (c) => {
  let a = Math.floor(serialAt(c, 0));
  let b = Math.floor(serialAt(c, 1));
  if (a > b) [a, b] = [b, a];
  const basis = c.int(2, 0);
  const p = dateComponents(a), q = dateComponents(b);
  switch (basis) {
    case 0: {
      let d1 = p.day, d2 = q.day;
      if (d1 === 31) d1 = 30;
      if (d2 === 31 && d1 === 30) d2 = 30;
      return scalar(((q.year - p.year) * 360 + (q.month - p.month) * 30 + (d2 - d1)) / 360);
    }
    case 1: {
      let total = 0;
      for (let y = p.year; y <= q.year; y++) total += isLeapYear(y) ? 366 : 365;
      return scalar((b - a) / (total / (q.year - p.year + 1)));
    }
    case 2: return scalar((b - a) / 360);
    case 3: return scalar((b - a) / 365);
    case 4: {
      const d1 = Math.min(p.day, 30), d2 = Math.min(q.day, 30);
      return scalar(((q.year - p.year) * 360 + (q.month - p.month) * 30 + (d2 - d1)) / 360);
    }
    default: throw FormulaError.num;
  }
});
