import XCTest
@testable import WiredGrid

final class WorkbookTests: XCTestCase {
    private func makeController(_ entries: [String: String]) -> WorkbookController {
        let controller = WorkbookController(workbook: Workbook())
        for (a1, text) in entries {
            controller.setInput(text, at: CellAddress(a1: a1)!)
        }
        return controller
    }

    private func value(_ c: WorkbookController, _ a1: String) -> CellValue { c.value(at: CellAddress(a1: a1)!) }

    func testTypingParsesAndFormats() {
        let c = makeController(["A1": "12%", "A2": "=A1*2", "A3": "2024-03-05", "A4": "'007"])
        XCTAssertEqual(value(c, "A2"), .number(0.24))
        XCTAssertEqual(c.displayText(at: CellAddress(a1: "A1")!), "12%")
        XCTAssertEqual(c.displayText(at: CellAddress(a1: "A3")!), "2024-03-05")
        XCTAssertEqual(value(c, "A4"), .string("007"))
        XCTAssertEqual(c.inputText(at: CellAddress(a1: "A4")!), "'007")
        XCTAssertEqual(c.inputText(at: CellAddress(a1: "A2")!), "=A1*2")
    }

    func testInsertAndDeleteRowsAdjustFormulas() {
        let c = makeController(["A1": "1", "A2": "2", "A3": "3", "B1": "=SUM(A1:A3)", "B2": "=A3"])
        c.insertRows(at: 1, count: 2)
        XCTAssertEqual(c.sheet.cells[CellAddress(a1: "B1")!]?.formula, "SUM(A1:A5)")
        XCTAssertEqual(c.sheet.cells[CellAddress(a1: "B4")!]?.formula, "A5")
        XCTAssertEqual(value(c, "B1"), .number(6))
        c.deleteRows(at: 4, count: 1)   // deletes the row holding A5
        XCTAssertEqual(c.sheet.cells[CellAddress(a1: "B4")!]?.formula, "#REF!")
    }

    func testAutoFillSeries() {
        let c = makeController(["A1": "1", "A2": "3", "B1": "Mon", "C1": "Item 7", "D1": "=A1*10"])
        c.autoFill(from: CellRange(a1: "A1:A2")!, to: CellRange(a1: "A1:A5")!)
        XCTAssertEqual(value(c, "A5"), .number(9))
        c.autoFill(from: CellRange(a1: "B1")!, to: CellRange(a1: "B1:B3")!)
        XCTAssertEqual(value(c, "B3"), .string("Wed"))
        c.autoFill(from: CellRange(a1: "C1")!, to: CellRange(a1: "C1:C2")!)
        XCTAssertEqual(value(c, "C2"), .string("Item 8"))
        c.autoFill(from: CellRange(a1: "D1")!, to: CellRange(a1: "D1:D2")!)
        XCTAssertEqual(c.sheet.cells[CellAddress(a1: "D2")!]?.formula, "A2*10")
    }

    func testSortKeepsRowsTogether() {
        let c = makeController(["A1": "Name", "B1": "Score", "A2": "Cy", "B2": "70", "A3": "Ann", "B3": "95", "A4": "Bo", "B4": "80"])
        c.sort(CellRange(a1: "A1:B4")!, keys: [SortKey(column: 1, ascending: false)], hasHeader: true)
        XCTAssertEqual(value(c, "A2"), .string("Ann"))
        XCTAssertEqual(value(c, "A4"), .string("Cy"))
        XCTAssertEqual(value(c, "A1"), .string("Name"))
    }

    func testFilterHidesRows() {
        let c = makeController(["A1": "Fruit", "A2": "apple", "A3": "pear", "A4": "apple"])
        c.select(CellAddress(a1: "A1")!)
        c.toggleFilter()
        c.setFilterCriterion(.values(["pear"]), column: 0)
        XCTAssertEqual(c.sheet.filter?.hiddenRows, [1, 3])
        XCTAssertTrue(c.sheet.isRowHidden(1))
    }

    func testCopyPasteShiftsFormulas() {
        let c = makeController(["A1": "5", "B1": "=A1*2"])
        c.select(CellAddress(a1: "B1")!)
        c.copySelection()
        c.select(CellAddress(a1: "B3")!)
        c.paste()
        XCTAssertEqual(c.sheet.cells[CellAddress(a1: "B3")!]?.formula, "A3*2")
    }

    func testRenameSheetUpdatesReferences() {
        let c = makeController([:])
        c.addSheet()
        c.setInput("=Sheet1!A1+1", at: .origin)
        XCTAssertTrue(c.renameSheet(0, to: "Inputs"))
        XCTAssertEqual(c.sheet.cells[.origin]?.formula, "Inputs!A1+1")
    }

    func testMergeAndBorders() {
        let c = makeController(["A1": "Title"])
        c.select(range: CellRange(a1: "A1:C1")!)
        c.merge(.mergeAndCenter)
        XCTAssertEqual(c.sheet.merges, [CellRange(a1: "A1:C1")!])
        XCTAssertEqual(c.sheet.style(at: .origin).horizontal, .center)
        c.select(range: CellRange(a1: "A3:B4")!)
        c.applyBorders(.outside)
        XCTAssertNotNil(c.sheet.style(at: CellAddress(a1: "A3")!).borders.top)
        XCTAssertNil(c.sheet.style(at: CellAddress(a1: "A3")!).borders.bottom)
    }

    // MARK: - Files

    private func sampleWorkbook() -> Workbook {
        var sheet = Sheet(name: "Data & Stuff")
        sheet[CellAddress(a1: "A1")!] = Cell(value: .string("Name <tag>"), style: { var s = CellStyle(); s.bold = true; s.fillColor = RGBColor(0x1E8E5A); return s }())
        sheet[CellAddress(a1: "B1")!] = Cell(value: .number(1234.5), style: { var s = CellStyle(); s.numberFormat = "$#,##0.00"; return s }())
        sheet[CellAddress(a1: "B2")!] = Cell(formula: "B1*2")
        sheet[CellAddress(a1: "C1")!] = Cell(value: .bool(true))
        sheet[CellAddress(a1: "C2")!] = Cell(formula: "XLOOKUP(1,{1,2},{\"a\",\"b\"})")
        sheet.columnWidths[0] = 160
        sheet.rowHeights[3] = 42
        sheet.merges = [CellRange(a1: "D1:E2")!]
        sheet.frozenRows = 1
        sheet.conditionalFormats = [ConditionalFormat(range: CellRange(a1: "B1:B2")!, rule: .greaterThan(100))]
        sheet.notes[CellAddress(a1: "A1")!] = "hello"
        sheet.charts = [ChartObject(dataRange: CellRange(a1: "A1:B2")!, frame: CGRect(x: 10, y: 20, width: 300, height: 200))]
        var workbook = Workbook(sheets: [sheet, Sheet(name: "Second")])
        workbook.names = [DefinedName(name: "Rate", formula: "0.07")]
        return workbook
    }

    func testNativeRoundTrip() throws {
        let original = sampleWorkbook()
        let data = try NativeCodec.write(original)
        let read = try NativeCodec.read(data)
        XCTAssertEqual(read.sheets.count, 2)
        XCTAssertEqual(read.sheets[0].cells, original.sheets[0].cells)
        XCTAssertEqual(read.sheets[0].merges, original.sheets[0].merges)
        XCTAssertEqual(read.sheets[0].notes, original.sheets[0].notes)
        XCTAssertEqual(read.sheets[0].charts, original.sheets[0].charts)
        XCTAssertEqual(read.sheets[0].conditionalFormats, original.sheets[0].conditionalFormats)
        XCTAssertEqual(read.names, original.names)
    }

    func testXLSXRoundTrip() throws {
        let data = XLSXWriter.write(sampleWorkbook())
        let read = try XLSXReader.read(data)
        let sheet = read.sheets[0]
        XCTAssertEqual(read.sheets.map(\.name), ["Data & Stuff", "Second"])
        XCTAssertEqual(sheet.cells[CellAddress(a1: "A1")!]?.value, .string("Name <tag>"))
        XCTAssertEqual(sheet.style(at: CellAddress(a1: "A1")!).bold, true)
        XCTAssertEqual(sheet.style(at: CellAddress(a1: "A1")!).fillColor, RGBColor(0x1E8E5A))
        XCTAssertEqual(sheet.style(at: CellAddress(a1: "B1")!).numberFormat, "$#,##0.00")
        XCTAssertEqual(sheet.cells[CellAddress(a1: "B2")!]?.formula, "B1*2")
        XCTAssertEqual(sheet.cells[CellAddress(a1: "C2")!]?.formula, "XLOOKUP(1,{1,2},{\"a\",\"b\"})")
        XCTAssertEqual(sheet.cells[CellAddress(a1: "C1")!]?.value, .bool(true))
        XCTAssertEqual(sheet.columnWidths[0] ?? 0, 160, accuracy: 1)
        XCTAssertEqual(sheet.rowHeights[3] ?? 0, 42, accuracy: 1)
        XCTAssertEqual(sheet.merges, [CellRange(a1: "D1:E2")!])
        XCTAssertEqual(sheet.frozenRows, 1)
        XCTAssertEqual(sheet.conditionalFormats.first?.rule, .greaterThan(100))
        XCTAssertEqual(read.names.first?.name, "Rate")
    }

    func testCSVRoundTrip() throws {
        let csv = "Name,Amount,When\n\"Smith, J\",\"1,200.50\",2024-01-15\nLee,=B2*2,\n"
        let workbook = try DelimitedCodec.read(Data(csv.utf8), separator: ",")
        let sheet = workbook.sheets[0]
        XCTAssertEqual(sheet.cells[CellAddress(a1: "A2")!]?.value, .string("Smith, J"))
        XCTAssertEqual(sheet.cells[CellAddress(a1: "B2")!]?.value, .number(1200.5))
        XCTAssertEqual(sheet.cells[CellAddress(a1: "B3")!]?.formula, "B2*2")
        let written = String(decoding: DelimitedCodec.write(workbook, separator: ","), as: UTF8.self)
        XCTAssertTrue(written.contains("\"Smith, J\""))
        XCTAssertTrue(written.contains("2401"))
    }

    func testTemplatesCalculateWithoutErrors() {
        for template in TemplateLibrary.all {
            let controller = WorkbookController(workbook: template.build())
            for (index, sheet) in controller.workbook.sheets.enumerated() {
                for (address, cell) in sheet.cells where cell.formula != nil {
                    let value = controller.value(sheet: index, at: address)
                    XCTAssertFalse(value.isError, "\(template.name) \(address.a1) =\(cell.formula!) → \(value)")
                }
            }
        }
    }
}
