import { FormulaError, type CellValue } from "../model/values";
import { MONTH_NAMES, dateComponents, dateSerial, daysInMonth, serialFromDate } from "./dateSerial";

/**
 * Interprets what a user types into a cell: numbers, percentages, currency,
 * dates, times, booleans and errors. Suggests a number format when the entry
 * implies one (typing "12%" formats the cell as a percentage).
 */
export interface ParsedEntry {
  value: CellValue;
  format?: string;
}

const isDigit = (ch: string) => ch >= "0" && ch <= "9";
const allDigits = (s: string) => s.length > 0 && [...s].every(isDigit);
const trimSpaces = (s: string) => s.replace(/^[ \t\u00A0]+|[ \t\u00A0]+$/g, "");

export function parseEntry(raw: string): ParsedEntry {
  const text = trimSpaces(raw);
  if (!text) return { value: raw === "" ? null : raw };
  const upper = text.toUpperCase();
  if (upper === "TRUE") return { value: true };
  if (upper === "FALSE") return { value: false };
  if (text.startsWith("#")) {
    const error = FormulaError.fromCode(text);
    if (error) return { value: error };
  }
  return parseNumber(text) ?? parseDateTime(text) ?? { value: raw };
}

/** A number from text, including dates, times, percentages and currency. */
export function numberFromText(text: string): number | null {
  const trimmed = trimSpaces(text);
  if (!trimmed) return null;
  const parsed = parseNumber(trimmed) ?? parseDateTime(trimmed);
  return parsed && typeof parsed.value === "number" ? parsed.value : null;
}

// MARK: - Numbers

const CURRENCY_SYMBOLS = ["$", "€", "£", "¥"];

function parseNumber(input: string): ParsedEntry | null {
  let s = input;
  let negative = false;
  let currency: string | undefined;
  let percent = false;

  if (s.startsWith("(") && s.endsWith(")")) {
    negative = true;
    s = s.slice(1, -1);
  }
  if (s.startsWith("-")) { negative = !negative; s = s.slice(1); } else if (s.startsWith("+")) s = s.slice(1);
  if (s && CURRENCY_SYMBOLS.includes(s[0])) {
    currency = s[0];
    s = s.slice(1);
    if (s.startsWith("-")) { negative = !negative; s = s.slice(1); }
  }
  if (s && CURRENCY_SYMBOLS.includes(s[s.length - 1]) && !currency) {
    currency = s[s.length - 1];
    s = s.slice(0, -1);
  }
  s = trimSpaces(s);
  if (s.endsWith("%")) {
    percent = true;
    s = trimSpaces(s.slice(0, -1));
  }
  if (!s || !(isDigit(s[0]) || s[0] === ".")) return null;

  // Mixed fraction: "1 1/2" or "0 3/4".
  const space = s.indexOf(" ");
  if (!percent && !currency && space >= 0) {
    const whole = s.slice(0, space), fraction = s.slice(space + 1);
    const parts = fraction.split("/").filter((p) => p !== "");
    const w = Number(whole), n = Number(parts[0]), d = Number(parts[1]);
    if (allDigits(whole) && parts.length === 2 && /^[\d.]+$/.test(parts[0]) && /^[\d.]+$/.test(parts[1]) && !Number.isNaN(n) && !Number.isNaN(d) && d !== 0) {
      return { value: (w + n / d) * (negative ? -1 : 1), format: d < 10 ? "# ?/?" : "# ??/??" };
    }
    return null;
  }

  // Thousands separators must be in valid positions.
  let hasGrouping = false;
  if (s.includes(",")) {
    const integerPart = s.split(".")[0];
    const groups = integerPart.split(",");
    if (!(groups.length > 1 && groups[0].length >= 1 && groups[0].length <= 3 && groups.slice(1).every((g) => g.length === 3))) return null;
    hasGrouping = true;
    s = s.replace(/,/g, "");
  }
  if (![...s].every((ch) => isDigit(ch) || ch === "." || ch === "e" || ch === "E" || ch === "+" || ch === "-")) return null;
  if (!(isDigit(s[0]) || s[0] === ".")) return null;
  // Swift's Double() is strict: one number, nothing trailing.
  if (!/^(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(s)) return null;
  let value = Number(s);
  if (Number.isNaN(value)) return null;
  if (negative) value = -value;
  const lower = s.toLowerCase();
  const pieces = s.split(".").filter((p) => p !== "");
  const decimals = s.split(".").length > 1 && pieces.length > 1 && !lower.includes("e") ? pieces[1].length : 0;

  let format: string | undefined;
  if (percent) {
    value /= 100;
    format = decimals > 0 ? "0." + "0".repeat(Math.min(decimals, 10)) + "%" : "0%";
  } else if (currency) {
    format = decimals > 0 ? `${currency}#,##0.00` : `${currency}#,##0`;
    if (currency !== "$") format = decimals > 0 ? `#,##0.00 ${currency}` : `#,##0 ${currency}`;
    if (currency === "£" || currency === "¥") format = decimals > 0 ? `${currency}#,##0.00` : `${currency}#,##0`;
  } else if (hasGrouping) {
    format = decimals > 0 ? "#,##0." + "0".repeat(Math.min(decimals, 10)) : "#,##0";
  } else if (lower.includes("e")) {
    format = "0.00E+00";
  }
  return { value, format };
}

// MARK: - Dates and times

const MONTH_LOOKUP: Record<string, number> = (() => {
  const map: Record<string, number> = {};
  MONTH_NAMES.forEach((name, i) => {
    map[name.toLowerCase()] = i + 1;
    map[name.toLowerCase().slice(0, 3)] = i + 1;
  });
  map.sept = 9;
  return map;
})();

const currentYear = () => dateComponents(serialFromDate(new Date())).year;

function parseDateTime(input: string): ParsedEntry | null {
  const text = trimSpaces(input);
  let datePart = text;
  let time: [number, string] | null = null;
  const onlyTime = parseTime(text);
  if (onlyTime) return { value: onlyTime[0], format: onlyTime[1] };
  const space = text.lastIndexOf(" ");
  if (space >= 0) {
    const tail = text.slice(space + 1);
    let head = text.slice(0, space);
    let timeText = tail;
    const second = head.lastIndexOf(" ");
    if (["AM", "PM", "A", "P"].includes(tail.toUpperCase()) && second >= 0) {
      timeText = head.slice(second + 1) + " " + tail;
      head = head.slice(0, second);
    }
    const t = parseTime(timeText);
    if (t) {
      time = t;
      datePart = head;
    }
  }
  const tIndex = text.indexOf("T");
  if (tIndex >= 0 && [...text].length > 11) {
    const parsedTime = parseTime(text.slice(tIndex + 1));
    if (parsedTime) {
      time = parsedTime;
      datePart = text.slice(0, tIndex);
    }
  }
  const date = parseDate(datePart);
  if (!date) return null;
  if (time) return { value: date[0] + time[0], format: date[1] + " " + time[1] };
  return { value: date[0], format: date[1] };
}

function parseTime(text: string): [number, string] | null {
  let s = trimSpaces(text).toUpperCase();
  let meridiem: "AM" | "PM" | undefined;
  for (const suffix of ["AM", "PM", "A", "P"]) {
    if (s.endsWith(suffix)) {
      meridiem = suffix.startsWith("A") ? "AM" : "PM";
      s = trimSpaces(s.slice(0, -suffix.length));
      break;
    }
  }
  const parts = s.split(":");
  const numeric = (p: string) => p.length > 0 && [...p].every((c) => isDigit(c) || c === ".") && !Number.isNaN(Number(p));
  const ok = parts.length >= 2 && (parts.length <= 3 || (meridiem === undefined && parts.length === 1)) && parts.every(numeric);
  if (!ok || !(Number(parts[1]) < 60)) {
    // "3 PM"
    if (meridiem && /^\d+$/.test(s)) {
      const hour = Number(s);
      if (hour >= 1 && hour <= 12) return [((hour % 12) + (meridiem === "PM" ? 12 : 0)) / 24, "h:mm AM/PM"];
    }
    return null;
  }
  let hour = Number(parts[0]);
  const minute = Number(parts[1]);
  const second = parts.length === 3 ? Number(parts[2]) || 0 : 0;
  if (second >= 60) return null;
  if (meridiem) {
    if (hour < 1 || hour > 12) return null;
    hour = (hour % 12) + (meridiem === "PM" ? 12 : 0);
  }
  const total = (hour * 3600 + minute * 60 + second) / 86400;
  let format: string;
  if (meridiem) format = parts.length === 3 ? "h:mm:ss AM/PM" : "h:mm AM/PM";
  else if (hour >= 24) format = parts.length === 3 ? "[h]:mm:ss" : "[h]:mm";
  else format = parts.length === 3 ? "h:mm:ss" : "h:mm";
  return [total, format];
}

function parseDate(text: string): [number, string] | null {
  const s = trimSpaces(text).replace(/,/g, "");
  const valid = (y: number, m: number, d: number) => m >= 1 && m <= 12 && d >= 1 && y >= 1900 && y <= 9999 && d <= daysInMonth(y, m);
  const expandYear = (y: number, digits: number) => (digits <= 2 ? (y < 30 ? 2000 + y : 1900 + y) : y);

  // Numeric: 2024-01-15, 2024/1/15, 1/15/2024, 1/15/24, 1/15, 15.01.2024
  for (const separator of ["-", "/", "."]) {
    if (!s.includes(separator)) continue;
    const parts = s.split(separator);
    if (parts.every(allDigits)) {
      const n = parts.map(Number);
      if (parts.length === 3) {
        if (parts[0].length === 4) {
          if (!valid(n[0], n[1], n[2])) return null;
          return [dateSerial(n[0], n[1], n[2]), separator === "-" ? "yyyy-mm-dd" : "yyyy/m/d"];
        }
        if (separator === ".") {
          const y = expandYear(n[2], parts[2].length);
          if (!valid(y, n[1], n[0])) return null;
          return [dateSerial(y, n[1], n[0]), "d.m.yyyy"];
        }
        const y = expandYear(n[2], parts[2].length);
        if (parts[2].length !== 2 && parts[2].length !== 4) return null;
        if (valid(y, n[0], n[1])) return [dateSerial(y, n[0], n[1]), parts[2].length === 2 ? "m/d/yy" : "m/d/yyyy"];
        if (valid(y, n[1], n[0])) return [dateSerial(y, n[1], n[0]), "d/m/yyyy"];
        return null;
      }
      if (parts.length === 2 && separator === "/") {
        // m/d in the current year, or m/yyyy.
        if (parts[1].length === 4 && n[0] >= 1 && n[0] <= 12 && valid(n[1], n[0], 1)) return [dateSerial(n[1], n[0], 1), "mmm-yy"];
        const y = currentYear();
        if (valid(y, n[0], n[1])) return [dateSerial(y, n[0], n[1]), "d-mmm"];
      }
      return null;
    }
  }

  // Textual: 15-Jan-2024, 15 Jan 2024, Jan 15 2024, January 15, 15-Jan, Jan-24
  const tokens = s.split(/[ \-/]+/).filter((t) => t !== "");
  if (tokens.length < 2 || tokens.length > 3) return null;
  let month: number | undefined;
  const numbers: [number, number][] = [];
  let monthFirst = false;
  for (let i = 0; i < tokens.length; i++) {
    const token = tokens[i];
    const m = MONTH_LOOKUP[token.toLowerCase().replace(/^\.+|\.+$/g, "")];
    if (m) {
      if (month !== undefined) return null;
      month = m;
      monthFirst = i === 0;
      continue;
    }
    const stripped = token.toLowerCase().replace(/st|nd|rd|th/g, "");
    if (/^[+-]?\d+$/.test(stripped)) numbers.push([Number(stripped), token.length]);
    else return null;
  }
  if (month === undefined) return null;
  if (numbers.length === 1) {
    const [n, digits] = numbers[0];
    if (digits === 4 || (monthFirst && n > 31)) {
      const y = expandYear(n, digits);
      if (!valid(y, month, 1)) return null;
      return [dateSerial(y, month, 1), "mmm-yy"];
    }
    const y = currentYear();
    if (!valid(y, month, n)) {
      // "Jan-24" means January 2024.
      const year = expandYear(n, digits);
      if (!valid(year, month, 1)) return null;
      return [dateSerial(year, month, 1), "mmm-yy"];
    }
    return [dateSerial(y, month, n), "d-mmm"];
  }
  if (numbers.length === 2) {
    const [a] = numbers[0], [b, bDigits] = numbers[1];
    const y = expandYear(b, bDigits);
    if (!valid(y, month, a)) return null;
    return [dateSerial(y, month, a), monthFirst ? "mmmm d, yyyy" : "d-mmm-yy"];
  }
  return null;
}
