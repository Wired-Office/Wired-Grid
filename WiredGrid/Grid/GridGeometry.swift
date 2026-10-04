import AppKit

/// Positions along one axis (rows or columns) with custom and hidden sizes.
/// Offsets are computed with a binary search over the few custom sizes, so the
/// full 1,048,576-row sheet costs nothing.
struct AxisMetrics {
    let defaultSize: CGFloat
    let limit: Int
    private let keys: [Int]
    private let sizes: [CGFloat]
    /// prefix[i] = sum of (size - default) for keys[0..<i]
    private let prefix: [CGFloat]

    init(defaultSize: Double, custom: [Int: Double], hidden: Set<Int>, zoom: CGFloat, limit: Int) {
        self.defaultSize = CGFloat(defaultSize) * zoom
        self.limit = limit
        var merged: [Int: CGFloat] = [:]
        for (index, size) in custom where index < limit { merged[index] = CGFloat(size) * zoom }
        for index in hidden where index < limit { merged[index] = 0 }
        keys = merged.keys.sorted()
        sizes = keys.map { merged[$0]! }
        var running: CGFloat = 0
        var prefix: [CGFloat] = [0]
        prefix.reserveCapacity(keys.count + 1)
        for size in sizes {
            running += size - CGFloat(defaultSize) * zoom
            prefix.append(running)
        }
        self.prefix = prefix
    }

    /// Number of custom entries with index < i.
    private func customCount(before i: Int) -> Int {
        var low = 0, high = keys.count
        while low < high {
            let mid = (low + high) / 2
            if keys[mid] < i { low = mid + 1 } else { high = mid }
        }
        return low
    }

    func size(_ i: Int) -> CGFloat {
        let k = customCount(before: i)
        if k < keys.count && keys[k] == i { return sizes[k] }
        return defaultSize
    }

    /// Start of index `i`.
    func offset(_ i: Int) -> CGFloat {
        CGFloat(i) * defaultSize + prefix[customCount(before: i)]
    }

    func end(_ i: Int) -> CGFloat { offset(i) + size(i) }

    /// The index covering `position` (skipping zero-size entries forward).
    func index(at position: CGFloat) -> Int {
        guard position > 0 else { return firstVisible(from: 0) }
        var low = 0, high = limit - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if offset(mid) <= position { low = mid } else { high = mid - 1 }
        }
        return firstVisible(from: low)
    }

    func firstVisible(from i: Int) -> Int {
        var index = i
        while index < limit - 1 && size(index) == 0 { index += 1 }
        return index
    }

    func isHidden(_ i: Int) -> Bool { size(i) == 0 }
}

/// Maps between cells and view coordinates, including headers and frozen panes.
struct GridGeometry {
    let rows: AxisMetrics
    let columns: AxisMetrics
    let headerWidth: CGFloat
    let headerHeight: CGFloat
    let frozenRows: Int
    let frozenColumns: Int
    let frozenWidth: CGFloat
    let frozenHeight: CGFloat
    let zoom: CGFloat
    /// Scroll offset into the unfrozen area.
    var scroll: CGPoint
    var bounds: CGRect

    init(sheet: Sheet, zoom: CGFloat, scroll: CGPoint, bounds: CGRect, showHeadings: Bool) {
        self.zoom = zoom
        rows = AxisMetrics(defaultSize: Sheet.defaultRowHeight, custom: sheet.rowHeights,
                           hidden: sheet.hiddenRows.union(sheet.filter?.hiddenRows ?? []), zoom: zoom, limit: SheetLimits.rows)
        columns = AxisMetrics(defaultSize: Sheet.defaultColumnWidth, custom: sheet.columnWidths,
                              hidden: sheet.hiddenColumns, zoom: zoom, limit: SheetLimits.columns)
        if showHeadings {
            let digits = max(3, String(Int(scroll.y / max(rows.defaultSize, 1)) + 200).count)
            headerWidth = ceil(CGFloat(digits) * 8 * max(zoom, 0.8) + 14)
            headerHeight = ceil(22 * max(zoom, 0.8))
        } else {
            headerWidth = 0
            headerHeight = 0
        }
        frozenRows = sheet.frozenRows
        frozenColumns = sheet.frozenColumns
        frozenWidth = columns.offset(sheet.frozenColumns)
        frozenHeight = rows.offset(sheet.frozenRows)
        self.scroll = CGPoint(x: max(scroll.x, 0), y: max(scroll.y, 0))
        self.bounds = bounds
    }

    /// Top-left of the scrolling cell area.
    var bodyOrigin: CGPoint { CGPoint(x: headerWidth + frozenWidth, y: headerHeight + frozenHeight) }

    var bodyRect: CGRect {
        CGRect(x: bodyOrigin.x, y: bodyOrigin.y, width: max(bounds.width - bodyOrigin.x, 0), height: max(bounds.height - bodyOrigin.y, 0))
    }

    var cellAreaRect: CGRect {
        CGRect(x: headerWidth, y: headerHeight, width: max(bounds.width - headerWidth, 0), height: max(bounds.height - headerHeight, 0))
    }

    func x(_ column: Int) -> CGFloat {
        if column < frozenColumns { return headerWidth + columns.offset(column) }
        return headerWidth + columns.offset(column) - scroll.x
    }

    func y(_ row: Int) -> CGFloat {
        if row < frozenRows { return headerHeight + rows.offset(row) }
        return headerHeight + rows.offset(row) - scroll.y
    }

    func rect(_ address: CellAddress) -> CGRect {
        CGRect(x: x(address.column), y: y(address.row), width: columns.size(address.column), height: rows.size(address.row))
    }

    func rect(_ range: CellRange) -> CGRect {
        let left = x(range.minColumn), top = y(range.minRow)
        let right = x(range.maxColumn) + columns.size(range.maxColumn)
        let bottom = y(range.maxRow) + rows.size(range.maxRow)
        return CGRect(x: left, y: top, width: max(right - left, 0), height: max(bottom - top, 0))
    }

    /// The column under an x position in the cell area (frozen or scrolled).
    func column(atX px: CGFloat) -> Int {
        let local = px - headerWidth
        if frozenColumns > 0 && local < frozenWidth { return columns.index(at: local) }
        return max(columns.index(at: local + scroll.x), frozenColumns)
    }

    func row(atY py: CGFloat) -> Int {
        let local = py - headerHeight
        if frozenRows > 0 && local < frozenHeight { return rows.index(at: local) }
        return max(rows.index(at: local + scroll.y), frozenRows)
    }

    func address(at point: CGPoint) -> CellAddress {
        CellAddress(row: row(atY: point.y), column: column(atX: point.x))
    }

    /// Visible scrolled columns (excluding frozen ones).
    var visibleColumns: ClosedRange<Int> {
        let first = max(columns.index(at: frozenWidth + scroll.x), frozenColumns)
        let last = max(columns.index(at: frozenWidth + scroll.x + max(bounds.width - bodyOrigin.x, 1)), first)
        return first...max(first, min(last + 1, SheetLimits.columns - 1))
    }

    var visibleRows: ClosedRange<Int> {
        let first = max(rows.index(at: frozenHeight + scroll.y), frozenRows)
        let last = max(rows.index(at: frozenHeight + scroll.y + max(bounds.height - bodyOrigin.y, 1)), first)
        return first...max(first, min(last + 1, SheetLimits.rows - 1))
    }

    var frozenColumnRange: ClosedRange<Int>? { frozenColumns > 0 ? 0...(frozenColumns - 1) : nil }
    var frozenRowRange: ClosedRange<Int>? { frozenRows > 0 ? 0...(frozenRows - 1) : nil }

    /// Total size of the scrolling content for `rowCount` × `columnCount` cells.
    func contentSize(rowCount: Int, columnCount: Int) -> CGSize {
        CGSize(
            width: headerWidth + columns.offset(columnCount),
            height: headerHeight + rows.offset(rowCount)
        )
    }
}
