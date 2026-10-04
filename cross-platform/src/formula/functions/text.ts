import { FormulaError } from "../../model/values";
import { register, VARIADIC, type FunctionCall } from "../calculator";
import { asText, escapeRegex, Matrix, matrixValue, numberResult, scalar, wildcardRegex } from "../fvalue";
import { excelRound, formatValue } from "../numberFormat";
import { numberFromText } from "../valueParser";

const V = VARIADIC;
const T = "Text" as const;
const chars = (s: string) => [...s];

const joinAll = (c: FunctionCall, from: number, to: number): string[] => {
  const parts: string[] = [];
  for (let i = from; i < to; i++) {
    if (c.isMissing(i)) continue;
    for (const value of c.flat(i)) {
      if (value instanceof FormulaError) throw value;
      parts.push(asText(value));
    }
  }
  return parts;
};

register("CONCATENATE", T, "CONCATENATE(text1, [text2], …)", "Joins several text strings into one.", [1, V], (c) => {
  let result = "";
  for (let i = 0; i < c.count; i++) result += c.text(i, "");
  return scalar(result);
});
register("CONCAT", T, "CONCAT(text1, [text2], …)", "Joins text from multiple ranges and strings.", [1, V], (c) => scalar(joinAll(c, 0, c.count).join("")));
register("TEXTJOIN", T, "TEXTJOIN(delimiter, ignore_empty, text1, …)", "Joins text with a delimiter between each value.", [3, V], (c) => {
  const delimiter = c.text(0);
  const ignoreEmpty = c.bool(1);
  let parts = joinAll(c, 2, c.count);
  if (ignoreEmpty) parts = parts.filter((p) => p !== "");
  return scalar(parts.join(delimiter));
});
register("LEFT", T, "LEFT(text, [num_chars])", "Returns the leftmost characters of a text value.", [1, 2], (c) => {
  const n = c.int(1, 1);
  if (n < 0) throw FormulaError.value;
  return c.liftText(0, (s) => chars(s).slice(0, n).join(""));
});
register("RIGHT", T, "RIGHT(text, [num_chars])", "Returns the rightmost characters of a text value.", [1, 2], (c) => {
  const n = c.int(1, 1);
  if (n < 0) throw FormulaError.value;
  return c.liftText(0, (s) => (n === 0 ? "" : chars(s).slice(-n).join("")));
});
register("MID", T, "MID(text, start_num, num_chars)", "Returns characters from the middle of a text string.", [3, 3], (c) => {
  const start = c.int(1), length = c.int(2);
  if (start < 1 || length < 0) throw FormulaError.value;
  return c.liftText(0, (s) => chars(s).slice(start - 1, start - 1 + length).join(""));
});
register("LEN", T, "LEN(text)", "Returns the number of characters in a text string.", [1, 1], (c) => c.liftText(0, (s) => chars(s).length));
register("LOWER", T, "LOWER(text)", "Converts text to lowercase.", [1, 1], (c) => c.liftText(0, (s) => s.toLowerCase()));
register("UPPER", T, "UPPER(text)", "Converts text to uppercase.", [1, 1], (c) => c.liftText(0, (s) => s.toUpperCase()));
register("PROPER", T, "PROPER(text)", "Capitalizes the first letter of each word.", [1, 1], (c) =>
  c.liftText(0, (s) => {
    let result = "";
    let previousIsLetter = false;
    for (const ch of s) {
      result += previousIsLetter ? ch.toLowerCase() : ch.toUpperCase();
      previousIsLetter = /\p{L}/u.test(ch);
    }
    return result;
  }));
register("TRIM", T, "TRIM(text)", "Removes extra spaces from text.", [1, 1], (c) => c.liftText(0, (s) => s.split(" ").filter(Boolean).join(" ")));
register("CLEAN", T, "CLEAN(text)", "Removes nonprintable characters from text.", [1, 1], (c) =>
  c.liftText(0, (s) => chars(s).filter((ch) => ch.codePointAt(0)! >= 32).join("")));
register("SUBSTITUTE", T, "SUBSTITUTE(text, old_text, new_text, [instance_num])", "Substitutes new text for old text.", [3, 4], (c) => {
  const old = c.text(1), replacement = c.text(2);
  const instance = c.isMissing(3) ? undefined : c.int(3);
  if (instance !== undefined && instance < 1) throw FormulaError.value;
  return c.liftText(0, (s) => {
    if (!old) return s;
    if (instance === undefined) return s.split(old).join(replacement);
    let count = 0;
    let from = 0;
    for (;;) {
      const found = s.indexOf(old, from);
      if (found < 0) return s;
      if (++count === instance) return s.slice(0, found) + replacement + s.slice(found + old.length);
      from = found + old.length;
    }
  });
});
register("REPLACE", T, "REPLACE(old_text, start_num, num_chars, new_text)", "Replaces characters within text.", [4, 4], (c) => {
  const text = chars(c.text(0));
  const start = c.int(1), length = c.int(2);
  const replacement = c.text(3);
  if (start < 1 || length < 0) throw FormulaError.value;
  const from = Math.min(start - 1, text.length), to = Math.min(from + length, text.length);
  text.splice(from, to - from, ...chars(replacement));
  return scalar(text.join(""));
});
const finder = (caseInsensitive: boolean) => (c: FunctionCall) => {
  const needle = c.text(0);
  const start = c.int(2, 1);
  return c.liftText(1, (haystack) => {
    const all = chars(haystack);
    if (start < 1 || start > all.length + 1) throw FormulaError.value;
    const tail = all.slice(start - 1).join("");
    if (!needle) return start;
    let index: number;
    if (caseInsensitive) {
      const pattern = /[*?]/.test(needle) ? wildcardRegex(needle).source.slice(1, -1) : escapeRegex(needle);
      const match = new RegExp(pattern, "is").exec(tail);
      index = match ? match.index : -1;
    } else {
      index = tail.indexOf(needle);
    }
    if (index < 0) throw FormulaError.value;
    return chars(tail.slice(0, index)).length + start;
  });
};
register("FIND", T, "FIND(find_text, within_text, [start_num])", "Finds one text value within another (case-sensitive).", [2, 3], finder(false));
register("SEARCH", T, "SEARCH(find_text, within_text, [start_num])", "Finds one text value within another (not case-sensitive, wildcards allowed).", [2, 3], finder(true));
register("REPT", T, "REPT(text, number_times)", "Repeats text a given number of times.", [2, 2], (c) => {
  const n = c.int(1);
  if (n < 0 || n >= 32768) throw FormulaError.value;
  return c.liftText(0, (s) => s.repeat(n));
});
register("TEXT", T, "TEXT(value, format_text)", "Formats a number and converts it to text.", [2, 2], (c) => {
  const code = c.text(1);
  return c.lift(0, (value) => {
    if (value instanceof FormulaError) return value;
    let v = value;
    if (typeof value === "string") {
      const n = numberFromText(value);
      if (n !== null) v = n;
    }
    return formatValue(v, code).text;
  });
});
register("VALUE", T, "VALUE(text)", "Converts a text argument to a number.", [1, 1], (c) =>
  c.lift(0, (value) => {
    if (typeof value === "number" || value instanceof FormulaError) return value;
    if (value === null) return 0;
    if (typeof value === "boolean") throw FormulaError.value;
    const n = numberFromText(value.trim());
    if (n === null) throw FormulaError.value;
    return n;
  }));
register("NUMBERVALUE", T, "NUMBERVALUE(text, [decimal_separator], [group_separator])", "Converts text to a number in a locale-independent way.", [1, 3], (c) => {
  let s = c.text(0).trim();
  const decimal = c.text(1, "."), group = c.text(2, ",");
  if (group) s = s.split(group).join("");
  if (decimal) s = s.split(decimal).join(".");
  let percent = 0;
  while (s.endsWith("%")) { percent++; s = s.slice(0, -1); }
  if (!/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(s)) throw FormulaError.value;
  return numberResult(Number(s) / Math.pow(100, percent));
});
register("EXACT", T, "EXACT(text1, text2)", "Checks whether two text values are identical.", [2, 2], (c) => scalar(c.text(0) === c.text(1)));
register("CHAR", T, "CHAR(number)", "Returns the character specified by a code number.", [1, 1], (c) => {
  const n = c.int(0);
  if (n < 1 || n > 255) throw FormulaError.value;
  return scalar(String.fromCodePoint(n));
});
register("UNICHAR", T, "UNICHAR(number)", "Returns the Unicode character for a number.", [1, 1], (c) => {
  const n = c.int(0);
  if (n <= 0 || n > 0x10ffff || (n >= 0xd800 && n <= 0xdfff)) throw FormulaError.value;
  return scalar(String.fromCodePoint(n));
});
const firstCode = (c: FunctionCall) => {
  const s = c.text(0);
  if (!s) throw FormulaError.value;
  return scalar(s.codePointAt(0)!);
};
register("CODE", T, "CODE(text)", "Returns a numeric code for the first character.", [1, 1], firstCode);
register("UNICODE", T, "UNICODE(text)", "Returns the Unicode code point of the first character.", [1, 1], firstCode);
register("DOLLAR", T, "DOLLAR(number, [decimals])", "Converts a number to text in currency format.", [1, 2], (c) => {
  const decimals = c.int(1, 2);
  const code = "$#,##0" + (decimals > 0 ? "." + "0".repeat(decimals) : "");
  return scalar(formatValue(excelRound(c.number(0), decimals), code + ";($" + code.slice(1) + ")").text);
});
register("FIXED", T, "FIXED(number, [decimals], [no_commas])", "Formats a number as text with a fixed number of decimals.", [1, 3], (c) => {
  const decimals = c.int(1, 2);
  const noCommas = c.bool(2, false);
  const code = (noCommas ? "0" : "#,##0") + (decimals > 0 ? "." + "0".repeat(decimals) : "");
  return scalar(formatValue(excelRound(c.number(0), decimals), code).text);
});
register("T", T, "T(value)", "Returns the text if the value is text, otherwise empty text.", [1, 1], (c) => {
  const v = c.scalar(0);
  return scalar(typeof v === "string" ? v : "");
});
register("TEXTBEFORE", T, "TEXTBEFORE(text, delimiter, [instance_num])", "Returns text that occurs before a delimiter.", [2, 3], (c) => {
  const text = c.text(0), delimiter = c.text(1), instance = c.int(2, 1);
  const parts = delimiter ? text.split(delimiter) : [text];
  if (instance === 0 || Math.abs(instance) >= parts.length) throw FormulaError.na;
  const count = instance > 0 ? instance : parts.length + instance;
  return scalar(parts.slice(0, count).join(delimiter));
});
register("TEXTAFTER", T, "TEXTAFTER(text, delimiter, [instance_num])", "Returns text that occurs after a delimiter.", [2, 3], (c) => {
  const text = c.text(0), delimiter = c.text(1), instance = c.int(2, 1);
  const parts = delimiter ? text.split(delimiter) : [text];
  if (instance === 0 || Math.abs(instance) >= parts.length) throw FormulaError.na;
  const count = instance > 0 ? instance : parts.length + instance;
  return scalar(parts.slice(count).join(delimiter));
});
register("TEXTSPLIT", T, "TEXTSPLIT(text, col_delimiter, [row_delimiter])", "Splits text into rows or columns using delimiters.", [2, 3], (c) => {
  const text = c.text(0), columnDelimiter = c.text(1);
  const rowDelimiter = c.isMissing(2) ? undefined : c.text(2);
  const rows = rowDelimiter !== undefined && rowDelimiter !== "" ? text.split(rowDelimiter) : [text];
  const m = Matrix.fromRows(rows.map((row) => (columnDelimiter ? row.split(columnDelimiter) : [row])));
  for (let i = 0; i < m.values.length; i++) if (m.values[i] === null) m.values[i] = FormulaError.na;
  return matrixValue(m);
});
register("HYPERLINK", T, "HYPERLINK(link_location, [friendly_name])", "Creates a link to a web page or file.", [1, 2], (c) =>
  c.isMissing(1) ? scalar(c.text(0)) : c.value(1));
