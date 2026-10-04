import AppKit

/// Renders a sheet's print area (or used range) for printing and PDF export.
/// Page breaks snap to row and column boundaries.
final class SheetPrintView: NSView {
    private let controller: WorkbookController
    private let sheetIndex: Int
    private let range: CellRange
    private let columnOffsets: [CGFloat]
    private let rowOffsets: [CGFloat]
    private let headingWidth: CGFloat
    private let headingHeight: CGFloat
    private let styler = GridView()

    init(controller: WorkbookController, sheetIndex: Int, printInfo: NSPrintInfo) {
        self.controller = controller
        self.sheetIndex = sheetIndex
        let sheet = controller.workbook.sheets[sheetIndex]
        var area = sheet.pageSetup.printArea ?? sheet.usedRange.map { CellRange(.origin, $0.end) } ?? CellRange(.origin)
        // Include charts that sit beyond the data.
        for chart in sheet.charts {
            let right = chart.frame.maxX, bottom = chart.frame.maxY
            var column = area.maxColumn, row = area.maxRow
            while controller.columnOffset(column + 1) < right && column < area.maxColumn + 200 { column += 1 }
            while controller.rowOffset(row + 1) < bottom && row < area.maxRow + 2000 { row += 1 }
            area = area.union(CellRange(CellAddress(row: row, column: column)))
        }
        range = area
        var x: CGFloat = 0
        columnOffsets = (area.minColumn...area.maxColumn + 1).map { column in
            defer { x += CGFloat(sheet.columnWidth(column)) }
            return x
        }
        var y: CGFloat = 0
        rowOffsets = (area.minRow...area.maxRow + 1).map { row in
            defer { y += CGFloat(sheet.rowHeight(row)) }
            return y
        }
        headingWidth = sheet.pageSetup.printHeadings ? 36 : 0
        headingHeight = sheet.pageSetup.printHeadings ? 18 : 0
        super.init(frame: NSRect(x: 0, y: 0, width: x + headingWidth + 1, height: y + headingHeight + 1))
        styler.controller = controller
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    private func columnX(_ column: Int) -> CGFloat { headingWidth + columnOffsets[column - range.minColumn] }
    private func rowY(_ row: Int) -> CGFloat { headingHeight + rowOffsets[row - range.minRow] }

    private func rect(_ address: CellAddress) -> CGRect {
        CGRect(x: columnX(address.column), y: rowY(address.row),
               width: columnX(address.column + 1) - columnX(address.column), height: rowY(address.row + 1) - rowY(address.row))
    }

    private func rect(_ merge: CellRange) -> CGRect {
        let clipped = merge.intersection(range) ?? merge
        return CGRect(x: columnX(clipped.minColumn), y: rowY(clipped.minRow),
                      width: columnX(clipped.maxColumn + 1) - columnX(clipped.minColumn), height: rowY(clipped.maxRow + 1) - rowY(clipped.minRow))
    }

    // MARK: - Pagination

    override func adjustPageHeightNew(_ newBottom: UnsafeMutablePointer<CGFloat>, top oldTop: CGFloat, bottom oldBottom: CGFloat, limit bottomLimit: CGFloat) {
        // Move the break up to the nearest row boundary.
        let target = oldBottom
        if let boundary = rowOffsets.map({ $0 + headingHeight }).last(where: { $0 <= target && $0 >= bottomLimit }) {
            newBottom.pointee = boundary
        } else {
            newBottom.pointee = oldBottom
        }
    }

    override func adjustPageWidthNew(_ newRight: UnsafeMutablePointer<CGFloat>, left oldLeft: CGFloat, right oldRight: CGFloat, limit rightLimit: CGFloat) {
        if let boundary = columnOffsets.map({ $0 + headingWidth }).last(where: { $0 <= oldRight && $0 >= rightLimit }) {
            newRight.pointee = boundary
        } else {
            newRight.pointee = oldRight
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let sheet = controller.workbook.sheets[sheetIndex]
        NSColor.white.setFill()
        dirtyRect.fill()
        let setup = sheet.pageSetup
        let merges = sheet.merges.filter { $0.intersects(range) }
        let saved = NSApp.appearance
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            // Gridlines.
            if setup.printGridlines {
                NSColor(white: 0.8, alpha: 1).setFill()
                for column in range.minColumn...range.maxColumn + 1 {
                    CGRect(x: columnX(column), y: headingHeight, width: 0.5, height: bounds.height - headingHeight).fill()
                }
                for row in range.minRow...range.maxRow + 1 {
                    CGRect(x: headingWidth, y: rowY(row), width: bounds.width - headingWidth, height: 0.5).fill()
                }
            }
            if setup.printHeadings {
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.darkGray]
                NSColor(white: 0.94, alpha: 1).setFill()
                CGRect(x: 0, y: 0, width: bounds.width, height: headingHeight).fill()
                CGRect(x: 0, y: 0, width: headingWidth, height: bounds.height).fill()
                for column in range.columns {
                    let label = CellAddress.columnName(column) as NSString
                    let size = label.size(withAttributes: attrs)
                    let x = (columnX(column) + columnX(column + 1)) / 2
                    label.draw(at: CGPoint(x: x - size.width / 2, y: (headingHeight - size.height) / 2), withAttributes: attrs)
                }
                for row in range.rows {
                    let label = String(row + 1) as NSString
                    let size = label.size(withAttributes: attrs)
                    let y = (rowY(row) + rowY(row + 1)) / 2
                    label.draw(at: CGPoint(x: headingWidth - size.width - 4, y: y - size.height / 2), withAttributes: attrs)
                }
            }
            var visibleRows = range.rows.filter { rowY($0) + 1 >= dirtyRect.minY && rowY($0) <= dirtyRect.maxY }
            if visibleRows.isEmpty { visibleRows = [] }
            for row in visibleRows where !sheet.isRowHidden(row) {
                for column in range.columns where !sheet.hiddenColumns.contains(column) {
                    let address = CellAddress(row: row, column: column)
                    if let merge = merges.first(where: { $0.contains(address) }), merge.start != address { continue }
                    let cellRect = merges.first(where: { $0.start == address }).map(rect) ?? rect(address)
                    let value = controller.value(sheet: sheetIndex, at: address)
                    let style = sheet.style(at: address)
                    guard !value.isEmpty || style.fillColor != nil || !style.borders.isEmpty else { continue }
                    let appearance = printAppearance(at: address, value: value, sheet: sheet)
                    if let fill = style.fillColor {
                        fill.nsColor.setFill()
                        cellRect.fill()
                    }
                    var textRect = cellRect
                    if value.isText, !appearance.wrap, merges.first(where: { $0.start == address }) == nil,
                       appearance.horizontal == .general || appearance.horizontal == .left {
                        // Text overflows into empty cells to the right, as on screen.
                        var next = column + 1
                        let needed = CellRenderer.textWidth(appearance) + CellRenderer.padding * 2
                        while textRect.width < needed, next <= range.maxColumn,
                              controller.value(sheet: sheetIndex, at: CellAddress(row: row, column: next)).isEmpty {
                            textRect.size.width = columnX(next + 1) - textRect.minX
                            next += 1
                        }
                    }
                    CellRenderer.draw(appearance, value: value, in: textRect, clip: textRect, zoom: 1)
                    drawBorders(style.borders, in: cellRect)
                }
            }
            // Charts.
            for chart in sheet.charts {
                let origin = CGPoint(x: headingWidth + CGFloat(chart.frame.minX) - CGFloat(controller.columnOffset(range.minColumn)),
                                     y: headingHeight + CGFloat(chart.frame.minY) - CGFloat(controller.rowOffset(range.minRow)))
                let frame = CGRect(origin: origin, size: chart.frame.size)
                guard frame.intersects(dirtyRect) else { continue }
                let data = ChartData.read(chart, sheetIndex: sheetIndex, controller: controller)
                ChartRenderer.draw(chart, data: data, in: frame, dark: false)
                NSColor(white: 0.8, alpha: 1).setStroke()
                NSBezierPath(rect: frame).stroke()
            }
        }
        _ = saved
    }

    private func printAppearance(at address: CellAddress, value: CellValue, sheet: Sheet) -> CellAppearance {
        var a = styler.appearance(at: address, value: value, sheet: sheet, controller: controller, zoom: 1)
        // Automatic text prints black.
        if sheet.style(at: address).textColor == nil && sheet.style(at: address).fillColor == nil { a.color = .black }
        return a
    }

    private func drawBorders(_ borders: CellBorders, in rect: CGRect) {
        func line(_ border: BorderLine?, _ from: CGPoint, _ to: CGPoint) {
            guard let border else { return }
            border.color.nsColor.setStroke()
            let path = NSBezierPath()
            path.lineWidth = border.style.width * 0.75
            if border.style == .dashed { path.setLineDash([3, 2], count: 2, phase: 0) }
            if border.style == .dotted { path.setLineDash([1, 1], count: 2, phase: 0) }
            path.move(to: from)
            path.line(to: to)
            path.stroke()
        }
        line(borders.top, CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY))
        line(borders.bottom, CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY))
        line(borders.left, CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY))
        line(borders.right, CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY))
    }
}
