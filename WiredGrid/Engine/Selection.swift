import Foundation

/// The selected cells on one sheet: one or more ranges plus the active cell.
struct Selection: Equatable {
    /// The cell that receives typing.
    var active: CellAddress
    /// Where Shift-extension starts from.
    var anchor: CellAddress
    /// Every selected range; the last is the current one and contains `active`.
    var ranges: [CellRange]

    init(_ address: CellAddress) {
        active = address
        anchor = address
        ranges = [CellRange(address)]
    }

    init(range: CellRange, active: CellAddress? = nil) {
        self.active = active ?? range.start
        anchor = range.start
        ranges = [range]
    }

    var primary: CellRange { ranges.last ?? CellRange(active) }
    var isSingleCell: Bool { ranges.count == 1 && primary.isSingleCell }
    var isMultiple: Bool { ranges.count > 1 }

    func contains(_ address: CellAddress) -> Bool {
        ranges.contains { $0.contains(address) }
    }

    /// Every selected column is selected top to bottom.
    var isWholeColumns: Bool { ranges.allSatisfy(\.isWholeColumns) }
    var isWholeRows: Bool { ranges.allSatisfy(\.isWholeRows) }

    var selectedColumns: Set<Int> {
        var set = Set<Int>()
        for range in ranges where range.isWholeColumns { set.formUnion(range.columns) }
        return set
    }

    var selectedRows: Set<Int> {
        var set = Set<Int>()
        for range in ranges where range.isWholeRows { set.formUnion(range.rows) }
        return set
    }
}
