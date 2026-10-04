import { describe, expect, it } from "vitest";
import { columnName, parseA1, parseRange, quotedSheetName, rangeA1, isWholeColumns } from "../src/model/address";
import { FormulaError, type CellValue } from "../src/model/values";
import { newSheet, setCell, type Workbook } from "../src/model/workbook";
import { Calculator } from "../src/formula";
import { adjustingDecimals, formatNumber, formatValue, FORMATS, general, isDateFormat, isTimeFormat } from "../src/formula/numberFormat";
import { parseEntry } from "../src/formula/valueParser";
import { adjustFormula, renameSheetInFormula, shiftFormula, toggleAbsolute } from "../src/formula/rewriter";

type Entry = string | number | boolean;

function put(workbook: Workbook, sheet: number, a1: string, content: Entry) {
  const a = parseA1(a1)!;
  const s = workbook.sheets[sheet];
  if (typeof content === "string" && content.startsWith("=")) setCell(s, a.row, a.column, { value: null, formula: content.slice(1) });
  else setCell(s, a.row, a.column, { value: content });
}

function book(cells: Record<string, Entry> = {}): Workbook {
  const workbook: Workbook = { sheets: [newSheet("Sheet1")], activeSheetIndex: 0, names: [], author: "", created: new Date() };
  for (const [a1, content] of Object.entries(cells)) put(workbook, 0, a1, content);
  return workbook;
}

/** Builds a one-sheet workbook from A1-keyed entries ("=…" are formulas) and evaluates `formula`. */
function evaluate(formula: string, cells: Record<string, Entry> = {}): CellValue {
  const workbook = book(cells);
  put(workbook, 0, "Z100", "=" + formula);
  const calculator = new Calculator(workbook);
  calculator.recalculate();
  return calculator.value(0, 99, 25);
}

const number = (formula: string, cells: Record<string, Entry> = {}) => {
  const v = evaluate(formula, cells);
  if (typeof v !== "number") throw new Error(`${formula} → ${String(v)}`);
  return v;
};

describe("formulas", () => {
  it("does arithmetic with Excel precedence", () => {
    expect(number("1+2*3")).toBe(7);
    expect(number("(1+2)*3")).toBe(9);
    expect(number("-2^2")).toBe(4);
    expect(number("2^3^2")).toBe(64);
    expect(number("50%*10")).toBe(5);
    expect(evaluate("1/0")).toBe(FormulaError.div0);
    expect(evaluate('"a"&1&TRUE')).toBe("a1TRUE");
    expect(evaluate('"abc"="ABC"')).toBe(true);
  });

  it("reads references and ranges", () => {
    const cells = { A1: 1, A2: 2, A3: 3, B1: "x", C1: "=A1+A2" };
    expect(number("SUM(A1:A3)", cells)).toBe(6);
    expect(number("SUM(A:A)", cells)).toBe(6);
    expect(number("C1*10", cells)).toBe(30);
    expect(number("COUNT(A1:B3)", cells)).toBe(3);
    expect(number("COUNTA(A1:B3)", cells)).toBe(4);
    expect(number("SUMPRODUCT(A1:A3,A1:A3)", cells)).toBe(14);
    expect(number("SUM(A1:A3*2)", cells)).toBe(12);
  });

  it("aggregates conditionally", () => {
    const cells = { A1: "apple", A2: "banana", A3: "apple", B1: 10, B2: 20, B3: 30 };
    expect(number('SUMIF(A1:A3,"apple",B1:B3)', cells)).toBe(40);
    expect(number('COUNTIF(B1:B3,">15")', cells)).toBe(2);
    expect(number('AVERAGEIFS(B1:B3,A1:A3,"a*",B1:B3,"<25")', cells)).toBe(10);
    expect(number('MAXIFS(B1:B3,A1:A3,"apple")', cells)).toBe(30);
  });

  it("evaluates logical functions", () => {
    expect(evaluate('IF(1>2,"y","n")')).toBe("n");
    expect(evaluate('IFERROR(1/0,"oops")')).toBe("oops");
    expect(evaluate("IFS(FALSE,1,TRUE,2)")).toBe(2);
    expect(evaluate('SWITCH(2,1,"a",2,"b","c")')).toBe("b");
    expect(number("LET(x,3,y,4,SQRT(x^2+y^2))")).toBe(5);
    expect(evaluate('AND(TRUE,1,"TRUE")')).toBe(true);
  });

  it("looks values up", () => {
    const cells = { A1: "id", A2: 1, A3: 2, A4: 3, B1: "name", B2: "Ann", B3: "Bo", B4: "Cy" };
    expect(evaluate("VLOOKUP(2,A2:B4,2,FALSE)", cells)).toBe("Bo");
    expect(evaluate("VLOOKUP(2.5,A2:B4,2)", cells)).toBe("Bo");
    expect(evaluate('XLOOKUP("Cy",B2:B4,A2:A4)', cells)).toBe(3);
    expect(evaluate('XLOOKUP(9,A2:A4,B2:B4,"none")', cells)).toBe("none");
    expect(evaluate("INDEX(B2:B4,MATCH(3,A2:A4,0))", cells)).toBe("Cy");
    expect(evaluate('HLOOKUP("name",A1:B4,3,FALSE)', cells)).toBe("Bo");
    expect(evaluate('MATCH("b*",B2:B4,0)', cells)).toBe(2);
  });

  it("spills dynamic arrays", () => {
    const workbook = book({ A1: "=SEQUENCE(3,2,10,10)", D1: "=SUM(A1:B3)", F1: "=SEQUENCE(2)", F2: "blocked" });
    const calculator = new Calculator(workbook);
    calculator.recalculate();
    expect(calculator.value(0, 2, 1)).toBe(60);
    expect(calculator.value(0, 0, 3)).toBe(210);
    expect(calculator.value(0, 0, 5)).toBe(FormulaError.spill);
  });

  it("sorts, deduplicates and filters arrays", () => {
    const cells = { A1: 3, A2: 1, A3: 3, A4: 2 };
    expect(evaluate("INDEX(SORT(A1:A4),1)", cells)).toBe(1);
    expect(number("ROWS(UNIQUE(A1:A4))", cells)).toBe(3);
    expect(number("SUM(FILTER(A1:A4,A1:A4>1))", cells)).toBe(8);
  });

  it("handles text", () => {
    expect(evaluate('LEFT("Spreadsheet",6)')).toBe("Spread");
    expect(evaluate('PROPER("hello wired grid")')).toBe("Hello Wired Grid");
    expect(evaluate('TEXTJOIN(", ",TRUE,"a","","b")')).toBe("a, b");
    expect(evaluate('SUBSTITUTE("a-b-c","-","+",2)')).toBe("a-b+c");
    expect(number('SEARCH("GRID","wired grid")')).toBe(7);
    expect(evaluate('TEXT(1234.5,"$#,##0.00")')).toBe("$1,234.50");
    expect(evaluate('TEXT(0.256,"0.0%")')).toBe("25.6%");
    expect(number('VALUE("1,234.5")')).toBe(1234.5);
  });

  it("handles dates", () => {
    expect(number("DATE(2024,1,15)")).toBe(45306);
    expect(number("DATE(2024,14,1)")).toBe(number("DATE(2025,2,1)"));
    expect(number("YEAR(45306)")).toBe(2024);
    expect(number("WEEKDAY(DATE(2024,1,15))")).toBe(2);
    expect(number("EOMONTH(DATE(2024,1,15),1)")).toBe(number("DATE(2024,2,29)"));
    expect(number('DATEDIF(DATE(2020,5,10),DATE(2024,5,9),"Y")')).toBe(3);
    expect(number("NETWORKDAYS(DATE(2024,1,1),DATE(2024,1,12))")).toBe(10);
  });

  it("handles finance", () => {
    expect(number("PMT(0.05/12,360,200000)")).toBeCloseTo(-1073.6432460242795, 6);
    expect(number("FV(0.06/12,120,-100)")).toBeCloseTo(16387.93, 2);
    expect(number("RATE(360,-1073.64,200000)*12")).toBeCloseTo(0.05, 5);
    expect(number("IRR({-100,30,40,50})")).toBeCloseTo(0.0889633947, 6);
    expect(number("NPV(0.1,100,100)")).toBeCloseTo(173.5537, 4);
  });

  it("handles statistics", () => {
    const cells = { A1: 2, A2: 4, A3: 4, A4: 4, A5: 5, A6: 5, A7: 7, A8: 9 };
    expect(number("STDEV.P(A1:A8)", cells)).toBe(2);
    expect(number("MEDIAN(A1:A8)", cells)).toBe(4.5);
    expect(number("MODE(A1:A8)", cells)).toBe(4);
    expect(number("LARGE(A1:A8,2)", cells)).toBe(7);
    expect(number("PERCENTILE(A1:A8,0.5)", cells)).toBe(4.5);
    expect(number("NORM.S.INV(0.975)")).toBeCloseTo(1.959964, 5);
    expect(number("NORM.S.DIST(1,TRUE)")).toBeCloseTo(0.841344746068543, 12);
    expect(number("NORM.S.DIST(-5,TRUE)")).toBeCloseTo(2.866515718791939e-7, 15);
    expect(number("BINOM.DIST(3,10,0.5,FALSE)")).toBeCloseTo(0.1171875, 10);
  });

  it("reports errors and cycles", () => {
    expect(evaluate("NOSUCHFUNC(1)")).toBe(FormulaError.name);
    expect(evaluate("UndefinedName+1")).toBe(FormulaError.name);
    expect(evaluate("VLOOKUP(9,A1:B2,2,FALSE)")).toBe(FormulaError.na);
    expect(evaluate("Z100+1")).toBe(FormulaError.circular);
    expect(evaluate("ISERROR(1/0)")).toBe(true);
  });

  it("resolves other sheets and defined names", () => {
    const workbook: Workbook = { sheets: [newSheet("Data Sheet"), newSheet("Summary")], activeSheetIndex: 0, names: [{ name: "Factor", formula: "2", comment: "" }], author: "", created: new Date() };
    put(workbook, 0, "B2", 21);
    put(workbook, 1, "A1", "='Data Sheet'!B2*Factor");
    const calculator = new Calculator(workbook);
    calculator.recalculate();
    expect(calculator.value(1, 0, 0)).toBe(42);
  });

  it("evaluates long bottom-up chains without overflowing", () => {
    const cells: Record<string, Entry> = { A20000: 1 };
    for (let r = 1; r < 20000; r++) cells[`A${r}`] = `=A${r + 1}+1`;
    const workbook = book(cells);
    const calculator = new Calculator(workbook);
    calculator.recalculate();
    expect(calculator.value(0, 0, 0)).toBe(20000);
  });

  it("rewrites references", () => {
    expect(shiftFormula("SUM(A1:B$2)+$C3+Sheet2!D4", 2, 1)).toBe("SUM(B3:C$2)+$C5+Sheet2!E6");
    expect(shiftFormula("A1", -1, 0)).toBe("#REF!");
    expect(adjustFormula("SUM(A1:A10)+A11", "S", "S", { kind: "deleteRows", at: 2, count: 3 })).toBe("SUM(A1:A7)+A8");
    expect(adjustFormula("B5", "S", "S", { kind: "insertColumns", at: 0, count: 2 })).toBe("D5");
    expect(renameSheetInFormula("Old!A1+A2", "Old", "New Name")).toBe("'New Name'!A1+A2");
    expect(toggleAbsolute("A1+B2", 1)?.text).toBe("$A$1+B2");
  });
});

describe("number formats", () => {
  const f = (value: number, code: string) => formatNumber(value, code).text;

  it("formats General", () => {
    expect(general(0.1 + 0.2)).toBe("0.3");
    expect(general(1e12)).toBe("1E+12");
    expect(general(3.14159265358979)).toBe("3.141592654");
    expect(general(-42)).toBe("-42");
  });

  it("understands number codes", () => {
    expect(f(1234.5678, "#,##0.00")).toBe("1,234.57");
    expect(f(-1234.5, "$#,##0.00;[Red]($#,##0.00)")).toBe("($1,234.50)");
    expect(formatNumber(-5, "0;[Red]-0").color).toBe("#FF0000");
    expect(f(0.256, "0.0%")).toBe("25.6%");
    expect(f(123456, "0.00E+00")).toBe("1.23E+05");
    expect(f(1.5, "# ?/?")).toBe("1 1/2");
    expect(f(42, "000")).toBe("042");
    expect(f(1234567, '#,##0,"K"')).toBe("1,235K");
    expect(f(5551234567, "(000) 000-0000")).toBe("(555) 123-4567");
    expect(f(0, '0;-0;"zero"')).toBe("zero");
    expect(formatValue("hi", '"<"@">"').text).toBe("<hi>");
  });

  it("splits accounting formats at the fill", () => {
    const result = formatNumber(1234, FORMATS.accounting);
    expect(result.fillSplit?.[0].trim()).toBe("$");
    expect(result.fillSplit?.[1].trim()).toBe("1,234.00");
  });

  it("formats dates and times", () => {
    expect(f(45306, "yyyy-mm-dd")).toBe("2024-01-15");
    expect(f(45306, "dddd, mmmm d, yyyy")).toBe("Monday, January 15, 2024");
    expect(f(45000.75, "m/d/yyyy h:mm AM/PM")).toBe("3/15/2023 6:00 PM");
    expect(f(1.5, "[h]:mm")).toBe("36:00");
    expect(f(0.5, "h:mm")).toBe("12:00");
    expect(isDateFormat("d-mmm-yy")).toBe(true);
    expect(isTimeFormat("h:mm:ss")).toBe(true);
  });

  it("adjusts decimals", () => {
    expect(adjustingDecimals("0.00", 1)).toBe("0.000");
    expect(adjustingDecimals("0.0", -1)).toBe("0");
    expect(adjustingDecimals("General", 1, 3.25)).toBe("0.000");
    expect(adjustingDecimals("#,##0", 1)).toBe("#,##0.0");
  });

  it("parses typed values", () => {
    expect(parseEntry("12%").value).toBe(0.12);
    expect(parseEntry("12%").format).toBe("0%");
    expect(parseEntry("$1,234.50").value).toBe(1234.5);
    expect(parseEntry("(45)").value).toBe(-45);
    expect(parseEntry("2024-01-15").value).toBe(45306);
    expect(parseEntry("Jan 15, 2024").value).toBe(45306);
    expect(parseEntry("9:30 PM").value as number).toBeCloseTo(21.5 / 24, 9);
    expect(parseEntry("1 1/2").value).toBe(1.5);
    expect(parseEntry("TRUE").value).toBe(true);
    expect(parseEntry("#N/A").value).toBe(FormulaError.na);
    expect(parseEntry("1,23").value).toBe("1,23");
    expect(parseEntry("hello").value).toBe("hello");
  });

  it("names addresses", () => {
    expect(columnName(0)).toBe("A");
    expect(columnName(27)).toBe("AB");
    expect(columnName(16383)).toBe("XFD");
    expect(parseA1("$C$7")).toEqual({ row: 6, column: 2 });
    expect(isWholeColumns(parseRange("B:D")!)).toBe(true);
    expect(rangeA1(parseRange("C3:A1")!)).toBe("A1:C3");
    expect(quotedSheetName("My Sheet")).toBe("'My Sheet'");
    expect(quotedSheetName("Sheet1")).toBe("Sheet1");
  });
});
