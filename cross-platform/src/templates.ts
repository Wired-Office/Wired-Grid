import { columnIndex, forEachCell, parseA1, parseRange, a1 } from "./model/address";
import {
  newSheet, normalizeStyle, setCell, updateStyle, uuid,
  type CellStyle, type ChartKind, type ChartObject, type ChartPalette, type Color, type ConditionalFormat, type HighlightFormat,
  type Rule, type Sheet, type TableStyle, type Workbook,
} from "./model/workbook";
import { WorkbookController } from "./engine/controller";
import { serialFromDate } from "./formula/dateSerial";
import { settings } from "./settings";

/** A starting point in the template chooser. */
export interface WorkbookTemplate {
  id: string;
  name: string;
  subtitle: string;
  tint: Color;
  build: () => Workbook;
}

/** Builds sheets tersely: `b.set("A1", "Title", style)`. */
class SheetBuilder {
  sheet: Sheet;

  constructor(name: string) {
    this.sheet = newSheet(name);
  }

  set(ref: string, content: string | number | boolean, style?: CellStyle) {
    const a = parseA1(ref);
    if (!a) return;
    const cell = { value: null as string | number | boolean | null, formula: undefined as string | undefined, style: style ? normalizeStyle(style) : undefined };
    if (typeof content === "string" && content.startsWith("=")) {
      try {
        cell.formula = WorkbookController.normalizeFormula(content.slice(1));
      } catch {
        cell.formula = content.slice(1);
      }
    } else {
      cell.value = content;
    }
    setCell(this.sheet, a.row, a.column, cell);
  }

  row(ref: string, values: (string | number | boolean)[], style?: CellStyle) {
    const start = parseA1(ref);
    if (!start) return;
    values.forEach((v, i) => this.set(a1({ row: start.row, column: start.column + i }), v, style));
  }

  style(ref: string, change: (s: CellStyle) => CellStyle) {
    const r = parseRange(ref);
    if (r) forEachCell(r, (row, column) => updateStyle(this.sheet, row, column, change));
  }

  width(column: string, width: number) {
    const c = columnIndex(column);
    if (c !== null) this.sheet.columnWidths.set(c, width);
  }

  merge(ref: string) {
    const r = parseRange(ref);
    if (r) this.sheet.merges.push(r);
  }
}

const book = (sheets: Sheet[]): Workbook => ({ sheets, activeSheetIndex: 0, names: [], author: settings().authorName, created: new Date() });

const cf = (ref: string, rule: Rule, format: HighlightFormat = LIGHT_RED): ConditionalFormat => ({ id: uuid(), range: parseRange(ref)!, rule, format });

const chart = (kind: ChartKind, ref: string, title: string, frame: [number, number, number, number], palette: ChartPalette = "grid"): ChartObject => ({
  id: uuid(), kind, dataRange: parseRange(ref)!, title, frame: { x: frame[0], y: frame[1], width: frame[2], height: frame[3] },
  seriesInColumns: true, showLegend: true, showDataLabels: false, showGridlines: true, palette, xAxisTitle: "", yAxisTitle: "",
});

const LIGHT_RED: HighlightFormat = { fill: "#FFC7CE", text: "#9C0006", bold: false, italic: false };
const YELLOW: HighlightFormat = { fill: "#FFEB9C", text: "#9C5700", bold: false, italic: false };
const GREEN: HighlightFormat = { fill: "#C6EFCE", text: "#006100", bold: false, italic: false };
const RED_TEXT: HighlightFormat = { text: "#9C0006", bold: false, italic: false };

const green = "#1E8E5A";
const darkGreen = "#1B4332";
const title: CellStyle = { fontSize: 22, bold: true, textColor: darkGreen };
const subtitle: CellStyle = { textColor: "#6C757D" };
const header: CellStyle = { bold: true, fillColor: green, textColor: "#FFFFFF", vertical: "middle" };
const money: CellStyle = { numberFormat: "$#,##0.00" };
const totalMoney: CellStyle = { numberFormat: "$#,##0.00", bold: true, borders: { top: { style: "thin", color: green }, bottom: { style: "double", color: green } } };
const bold: CellStyle = { bold: true };

export const BLANK: WorkbookTemplate = {
  id: "blank", name: "Blank Workbook", subtitle: "An empty sheet", tint: "#1E8E5A",
  build: () => book(Array.from({ length: Math.max(1, Math.min(settings().defaultSheetCount, 16)) }, (_, i) => newSheet(`Sheet${i + 1}`))),
};

const budget: WorkbookTemplate = {
  id: "budget", name: "Monthly Budget", subtitle: "Income, expenses and what's left", tint: "#2F6FDB",
  build() {
    const b = new SheetBuilder("Budget");
    b.set("A1", "Monthly Budget", title);
    b.set("A2", "Adjust the planned amounts; actuals update the chart.", subtitle);
    b.row("A4", ["Income", "Planned", "Actual", "Difference"], header);
    const income: [string, number, number][] = [["Salary", 5200, 5200], ["Freelance", 800, 950], ["Other", 100, 40]];
    income.forEach(([name, planned, actual], i) => {
      const r = 5 + i;
      b.set(`A${r}`, name);
      b.set(`B${r}`, planned, money);
      b.set(`C${r}`, actual, money);
      b.set(`D${r}`, `=C${r}-B${r}`, money);
    });
    b.set("A8", "Total Income", bold);
    b.set("B8", "=SUM(B5:B7)", totalMoney);
    b.set("C8", "=SUM(C5:C7)", totalMoney);
    b.set("D8", "=C8-B8", totalMoney);
    b.row("A10", ["Expenses", "Planned", "Actual", "Difference"], header);
    const expenses: [string, number, number][] = [["Rent", 1800, 1800], ["Groceries", 600, 648.35], ["Utilities", 220, 198.4],
      ["Transport", 180, 215], ["Dining Out", 250, 312.5], ["Subscriptions", 45, 45], ["Savings", 1000, 1000], ["Fun", 300, 260]];
    expenses.forEach(([name, planned, actual], i) => {
      const r = 11 + i;
      b.set(`A${r}`, name);
      b.set(`B${r}`, planned, money);
      b.set(`C${r}`, actual, money);
      b.set(`D${r}`, `=B${r}-C${r}`, money);
    });
    const last = 10 + expenses.length;
    b.set(`A${last + 1}`, "Total Expenses", bold);
    b.set(`B${last + 1}`, `=SUM(B11:B${last})`, totalMoney);
    b.set(`C${last + 1}`, `=SUM(C11:C${last})`, totalMoney);
    b.set(`D${last + 1}`, `=B${last + 1}-C${last + 1}`, totalMoney);
    b.set("F4", "Summary", header);
    b.set("G4", "", header);
    b.set("F5", "Income");
    b.set("G5", "=C8", money);
    b.set("F6", "Expenses");
    b.set("G6", `=C${last + 1}`, money);
    b.set("F7", "Left Over", bold);
    b.set("G7", "=G5-G6", totalMoney);
    b.set("F8", "Savings Rate");
    b.set("G8", "=IFERROR((G7+C17)/G5,0)", { numberFormat: "0.0%" });
    for (const [c, w] of [["A", 150], ["B", 100], ["C", 100], ["D", 100], ["E", 24], ["F", 110], ["G", 110]] as const) b.width(c, w);
    b.sheet.rowHeights.set(0, 34);
    b.sheet.conditionalFormats = [cf(`D11:D${last}`, { type: "lessThan", value: 0 }), cf(`C11:C${last}`, { type: "dataBar", color: "#63BE7B" })];
    b.sheet.charts = [chart("bar", `A10:C${last}`, "Planned vs. Actual", [580, 200, 440, 320], "ocean")];
    return book([b.sheet]);
  },
};

const invoice: WorkbookTemplate = {
  id: "invoice", name: "Invoice", subtitle: "Line items, tax and total", tint: "#F29D38",
  build() {
    const b = new SheetBuilder("Invoice");
    b.set("A1", "INVOICE", { fontSize: 28, bold: true, textColor: "#C8621B" });
    b.set("A3", "Your Company", bold);
    b.set("A4", "123 Market Street");
    b.set("A5", "Springfield, 12345");
    b.set("D3", "Invoice #", bold); b.set("E3", "2026-001");
    b.set("D4", "Date", bold); b.set("E4", "=TODAY()", { numberFormat: "mmmm d, yyyy", horizontal: "left" });
    b.set("D5", "Due", bold); b.set("E5", "=E4+30", { numberFormat: "mmmm d, yyyy", horizontal: "left" });
    b.set("A7", "Bill To", bold);
    b.set("A8", "Client Name");
    b.set("A9", "Client Address");
    b.row("A11", ["Description", "", "Qty", "Unit Price", "Amount"], { bold: true, fillColor: "#C8621B", textColor: "#FFFFFF" });
    b.merge("A11:B11");
    const items: [string, number, number][] = [["Website design", 1, 2400], ["Hosting (12 months)", 12, 25], ["Logo refresh", 1, 650], ["Consulting hours", 6, 120]];
    items.forEach(([name, qty, price], i) => {
      const r = 12 + i;
      b.set(`A${r}`, name);
      b.merge(`A${r}:B${r}`);
      b.set(`C${r}`, qty);
      b.set(`D${r}`, price, money);
      b.set(`E${r}`, `=IF(C${r}="","",C${r}*D${r})`, money);
    });
    for (let r = 16; r <= 18; r++) {
      b.merge(`A${r}:B${r}`);
      b.set(`E${r}`, `=IF(C${r}="","",C${r}*D${r})`, money);
    }
    b.set("D20", "Subtotal", bold); b.set("E20", "=SUM(E12:E18)", money);
    b.set("D21", "Tax rate", bold); b.set("E21", 0.08, { numberFormat: "0.0%" });
    b.set("D22", "Tax", bold); b.set("E22", "=ROUND(E20*E21,2)", money);
    b.set("D23", "Total Due", { bold: true, fontSize: 14 });
    b.set("E23", "=E20+E22", { bold: true, fontSize: 14, numberFormat: "$#,##0.00", fillColor: "#FCE8D8" });
    b.set("A25", "Thank you for your business!", { italic: true, textColor: "#6C757D" });
    for (const [c, w] of [["A", 150], ["B", 110], ["C", 60], ["D", 100], ["E", 120]] as const) b.width(c, w);
    b.sheet.rowHeights.set(0, 44);
    b.sheet.showGridlines = false;
    for (let r = 12; r <= 18; r++) b.style(`A${r}:E${r}`, (s) => ({ ...s, borders: { ...(s.borders ?? {}), bottom: { style: "thin", color: "#E0E0E0" } } }));
    return book([b.sheet]);
  },
};

const loan: WorkbookTemplate = {
  id: "loan", name: "Loan Calculator", subtitle: "Payments and an amortization schedule", tint: "#8E5BD6",
  build() {
    const b = new SheetBuilder("Loan");
    b.set("A1", "Loan Calculator", title);
    b.set("A3", "Loan amount", bold); b.set("B3", 350000, money);
    b.set("A4", "Annual interest rate", bold); b.set("B4", 0.0625, { numberFormat: "0.00%" });
    b.set("A5", "Term (years)", bold); b.set("B5", 30);
    b.set("A6", "Payments per year", bold); b.set("B6", 12);
    for (let r = 3; r <= 6; r++) b.style(`B${r}`, (s) => ({ ...s, fillColor: "#FFF4D6" }));
    b.set("D3", "Monthly payment", bold); b.set("E3", "=-PMT(B4/B6,B5*B6,B3)", totalMoney);
    b.set("D4", "Total paid", bold); b.set("E4", "=E3*B5*B6", money);
    b.set("D5", "Total interest", bold); b.set("E5", "=E4-B3", money);
    b.row("A8", ["#", "Payment", "Principal", "Interest", "Balance"], header);
    for (let i = 1; i <= 360; i++) {
      const r = 8 + i;
      b.set(`A${r}`, i);
      b.set(`B${r}`, "=$E$3", money);
      b.set(`C${r}`, `=-PPMT($B$4/$B$6,A${r},$B$5*$B$6,$B$3)`, money);
      b.set(`D${r}`, `=-IPMT($B$4/$B$6,A${r},$B$5*$B$6,$B$3)`, money);
      b.set(`E${r}`, i === 1 ? `=$B$3-C${r}` : `=E${r - 1}-C${r}`, money);
    }
    for (const [c, w] of [["A", 150], ["B", 110], ["C", 110], ["D", 130], ["E", 120]] as const) b.width(c, w);
    b.sheet.frozenRows = 8;
    b.sheet.charts = [chart("area", "C8:D128", "Principal vs. Interest (first 10 years)", [640, 30, 460, 280], "vivid")];
    return book([b.sheet]);
  },
};

const gradebook: WorkbookTemplate = {
  id: "gradebook", name: "Gradebook", subtitle: "Scores, averages and letter grades", tint: "#D9534F",
  build() {
    const b = new SheetBuilder("Grades");
    b.set("A1", "Class Gradebook", title);
    b.row("A3", ["Student", "Quiz 1", "Quiz 2", "Midterm", "Project", "Final", "Average", "Grade"], header);
    const students: [string, number[]][] = [
      ["Avery Chen", [88, 92, 85, 95, 90]], ["Blake Rivera", [72, 80, 78, 85, 74]], ["Casey Morgan", [95, 98, 93, 97, 96]],
      ["Dana Patel", [65, 70, 62, 78, 68]], ["Emerson Diaz", [81, 77, 88, 90, 84]], ["Finley Brooks", [58, 66, 60, 70, 55]],
      ["Harper Kim", [90, 85, 91, 88, 93]], ["Jordan Lee", [77, 83, 80, 79, 82]],
    ];
    students.forEach(([name, scores], i) => {
      const r = 4 + i;
      b.set(`A${r}`, name);
      b.row(`B${r}`, scores);
      b.set(`G${r}`, `=AVERAGE(B${r}:F${r})`, { numberFormat: "0.0" });
      b.set(`H${r}`, `=IFS(G${r}>=90,"A",G${r}>=80,"B",G${r}>=70,"C",G${r}>=60,"D",TRUE,"F")`, { horizontal: "center", bold: true });
    });
    const end = 3 + students.length;
    b.set(`A${end + 2}`, "Class average", bold);
    for (const c of ["B", "C", "D", "E", "F", "G"]) b.set(`${c}${end + 2}`, `=AVERAGE(${c}4:${c}${end})`, { numberFormat: "0.0", bold: true });
    b.set(`A${end + 3}`, "Highest", bold);
    b.set(`G${end + 3}`, `=MAX(G4:G${end})`, { numberFormat: "0.0" });
    b.set(`A${end + 4}`, "Top student", bold);
    b.set(`G${end + 4}`, `=XLOOKUP(MAX(G4:G${end}),G4:G${end},A4:A${end})`);
    b.width("A", 140);
    for (const c of ["B", "C", "D", "E", "F", "G", "H"]) b.width(c, 76);
    b.sheet.conditionalFormats = [
      cf(`B4:F${end}`, { type: "colorScale", colors: ["#F8696B", "#FFEB84", "#63BE7B"] }),
      cf(`H4:H${end}`, { type: "equalTo", text: "F" }, LIGHT_RED),
      cf(`H4:H${end}`, { type: "equalTo", text: "A" }, GREEN),
    ];
    b.sheet.frozenRows = 3;
    b.sheet.frozenColumns = 1;
    b.sheet.filter = { range: parseRange(`A3:H${end}`)!, criteria: new Map(), hiddenRows: new Set() };
    return book([b.sheet]);
  },
};

const tracker: WorkbookTemplate = {
  id: "tracker", name: "Project Tracker", subtitle: "Tasks, owners, status and due dates", tint: "#17A2B8",
  build() {
    const b = new SheetBuilder("Tasks");
    b.set("A1", "Project Tracker", title);
    b.set("A2", '=COUNTIF(D5:D30,"Done")&" of "&COUNTA(A5:A30)&" tasks done"', subtitle);
    b.row("A4", ["Task", "Owner", "Due", "Status", "Priority", "Days Left"], header);
    const tasks: [string, string, number, string, string][] = [
      ["Kickoff meeting", "Sam", -10, "Done", "High"], ["Gather requirements", "Riley", -4, "Done", "High"],
      ["Design mockups", "Alex", 3, "In Progress", "High"], ["Build prototype", "Jamie", 12, "Not Started", "Medium"],
      ["User testing", "Riley", 20, "Not Started", "Medium"], ["Write documentation", "Sam", 25, "Not Started", "Low"],
      ["Launch", "Alex", 30, "Not Started", "High"],
    ];
    const today = Math.floor(serialFromDate(new Date()));
    tasks.forEach(([task, owner, due, status, priority], i) => {
      const r = 5 + i;
      b.set(`A${r}`, task);
      b.set(`B${r}`, owner);
      b.set(`C${r}`, today + due, { numberFormat: "mmm d" });
      b.set(`D${r}`, status);
      b.set(`E${r}`, priority, { horizontal: "center" });
      b.set(`F${r}`, `=IF(D${r}="Done","—",C${r}-TODAY())`, { horizontal: "right" });
    });
    const end = 4 + tasks.length;
    for (const [c, w] of [["A", 190], ["B", 90], ["C", 80], ["D", 110], ["E", 80], ["F", 80]] as const) b.width(c, w);
    b.sheet.conditionalFormats = [
      cf(`D5:D${end}`, { type: "equalTo", text: "Done" }, GREEN),
      cf(`D5:D${end}`, { type: "equalTo", text: "In Progress" }, YELLOW),
      cf(`E5:E${end}`, { type: "equalTo", text: "High" }, RED_TEXT),
      cf(`F5:F${end}`, { type: "lessThan", value: 0 }, LIGHT_RED),
    ];
    const tableStyle: TableStyle = "teal";
    b.sheet.tables = [{ id: uuid(), name: "Tasks", range: parseRange(`A4:F${end}`)!, style: tableStyle, showHeader: true, bandedRows: true, showTotals: false }];
    b.sheet.filter = { range: parseRange(`A4:F${end}`)!, criteria: new Map(), hiddenRows: new Set() };
    b.sheet.frozenRows = 4;
    return book([b.sheet]);
  },
};

const sales: WorkbookTemplate = {
  id: "sales", name: "Sales Dashboard", subtitle: "Monthly sales by region with charts", tint: "#E83E8C",
  build() {
    const b = new SheetBuilder("Sales");
    b.set("A1", "Sales Dashboard", title);
    b.row("A3", ["Month", "North", "South", "East", "West", "Total"], header);
    const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    const base = [42, 38, 51, 47];
    months.forEach((month, i) => {
      const r = 4 + i;
      b.set(`A${r}`, month);
      ["B", "C", "D", "E"].forEach((c, j) => {
        const seasonal = 1 + 0.25 * Math.sin((i / 12) * 2 * Math.PI + j);
        b.set(`${c}${r}`, Math.round(base[j] * seasonal * (1 + i * 0.03) * 1000), { numberFormat: "$#,##0" });
      });
      b.set(`F${r}`, `=SUM(B${r}:E${r})`, { numberFormat: "$#,##0", bold: true });
    });
    b.set("A16", "Total", bold);
    for (const c of ["B", "C", "D", "E", "F"]) {
      b.set(`${c}16`, `=SUM(${c}4:${c}15)`, { numberFormat: "$#,##0", bold: true, borders: { top: { style: "thin", color: green }, bottom: { style: "double", color: green } } });
    }
    b.set("H3", "Highlights", header); b.set("I3", "", header);
    b.set("H4", "Best month"); b.set("I4", "=INDEX(A4:A15,MATCH(MAX(F4:F15),F4:F15,0))");
    b.set("H5", "Best region"); b.set("I5", "=INDEX(B3:E3,MATCH(MAX(B16:E16),B16:E16,0))");
    b.set("H6", "Average month"); b.set("I6", "=AVERAGE(F4:F15)", { numberFormat: "$#,##0" });
    b.set("H7", "Growth (Dec vs Jan)"); b.set("I7", "=F15/F4-1", { numberFormat: "+0.0%;-0.0%" });
    b.width("A", 80);
    for (const c of ["B", "C", "D", "E", "F"]) b.width(c, 90);
    b.width("G", 24); b.width("H", 140); b.width("I", 100);
    b.sheet.conditionalFormats = [cf("F4:F15", { type: "dataBar", color: "#E83E8C" })];
    // A small helper table (region names over yearly totals) feeds the pie.
    b.row("K3", ["Region", "Total"], header);
    ["North", "South", "East", "West"].forEach((region, i) => {
      b.set(`K${4 + i}`, region);
      b.set(`L${4 + i}`, `=${["B", "C", "D", "E"][i]}16`, { numberFormat: "$#,##0" });
    });
    b.width("J", 24); b.width("K", 90); b.width("L", 100);
    b.sheet.charts = [
      chart("line", "A3:E15", "Monthly Sales by Region", [0, 380, 520, 300]),
      chart("pie", "K3:L7", "Share by Region", [540, 380, 360, 300], "sunset"),
    ];
    return book([b.sheet]);
  },
};

export const TEMPLATES: WorkbookTemplate[] = [BLANK, budget, invoice, loan, gradebook, tracker, sales];
