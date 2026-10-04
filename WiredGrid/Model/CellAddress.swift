import Foundation

/// The size of a worksheet, matching Excel's limits.
enum SheetLimits {
    static let rows = 1_048_576
    static let columns = 16_384
}

/// A zero-based cell position. `A1` is row 0, column 0.
struct CellAddress: Hashable, Comparable, Codable {
    var row: Int
    var column: Int

    init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    static let origin = CellAddress(row: 0, column: 0)

    static func < (lhs: CellAddress, rhs: CellAddress) -> Bool {
        lhs.row != rhs.row ? lhs.row < rhs.row : lhs.column < rhs.column
    }

    var isValid: Bool {
        row >= 0 && column >= 0 && row < SheetLimits.rows && column < SheetLimits.columns
    }

    func offset(rows: Int = 0, columns: Int = 0) -> CellAddress {
        CellAddress(row: row + rows, column: column + columns)
    }

    func clamped() -> CellAddress {
        CellAddress(row: min(max(row, 0), SheetLimits.rows - 1), column: min(max(column, 0), SheetLimits.columns - 1))
    }

    /// "B7"
    var a1: String { CellAddress.columnName(column) + String(row + 1) }

    /// "A", "Z", "AA", … for a zero-based column index.
    static func columnName(_ index: Int) -> String {
        var index = index + 1
        var name = ""
        while index > 0 {
            let remainder = (index - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + remainder))) + name
            index = (index - 1) / 26
        }
        return name
    }

    /// Zero-based column index for "A", "aa", …; nil for anything else.
    static func columnIndex(_ name: Substring) -> Int? {
        guard !name.isEmpty, name.count <= 3 else { return nil }
        var value = 0
        for scalar in name.unicodeScalars {
            let upper = scalar.value >= 97 ? scalar.value - 32 : scalar.value
            guard upper >= 65, upper <= 90 else { return nil }
            value = value * 26 + Int(upper - 64)
        }
        let index = value - 1
        return index < SheetLimits.columns ? index : nil
    }

    static func columnIndex(_ name: String) -> Int? { columnIndex(Substring(name)) }

    /// Parses "B7" or "$B$7".
    init?(a1 text: String) {
        let trimmed = text.replacingOccurrences(of: "$", with: "")
        let letters = trimmed.prefix { $0.isLetter }
        let digits = trimmed.dropFirst(letters.count)
        guard let column = CellAddress.columnIndex(letters),
              !digits.isEmpty, digits.allSatisfy(\.isNumber),
              let row = Int(digits), row >= 1, row <= SheetLimits.rows
        else { return nil }
        self.init(row: row - 1, column: column)
    }
}

/// An inclusive rectangle of cells. Always stored normalized (start ≤ end).
struct CellRange: Hashable, Codable {
    private(set) var start: CellAddress
    private(set) var end: CellAddress

    init(_ a: CellAddress, _ b: CellAddress) {
        start = CellAddress(row: min(a.row, b.row), column: min(a.column, b.column))
        end = CellAddress(row: max(a.row, b.row), column: max(a.column, b.column))
    }

    init(_ single: CellAddress) {
        self.init(single, single)
    }

    init(rows: ClosedRange<Int>, columns: ClosedRange<Int>) {
        self.init(CellAddress(row: rows.lowerBound, column: columns.lowerBound), CellAddress(row: rows.upperBound, column: columns.upperBound))
    }

    var minRow: Int { start.row }
    var maxRow: Int { end.row }
    var minColumn: Int { start.column }
    var maxColumn: Int { end.column }
    var rowCount: Int { end.row - start.row + 1 }
    var columnCount: Int { end.column - start.column + 1 }
    var cellCount: Int { rowCount * columnCount }
    var rows: ClosedRange<Int> { start.row...end.row }
    var columns: ClosedRange<Int> { start.column...end.column }
    var isSingleCell: Bool { start == end }

    var isWholeColumns: Bool { start.row == 0 && end.row == SheetLimits.rows - 1 }
    var isWholeRows: Bool { start.column == 0 && end.column == SheetLimits.columns - 1 }

    static func wholeColumns(_ columns: ClosedRange<Int>) -> CellRange {
        CellRange(rows: 0...(SheetLimits.rows - 1), columns: columns)
    }

    static func wholeRows(_ rows: ClosedRange<Int>) -> CellRange {
        CellRange(rows: rows, columns: 0...(SheetLimits.columns - 1))
    }

    static let all = CellRange(rows: 0...(SheetLimits.rows - 1), columns: 0...(SheetLimits.columns - 1))

    func contains(_ address: CellAddress) -> Bool {
        rows.contains(address.row) && columns.contains(address.column)
    }

    func contains(_ other: CellRange) -> Bool {
        contains(other.start) && contains(other.end)
    }

    func intersects(_ other: CellRange) -> Bool {
        minRow <= other.maxRow && other.minRow <= maxRow && minColumn <= other.maxColumn && other.minColumn <= maxColumn
    }

    func intersection(_ other: CellRange) -> CellRange? {
        guard intersects(other) else { return nil }
        return CellRange(
            CellAddress(row: max(minRow, other.minRow), column: max(minColumn, other.minColumn)),
            CellAddress(row: min(maxRow, other.maxRow), column: min(maxColumn, other.maxColumn))
        )
    }

    func union(_ other: CellRange) -> CellRange {
        CellRange(
            CellAddress(row: min(minRow, other.minRow), column: min(minColumn, other.minColumn)),
            CellAddress(row: max(maxRow, other.maxRow), column: max(maxColumn, other.maxColumn))
        )
    }

    func offset(rows: Int = 0, columns: Int = 0) -> CellRange {
        CellRange(start.offset(rows: rows, columns: columns), end.offset(rows: rows, columns: columns))
    }

    /// Row-major iteration.
    var addresses: [CellAddress] {
        var result: [CellAddress] = []
        result.reserveCapacity(cellCount)
        for row in rows {
            for column in columns { result.append(CellAddress(row: row, column: column)) }
        }
        return result
    }

    /// "A1:C4", "A:A", "3:5" or "B2".
    var a1: String {
        if isWholeColumns && !isWholeRows {
            return CellAddress.columnName(minColumn) + ":" + CellAddress.columnName(maxColumn)
        }
        if isWholeRows && !isWholeColumns {
            return "\(minRow + 1):\(maxRow + 1)"
        }
        return isSingleCell ? start.a1 : start.a1 + ":" + end.a1
    }

    /// Parses "A1", "A1:C4", "A:C" or "2:9" (dollar signs allowed).
    init?(a1 text: String) {
        let parts = text.replacingOccurrences(of: "$", with: "").split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 1, let address = CellAddress(a1: parts[0]) {
            self.init(address)
            return
        }
        guard parts.count == 2 else { return nil }
        if let a = CellAddress(a1: parts[0]), let b = CellAddress(a1: parts[1]) {
            self.init(a, b)
        } else if let a = CellAddress.columnIndex(parts[0]), let b = CellAddress.columnIndex(parts[1]) {
            self = .wholeColumns(min(a, b)...max(a, b))
        } else if let a = Int(parts[0]), let b = Int(parts[1]), a >= 1, b >= 1, a <= SheetLimits.rows, b <= SheetLimits.rows {
            self = .wholeRows((min(a, b) - 1)...(max(a, b) - 1))
        } else {
            return nil
        }
    }
}

extension CellRange: CustomStringConvertible {
    var description: String { a1 }
}

extension CellAddress: CustomStringConvertible {
    var description: String { a1 }
}

/// Quotes a sheet name for use in a formula when it needs it: `'My Sheet'!A1`.
func quotedSheetName(_ name: String) -> String {
    let plain = name.first.map { $0.isLetter || $0 == "_" } ?? false
        && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
        && CellRange(a1: name) == nil
    return plain ? name : "'" + name.replacingOccurrences(of: "'", with: "''") + "'"
}
