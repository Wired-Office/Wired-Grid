import Foundation

/// One cell's stored contents: a literal value or a formula, plus formatting.
struct Cell: Equatable, Codable {
    /// The literal value. For formula cells this is the last computed value (used for files).
    var value: CellValue = .empty
    /// Formula text without the leading "=".
    var formula: String?
    /// Explicit formatting; nil inherits the row or column style.
    var style: CellStyle?
    /// An optional hyperlink.
    var link: String?

    var isFormula: Bool { formula != nil }

    /// True when the cell holds neither content nor formatting.
    var isVacant: Bool { formula == nil && value.isEmpty && style == nil && link == nil }
    var hasContent: Bool { formula != nil || !value.isEmpty }
}

/// The worksheet: a sparse dictionary of cells plus row/column geometry and features.
struct Sheet: Identifiable {
    var id = UUID()
    var name: String
    var cells: [CellAddress: Cell] = [:]

    /// Custom sizes in points at 100% zoom. Missing entries use the defaults.
    var columnWidths: [Int: Double] = [:]
    var rowHeights: [Int: Double] = [:]
    var hiddenColumns: Set<Int> = []
    var hiddenRows: Set<Int> = []
    var columnStyles: [Int: CellStyle] = [:]
    var rowStyles: [Int: CellStyle] = [:]

    var merges: [CellRange] = []
    var frozenRows = 0
    var frozenColumns = 0
    var notes: [CellAddress: String] = [:]
    var conditionalFormats: [ConditionalFormat] = []
    var charts: [ChartObject] = []
    var filter: AutoFilter?
    var tables: [TableObject] = []

    var tabColor: RGBColor?
    var showGridlines = true
    var showHeadings = true
    var zoom: Double = 1
    var pageSetup = PageSetup()

    static let defaultColumnWidth: Double = 80
    static let defaultRowHeight: Double = 21

    init(name: String) {
        self.name = name
    }

    // MARK: Cells

    subscript(address: CellAddress) -> Cell? {
        get { cells[address] }
        set {
            if let newValue, !newValue.isVacant {
                cells[address] = newValue
            } else {
                cells[address] = nil
            }
        }
    }

    func style(at address: CellAddress) -> CellStyle {
        if let style = cells[address]?.style { return style }
        if let style = rowStyles[address.row] { return style }
        if let style = columnStyles[address.column] { return style }
        return .plain
    }

    mutating func updateStyle(at address: CellAddress, _ change: (inout CellStyle) -> Void) {
        var style = style(at: address)
        change(&style)
        var cell = cells[address] ?? Cell()
        cell.style = style.isPlain && rowStyles[address.row] == nil && columnStyles[address.column] == nil ? nil : style
        self[address] = cell
    }

    /// The smallest range holding every non-vacant cell, or nil for an empty sheet.
    var usedRange: CellRange? {
        guard !cells.isEmpty else { return nil }
        var minRow = Int.max, minColumn = Int.max, maxRow = 0, maxColumn = 0
        for address in cells.keys {
            minRow = min(minRow, address.row)
            maxRow = max(maxRow, address.row)
            minColumn = min(minColumn, address.column)
            maxColumn = max(maxColumn, address.column)
        }
        return CellRange(CellAddress(row: minRow, column: minColumn), CellAddress(row: maxRow, column: maxColumn))
    }

    /// Used range anchored at A1 (what Excel calls the "last cell").
    var contentExtent: CellAddress {
        guard let used = usedRange else { return .origin }
        return used.end
    }

    // MARK: Geometry

    func columnWidth(_ column: Int) -> Double {
        if hiddenColumns.contains(column) { return 0 }
        return columnWidths[column] ?? Sheet.defaultColumnWidth
    }

    func isRowHidden(_ row: Int) -> Bool {
        hiddenRows.contains(row) || (filter?.hiddenRows.contains(row) ?? false)
    }

    func rowHeight(_ row: Int) -> Double {
        if isRowHidden(row) { return 0 }
        return rowHeights[row] ?? Sheet.defaultRowHeight
    }

    // MARK: Merges

    func merge(containing address: CellAddress) -> CellRange? {
        merges.first { $0.contains(address) }
    }

    /// Expands a range so it fully includes every merge it touches.
    func expandedToMerges(_ range: CellRange) -> CellRange {
        var result = range
        var changed = true
        while changed {
            changed = false
            for merge in merges where merge.intersects(result) && !result.contains(merge) {
                result = result.union(merge)
                changed = true
            }
        }
        return result
    }

    // MARK: Data regions

    func hasContent(_ address: CellAddress) -> Bool {
        cells[address]?.hasContent ?? false
    }

    /// The contiguous block of content around a cell (Excel's "current region").
    func currentRegion(around address: CellAddress) -> CellRange {
        var range = CellRange(address)
        var grew = true
        while grew {
            grew = false
            let probe = CellRange(
                CellAddress(row: max(range.minRow - 1, 0), column: max(range.minColumn - 1, 0)),
                CellAddress(row: range.maxRow + 1, column: range.maxColumn + 1)
            )
            // Grow in any direction that has content on the border ring.
            if range.minRow > 0, probe.columns.contains(where: { hasContent(CellAddress(row: range.minRow - 1, column: $0)) }) {
                range = range.union(CellRange(CellAddress(row: range.minRow - 1, column: range.minColumn))); grew = true
            }
            if probe.columns.contains(where: { hasContent(CellAddress(row: range.maxRow + 1, column: $0)) }) {
                range = range.union(CellRange(CellAddress(row: range.maxRow + 1, column: range.minColumn))); grew = true
            }
            if range.minColumn > 0, probe.rows.contains(where: { hasContent(CellAddress(row: $0, column: range.minColumn - 1)) }) {
                range = range.union(CellRange(CellAddress(row: range.minRow, column: range.minColumn - 1))); grew = true
            }
            if probe.rows.contains(where: { hasContent(CellAddress(row: $0, column: range.maxColumn + 1)) }) {
                range = range.union(CellRange(CellAddress(row: range.minRow, column: range.maxColumn + 1))); grew = true
            }
        }
        return range
    }

    /// Where Cmd+Arrow lands: the edge of the current data block, or the next block.
    func dataEdge(from address: CellAddress, rowStep: Int, columnStep: Int) -> CellAddress {
        let limitRow = SheetLimits.rows - 1
        let limitColumn = SheetLimits.columns - 1
        func valid(_ a: CellAddress) -> Bool { a.row >= 0 && a.column >= 0 && a.row <= limitRow && a.column <= limitColumn }
        let extent = contentExtent
        var current = address
        var next = current.offset(rows: rowStep, columns: columnStep)
        guard valid(next) else { return current }

        if hasContent(current) && hasContent(next) {
            // Run to the last filled cell in this block.
            while valid(next) && hasContent(next) {
                current = next
                next = current.offset(rows: rowStep, columns: columnStep)
            }
            return current
        }
        // Skip blanks to the next filled cell, or the sheet edge.
        current = next
        while !hasContent(current) {
            let candidate = current.offset(rows: rowStep, columns: columnStep)
            let beyond = (rowStep > 0 && current.row > extent.row) || (columnStep > 0 && current.column > extent.column)
            if !valid(candidate) || beyond {
                if rowStep > 0 { return CellAddress(row: limitRow, column: current.column) }
                if columnStep > 0 { return CellAddress(row: current.row, column: limitColumn) }
                return valid(candidate) ? candidate : current
            }
            current = candidate
        }
        return current
    }
}

/// Print settings for a sheet.
struct PageSetup: Codable, Hashable {
    enum Orientation: String, Codable { case portrait, landscape }
    enum Scaling: String, Codable { case actual, fitWidth, fitPage }

    var orientation: Orientation = .portrait
    var scaling: Scaling = .actual
    var margin: Double = 36
    var printGridlines = false
    var printHeadings = false
    var printArea: CellRange?
    var centerHorizontally = false
    var header = ""
    var footer = "Page &P of &N"
}

/// A defined name such as `TaxRate` → `Sheet1!$B$2`.
struct DefinedName: Codable, Hashable, Identifiable {
    var id: String { name.uppercased() }
    var name: String
    /// A formula body such as "Sheet1!$B$2" or "0.07".
    var formula: String
    var comment = ""
}

/// The whole workbook model.
struct Workbook {
    var sheets: [Sheet]
    var activeSheetIndex = 0
    var names: [DefinedName] = []
    var author = ""
    var created = Date()

    init(sheets: [Sheet] = [Sheet(name: "Sheet1")]) {
        self.sheets = sheets
    }

    var activeSheet: Sheet {
        get { sheets[min(activeSheetIndex, sheets.count - 1)] }
        set { sheets[min(activeSheetIndex, sheets.count - 1)] = newValue }
    }

    func sheetIndex(named name: String) -> Int? {
        sheets.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func sheetIndex(id: UUID) -> Int? {
        sheets.firstIndex { $0.id == id }
    }

    func definedName(_ name: String) -> DefinedName? {
        names.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// "Sheet4", or the next free number.
    func nextSheetName(base: String = "Sheet") -> String {
        var number = sheets.count + 1
        while sheetIndex(named: "\(base)\(number)") != nil { number += 1 }
        return "\(base)\(number)"
    }

    func uniqueSheetName(_ proposed: String) -> String {
        if sheetIndex(named: proposed) == nil { return proposed }
        var number = 2
        while sheetIndex(named: "\(proposed) (\(number))") != nil { number += 1 }
        return "\(proposed) (\(number))"
    }
}
