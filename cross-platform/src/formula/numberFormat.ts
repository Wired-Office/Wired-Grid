import { FormulaError, type CellValue } from "../model/values";
import type { Color } from "../model/workbook";
import { DAY_NAMES, MONTH_NAMES, dateComponents, weekday } from "./dateSerial";

/** The result of applying a number format. */
export interface FormattedValue {
  text: string;
  color?: Color;
  /** For formats with a `*` fill (Accounting): text before and after the fill point. */
  fillSplit?: [string, string];
  fillCharacter?: string;
}

// MARK: - Numbers as text

type RoundingMode = "nearest" | "awayFromZero" | "towardZero" | "down" | "up";

function roundWith(x: number, mode: RoundingMode): number {
  switch (mode) {
    case "nearest": return Math.sign(x) * Math.round(Math.abs(x));
    case "awayFromZero": return Math.sign(x) * Math.ceil(Math.abs(x));
    case "towardZero": return Math.trunc(x);
    case "down": return Math.floor(x);
    case "up": return Math.ceil(x);
  }
}

/** Excel-style rounding: half away from zero, after trimming binary noise to 15 digits. */
export function excelRound(x: number, digits: number, mode: RoundingMode = "nearest"): number {
  const factor = Math.pow(10, digits);
  let scaled = x * factor;
  const cleaned = Number(scaled.toPrecision(15));
  if (Number.isFinite(cleaned)) scaled = cleaned;
  const result = roundWith(scaled, mode) / factor;
  return result === 0 ? 0 : result;
}

/** Like C's "%.{places}f", also for numbers too large for `toFixed`. */
export function toFixed(x: number, places: number): string {
  const p = Math.max(0, Math.min(places, 100));
  if (Math.abs(x) < 1e21) return x.toFixed(p);
  const integer = BigInt(Math.round(x)).toString();
  return p > 0 ? integer + "." + "0".repeat(p) : integer;
}

/** Like C's "%.{places}E": "1.23E+05". */
export function toExponential(x: number, places: number): string {
  const s = x.toExponential(Math.max(0, Math.min(places, 100)));
  const [mantissa, exponent] = s.split("e");
  const sign = exponent.startsWith("-") ? "-" : "+";
  const digits = exponent.replace(/^[+-]/, "");
  return mantissa + "E" + sign + (digits.length < 2 ? "0" + digits : digits);
}

function trimZeros(s: string): string {
  if (!s.includes(".")) return s;
  return s.replace(/0+$/, "").replace(/\.$/, "");
}

export const GENERAL = "General";

/** Excel's General format: up to `maxLength` characters, switching to scientific when needed. */
export function general(value: number, maxLength = 11): string {
  if (value === 0) return "0";
  if (!Number.isFinite(value)) return FormulaError.num.code;
  const magnitude = Math.abs(value);
  if ((magnitude >= 1e-9 && magnitude < 1e11) || (maxLength > 11 && magnitude < 1e15 && magnitude >= 1e-9)) {
    if (value === Math.round(value) && magnitude < 1e15) {
      const s = String(value);
      if (s.length <= maxLength) return s;
    }
    const integerDigits = magnitude >= 1 ? Math.floor(Math.log10(magnitude)) + 1 : 1;
    let decimals = Math.max(0, Math.min(15 - integerDigits, 14));
    while (decimals >= 0) {
      const s = trimZeros(toFixed(value, decimals));
      if (s.length <= maxLength && s !== "0" && s !== "-0") return s;
      decimals--;
    }
  }
  let decimals = 5;
  while (decimals >= 0) {
    let s = toExponential(value, decimals);
    const e = s.indexOf("E");
    if (e >= 0) s = trimZeros(s.slice(0, e)) + s.slice(e);
    if (s.length <= Math.max(maxLength, 7)) return s;
    decimals--;
  }
  return toExponential(value, 0);
}

/** Plain text used for sorting, filtering, TSV export and comparisons. */
export function plainText(v: CellValue): string {
  if (v === null) return "";
  if (typeof v === "number") return general(v);
  if (typeof v === "string") return v;
  if (typeof v === "boolean") return v ? "TRUE" : "FALSE";
  return v.code;
}

// MARK: - Presets

export const FORMATS = {
  general: GENERAL,
  number: "#,##0.00",
  currency: "$#,##0.00",
  accounting: '_($* #,##0.00_);_($* (#,##0.00);_($* "-"??_);_(@_)',
  shortDate: "m/d/yyyy",
  longDate: "dddd, mmmm d, yyyy",
  time: "h:mm:ss AM/PM",
  percent: "0.00%",
  fraction: "# ?/?",
  scientific: "0.00E+00",
  text: "@",
};

// MARK: - Parsing

type Token =
  | { k: "literal"; s: string }
  | { k: "digit"; ch: "0" | "#" | "?" }
  | { k: "decimalPoint" }
  | { k: "comma" }
  | { k: "percent" }
  | { k: "exponent"; s: string }
  | { k: "slash" }
  | { k: "text" }
  | { k: "skip"; ch: string }
  | { k: "fill"; ch: string }
  | { k: "general" }
  | { k: "date"; s: string };

interface Section {
  tokens: Token[];
  color?: Color;
  condition?: (n: number) => boolean;
  elapsed: boolean;
}

const has = (s: Section, k: Token["k"]) => s.tokens.some((t) => t.k === k);
const hasText = (s: Section) => has(s, "text");
const isGeneralSection = (s: Section) => has(s, "general");
const isDateSection = (s: Section) => has(s, "date");
const hasDigits = (s: Section) => has(s, "digit");
const isTextOnly = (s: Section) => hasText(s) && !hasDigits(s) && !isGeneralSection(s) && !isDateSection(s);

const cache = new Map<string, Section[]>();

function parsed(code: string): Section[] {
  let sections = cache.get(code);
  if (!sections) {
    sections = parse(code);
    if (cache.size > 500) cache.clear();
    cache.set(code, sections);
  }
  return sections;
}

const COLOR_NAMES: Record<string, Color> = {
  BLACK: "#000000", WHITE: "#FFFFFF", RED: "#FF0000", GREEN: "#00A000", BLUE: "#0000FF", YELLOW: "#C8A000", MAGENTA: "#FF00FF", CYAN: "#00A0C0",
};
const INDEXED_COLORS = ["#000000", "#FFFFFF", "#FF0000", "#00FF00", "#0000FF", "#FFFF00", "#FF00FF", "#00FFFF"];

function parse(code: string): Section[] {
  if (code === "" || code.toLowerCase() === "general") return [{ tokens: [{ k: "general" }], elapsed: false }];
  const sections: Section[] = [];
  let section: Section = { tokens: [], elapsed: false };
  const chars = [...code];
  let i = 0;
  let literal = "";
  const flush = () => {
    if (literal) {
      section.tokens.push({ k: "literal", s: literal });
      literal = "";
    }
  };

  while (i < chars.length) {
    const ch = chars[i];
    const lower = ch.toLowerCase();
    switch (ch) {
      case ";":
        flush();
        sections.push(section);
        section = { tokens: [], elapsed: false };
        i++;
        break;
      case '"':
        i++;
        while (i < chars.length && chars[i] !== '"') literal += chars[i++];
        i++;
        break;
      case "\\":
        if (i + 1 < chars.length) literal += chars[i + 1];
        i += 2;
        break;
      case "_":
        flush();
        if (i + 1 < chars.length) section.tokens.push({ k: "skip", ch: chars[i + 1] });
        i += 2;
        break;
      case "*":
        flush();
        if (i + 1 < chars.length) section.tokens.push({ k: "fill", ch: chars[i + 1] });
        i += 2;
        break;
      case "[": {
        let content = "";
        i++;
        while (i < chars.length && chars[i] !== "]") content += chars[i++];
        i++;
        const upper = content.toUpperCase();
        const indexed = /^COLOR(\d+)$/.exec(upper);
        if (COLOR_NAMES[upper]) {
          section.color = COLOR_NAMES[upper];
        } else if (indexed) {
          section.color = INDEXED_COLORS[Math.max(0, Math.min(7, Number(indexed[1]) - 1))];
        } else if (content.startsWith("$")) {
          flush();
          section.tokens.push({ k: "literal", s: content.slice(1).split("-")[0] ?? "" });
        } else if (upper.length > 0 && "HMS".includes(upper[0]) && [...upper].every((c) => c === upper[0])) {
          flush();
          section.elapsed = true;
          section.tokens.push({ k: "date", s: "[" + upper.toLowerCase() + "]" });
        } else {
          const condition = parseCondition(content);
          if (condition) section.condition = condition;
        }
        break;
      }
      case "0":
      case "#":
      case "?":
        flush();
        section.tokens.push({ k: "digit", ch });
        i++;
        break;
      case ".":
        flush();
        // A decimal point in a time format means fractional seconds.
        if (isDateSection(section) && i + 1 < chars.length && chars[i + 1] === "0") {
          let zeros = "";
          i++;
          while (i < chars.length && chars[i] === "0") { zeros += "0"; i++; }
          section.tokens.push({ k: "date", s: "." + zeros });
        } else {
          section.tokens.push({ k: "decimalPoint" });
          i++;
        }
        break;
      case ",":
        flush();
        section.tokens.push({ k: "comma" });
        i++;
        break;
      case "%":
        flush();
        section.tokens.push({ k: "percent" });
        i++;
        break;
      case "/":
        flush();
        section.tokens.push(isDateSection(section) ? { k: "literal", s: "/" } : { k: "slash" });
        i++;
        break;
      case "@":
        flush();
        section.tokens.push({ k: "text" });
        i++;
        break;
      case "E":
      case "e":
        if (i + 1 < chars.length && (chars[i + 1] === "+" || chars[i + 1] === "-")) {
          flush();
          section.tokens.push({ k: "exponent", s: "E" + chars[i + 1] });
          i += 2;
        } else {
          literal += ch;
          i++;
        }
        break;
      case "G":
      case "g":
        if (chars.slice(i, i + 7).join("").toLowerCase() === "general") {
          flush();
          section.tokens.push({ k: "general" });
          i += 7;
        } else {
          literal += ch;
          i++;
        }
        break;
      case "A":
      case "a": {
        const rest = chars.slice(i, i + 5).join("").toUpperCase();
        if (rest.startsWith("AM/PM")) {
          flush();
          section.tokens.push({ k: "date", s: "AM/PM" });
          i += 5;
        } else if (rest.startsWith("A/P")) {
          flush();
          section.tokens.push({ k: "date", s: "A/P" });
          i += 3;
        } else {
          literal += ch;
          i++;
        }
        break;
      }
      default:
        if ("ymdhs".includes(lower) && lower.length === 1) {
          flush();
          let run = lower;
          i++;
          while (i < chars.length && chars[i].toLowerCase() === lower) { run += lower; i++; }
          section.tokens.push({ k: "date", s: run });
        } else {
          literal += ch;
          i++;
        }
    }
  }
  flush();
  sections.push(section);
  return sections.map(resolveMinutes);
}

/** "m" after an hour or before a second means minutes, not months. */
function resolveMinutes(section: Section): Section {
  const tokens = [...section.tokens];
  const dateIndices = tokens.map((t, i) => (t.k === "date" ? i : -1)).filter((i) => i >= 0);
  dateIndices.forEach((index, position) => {
    const token = tokens[index] as { k: "date"; s: string };
    if (token.s[0] !== "m" || token.s.length > 2) return;
    const previous = position > 0 ? (tokens[dateIndices[position - 1]] as { s: string }).s : undefined;
    const next = position + 1 < dateIndices.length ? (tokens[dateIndices[position + 1]] as { s: string }).s : undefined;
    if (previous?.[0] === "h" || previous?.startsWith("[h") || next?.[0] === "s") {
      tokens[index] = { k: "date", s: token.s === "m" ? "n" : "nn" };
    }
  });
  return { ...section, tokens };
}

function parseCondition(content: string): ((n: number) => boolean) | undefined {
  for (const op of [">=", "<=", "<>", "=", ">", "<"]) {
    if (!content.startsWith(op)) continue;
    const rest = content.slice(op.length).trim();
    const limit = rest === "" ? NaN : Number(rest);
    if (Number.isNaN(limit)) return undefined;
    switch (op) {
      case ">=": return (n) => n >= limit;
      case "<=": return (n) => n <= limit;
      case "<>": return (n) => n !== limit;
      case "=": return (n) => n === limit;
      case ">": return (n) => n > limit;
      default: return (n) => n < limit;
    }
  }
  return undefined;
}

// MARK: - Formatting

export function formatValue(value: CellValue, code: string): FormattedValue {
  if (value === null) return { text: "" };
  if (typeof value === "boolean") return { text: value ? "TRUE" : "FALSE" };
  if (value instanceof FormulaError) return { text: value.code };
  if (typeof value === "string") {
    const sections = parsed(code);
    const textSection = sections.length >= 4 ? sections[3] : sections.find(hasText);
    return textSection ? renderText(textSection, value) : { text: value };
  }
  return formatNumber(value, code);
}

export function formatNumber(n: number, code: string): FormattedValue {
  const sections = parsed(code);
  if (!sections.length) return { text: general(n) };
  let section: Section;
  let value = n;
  let autoMinus = false;
  // Explicit conditions such as [>=100] pick their own sections.
  if (sections.some((s) => s.condition)) {
    section = sections.find((s) => s.condition?.(n)) ?? sections.find((s) => !s.condition && !isTextOnly(s)) ?? sections[0];
    value = Math.abs(n);
    autoMinus = n < 0;
  } else {
    const numeric = sections.filter((s) => !isTextOnly(s));
    switch (numeric.length) {
      case 0:
        return { text: general(n) };
      case 1:
        section = numeric[0];
        autoMinus = n < 0;
        value = Math.abs(n);
        break;
      case 2:
        section = n < 0 ? numeric[1] : numeric[0];
        value = Math.abs(n);
        break;
      default:
        section = n < 0 ? numeric[1] : n === 0 ? numeric[2] : numeric[0];
        value = Math.abs(n);
    }
  }
  const result = renderNumber(section, value);
  if (autoMinus && !isDateSection(section) && (/[1-9]/.test(result.text) || (isGeneralSection(section) && n !== 0))) {
    result.text = "-" + result.text;
    if (result.fillSplit) result.fillSplit = ["-" + result.fillSplit[0], result.fillSplit[1]];
  }
  return result;
}

function withFill(out: string, color: Color | undefined, fill: [string, string] | undefined): FormattedValue {
  const result: FormattedValue = { text: out, color };
  if (fill) {
    result.fillSplit = [fill[0], out.slice(fill[0].length)];
    result.fillCharacter = fill[1];
  }
  return result;
}

function renderText(section: Section, text: string): FormattedValue {
  let out = "";
  let fill: [string, string] | undefined;
  for (const t of section.tokens) {
    if (t.k === "literal") out += t.s;
    else if (t.k === "text") out += text;
    else if (t.k === "skip") out += " ";
    else if (t.k === "fill") fill = [out, t.ch];
  }
  return withFill(out, section.color, fill);
}

function renderNumber(section: Section, number: number): FormattedValue {
  if (isDateSection(section)) return renderDate(section, number);
  if (isGeneralSection(section) && !hasDigits(section)) {
    let out = "";
    for (const t of section.tokens) {
      if (t.k === "general") out += general(number);
      else if (t.k === "literal") out += t.s;
      else if (t.k === "skip") out += " ";
    }
    return { text: out, color: section.color };
  }

  const tokens = section.tokens;
  const find = (k: Token["k"]) => {
    const i = tokens.findIndex((t) => t.k === k);
    return i < 0 ? undefined : i;
  };
  const decimalIndex = find("decimalPoint");
  const exponentIndex = find("exponent");
  const slashIndex = find("slash");
  const percentCount = tokens.filter((t) => t.k === "percent").length;
  const digitIndices = tokens.map((t, i) => (t.k === "digit" ? i : -1)).filter((i) => i >= 0);

  let value = number * Math.pow(100, percentCount);

  if (slashIndex !== undefined && digitIndices.length) return renderFraction(section, value, slashIndex);

  const integerEnd = decimalIndex ?? exponentIndex ?? tokens.length;
  const integerDigitIndices = digitIndices.filter((i) => i < integerEnd);
  const fractionDigitIndices = digitIndices.filter((i) => i > (decimalIndex ?? Infinity) && i < (exponentIndex ?? Infinity));
  const exponentDigitIndices = digitIndices.filter((i) => i > (exponentIndex ?? Infinity));
  const digitKind = (i: number) => (tokens[i] as { ch: string }).ch;

  // Commas: between integer digits → grouping; right after the last integer digit → scale by 1000.
  let grouping = false;
  let scaleCount = 0;
  const lastIntegerDigit = integerDigitIndices[integerDigitIndices.length - 1];
  if (lastIntegerDigit !== undefined) {
    for (let index = 0; index < integerEnd; index++) {
      if (tokens[index].k !== "comma") continue;
      if (index < lastIntegerDigit && index > integerDigitIndices[0]) grouping = true;
      else if (index > lastIntegerDigit) scaleCount++;
    }
  }
  value /= Math.pow(1000, scaleCount);

  let exponentValue = 0;
  if (exponentIndex !== undefined && value !== 0) {
    const integerPlaces = Math.max(integerDigitIndices.length, 1);
    exponentValue = Math.floor(Math.log10(Math.abs(value))) - (integerPlaces - 1);
    // Engineering-style formats (##0.0E+0) use multiples of the integer width.
    if (integerPlaces > 1 && integerDigitIndices.some((i) => digitKind(i) === "#")) {
      exponentValue = Math.floor(Math.floor(Math.log10(Math.abs(value))) / integerPlaces) * integerPlaces;
    }
    value /= Math.pow(10, exponentValue);
  }

  const fractionPlaces = fractionDigitIndices.length;
  let rounded = excelRound(value, fractionPlaces);
  if (exponentIndex !== undefined && Math.abs(rounded) >= Math.pow(10, Math.max(integerDigitIndices.length, 1))) {
    rounded /= 10;
    exponentValue++;
  }
  const fixed = toFixed(Math.abs(rounded), fractionPlaces);
  const parts = fixed.split(".");
  let integerDigits = parts[0];
  if (integerDigits === "0") integerDigits = "";
  const fractionDigits = parts.length > 1 ? [...parts[1]] : [];

  // Integer part: fill placeholders from the right.
  const integerOutput = new Map<number, string>();
  const minimumZeros = integerDigitIndices.filter((i) => digitKind(i) === "0").length;
  if (grouping) {
    let digits = integerDigits;
    if (digits.length < minimumZeros) digits = "0".repeat(minimumZeros - digits.length) + digits;
    if (integerDigitIndices.length) {
      integerOutput.set(integerDigitIndices[0], groupThousands(digits));
      for (const index of integerDigitIndices.slice(1)) integerOutput.set(index, "");
    }
  } else {
    const remaining = [...integerDigits];
    for (const index of [...integerDigitIndices].reverse()) {
      const kind = digitKind(index);
      const last = remaining.pop();
      if (last !== undefined) integerOutput.set(index, last);
      else integerOutput.set(index, kind === "0" ? "0" : kind === "?" ? " " : "");
    }
    if (integerDigitIndices.length && remaining.length) {
      const first = integerDigitIndices[0];
      integerOutput.set(first, remaining.join("") + (integerOutput.get(first) ?? ""));
    }
  }

  // Fraction part: fill from the left, trimming optional trailing zeros.
  const fractionOutput = new Map<number, string>();
  let lastSignificant = -1;
  fractionDigits.forEach((d, p) => { if (d !== "0") lastSignificant = p; });
  fractionDigitIndices.forEach((index, position) => {
    const kind = digitKind(index);
    const digit = position < fractionDigits.length ? fractionDigits[position] : "0";
    if (position > lastSignificant && kind !== "0") fractionOutput.set(index, kind === "?" ? " " : "");
    else fractionOutput.set(index, digit);
  });

  // Exponent digits.
  const exponentOutput = new Map<number, string>();
  if (exponentDigitIndices.length) {
    let digits = String(Math.abs(exponentValue));
    const minimum = exponentDigitIndices.length;
    if (digits.length < minimum) digits = "0".repeat(minimum - digits.length) + digits;
    exponentOutput.set(exponentDigitIndices[0], digits);
    for (const index of exponentDigitIndices.slice(1)) exponentOutput.set(index, "");
  }

  let out = "";
  let fill: [string, string] | undefined;
  const showDecimalPoint = fractionDigitIndices.length > 0;
  tokens.forEach((t, index) => {
    switch (t.k) {
      case "literal": out += t.s; break;
      case "digit": out += integerOutput.get(index) ?? fractionOutput.get(index) ?? exponentOutput.get(index) ?? ""; break;
      case "decimalPoint": if (showDecimalPoint || decimalIndex === index) out += "."; break;
      case "percent": out += "%"; break;
      case "exponent": out += exponentValue < 0 ? "E-" : t.s === "E+" ? "E+" : "E"; break;
      case "skip": out += " "; break;
      case "fill": fill = [out, t.ch]; break;
      case "general": out += general(number); break;
      default: break;
    }
  });
  return withFill(out, section.color, fill);
}

function groupThousands(digits: string): string {
  if (digits.length <= 3) return digits;
  let result = "";
  [...digits].forEach((ch, i) => {
    if (i > 0 && (digits.length - i) % 3 === 0) result += ",";
    result += ch;
  });
  return result;
}

function renderFraction(section: Section, value: number, slashIndex: number): FormattedValue {
  const tokens = section.tokens;
  const digitIndices = tokens.map((t, i) => (t.k === "digit" ? i : -1)).filter((i) => i >= 0);
  const denominatorIndices = digitIndices.filter((i) => i > slashIndex);
  // Literal digits after the slash give a fixed denominator ("# ?/8").
  let fixedDenominator: number | undefined;
  const after = tokens.slice(slashIndex + 1).find((t) => t.k === "literal" || t.k === "digit");
  if (after?.k === "literal" && /^\s*\d+\s*$/.test(after.s)) fixedDenominator = Number(after.s.trim());
  // A whole part if a digit group is separated by a literal before the numerator.
  const numeratorIndices = digitIndices.filter((i) => i < slashIndex);
  let wholeIndices: number[] = [];
  let numeratorGroup = numeratorIndices;
  let breakIndex = -1;
  for (let k = numeratorIndices.length - 1; k > 0; k--) {
    if (numeratorIndices[k] - numeratorIndices[k - 1] > 1) { breakIndex = k; break; }
  }
  if (breakIndex > 0) {
    wholeIndices = numeratorIndices.slice(0, breakIndex);
    numeratorGroup = numeratorIndices.slice(breakIndex);
  }
  const whole = wholeIndices.length ? Math.trunc(value) : 0;
  const remainder = value - whole;
  let numerator = 0, denominator = 1;
  if (fixedDenominator !== undefined) {
    denominator = fixedDenominator;
    numerator = Math.round(remainder * denominator);
  } else {
    const maxDenominator = Math.pow(10, Math.max(denominatorIndices.length, 1)) - 1;
    let bestError = Infinity;
    for (let d = 1; d <= Math.max(maxDenominator, 1); d++) {
      const n = Math.round(remainder * d);
      const error = Math.abs(remainder - n / d);
      if (error < bestError - 1e-12) { bestError = error; numerator = n; denominator = d; }
      if (error < 1e-12) break;
    }
  }
  let wholeValue = whole;
  if (numerator === denominator && wholeIndices.length) { wholeValue++; numerator = 0; }

  let out = "";
  let wroteWhole = false;
  for (let index = 0; index < tokens.length; index++) {
    const t = tokens[index];
    if (wholeIndices.includes(index)) {
      if (!wroteWhole) {
        out += wholeValue === 0 && numerator !== 0 ? "" : String(wholeValue);
        wroteWhole = true;
      }
    } else if (numeratorGroup[0] === index) {
      if (numerator === 0 && wholeIndices.length) {
        // "5" rather than "5 0/1"
        return { text: out.trim() === "" ? "0" : String(wholeValue), color: section.color };
      }
      const text = String(numerator);
      out += " ".repeat(Math.max(0, numeratorGroup.length - text.length)) + text;
    } else if (numeratorGroup.includes(index)) {
      // consumed
    } else if (t.k === "slash") {
      out += "/";
    } else if (denominatorIndices[0] === index) {
      const text = String(denominator);
      out += text + " ".repeat(Math.max(0, denominatorIndices.length - text.length));
    } else if (denominatorIndices.includes(index)) {
      // consumed
    } else if (t.k === "literal") {
      out += fixedDenominator !== undefined && index > slashIndex && /^\s*\d+\s*$/.test(t.s) ? String(denominator) : t.s;
    } else if (t.k === "skip") {
      out += " ";
    }
  }
  return { text: out, color: section.color };
}

function pad(n: number, width: number): string {
  const s = String(n);
  return s.length >= width ? s : "0".repeat(width - s.length) + s;
}

function renderDate(section: Section, serial: number): FormattedValue {
  if (serial < 0 || serial >= 2_958_466) return { text: "#".repeat(8) };
  const { year, month, day } = dateComponents(serial);
  const hasMeridiem = section.tokens.some((t) => t.k === "date" && (t.s === "AM/PM" || t.s === "A/P"));
  const fractionToken = section.tokens.find((t) => t.k === "date" && t.s.startsWith(".")) as { s: string } | undefined;
  const fractionDigits = fractionToken ? fractionToken.s.length - 1 : 0;
  const totalSeconds = serial * 86400;
  const roundedSeconds = fractionDigits > 0 ? totalSeconds : Math.round(totalSeconds);
  const secondsOfDay = roundedSeconds - Math.floor(serial) * 86400;
  const hour = Math.trunc(secondsOfDay / 3600) % 24;
  const minute = Math.trunc((secondsOfDay % 3600) / 60);
  const second = Math.trunc(secondsOfDay % 60);
  const wd = weekday(serial);
  const hour12 = hour % 12 === 0 ? 12 : hour % 12;

  let out = "";
  let fill: [string, string] | undefined;
  for (const t of section.tokens) {
    switch (t.k) {
      case "literal": out += t.s; break;
      case "skip": out += " "; break;
      case "fill": fill = [out, t.ch]; break;
      case "digit": out += t.ch === "0" ? "0" : ""; break;
      case "decimalPoint": out += "."; break;
      case "comma": out += ","; break;
      case "percent": out += "%"; break;
      case "date": {
        const s = t.s;
        if (s === "yyyy" || s === "yyy") out += pad(year, 4);
        else if (s === "yy" || s === "y") out += pad(year % 100, 2);
        else if (s[0] === "y") out += pad(year, 4);
        else if (s === "m") out += String(month);
        else if (s === "mm") out += pad(month, 2);
        else if (s === "mmm") out += MONTH_NAMES[month - 1].slice(0, 3);
        else if (s === "mmmmm") out += MONTH_NAMES[month - 1].slice(0, 1);
        else if (s[0] === "m") out += MONTH_NAMES[month - 1];
        else if (s === "d") out += String(day);
        else if (s === "dd") out += pad(day, 2);
        else if (s === "ddd") out += DAY_NAMES[wd - 1].slice(0, 3);
        else if (s[0] === "d") out += DAY_NAMES[wd - 1];
        else if (s === "h") out += String(hasMeridiem ? hour12 : hour);
        else if (s[0] === "h") out += pad(hasMeridiem ? hour12 : hour, 2);
        else if (s === "n") out += String(minute);
        else if (s === "nn") out += pad(minute, 2);
        else if (s === "s") out += String(second);
        else if (s[0] === "s") out += pad(second, 2);
        else if (s === "AM/PM") out += hour < 12 ? "AM" : "PM";
        else if (s === "A/P") out += hour < 12 ? "A" : "P";
        else if (s === "[h]" || s === "[hh]") out += pad(Math.trunc(totalSeconds / 3600), s.length - 2);
        else if (s === "[m]" || s === "[mm]") out += pad(Math.trunc(totalSeconds / 60), s.length - 2);
        else if (s === "[s]" || s === "[ss]") out += pad(Math.trunc(totalSeconds), s.length - 2);
        else if (s.startsWith(".")) {
          const fraction = totalSeconds - Math.floor(totalSeconds);
          const digits = s.length - 1;
          out += "." + pad(Math.floor(fraction * Math.pow(10, digits)), digits);
        } else out += s;
        break;
      }
      default: break;
    }
  }
  return withFill(out, section.color, fill);
}

// MARK: - Introspection

export function isDateFormat(code: string): boolean {
  const first = parsed(code)[0];
  return !!first && isDateSection(first);
}

export function isTimeFormat(code: string): boolean {
  const section = parsed(code)[0];
  if (!section || !isDateSection(section)) return false;
  const dates = section.tokens.filter((t) => t.k === "date").map((t) => (t as { s: string }).s);
  return dates.some((s) => "hns".includes(s[0]) || s.startsWith("[")) && !dates.some((s) => "dym".includes(s[0]));
}

export const isTextFormat = (code: string) => code === "@";

export function isPercentFormat(code: string): boolean {
  return parsed(code)[0]?.tokens.some((t) => t.k === "percent") ?? false;
}

/** Number of decimal places in the first section. */
export function formatDecimals(code: string): number {
  const section = parsed(code)[0];
  if (!section) return 0;
  const point = section.tokens.findIndex((t) => t.k === "decimalPoint");
  if (point < 0) return 0;
  let count = 0;
  for (const t of section.tokens.slice(point + 1)) {
    if (t.k === "digit") count++;
    else if (t.k === "exponent") break;
  }
  return count;
}

/** Adds or removes one decimal place in every numeric section. */
export function adjustingDecimals(code: string, delta: number, sampleValue?: number): string {
  let base = code;
  if (code === GENERAL || code === "") {
    // Start from the value's current General rendering.
    let places = 0;
    if (sampleValue !== undefined) {
      const s = general(sampleValue);
      const dot = s.indexOf(".");
      if (dot >= 0 && !s.includes("E")) places = s.length - dot - 1;
    }
    base = places > 0 ? "0." + "0".repeat(places) : "0";
  }
  return splitSections(base)
    .map((section) => (section.includes("@") && !section.includes("0") ? section : adjustSection(section, delta)))
    .join(";");
}

function splitSections(code: string): string[] {
  const sections: string[] = [];
  let current = "";
  let inQuote = false;
  let escape = false;
  for (const ch of code) {
    if (escape) { current += ch; escape = false; continue; }
    if (ch === "\\") { escape = true; current += ch; continue; }
    if (ch === '"') inQuote = !inQuote;
    if (ch === ";" && !inQuote) { sections.push(current); current = ""; continue; }
    current += ch;
  }
  sections.push(current);
  return sections;
}

function adjustSection(section: string, delta: number): string {
  const chars = [...section];
  let inQuote = false;
  let lastDigit: number | undefined;
  let decimalPoint: number | undefined;
  let i = 0;
  while (i < chars.length) {
    const ch = chars[i];
    if (ch === '"') inQuote = !inQuote;
    if (!inQuote) {
      if (ch === "\\" || ch === "_" || ch === "*") { i += 2; continue; }
      if (ch === "[") while (i < chars.length && chars[i] !== "]") i++;
      if ((ch === "E" || ch === "e") && i + 1 < chars.length && (chars[i + 1] === "+" || chars[i + 1] === "-")) break;
      if ("0#?".includes(ch)) lastDigit = i;
      if (ch === ".") decimalPoint = i;
    }
    i++;
  }
  if (lastDigit === undefined) return section;
  const result = [...chars];
  if (delta > 0) {
    if (decimalPoint === undefined || decimalPoint > lastDigit) result.splice(lastDigit + 1, 0, ".", "0");
    else result.splice(lastDigit + 1, 0, "0");
  } else if (decimalPoint !== undefined && decimalPoint < lastDigit) {
    result.splice(lastDigit, 1);
    if (lastDigit - 1 === decimalPoint) result.splice(decimalPoint, 1);
  }
  return result.join("");
}
