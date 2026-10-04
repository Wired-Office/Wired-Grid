import { describe, expect, it } from "vitest";
import { cellKey, parseA1, parseRange } from "../src/model/address";
import { FormulaError, type CellValue } from "../src/model/values";
import { newSheet, newWorkbook, setCell, styleAt, type Workbook } from "../src/model/workbook";
import { WorkbookController } from "../src/engine/controller";
import { readGrid, writeGrid, encodeWorkbook, decodeWorkbook } from "../src/formats/native";
import { readXLSX, writeXLSX } from "../src/formats/xlsx";
import { readDelimited, writeDelimited } from "../src/formats/delimited";
import { readZip, toUTF8, utf8, writeZip } from "../src/formats/zip";

const A = (a1: string) => parseA1(a1)!;
const R = (a1: string) => parseRange(a1)!;

function controllerWith(entries: Record<string, string>) {
  const c = new WorkbookController(newWorkbook());
  for (const [a1, text] of Object.entries(entries)) c.setInput(text, A(a1));
  return c;
}

const value = (c: WorkbookController, a1: string): CellValue => c.value(A(a1));
const formula = (c: WorkbookController, a1: string) => c.sheet.cells.get(cellKey(A(a1).row, A(a1).column))?.formula;

describe("editing", () => {
  it("parses and formats typed entries", () => {
    const c = controllerWith({ A1: "12%", A2: "=A1*2", A3: "2024-03-05", A4: "'007" });
    expect(value(c, "A2")).toBe(0.24);
    expect(c.displayText(A("A1"))).toBe("12%");
    expect(c.displayText(A("A3"))).toBe("2024-03-05");
    expect(value(c, "A4")).toBe("007");
    expect(c.inputText(A("A4"))).toBe("'007");
    expect(c.inputText(A("A2"))).toBe("=A1*2");
  });

  it("normalizes formulas", () => {
    expect(WorkbookController.normalizeFormula("sum(a1:b2")).toBe("SUM(A1:B2)");
    expect(() => WorkbookController.normalizeFormula("1+*2")).toThrow();
  });

  it("adjusts formulas when rows are inserted and deleted", () => {
    const c = controllerWith({ A1: "1", A2: "2", A3: "3", B1: "=SUM(A1:A3)", B2: "=A3" });
    c.insertRows(1, 2);
    expect(formula(c, "B1")).toBe("SUM(A1:A5)");
    expect(formula(c, "B4")).toBe("A5");
    expect(value(c, "B1")).toBe(6);
    c.deleteRows(4, 1);
    expect(formula(c, "B4")).toBe("#REF!");
  });

  it("fills series with the fill handle", () => {
    const c = controllerWith({ A1: "1", A2: "3", B1: "Mon", C1: "Item 7", D1: "=A1*10" });
    c.autoFill(R("A1:A2"), R("A1:A5"));
    expect(value(c, "A5")).toBe(9);
    c.autoFill(R("B1"), R("B1:B3"));
    expect(value(c, "B3")).toBe("Wed");
    c.autoFill(R("C1"), R("C1:C2"));
    expect(value(c, "C2")).toBe("Item 8");
    c.autoFill(R("D1"), R("D1:D2"));
    expect(formula(c, "D2")).toBe("A2*10");
  });

  it("sorts rows together", () => {
    const c = controllerWith({ A1: "Name", B1: "Score", A2: "Cy", B2: "70", A3: "Ann", B3: "95", A4: "Bo", B4: "80" });
    c.sort(R("A1:B4"), [{ column: 1, ascending: false }], true);
    expect(value(c, "A2")).toBe("Ann");
    expect(value(c, "A4")).toBe("Cy");
    expect(value(c, "A1")).toBe("Name");
  });

  it("filters rows", () => {
    const c = controllerWith({ A1: "Fruit", A2: "apple", A3: "pear", A4: "apple" });
    c.select(A("A1"));
    c.toggleFilter();
    c.setFilterCriterion({ type: "values", values: ["pear"] }, 0);
    expect([...c.sheet.filter!.hiddenRows].sort()).toEqual([1, 3]);
  });

  it("shifts formulas on copy and paste", () => {
    const c = controllerWith({ A1: "5", B1: "=A1*2" });
    c.select(A("B1"));
    const copied = c.copySelection();
    c.select(A("B3"));
    c.paste("all", copied!.text);
    expect(formula(c, "B3")).toBe("A3*2");
  });

  it("pastes plain text from other apps", () => {
    const c = controllerWith({});
    c.select(A("B2"));
    c.paste("all", "1\t2\n3\t=B2+C2");
    expect(value(c, "C3")).toBe(3);
  });

  it("updates references when a sheet is renamed", () => {
    const c = controllerWith({});
    c.addSheet();
    c.setInput("=Sheet1!A1+1", A("A1"));
    expect(c.renameSheet(0, "Inputs")).toBe(true);
    expect(formula(c, "A1")).toBe("Inputs!A1+1");
  });

  it("merges and draws borders", async () => {
    const c = controllerWith({ A1: "Title" });
    c.selectRange(R("A1:C1"));
    await c.merge("mergeAndCenter");
    expect(c.sheet.merges).toEqual([R("A1:C1")]);
    expect(styleAt(c.sheet, 0, 0).horizontal).toBe("center");
    c.selectRange(R("A3:B4"));
    c.applyBorders("outside");
    expect(styleAt(c.sheet, 2, 0).borders?.top).toBeDefined();
    expect(styleAt(c.sheet, 2, 0).borders?.bottom).toBeUndefined();
  });

  it("undoes and redoes", () => {
    const c = controllerWith({ A1: "1" });
    c.setInput("2", A("A1"));
    expect(value(c, "A1")).toBe(2);
    c.undo();
    expect(value(c, "A1")).toBe(1);
    c.redo();
    expect(value(c, "A1")).toBe(2);
  });
});

function sampleWorkbook(): Workbook {
  const sheet = newSheet("Data & Stuff");
  const put = (a1: string, cell: Parameters<typeof setCell>[3]) => setCell(sheet, A(a1).row, A(a1).column, cell);
  put("A1", { value: "Name <tag>", style: { bold: true, fillColor: "#1E8E5A" } });
  put("B1", { value: 1234.5, style: { numberFormat: "$#,##0.00" } });
  put("B2", { value: null, formula: "B1*2" });
  put("C1", { value: true });
  put("C2", { value: null, formula: 'XLOOKUP(1,{1,2},{"a","b"})' });
  sheet.columnWidths.set(0, 160);
  sheet.rowHeights.set(3, 42);
  sheet.merges = [R("D1:E2")];
  sheet.frozenRows = 1;
  sheet.conditionalFormats = [{ id: "CF1", range: R("B1:B2"), rule: { type: "greaterThan", value: 100 }, format: { fill: "#FFC7CE", text: "#9C0006", bold: false, italic: false } }];
  sheet.notes.set(cellKey(0, 0), "hello");
  sheet.charts = [{
    id: "C1", kind: "column", dataRange: R("A1:B2"), title: "", frame: { x: 10, y: 20, width: 300, height: 200 }, seriesInColumns: true,
    showLegend: true, showDataLabels: false, showGridlines: true, palette: "grid", xAxisTitle: "", yAxisTitle: "",
  }];
  return { sheets: [sheet, newSheet("Second")], activeSheetIndex: 0, names: [{ name: "Rate", formula: "0.07", comment: "" }], author: "", created: new Date("2026-09-30T10:00:00Z") };
}

describe("files", () => {
  it("round-trips .grid files", () => {
    const original = sampleWorkbook();
    const read = readGrid(writeGrid(original));
    expect(read.sheets.length).toBe(2);
    expect(read.sheets[0].cells).toEqual(original.sheets[0].cells);
    expect(read.sheets[0].merges).toEqual(original.sheets[0].merges);
    expect(read.sheets[0].notes).toEqual(original.sheets[0].notes);
    expect(read.sheets[0].charts).toEqual(original.sheets[0].charts);
    expect(read.sheets[0].conditionalFormats).toEqual(original.sheets[0].conditionalFormats);
    expect(read.names).toEqual(original.names);
  });

  it("writes .grid JSON the way Wired Grid for Mac does", () => {
    const json = encodeWorkbook(sampleWorkbook()) as Record<string, unknown>;
    const sheet = (json.sheets as Record<string, unknown>[])[0];
    expect(json.created).toBe("2026-09-30T10:00:00Z");
    expect(json.formatVersion).toBe(1);
    expect((sheet.conditionalFormats as unknown[])[0]).toMatchObject({ rule: { greaterThan: { _0: 100 } }, format: { bold: false, italic: false, fill: "#FFC7CE" } });
    expect((sheet.charts as Record<string, unknown>[])[0].frame).toEqual([[10, 20], [300, 200]]);
    expect(sheet.columnWidths).toEqual({ "0": 160 });
    expect((sheet.cells as unknown[])[0]).toEqual({ r: 0, c: 0, v: { s: "Name <tag>" }, s: 0 });
    expect((sheet.styles as unknown[])[0]).toEqual({ bold: true, fillColor: "#1E8E5A" });
    const zip = readZip(writeGrid(sampleWorkbook()));
    expect([...zip.keys()]).toEqual(["mimetype", "Workbook.json"]);
    expect(utf8(zip.get("mimetype")!)).toBe("application/vnd.wiredgrid.grid");
  });

  it("reads .grid JSON written by Wired Grid for Mac", () => {
    const mac = {
      activeSheetIndex: 0, created: "2026-09-30T08:12:44Z", formatVersion: 1,
      names: [{ comment: "", formula: "Sheet1!$B$2", name: "Total" }],
      sheets: [{
        cells: [{ c: 0, r: 0, s: 0, v: { s: "Item" } }, { c: 1, r: 1, v: { n: 42 } }, { c: 1, f: "B2*2", r: 2, v: { n: 84 } }, { c: 2, r: 2, v: { e: "#DIV/0!" } }],
        conditionalFormats: [{ format: { bold: true, italic: false }, id: "8F0C", range: { end: { column: 1, row: 9 }, start: { column: 1, row: 1 } }, rule: { top: { _0: 3, percent: false } } }],
        filter: { criteria: { "1": { values: { _0: ["42"] } } }, hiddenRows: [], range: { end: { column: 2, row: 2 }, start: { column: 0, row: 0 } } },
        id: "5A1E1F2C-0D44-4C0B-9F00-1C1B2E9C3A11", name: "Sheet1", styles: [{ bold: true, borders: { bottom: { color: "#1E8E5A", style: "double" } } }],
        tables: [{ bandedRows: true, id: "T1", name: "Table1", range: { end: { column: 2, row: 2 }, start: { column: 0, row: 0 } }, showHeader: true, showTotals: false, style: "blue" }],
      }],
    };
    const workbook = decodeWorkbook(mac);
    const sheet = workbook.sheets[0];
    expect(sheet.cells.get(cellKey(2, 1))?.formula).toBe("B2*2");
    expect(sheet.cells.get(cellKey(2, 2))?.value).toBe(FormulaError.div0);
    expect(styleAt(sheet, 0, 0).borders?.bottom).toEqual({ style: "double", color: "#1E8E5A" });
    expect(sheet.conditionalFormats[0].rule).toEqual({ type: "top", count: 3, percent: false });
    expect(sheet.filter?.criteria.get(1)).toEqual({ type: "values", values: ["42"] });
    expect(sheet.tables[0].style).toBe("blue");
    expect(workbook.names[0].formula).toBe("Sheet1!$B$2");
    const json = JSON.stringify(mac);
    const bytes = writeZip([["mimetype", "application/vnd.wiredgrid.grid"], ["Workbook.json", toUTF8(json)]], ["mimetype"]);
    expect(readGrid(bytes).sheets[0].name).toBe("Sheet1");
  });

  it("round-trips .xlsx files", () => {
    const read = readXLSX(writeXLSX(sampleWorkbook()));
    const sheet = read.sheets[0];
    expect(read.sheets.map((s) => s.name)).toEqual(["Data & Stuff", "Second"]);
    expect(sheet.cells.get(cellKey(0, 0))?.value).toBe("Name <tag>");
    expect(styleAt(sheet, 0, 0).bold).toBe(true);
    expect(styleAt(sheet, 0, 0).fillColor).toBe("#1E8E5A");
    expect(styleAt(sheet, 0, 1).numberFormat).toBe("$#,##0.00");
    expect(sheet.cells.get(cellKey(1, 1))?.formula).toBe("B1*2");
    expect(sheet.cells.get(cellKey(1, 2))?.formula).toBe('XLOOKUP(1,{1,2},{"a","b"})');
    expect(sheet.cells.get(cellKey(0, 2))?.value).toBe(true);
    expect(sheet.columnWidths.get(0)).toBeCloseTo(160, 0);
    expect(sheet.rowHeights.get(3)).toBeCloseTo(42, 0);
    expect(sheet.merges).toEqual([R("D1:E2")]);
    expect(sheet.frozenRows).toBe(1);
    expect(sheet.conditionalFormats[0]?.rule).toEqual({ type: "greaterThan", value: 100 });
    expect(read.names[0]?.name).toBe("Rate");
  });

  it("round-trips CSV", () => {
    const csv = 'Name,Amount,When\n"Smith, J","1,200.50",2024-01-15\nLee,=B2*2,\n';
    const workbook = readDelimited(toUTF8(csv), ",");
    const sheet = workbook.sheets[0];
    expect(sheet.cells.get(cellKey(1, 0))?.value).toBe("Smith, J");
    expect(sheet.cells.get(cellKey(1, 1))?.value).toBe(1200.5);
    expect(sheet.cells.get(cellKey(2, 1))?.formula).toBe("B2*2");
    const written = utf8(writeDelimited(workbook, ","));
    expect(written).toContain('"Smith, J"');
    expect(written).toContain("2401");
  });
});
