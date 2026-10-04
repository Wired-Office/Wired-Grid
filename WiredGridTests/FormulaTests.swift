import XCTest
@testable import WiredGrid

final class FormulaTests: XCTestCase {
    /// Builds a one-sheet workbook from A1-keyed entries ("=…" are formulas) and evaluates `formula`.
    private func eval(_ formula: String, _ cells: [String: Any] = [:]) -> CellValue {
        var sheet = Sheet(name: "Sheet1")
        for (a1, content) in cells {
            let address = CellAddress(a1: a1)!
            switch content {
            case let s as String where s.hasPrefix("="): sheet[address] = Cell(formula: String(s.dropFirst()))
            case let s as String: sheet[address] = Cell(value: .string(s))
            case let n as Double: sheet[address] = Cell(value: .number(n))
            case let n as Int: sheet[address] = Cell(value: .number(Double(n)))
            case let b as Bool: sheet[address] = Cell(value: .bool(b))
            default: break
            }
        }
        sheet[CellAddress(a1: "Z100")!] = Cell(formula: formula)
        let calculator = Calculator(workbook: Workbook(sheets: [sheet]))
        calculator.recalculate()
        return calculator.value(sheet: 0, at: CellAddress(a1: "Z100")!)
    }

    private func number(_ formula: String, _ cells: [String: Any] = [:], file: StaticString = #filePath, line: UInt = #line) -> Double {
        guard case .number(let n) = eval(formula, cells) else {
            XCTFail("\(formula) → \(eval(formula, cells))", file: file, line: line)
            return .nan
        }
        return n
    }

    func testArithmeticAndPrecedence() {
        XCTAssertEqual(number("1+2*3"), 7)
        XCTAssertEqual(number("(1+2)*3"), 9)
        XCTAssertEqual(number("-2^2"), 4)          // negation binds tighter than ^, as in Excel
        XCTAssertEqual(number("2^3^2"), 64)        // left-associative
        XCTAssertEqual(number("50%*10"), 5)
        XCTAssertEqual(eval("1/0"), .error(.div0))
        XCTAssertEqual(eval("\"a\"&1&TRUE"), .string("a1TRUE"))
        XCTAssertEqual(eval("\"abc\"=\"ABC\""), .bool(true))
    }

    func testReferencesAndRanges() {
        let cells: [String: Any] = ["A1": 1, "A2": 2, "A3": 3, "B1": "x", "C1": "=A1+A2"]
        XCTAssertEqual(number("SUM(A1:A3)", cells), 6)
        XCTAssertEqual(number("SUM(A:A)", cells), 6)
        XCTAssertEqual(number("C1*10", cells), 30)
        XCTAssertEqual(number("COUNT(A1:B3)", cells), 3)
        XCTAssertEqual(number("COUNTA(A1:B3)", cells), 4)
        XCTAssertEqual(number("SUMPRODUCT(A1:A3,A1:A3)", cells), 14)
        XCTAssertEqual(number("SUM(A1:A3*2)", cells), 12)   // array arithmetic
    }

    func testConditionalAggregates() {
        let cells: [String: Any] = ["A1": "apple", "A2": "banana", "A3": "apple", "B1": 10, "B2": 20, "B3": 30]
        XCTAssertEqual(number("SUMIF(A1:A3,\"apple\",B1:B3)", cells), 40)
        XCTAssertEqual(number("COUNTIF(B1:B3,\">15\")", cells), 2)
        XCTAssertEqual(number("AVERAGEIFS(B1:B3,A1:A3,\"a*\",B1:B3,\"<25\")", cells), 10)
        XCTAssertEqual(number("MAXIFS(B1:B3,A1:A3,\"apple\")", cells), 30)
    }

    func testLogical() {
        XCTAssertEqual(eval("IF(1>2,\"y\",\"n\")"), .string("n"))
        XCTAssertEqual(eval("IFERROR(1/0,\"oops\")"), .string("oops"))
        XCTAssertEqual(eval("IFS(FALSE,1,TRUE,2)"), .number(2))
        XCTAssertEqual(eval("SWITCH(2,1,\"a\",2,\"b\",\"c\")"), .string("b"))
        XCTAssertEqual(number("LET(x,3,y,4,SQRT(x^2+y^2))"), 5)
        XCTAssertEqual(eval("AND(TRUE,1,\"TRUE\")"), .bool(true))
    }

    func testLookup() {
        let cells: [String: Any] = ["A1": "id", "A2": 1, "A3": 2, "A4": 3, "B1": "name", "B2": "Ann", "B3": "Bo", "B4": "Cy"]
        XCTAssertEqual(eval("VLOOKUP(2,A2:B4,2,FALSE)", cells), .string("Bo"))
        XCTAssertEqual(eval("VLOOKUP(2.5,A2:B4,2)", cells), .string("Bo"))
        XCTAssertEqual(eval("XLOOKUP(\"Cy\",B2:B4,A2:A4)", cells), .number(3))
        XCTAssertEqual(eval("XLOOKUP(9,A2:A4,B2:B4,\"none\")", cells), .string("none"))
        XCTAssertEqual(eval("INDEX(B2:B4,MATCH(3,A2:A4,0))", cells), .string("Cy"))
        XCTAssertEqual(eval("HLOOKUP(\"name\",A1:B4,3,FALSE)", cells), .string("Bo"))
        XCTAssertEqual(eval("MATCH(\"b*\",B2:B4,0)", cells), .number(2))
    }

    func testDynamicArraysSpill() {
        var sheet = Sheet(name: "Sheet1")
        sheet[CellAddress(a1: "A1")!] = Cell(formula: "SEQUENCE(3,2,10,10)")
        sheet[CellAddress(a1: "D1")!] = Cell(formula: "SUM(A1:B3)")
        sheet[CellAddress(a1: "F1")!] = Cell(formula: "SEQUENCE(2)")
        sheet[CellAddress(a1: "F2")!] = Cell(value: .string("blocked"))
        let calculator = Calculator(workbook: Workbook(sheets: [sheet]))
        calculator.recalculate()
        XCTAssertEqual(calculator.value(sheet: 0, at: CellAddress(a1: "B3")!), .number(60))
        XCTAssertEqual(calculator.value(sheet: 0, at: CellAddress(a1: "D1")!), .number(210))
        XCTAssertEqual(calculator.value(sheet: 0, at: CellAddress(a1: "F1")!), .error(.spill))
    }

    func testSortUniqueFilter() {
        let cells: [String: Any] = ["A1": 3, "A2": 1, "A3": 3, "A4": 2]
        XCTAssertEqual(eval("INDEX(SORT(A1:A4),1)", cells), .number(1))
        XCTAssertEqual(number("ROWS(UNIQUE(A1:A4))", cells), 3)
        XCTAssertEqual(number("SUM(FILTER(A1:A4,A1:A4>1))", cells), 8)
    }

    func testText() {
        XCTAssertEqual(eval("LEFT(\"Spreadsheet\",6)"), .string("Spread"))
        XCTAssertEqual(eval("PROPER(\"hello wired grid\")"), .string("Hello Wired Grid"))
        XCTAssertEqual(eval("TEXTJOIN(\", \",TRUE,\"a\",\"\",\"b\")"), .string("a, b"))
        XCTAssertEqual(eval("SUBSTITUTE(\"a-b-c\",\"-\",\"+\",2)"), .string("a-b+c"))
        XCTAssertEqual(number("SEARCH(\"GRID\",\"wired grid\")"), 7)
        XCTAssertEqual(eval("TEXT(1234.5,\"$#,##0.00\")"), .string("$1,234.50"))
        XCTAssertEqual(eval("TEXT(0.256,\"0.0%\")"), .string("25.6%"))
        XCTAssertEqual(number("VALUE(\"1,234.5\")"), 1234.5)
    }

    func testDates() {
        XCTAssertEqual(number("DATE(2024,1,15)"), 45306)
        XCTAssertEqual(number("DATE(2024,14,1)"), number("DATE(2025,2,1)"))
        XCTAssertEqual(number("YEAR(45306)"), 2024)
        XCTAssertEqual(number("WEEKDAY(DATE(2024,1,15))"), 2) // Monday
        XCTAssertEqual(number("EOMONTH(DATE(2024,1,15),1)"), number("DATE(2024,2,29)"))
        XCTAssertEqual(number("DATEDIF(DATE(2020,5,10),DATE(2024,5,9),\"Y\")"), 3)
        XCTAssertEqual(number("NETWORKDAYS(DATE(2024,1,1),DATE(2024,1,12))"), 10)
    }

    func testFinancial() {
        XCTAssertEqual(number("PMT(0.05/12,360,200000)"), -1073.6432460242795, accuracy: 1e-6)
        XCTAssertEqual(number("FV(0.06/12,120,-100)"), 16387.93, accuracy: 0.01)
        XCTAssertEqual(number("RATE(360,-1073.64,200000)*12"), 0.05, accuracy: 1e-5)
        XCTAssertEqual(number("IRR({-100,30,40,50})"), 0.0889633947, accuracy: 1e-6)
        XCTAssertEqual(number("NPV(0.1,100,100)"), 173.5537, accuracy: 1e-4)
    }

    func testStatistics() {
        let cells: [String: Any] = ["A1": 2, "A2": 4, "A3": 4, "A4": 4, "A5": 5, "A6": 5, "A7": 7, "A8": 9]
        XCTAssertEqual(number("STDEV.P(A1:A8)", cells), 2)
        XCTAssertEqual(number("MEDIAN(A1:A8)", cells), 4.5)
        XCTAssertEqual(number("MODE(A1:A8)", cells), 4)
        XCTAssertEqual(number("LARGE(A1:A8,2)", cells), 7)
        XCTAssertEqual(number("PERCENTILE(A1:A8,0.5)", cells), 4.5)
        XCTAssertEqual(number("NORM.S.INV(0.975)"), 1.959964, accuracy: 1e-5)
    }

    func testErrorsAndCycles() {
        XCTAssertEqual(eval("NOSUCHFUNC(1)"), .error(.name))
        XCTAssertEqual(eval("UndefinedName+1"), .error(.name))
        XCTAssertEqual(eval("VLOOKUP(9,A1:B2,2,FALSE)"), .error(.na))
        XCTAssertEqual(eval("Z100+1"), .error(.circular))
        XCTAssertEqual(eval("ISERROR(1/0)"), .bool(true))
    }

    func testCrossSheetAndNames() {
        var a = Sheet(name: "Data Sheet")
        a[CellAddress(a1: "B2")!] = Cell(value: .number(21))
        var b = Sheet(name: "Summary")
        b[CellAddress(a1: "A1")!] = Cell(formula: "'Data Sheet'!B2*Factor")
        var workbook = Workbook(sheets: [a, b])
        workbook.names = [DefinedName(name: "Factor", formula: "2")]
        let calculator = Calculator(workbook: workbook)
        calculator.recalculate()
        XCTAssertEqual(calculator.value(sheet: 1, at: .origin), .number(42))
    }

    func testRewriter() {
        XCTAssertEqual(FormulaRewriter.shift("SUM(A1:B$2)+$C3+Sheet2!D4", rows: 2, columns: 1), "SUM(B3:C$2)+$C5+Sheet2!E6")
        XCTAssertEqual(FormulaRewriter.shift("A1", rows: -1, columns: 0), "#REF!")
        XCTAssertEqual(FormulaRewriter.adjust("SUM(A1:A10)+A11", formulaSheet: "S", targetSheet: "S", change: .deleteRows(at: 2, count: 3)), "SUM(A1:A7)+A8")
        XCTAssertEqual(FormulaRewriter.adjust("B5", formulaSheet: "S", targetSheet: "S", change: .insertColumns(at: 0, count: 2)), "D5")
        XCTAssertEqual(FormulaRewriter.renameSheet("Old!A1+A2", from: "Old", to: "New Name"), "'New Name'!A1+A2")
        XCTAssertEqual(FormulaRewriter.toggleAbsolute("A1+B2", caret: 1)?.0, "$A$1+B2")
    }

    func testNormalization() throws {
        XCTAssertEqual(try WorkbookController.normalizeFormula("sum(a1:b2"), "SUM(A1:B2)")
        XCTAssertThrowsError(try WorkbookController.normalizeFormula("1+*2"))
    }
}
