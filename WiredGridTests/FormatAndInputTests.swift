import XCTest
@testable import WiredGrid

final class FormatAndInputTests: XCTestCase {
    private func f(_ value: Double, _ code: String) -> String { NumberFormat.formatNumber(value, code).text }

    func testGeneral() {
        XCTAssertEqual(NumberFormat.general(0.1 + 0.2), "0.3")
        XCTAssertEqual(NumberFormat.general(1e12), "1E+12")
        XCTAssertEqual(NumberFormat.general(3.14159265358979), "3.141592654")
        XCTAssertEqual(NumberFormat.general(-42), "-42")
    }

    func testNumberCodes() {
        XCTAssertEqual(f(1234.5678, "#,##0.00"), "1,234.57")
        XCTAssertEqual(f(-1234.5, "$#,##0.00;[Red]($#,##0.00)"), "($1,234.50)")
        XCTAssertEqual(NumberFormat.formatNumber(-5, "0;[Red]-0").color, RGBColor(0xFF0000))
        XCTAssertEqual(f(0.256, "0.0%"), "25.6%")
        XCTAssertEqual(f(123456, "0.00E+00"), "1.23E+05")
        XCTAssertEqual(f(1.5, "# ?/?"), "1 1/2")
        XCTAssertEqual(f(42, "000"), "042")
        XCTAssertEqual(f(1234567, "#,##0,\"K\""), "1,235K")
        XCTAssertEqual(f(5551234567, "(000) 000-0000"), "(555) 123-4567")
        XCTAssertEqual(f(0, "0;-0;\"zero\""), "zero")
        XCTAssertEqual(NumberFormat.format(.string("hi"), "\"<\"@\">\"").text, "<hi>")
    }

    func testAccountingSplit() {
        let result = NumberFormat.formatNumber(1234, NumberFormat.accounting)
        XCTAssertEqual(result.fillSplit?.left.trimmingCharacters(in: .whitespaces), "$")
        XCTAssertEqual(result.fillSplit?.right.trimmingCharacters(in: .whitespaces), "1,234.00")
    }

    func testDates() {
        XCTAssertEqual(f(45306, "yyyy-mm-dd"), "2024-01-15")
        XCTAssertEqual(f(45306, "dddd, mmmm d, yyyy"), "Monday, January 15, 2024")
        XCTAssertEqual(f(45000.75, "m/d/yyyy h:mm AM/PM"), "3/15/2023 6:00 PM")
        XCTAssertEqual(f(1.5, "[h]:mm"), "36:00")
        XCTAssertEqual(f(0.5, "h:mm"), "12:00")   // "mm" after "h" means minutes
        XCTAssertTrue(NumberFormat.isDate("d-mmm-yy"))
        XCTAssertTrue(NumberFormat.isTime("h:mm:ss"))
    }

    func testDecimalAdjustment() {
        XCTAssertEqual(NumberFormat.adjustingDecimals("0.00", by: 1, sampleValue: nil), "0.000")
        XCTAssertEqual(NumberFormat.adjustingDecimals("0.0", by: -1, sampleValue: nil), "0")
        XCTAssertEqual(NumberFormat.adjustingDecimals("General", by: 1, sampleValue: 3.25), "0.000")
        XCTAssertEqual(NumberFormat.adjustingDecimals("#,##0", by: 1, sampleValue: nil), "#,##0.0")
    }

    func testValueParser() {
        XCTAssertEqual(ValueParser.parse("12%").value, .number(0.12))
        XCTAssertEqual(ValueParser.parse("12%").format, "0%")
        XCTAssertEqual(ValueParser.parse("$1,234.50").value, .number(1234.5))
        XCTAssertEqual(ValueParser.parse("(45)").value, .number(-45))
        XCTAssertEqual(ValueParser.parse("2024-01-15").value, .number(45306))
        XCTAssertEqual(ValueParser.parse("Jan 15, 2024").value, .number(45306))
        XCTAssertEqual(ValueParser.parse("9:30 PM").number!, 21.5 / 24, accuracy: 1e-9)
        XCTAssertEqual(ValueParser.parse("1 1/2").value, .number(1.5))
        XCTAssertEqual(ValueParser.parse("TRUE").value, .bool(true))
        XCTAssertEqual(ValueParser.parse("#N/A").value, .error(.na))
        XCTAssertEqual(ValueParser.parse("1,23").value, .string("1,23"))
        XCTAssertEqual(ValueParser.parse("hello").value, .string("hello"))
    }

    func testAddresses() {
        XCTAssertEqual(CellAddress.columnName(0), "A")
        XCTAssertEqual(CellAddress.columnName(27), "AB")
        XCTAssertEqual(CellAddress.columnName(16383), "XFD")
        XCTAssertEqual(CellAddress(a1: "$C$7"), CellAddress(row: 6, column: 2))
        XCTAssertEqual(CellRange(a1: "B:D")?.isWholeColumns, true)
        XCTAssertEqual(CellRange(a1: "C3:A1")?.a1, "A1:C3")
        XCTAssertEqual(quotedSheetName("My Sheet"), "'My Sheet'")
        XCTAssertEqual(quotedSheetName("Sheet1"), "Sheet1")
    }

    func testAxisMetrics() {
        let axis = AxisMetrics(defaultSize: 20, custom: [2: 50], hidden: [4], zoom: 1, limit: 1_000_000)
        XCTAssertEqual(axis.offset(3), 90)
        XCTAssertEqual(axis.offset(5), 110)
        XCTAssertEqual(axis.index(at: 95), 3)
        XCTAssertEqual(axis.index(at: 110), 5)   // row 4 is hidden
        XCTAssertEqual(axis.offset(999_999), 999_999 * 20 + 30 - 20)
    }
}
