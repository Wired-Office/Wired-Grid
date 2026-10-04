import AppKit

/// A starting point in the template chooser.
struct WorkbookTemplate: Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String
    let symbol: String
    let tint: RGBColor
    let build: () -> Workbook

    static func == (a: WorkbookTemplate, b: WorkbookTemplate) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Builds sheets tersely: `b.set("A1", "Title", style)`.
private struct SheetBuilder {
    var sheet: Sheet

    init(_ name: String) { sheet = Sheet(name: name) }

    mutating func set(_ a1: String, _ content: Any, _ style: CellStyle? = nil) {
        guard let address = CellAddress(a1: a1) else { return }
        var cell = Cell(style: style)
        switch content {
        case let text as String where text.hasPrefix("="):
            cell.formula = (try? WorkbookController.normalizeFormula(String(text.dropFirst()))) ?? String(text.dropFirst())
        case let text as String: cell.value = .string(text)
        case let number as Double: cell.value = .number(number)
        case let number as Int: cell.value = .number(Double(number))
        case let flag as Bool: cell.value = .bool(flag)
        default: break
        }
        sheet[address] = cell
    }

    mutating func row(_ a1: String, _ values: [Any], _ style: CellStyle? = nil) {
        guard let start = CellAddress(a1: a1) else { return }
        for (i, value) in values.enumerated() { set(start.offset(columns: i).a1, value, style) }
    }

    mutating func style(_ range: String, _ change: (inout CellStyle) -> Void) {
        guard let r = CellRange(a1: range) else { return }
        for address in r.addresses { sheet.updateStyle(at: address, change) }
    }

    mutating func width(_ column: String, _ width: Double) {
        if let c = CellAddress.columnIndex(column) { sheet.columnWidths[c] = width }
    }

    mutating func merge(_ range: String) {
        if let r = CellRange(a1: range) { sheet.merges.append(r) }
    }
}

private extension CellStyle {
    static func make(_ change: (inout CellStyle) -> Void) -> CellStyle {
        var s = CellStyle()
        change(&s)
        return s
    }
}

enum TemplateLibrary {
    static let blank = WorkbookTemplate(id: "blank", name: "Blank Workbook", subtitle: "An empty sheet", symbol: "tablecells", tint: RGBColor(0x1E8E5A)) {
        var workbook = Workbook(sheets: (1...AppSettings.shared.defaultSheetCount).map { Sheet(name: "Sheet\($0)") })
        workbook.author = AppSettings.shared.authorName
        return workbook
    }

    static let all: [WorkbookTemplate] = [blank, budget, invoice, loan, gradebook, tracker, sales]

    private static let green = RGBColor(0x1E8E5A)
    private static let darkGreen = RGBColor(0x1B4332)
    private static let title = CellStyle.make { $0.fontSize = 22; $0.bold = true; $0.textColor = darkGreen }
    private static let subtitle = CellStyle.make { $0.textColor = RGBColor(0x6C757D) }
    private static let header = CellStyle.make {
        $0.bold = true; $0.fillColor = green; $0.textColor = .white; $0.vertical = .middle
    }
    private static let money = CellStyle.make { $0.numberFormat = "$#,##0.00" }
    private static let totalMoney = CellStyle.make {
        $0.numberFormat = "$#,##0.00"; $0.bold = true
        $0.borders.top = BorderLine(style: .thin, color: green)
        $0.borders.bottom = BorderLine(style: .double, color: green)
    }
    private static let bold = CellStyle.make { $0.bold = true }

    // MARK: Budget

    static let budget = WorkbookTemplate(id: "budget", name: "Monthly Budget", subtitle: "Income, expenses and what's left", symbol: "chart.pie", tint: RGBColor(0x2F6FDB)) {
        var b = SheetBuilder("Budget")
        b.set("A1", "Monthly Budget", title)
        b.set("A2", "Adjust the planned amounts; actuals update the chart.", subtitle)
        b.row("A4", ["Income", "Planned", "Actual", "Difference"], header)
        let income: [(String, Double, Double)] = [("Salary", 5200, 5200), ("Freelance", 800, 950), ("Other", 100, 40)]
        for (i, item) in income.enumerated() {
            let r = 5 + i
            b.row("A\(r)", [item.0], nil)
            b.set("B\(r)", item.1, money)
            b.set("C\(r)", item.2, money)
            b.set("D\(r)", "=C\(r)-B\(r)", money)
        }
        b.set("A8", "Total Income", bold)
        b.set("B8", "=SUM(B5:B7)", totalMoney)
        b.set("C8", "=SUM(C5:C7)", totalMoney)
        b.set("D8", "=C8-B8", totalMoney)

        b.row("A10", ["Expenses", "Planned", "Actual", "Difference"], header)
        let expenses: [(String, Double, Double)] = [("Rent", 1800, 1800), ("Groceries", 600, 648.35), ("Utilities", 220, 198.4),
                                                     ("Transport", 180, 215), ("Dining Out", 250, 312.5), ("Subscriptions", 45, 45),
                                                     ("Savings", 1000, 1000), ("Fun", 300, 260)]
        for (i, item) in expenses.enumerated() {
            let r = 11 + i
            b.set("A\(r)", item.0)
            b.set("B\(r)", item.1, money)
            b.set("C\(r)", item.2, money)
            b.set("D\(r)", "=B\(r)-C\(r)", money)
        }
        let last = 10 + expenses.count
        b.set("A\(last + 1)", "Total Expenses", bold)
        b.set("B\(last + 1)", "=SUM(B11:B\(last))", totalMoney)
        b.set("C\(last + 1)", "=SUM(C11:C\(last))", totalMoney)
        b.set("D\(last + 1)", "=B\(last + 1)-C\(last + 1)", totalMoney)

        b.set("F4", "Summary", header)
        b.set("G4", "", header)
        b.set("F5", "Income")
        b.set("G5", "=C8", money)
        b.set("F6", "Expenses")
        b.set("G6", "=C\(last + 1)", money)
        b.set("F7", "Left Over", bold)
        b.set("G7", "=G5-G6", totalMoney)
        b.set("F8", "Savings Rate")
        b.set("G8", "=IFERROR((G7+C17)/G5,0)", CellStyle.make { $0.numberFormat = "0.0%" })
        b.width("A", 150); b.width("B", 100); b.width("C", 100); b.width("D", 100); b.width("E", 24); b.width("F", 110); b.width("G", 110)
        b.sheet.rowHeights[0] = 34
        b.sheet.conditionalFormats = [
            ConditionalFormat(range: CellRange(a1: "D11:D\(last)")!, rule: .lessThan(0), format: .lightRed),
            ConditionalFormat(range: CellRange(a1: "C11:C\(last)")!, rule: .dataBar(RGBColor(0x63BE7B))),
        ]
        b.sheet.charts = [ChartObject(kind: .bar, dataRange: CellRange(a1: "A10:C\(last)")!, title: "Planned vs. Actual",
                                      frame: CGRect(x: 580, y: 200, width: 440, height: 320), palette: .ocean)]
        return Workbook(sheets: [b.sheet])
    }

    // MARK: Invoice

    static let invoice = WorkbookTemplate(id: "invoice", name: "Invoice", subtitle: "Line items, tax and total", symbol: "doc.text", tint: RGBColor(0xF29D38)) {
        var b = SheetBuilder("Invoice")
        b.set("A1", "INVOICE", CellStyle.make { $0.fontSize = 28; $0.bold = true; $0.textColor = RGBColor(0xC8621B) })
        b.set("A3", "Your Company", bold)
        b.set("A4", "123 Market Street")
        b.set("A5", "Springfield, 12345")
        b.set("D3", "Invoice #", bold); b.set("E3", "2026-001")
        b.set("D4", "Date", bold); b.set("E4", "=TODAY()", CellStyle.make { $0.numberFormat = "mmmm d, yyyy"; $0.horizontal = .left })
        b.set("D5", "Due", bold); b.set("E5", "=E4+30", CellStyle.make { $0.numberFormat = "mmmm d, yyyy"; $0.horizontal = .left })
        b.set("A7", "Bill To", bold)
        b.set("A8", "Client Name")
        b.set("A9", "Client Address")
        let orange = CellStyle.make { $0.bold = true; $0.fillColor = RGBColor(0xC8621B); $0.textColor = .white }
        b.row("A11", ["Description", "", "Qty", "Unit Price", "Amount"], orange)
        b.merge("A11:B11")
        let items: [(String, Double, Double)] = [("Website design", 1, 2400), ("Hosting (12 months)", 12, 25), ("Logo refresh", 1, 650), ("Consulting hours", 6, 120)]
        for (i, item) in items.enumerated() {
            let r = 12 + i
            b.set("A\(r)", item.0)
            b.merge("A\(r):B\(r)")
            b.set("C\(r)", item.1)
            b.set("D\(r)", item.2, money)
            b.set("E\(r)", "=IF(C\(r)=\"\",\"\",C\(r)*D\(r))", money)
        }
        for r in 16...18 { b.merge("A\(r):B\(r)"); b.set("E\(r)", "=IF(C\(r)=\"\",\"\",C\(r)*D\(r))", money) }
        b.set("D20", "Subtotal", bold); b.set("E20", "=SUM(E12:E18)", money)
        b.set("D21", "Tax rate", bold); b.set("E21", 0.08, CellStyle.make { $0.numberFormat = "0.0%" })
        b.set("D22", "Tax", bold); b.set("E22", "=ROUND(E20*E21,2)", money)
        b.set("D23", "Total Due", CellStyle.make { $0.bold = true; $0.fontSize = 14 })
        b.set("E23", "=E20+E22", CellStyle.make { $0.bold = true; $0.fontSize = 14; $0.numberFormat = "$#,##0.00"; $0.fillColor = RGBColor(0xFCE8D8) })
        b.set("A25", "Thank you for your business!", CellStyle.make { $0.italic = true; $0.textColor = RGBColor(0x6C757D) })
        b.width("A", 150); b.width("B", 110); b.width("C", 60); b.width("D", 100); b.width("E", 120)
        b.sheet.rowHeights[0] = 44
        b.sheet.showGridlines = false
        for r in 12...18 { b.style("A\(r):E\(r)") { $0.borders.bottom = BorderLine(style: .thin, color: RGBColor(0xE0E0E0)) } }
        return Workbook(sheets: [b.sheet])
    }

    // MARK: Loan

    static let loan = WorkbookTemplate(id: "loan", name: "Loan Calculator", subtitle: "Payments and an amortization schedule", symbol: "house", tint: RGBColor(0x8E5BD6)) {
        var b = SheetBuilder("Loan")
        b.set("A1", "Loan Calculator", title)
        b.set("A3", "Loan amount", bold); b.set("B3", 350000, money)
        b.set("A4", "Annual interest rate", bold); b.set("B4", 0.0625, CellStyle.make { $0.numberFormat = "0.00%" })
        b.set("A5", "Term (years)", bold); b.set("B5", 30)
        b.set("A6", "Payments per year", bold); b.set("B6", 12)
        let input = CellStyle.make { $0.fillColor = RGBColor(0xFFF4D6) }
        for r in 3...6 { b.style("B\(r)") { $0.fillColor = input.fillColor } }
        b.set("D3", "Monthly payment", bold); b.set("E3", "=-PMT(B4/B6,B5*B6,B3)", totalMoney)
        b.set("D4", "Total paid", bold); b.set("E4", "=E3*B5*B6", money)
        b.set("D5", "Total interest", bold); b.set("E5", "=E4-B3", money)
        b.row("A8", ["#", "Payment", "Principal", "Interest", "Balance"], header)
        for i in 1...360 {
            let r = 8 + i
            b.set("A\(r)", i)
            b.set("B\(r)", "=$E$3", money)
            b.set("C\(r)", "=-PPMT($B$4/$B$6,A\(r),$B$5*$B$6,$B$3)", money)
            b.set("D\(r)", "=-IPMT($B$4/$B$6,A\(r),$B$5*$B$6,$B$3)", money)
            b.set("E\(r)", i == 1 ? "=$B$3-C\(r)" : "=E\(r - 1)-C\(r)", money)
        }
        b.width("A", 150); b.width("B", 110); b.width("C", 110); b.width("D", 130); b.width("E", 120)
        b.sheet.frozenRows = 8
        b.sheet.charts = [ChartObject(kind: .area, dataRange: CellRange(a1: "C8:D128")!, title: "Principal vs. Interest (first 10 years)",
                                      frame: CGRect(x: 640, y: 30, width: 460, height: 280), showLegend: true, palette: .vivid)]
        return Workbook(sheets: [b.sheet])
    }

    // MARK: Gradebook

    static let gradebook = WorkbookTemplate(id: "gradebook", name: "Gradebook", subtitle: "Scores, averages and letter grades", symbol: "graduationcap", tint: RGBColor(0xD9534F)) {
        var b = SheetBuilder("Grades")
        b.set("A1", "Class Gradebook", title)
        b.row("A3", ["Student", "Quiz 1", "Quiz 2", "Midterm", "Project", "Final", "Average", "Grade"], header)
        let students: [(String, [Double])] = [
            ("Avery Chen", [88, 92, 85, 95, 90]), ("Blake Rivera", [72, 80, 78, 85, 74]), ("Casey Morgan", [95, 98, 93, 97, 96]),
            ("Dana Patel", [65, 70, 62, 78, 68]), ("Emerson Diaz", [81, 77, 88, 90, 84]), ("Finley Brooks", [58, 66, 60, 70, 55]),
            ("Harper Kim", [90, 85, 91, 88, 93]), ("Jordan Lee", [77, 83, 80, 79, 82]),
        ]
        for (i, student) in students.enumerated() {
            let r = 4 + i
            b.set("A\(r)", student.0)
            b.row("B\(r)", student.1.map { $0 as Any })
            b.set("G\(r)", "=AVERAGE(B\(r):F\(r))", CellStyle.make { $0.numberFormat = "0.0" })
            b.set("H\(r)", "=IFS(G\(r)>=90,\"A\",G\(r)>=80,\"B\",G\(r)>=70,\"C\",G\(r)>=60,\"D\",TRUE,\"F\")", CellStyle.make { $0.horizontal = .center; $0.bold = true })
        }
        let end = 3 + students.count
        b.set("A\(end + 2)", "Class average", bold)
        for column in ["B", "C", "D", "E", "F", "G"] {
            b.set("\(column)\(end + 2)", "=AVERAGE(\(column)4:\(column)\(end))", CellStyle.make { $0.numberFormat = "0.0"; $0.bold = true })
        }
        b.set("A\(end + 3)", "Highest", bold)
        b.set("G\(end + 3)", "=MAX(G4:G\(end))", CellStyle.make { $0.numberFormat = "0.0" })
        b.set("A\(end + 4)", "Top student", bold)
        b.set("G\(end + 4)", "=XLOOKUP(MAX(G4:G\(end)),G4:G\(end),A4:A\(end))")
        b.width("A", 140)
        for column in ["B", "C", "D", "E", "F", "G", "H"] { b.width(column, 76) }
        b.sheet.conditionalFormats = [
            ConditionalFormat(range: CellRange(a1: "B4:F\(end)")!, rule: .colorScale([RGBColor(0xF8696B), RGBColor(0xFFEB84), RGBColor(0x63BE7B)])),
            ConditionalFormat(range: CellRange(a1: "H4:H\(end)")!, rule: .equalTo("F"), format: .lightRed),
            ConditionalFormat(range: CellRange(a1: "H4:H\(end)")!, rule: .equalTo("A"), format: .green),
        ]
        b.sheet.frozenRows = 3
        b.sheet.frozenColumns = 1
        b.sheet.filter = AutoFilter(range: CellRange(a1: "A3:H\(end)")!)
        return Workbook(sheets: [b.sheet])
    }

    // MARK: Project tracker

    static let tracker = WorkbookTemplate(id: "tracker", name: "Project Tracker", subtitle: "Tasks, owners, status and due dates", symbol: "checklist", tint: RGBColor(0x17A2B8)) {
        var b = SheetBuilder("Tasks")
        b.set("A1", "Project Tracker", title)
        b.set("A2", "=COUNTIF(D5:D30,\"Done\")&\" of \"&COUNTA(A5:A30)&\" tasks done\"", subtitle)
        b.row("A4", ["Task", "Owner", "Due", "Status", "Priority", "Days Left"], header)
        let tasks: [(String, String, Int, String, String)] = [
            ("Kickoff meeting", "Sam", -10, "Done", "High"), ("Gather requirements", "Riley", -4, "Done", "High"),
            ("Design mockups", "Alex", 3, "In Progress", "High"), ("Build prototype", "Jamie", 12, "Not Started", "Medium"),
            ("User testing", "Riley", 20, "Not Started", "Medium"), ("Write documentation", "Sam", 25, "Not Started", "Low"),
            ("Launch", "Alex", 30, "Not Started", "High"),
        ]
        let today = DateSerial.from(Date()).rounded(.down)
        for (i, task) in tasks.enumerated() {
            let r = 5 + i
            b.set("A\(r)", task.0)
            b.set("B\(r)", task.1)
            b.set("C\(r)", today + Double(task.2), CellStyle.make { $0.numberFormat = "mmm d" })
            b.set("D\(r)", task.3)
            b.set("E\(r)", task.4, CellStyle.make { $0.horizontal = .center })
            b.set("F\(r)", "=IF(D\(r)=\"Done\",\"—\",C\(r)-TODAY())", CellStyle.make { $0.horizontal = .right })
        }
        let end = 4 + tasks.count
        b.width("A", 190); b.width("B", 90); b.width("C", 80); b.width("D", 110); b.width("E", 80); b.width("F", 80)
        b.sheet.conditionalFormats = [
            ConditionalFormat(range: CellRange(a1: "D5:D\(end)")!, rule: .equalTo("Done"), format: .green),
            ConditionalFormat(range: CellRange(a1: "D5:D\(end)")!, rule: .equalTo("In Progress"), format: .yellow),
            ConditionalFormat(range: CellRange(a1: "E5:E\(end)")!, rule: .equalTo("High"), format: .redText),
            ConditionalFormat(range: CellRange(a1: "F5:F\(end)")!, rule: .lessThan(0), format: .lightRed),
        ]
        b.sheet.tables = [TableObject(name: "Tasks", range: CellRange(a1: "A4:F\(end)")!, style: .teal)]
        b.sheet.filter = AutoFilter(range: CellRange(a1: "A4:F\(end)")!)
        b.sheet.frozenRows = 4
        return Workbook(sheets: [b.sheet])
    }

    // MARK: Sales dashboard

    static let sales = WorkbookTemplate(id: "sales", name: "Sales Dashboard", subtitle: "Monthly sales by region with charts", symbol: "chart.line.uptrend.xyaxis", tint: RGBColor(0xE83E8C)) {
        var b = SheetBuilder("Sales")
        b.set("A1", "Sales Dashboard", title)
        b.row("A3", ["Month", "North", "South", "East", "West", "Total"], header)
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let base: [Double] = [42, 38, 51, 47]
        for (i, month) in months.enumerated() {
            let r = 4 + i
            b.set("A\(r)", month)
            for (j, column) in ["B", "C", "D", "E"].enumerated() {
                let seasonal = 1 + 0.25 * sin(Double(i) / 12 * 2 * .pi + Double(j))
                let value = (base[j] * seasonal * (1 + Double(i) * 0.03) * 1000).rounded()
                b.set("\(column)\(r)", value, CellStyle.make { $0.numberFormat = "$#,##0" })
            }
            b.set("F\(r)", "=SUM(B\(r):E\(r))", CellStyle.make { $0.numberFormat = "$#,##0"; $0.bold = true })
        }
        b.set("A16", "Total", bold)
        for column in ["B", "C", "D", "E", "F"] {
            b.set("\(column)16", "=SUM(\(column)4:\(column)15)", CellStyle.make {
                $0.numberFormat = "$#,##0"; $0.bold = true
                $0.borders.top = BorderLine(style: .thin, color: green)
                $0.borders.bottom = BorderLine(style: .double, color: green)
            })
        }
        b.set("H3", "Highlights", header); b.set("I3", "", header)
        b.set("H4", "Best month"); b.set("I4", "=INDEX(A4:A15,MATCH(MAX(F4:F15),F4:F15,0))")
        b.set("H5", "Best region"); b.set("I5", "=INDEX(B3:E3,MATCH(MAX(B16:E16),B16:E16,0))")
        b.set("H6", "Average month"); b.set("I6", "=AVERAGE(F4:F15)", CellStyle.make { $0.numberFormat = "$#,##0" })
        b.set("H7", "Growth (Dec vs Jan)"); b.set("I7", "=F15/F4-1", CellStyle.make { $0.numberFormat = "+0.0%;-0.0%" })
        b.width("A", 80)
        for column in ["B", "C", "D", "E", "F"] { b.width(column, 90) }
        b.width("G", 24); b.width("H", 140); b.width("I", 100)
        b.sheet.conditionalFormats = [ConditionalFormat(range: CellRange(a1: "F4:F15")!, rule: .dataBar(RGBColor(0xE83E8C)))]
        // A small helper table (region names over yearly totals) feeds the pie.
        b.row("K3", ["Region", "Total"], header)
        for (i, region) in ["North", "South", "East", "West"].enumerated() {
            b.set("K\(4 + i)", region)
            b.set("L\(4 + i)", "=\(["B", "C", "D", "E"][i])16", CellStyle.make { $0.numberFormat = "$#,##0" })
        }
        b.width("J", 24); b.width("K", 90); b.width("L", 100)
        b.sheet.charts = [
            ChartObject(kind: .line, dataRange: CellRange(a1: "A3:E15")!, title: "Monthly Sales by Region", frame: CGRect(x: 0, y: 380, width: 520, height: 300)),
            ChartObject(kind: .pie, dataRange: CellRange(a1: "K3:L7")!, title: "Share by Region", frame: CGRect(x: 540, y: 380, width: 360, height: 300), palette: .sunset),
        ]
        return Workbook(sheets: [b.sheet])
    }
}
