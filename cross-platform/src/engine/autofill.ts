import type { CellValue } from "../model/values";
import { isPlainStyle, numberFormatOf, type Cell, type CellStyle } from "../model/workbook";
import { addMonths, dateComponents, DAY_NAMES, MONTH_NAMES } from "../formula/dateSerial";
import { isDateFormat, isTimeFormat } from "../formula/numberFormat";
import { shiftFormula } from "../formula/rewriter";
import { Statistics } from "../formula/functions/shared";

/**
 * Extends a pattern of cells the way Excel's fill handle does: number and date
 * series, "Item 1, Item 2…", weekday and month names, and formulas with
 * relative references shifted. Returns cells for `count` new positions after
 * (or before, when `reverse`) the source cells.
 */
export function extendFill(source: (Cell | undefined)[], styles: CellStyle[], count: number, reverse: boolean, step: [number, number], copyOnly: boolean): (Cell | undefined)[] {
  if (!source.length || count <= 0) return [];
  const n = source.length;
  const series = copyOnly ? null : detectSeries(source, styles);
  const result: (Cell | undefined)[] = [];
  for (let k = 1; k <= count; k++) {
    // Position relative to the source start (negative when filling up/left).
    const position = reverse ? -k : n - 1 + k;
    const sourceIndex = ((position % n) + n) % n;
    let cell = source[sourceIndex] ? { ...source[sourceIndex]! } : undefined;
    const style = styles[sourceIndex];
    if (cell?.formula !== undefined) {
      const distance = position - sourceIndex;
      cell.formula = shiftFormula(cell.formula, distance * step[0], distance * step[1]);
    } else if (series) {
      cell = { ...(cell ?? { value: null }), value: series(position) };
    }
    if (cell || !isPlainStyle(style)) {
      const filled: Cell = { ...(cell ?? { value: null }) };
      filled.style = isPlainStyle(style) ? undefined : style;
      result.push(filled);
    } else {
      result.push(undefined);
    }
  }
  return result;
}

/** A function from position (0 = first source cell) to value, if the source forms a series. */
function detectSeries(source: (Cell | undefined)[], styles: CellStyle[]): ((position: number) => CellValue) | null {
  if (source.some((c) => c?.formula !== undefined)) return null;
  const values = source.map((c) => c?.value ?? null);

  // Numbers (and dates).
  const numbers = values.filter((v): v is number => typeof v === "number");
  if (numbers.length === values.length) {
    const format = styles[0] ? numberFormatOf(styles[0]) : "General";
    const isDate = isDateFormat(format) && !isTimeFormat(format);
    if (numbers.length === 1) return isDate ? (p) => numbers[0] + p : null;
    if (isDate) {
      // Same day of month, different months → monthly steps.
      const parts = numbers.map(dateComponents);
      const months = parts.map((p) => p.year * 12 + p.month);
      const monthStep = months[1] - months[0];
      if (parts.every((p) => p.day === parts[0].day) && monthStep !== 0 && months.every((m, i) => i === 0 || m - months[i - 1] === monthStep)) {
        return (p) => addMonths(numbers[0], p * monthStep);
      }
    }
    // Least-squares linear trend, as Excel does.
    let fit: { slope: number; intercept: number };
    try {
      fit = Statistics.regression(numbers, numbers.map((_, i) => i));
    } catch {
      return null;
    }
    return (p) => Math.round((fit.intercept + fit.slope * p) * 1e10) / 1e10;
  }

  // Weekday and month names.
  const texts = values.filter((v): v is string => typeof v === "string");
  if (texts.length === values.length) {
    for (const [names, cycle] of [[DAY_NAMES, 7], [MONTH_NAMES, 12]] as const) {
      const full = names.map((n) => n.toLowerCase());
      const short = names.map((n) => n.slice(0, 3).toLowerCase());
      const indices = texts.map((t): [number, boolean] | null => {
        const lower = t.toLowerCase();
        if (full.includes(lower)) return [full.indexOf(lower), false];
        if (short.includes(lower)) return [short.indexOf(lower), true];
        return null;
      });
      if (indices.every((i) => i !== null)) {
        const first = indices[0]!;
        const step = indices.length > 1 ? (((indices[1]![0] - first[0]) % cycle) + cycle) % cycle : 1;
        const uppercase = texts[0] === texts[0].toUpperCase();
        const lowercase = texts[0] === texts[0].toLowerCase();
        return (p) => {
          const index = (((first[0] + p * Math.max(step, 1)) % cycle) + cycle) % cycle;
          let name = first[1] ? names[index].slice(0, 3) : names[index];
          if (uppercase) name = name.toUpperCase();
          else if (lowercase) name = name.toLowerCase();
          return name;
        };
      }
    }
  }

  // Text ending (or starting) in a number: "Item 1", "Q1", "1st".
  const pieces = values.map((v) => (typeof v === "string" ? splitTrailingNumber(v) : null));
  const first = pieces[0];
  if (first && pieces.every((p) => p && p.prefix === first.prefix && p.suffix === first.suffix)) {
    const step = pieces.length > 1 ? pieces[1]!.number - first.number : 1;
    return (p) => {
      const n = first.number + p * step;
      let digits = String(Math.abs(n));
      if (digits.length < first.width) digits = "0".repeat(first.width - digits.length) + digits;
      return first.prefix + (n < 0 ? "-" : "") + digits + first.suffix;
    };
  }
  return null;
}

function splitTrailingNumber(s: string): { prefix: string; number: number; width: number; suffix: string } | null {
  const chars = [...s];
  let lastDigit = -1;
  for (let i = chars.length - 1; i >= 0; i--) if (/\d/.test(chars[i])) { lastDigit = i; break; }
  if (lastDigit < 0) return null;
  let firstDigit = lastDigit;
  while (firstDigit > 0 && /\d/.test(chars[firstDigit - 1])) firstDigit--;
  const digits = chars.slice(firstDigit, lastDigit + 1).join("");
  if (digits.length > 9) return null;
  const suffix = chars.slice(lastDigit + 1).join("");
  // Only short suffixes like "st"/"th" count, otherwise it's just text.
  if ([...suffix].length > 3) return null;
  return { prefix: chars.slice(0, firstDigit).join(""), number: Number(digits), width: digits.startsWith("0") ? digits.length : 1, suffix };
}
