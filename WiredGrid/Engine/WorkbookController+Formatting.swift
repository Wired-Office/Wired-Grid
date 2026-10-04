import AppKit

enum BorderPreset: String, CaseIterable {
    case bottom, top, left, right, none, all, outside, thickOutside, doubleBottom, thickBottom, topAndBottom, topAndDoubleBottom, insideHorizontal, insideVertical

    var title: String {
        switch self {
        case .bottom: "Bottom Border"
        case .top: "Top Border"
        case .left: "Left Border"
        case .right: "Right Border"
        case .none: "No Border"
        case .all: "All Borders"
        case .outside: "Outside Borders"
        case .thickOutside: "Thick Outside Borders"
        case .doubleBottom: "Bottom Double Border"
        case .thickBottom: "Thick Bottom Border"
        case .topAndBottom: "Top and Bottom Border"
        case .topAndDoubleBottom: "Top and Double Bottom Border"
        case .insideHorizontal: "Inside Horizontal Borders"
        case .insideVertical: "Inside Vertical Borders"
        }
    }

    var symbol: String {
        switch self {
        case .bottom: "square.bottomhalf.filled"
        case .top: "square.tophalf.filled"
        case .left: "square.lefthalf.filled"
        case .right: "square.righthalf.filled"
        case .none: "square.dashed"
        case .all: "square.grid.2x2"
        case .outside: "square"
        case .thickOutside: "square.fill"
        case .doubleBottom: "equal.square"
        case .thickBottom: "underline"
        case .topAndBottom: "rectangle.split.1x2"
        case .topAndDoubleBottom: "rectangle.split.1x2.fill"
        case .insideHorizontal: "rectangle.grid.1x2"
        case .insideVertical: "rectangle.split.2x1"
        }
    }
}

enum MergeMode { case mergeAndCenter, mergeAcross, merge, unmerge }

/// Built-in cell styles (Home ▸ Cell Styles).
enum NamedCellStyle: String, CaseIterable, Identifiable {
    case normal, good, bad, neutral, title, heading1, heading2, heading3, total, input, output, calculation, note, warning, accent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: "Normal"
        case .good: "Good"
        case .bad: "Bad"
        case .neutral: "Neutral"
        case .title: "Title"
        case .heading1: "Heading 1"
        case .heading2: "Heading 2"
        case .heading3: "Heading 3"
        case .total: "Total"
        case .input: "Input"
        case .output: "Output"
        case .calculation: "Calculation"
        case .note: "Note"
        case .warning: "Warning Text"
        case .accent: "Accent"
        }
    }

    func apply(to style: inout CellStyle) {
        let format = style.numberFormat
        style = CellStyle()
        style.numberFormat = format
        switch self {
        case .normal: break
        case .good: style.fillColor = RGBColor(0xC6EFCE); style.textColor = RGBColor(0x006100)
        case .bad: style.fillColor = RGBColor(0xFFC7CE); style.textColor = RGBColor(0x9C0006)
        case .neutral: style.fillColor = RGBColor(0xFFEB9C); style.textColor = RGBColor(0x9C5700)
        case .title: style.fontSize = 20; style.bold = true; style.textColor = RGBColor(0x1B4332)
        case .heading1:
            style.fontSize = 15; style.bold = true; style.textColor = RGBColor(0x1B4332)
            style.borders.bottom = BorderLine(style: .thick, color: RGBColor(0x1E8E5A))
        case .heading2:
            style.fontSize = 13; style.bold = true; style.textColor = RGBColor(0x1B4332)
            style.borders.bottom = BorderLine(style: .medium, color: RGBColor(0x74C69D))
        case .heading3:
            style.bold = true; style.textColor = RGBColor(0x1B4332)
            style.borders.bottom = BorderLine(style: .thin, color: RGBColor(0x95D5B2))
        case .total:
            style.bold = true
            style.borders.top = BorderLine(style: .thin, color: RGBColor(0x1E8E5A))
            style.borders.bottom = BorderLine(style: .double, color: RGBColor(0x1E8E5A))
        case .input:
            style.fillColor = RGBColor(0xFFCC99); style.textColor = RGBColor(0x3F3F76)
            let line = BorderLine(style: .thin, color: RGBColor(0x7F7F7F))
            style.borders = CellBorders(top: line, left: line, bottom: line, right: line)
        case .output:
            style.fillColor = RGBColor(0xF2F2F2); style.textColor = RGBColor(0x3F3F3F); style.bold = true
            let line = BorderLine(style: .thin, color: RGBColor(0x3F3F3F))
            style.borders = CellBorders(top: line, left: line, bottom: line, right: line)
        case .calculation:
            style.fillColor = RGBColor(0xF2F2F2); style.textColor = RGBColor(0xFA7D00); style.bold = true
            let line = BorderLine(style: .thin, color: RGBColor(0x7F7F7F))
            style.borders = CellBorders(top: line, left: line, bottom: line, right: line)
        case .note:
            style.fillColor = RGBColor(0xFFFFCC)
            let line = BorderLine(style: .thin, color: RGBColor(0xB2B2B2))
            style.borders = CellBorders(top: line, left: line, bottom: line, right: line)
        case .warning: style.textColor = RGBColor(0xFF0000)
        case .accent: style.fillColor = RGBColor(0x1E8E5A); style.textColor = .white; style.bold = true
        }
    }
}

extension WorkbookController {
    // MARK: - Applying styles

    /// Applies a style change to every selected cell (and to whole rows/columns).
    func applyStyle(_ actionName: String, geometry: Bool = false, _ transform: @escaping (inout CellStyle) -> Void) {
        commitEditingIfNeeded()
        let ranges = selection.ranges
        let extent = sheet.contentExtent
        changeSheet(actionName, geometry: geometry) { sheet in
            Self.applyStyle(transform, to: ranges, in: &sheet, extent: extent)
            if geometry { autoFitRowForWrap(&sheet, rows: Set(ranges.flatMap { r -> [Int] in r.rowCount < 5000 ? Array(r.rows) : [] })) }
        }
    }

    static func applyStyle(_ transform: (inout CellStyle) -> Void, to ranges: [CellRange], in sheet: inout Sheet, extent: CellAddress) {
        for range in ranges {
            if range.isWholeColumns || range.isWholeRows {
                if range.isWholeColumns {
                    let columns = range.isWholeRows ? 0...max(extent.column, 25) : range.columns
                    for column in columns {
                        var style = sheet.columnStyles[column] ?? .plain
                        transform(&style)
                        sheet.columnStyles[column] = style.isPlain ? nil : style
                    }
                }
                if range.isWholeRows && !range.isWholeColumns {
                    for row in range.rows {
                        var style = sheet.rowStyles[row] ?? .plain
                        transform(&style)
                        sheet.rowStyles[row] = style.isPlain ? nil : style
                    }
                }
                for address in Array(sheet.cells.keys) where range.contains(address) {
                    sheet.updateStyle(at: address, transform)
                }
                // Row styles override column styles, so restyle rows crossing the columns too.
                if range.isWholeColumns {
                    for (row, var rowStyle) in sheet.rowStyles {
                        transform(&rowStyle)
                        for column in range.columns.clamped(to: 0...max(extent.column, 25)) {
                            let address = CellAddress(row: row, column: column)
                            if sheet.cells[address]?.style == nil {
                                var cell = sheet.cells[address] ?? Cell()
                                cell.style = rowStyle
                                sheet[address] = cell
                            }
                        }
                    }
                }
            } else {
                guard range.cellCount <= 2_000_000 else { continue }
                for address in range.addresses {
                    sheet.updateStyle(at: address, transform)
                }
            }
        }
    }

    func toggleBold() {
        let on = !activeStyle.bold
        applyStyle(on ? "Bold" : "Remove Bold") { $0.bold = on }
    }

    func toggleItalic() {
        let on = !activeStyle.italic
        applyStyle(on ? "Italic" : "Remove Italic") { $0.italic = on }
    }

    func toggleUnderline() {
        let on = !activeStyle.underline
        applyStyle(on ? "Underline" : "Remove Underline") { $0.underline = on; $0.doubleUnderline = false }
    }

    func toggleDoubleUnderline() {
        let on = !activeStyle.doubleUnderline
        applyStyle("Double Underline") { $0.doubleUnderline = on; $0.underline = false }
    }

    func toggleStrikethrough() {
        let on = !activeStyle.strikethrough
        applyStyle(on ? "Strikethrough" : "Remove Strikethrough") { $0.strikethrough = on }
    }

    func setFontName(_ name: String) {
        applyStyle("Font", geometry: true) { $0.fontName = name == AppSettings.shared.defaultFontName ? nil : name }
    }

    func setFontSize(_ size: Double) {
        let clamped = min(max(size, 1), 409)
        applyStyle("Font Size", geometry: true) { $0.fontSize = clamped == AppSettings.shared.defaultFontSize ? nil : clamped }
        adjustRowHeightsForFont()
    }

    static let fontSizes: [Double] = [8, 9, 10, 11, 12, 14, 16, 18, 20, 22, 24, 26, 28, 36, 48, 72]

    func growFont(_ grow: Bool) {
        let current = activeStyle.effectiveFontSize
        let next = grow ? (Self.fontSizes.first { $0 > current } ?? current + 12) : (Self.fontSizes.last { $0 < current } ?? max(current - 1, 1))
        setFontSize(next)
    }

    /// Rows grow to fit bigger fonts (unless sized by hand).
    private func adjustRowHeightsForFont() {
        let rows = Set(selection.ranges.flatMap { r -> [Int] in
            let bounded = boundedToContent(r)
            return bounded.rowCount < 5000 ? Array(bounded.rows) : []
        })
        guard !rows.isEmpty else { return }
        var sheetCopy = sheet
        var changed = false
        for row in rows where sheetCopy.rowHeights[row] == nil || autoSizedRows.contains(row) {
            var needed = Sheet.defaultRowHeight
            for (address, cell) in sheetCopy.cells where address.row == row && cell.hasContent {
                let font = sheetCopy.style(at: address).font()
                needed = max(needed, Double(ceil(font.ascender - font.descender + font.leading)) + 7)
            }
            if sheetCopy.style(at: CellAddress(row: row, column: 0)).wrap { continue }
            let newHeight: Double? = needed > Sheet.defaultRowHeight + 0.5 ? needed : nil
            if sheetCopy.rowHeights[row] != newHeight {
                sheetCopy.rowHeights[row] = newHeight
                changed = true
                if newHeight != nil { autoSizedRows.insert(row) }
            }
        }
        if changed {
            let heights = sheetCopy.rowHeights
            let index = activeSheetIndex
            // Folded into the font change for undo purposes.
            undoManager?.disableUndoRegistration()
            change("Row Height", geometry: true) { $0.sheets[index].rowHeights = heights }
            undoManager?.enableUndoRegistration()
        }
    }

    func setTextColor(_ color: RGBColor?) {
        applyStyle("Font Color") { $0.textColor = color }
    }

    func setFillColor(_ color: RGBColor?) {
        applyStyle("Fill Color") { $0.fillColor = color }
    }

    func setHorizontalAlignment(_ alignment: HorizontalAlignment) {
        let current = activeStyle.horizontal
        let target: HorizontalAlignment = current == alignment ? .general : alignment
        applyStyle("Alignment") { $0.horizontal = target }
    }

    func setVerticalAlignment(_ alignment: VerticalAlignment) {
        applyStyle("Alignment") { $0.vertical = alignment }
    }

    func toggleWrap() {
        let on = !activeStyle.wrap
        applyStyle("Wrap Text", geometry: true) { $0.wrap = on }
    }

    func changeIndent(_ delta: Int) {
        applyStyle("Indent") { style in
            style.indent = max(0, min(15, style.indent + delta))
            if style.indent > 0 && (style.horizontal == .general || style.horizontal == .center) { style.horizontal = .left }
        }
    }

    func setNumberFormat(_ code: String) {
        applyStyle("Number Format", geometry: false) { $0.numberFormat = code }
    }

    func adjustDecimals(_ delta: Int) {
        let format = activeStyle.numberFormat
        let sample = value(at: selection.active).number
        let adjusted = NumberFormat.adjustingDecimals(format, by: delta, sampleValue: sample)
        guard adjusted != format else { return }
        applyStyle(delta > 0 ? "Increase Decimal" : "Decrease Decimal") { $0.numberFormat = adjusted }
    }

    func setRotation(_ degrees: Int) {
        applyStyle("Orientation", geometry: true) { $0.rotation = degrees }
    }

    func applyNamedStyle(_ named: NamedCellStyle) {
        applyStyle("Cell Style", geometry: true) { named.apply(to: &$0) }
    }

    // MARK: - Borders

    func applyBorders(_ preset: BorderPreset, line: BorderLine = BorderLine()) {
        commitEditingIfNeeded()
        let ranges = selection.ranges.map { boundedToContent($0) }
        changeSheet(preset.title) { sheet in
            for range in ranges where range.cellCount <= 1_000_000 {
                func edit(_ address: CellAddress, _ change: (inout CellBorders) -> Void) {
                    sheet.updateStyle(at: address) { change(&$0.borders) }
                }
                let thick = BorderLine(style: .thick, color: line.color)
                let double = BorderLine(style: .double, color: line.color)
                for address in range.addresses {
                    let top = address.row == range.minRow, bottom = address.row == range.maxRow
                    let left = address.column == range.minColumn, right = address.column == range.maxColumn
                    switch preset {
                    case .all: edit(address) { $0 = CellBorders(top: line, left: line, bottom: line, right: line) }
                    case .none: edit(address) { $0 = CellBorders() }
                    case .outside, .thickOutside:
                        let l = preset == .thickOutside ? thick : line
                        edit(address) { b in
                            if top { b.top = l }
                            if bottom { b.bottom = l }
                            if left { b.left = l }
                            if right { b.right = l }
                        }
                    case .bottom: if bottom { edit(address) { $0.bottom = line } }
                    case .top: if top { edit(address) { $0.top = line } }
                    case .left: if left { edit(address) { $0.left = line } }
                    case .right: if right { edit(address) { $0.right = line } }
                    case .doubleBottom: if bottom { edit(address) { $0.bottom = double } }
                    case .thickBottom: if bottom { edit(address) { $0.bottom = thick } }
                    case .topAndBottom:
                        if top { edit(address) { $0.top = line } }
                        if bottom { edit(address) { $0.bottom = line } }
                    case .topAndDoubleBottom:
                        if top { edit(address) { $0.top = line } }
                        if bottom { edit(address) { $0.bottom = double } }
                    case .insideHorizontal: if !bottom { edit(address) { $0.bottom = line } }
                    case .insideVertical: if !right { edit(address) { $0.right = line } }
                    }
                }
                if preset == .none {
                    // Clear the facing edges of neighbours too.
                    for column in range.columns {
                        if range.minRow > 0 { let a = CellAddress(row: range.minRow - 1, column: column); if sheet.cells[a]?.style?.borders.bottom != nil { edit(a) { $0.bottom = nil } } }
                        let b = CellAddress(row: range.maxRow + 1, column: column); if sheet.cells[b]?.style?.borders.top != nil { edit(b) { $0.top = nil } }
                    }
                    for row in range.rows {
                        if range.minColumn > 0 { let a = CellAddress(row: row, column: range.minColumn - 1); if sheet.cells[a]?.style?.borders.right != nil { edit(a) { $0.right = nil } } }
                        let b = CellAddress(row: row, column: range.maxColumn + 1); if sheet.cells[b]?.style?.borders.left != nil { edit(b) { $0.left = nil } }
                    }
                }
            }
        }
    }

    // MARK: - Merging

    func merge(_ mode: MergeMode) {
        commitEditingIfNeeded()
        let ranges = selection.ranges.filter { !$0.isSingleCell && $0.cellCount < 1_000_000 }
        if mode == .unmerge || (mode == .mergeAndCenter && ranges.allSatisfy { r in sheet.merges.contains(r) } && !ranges.isEmpty) {
            let selected = selection.ranges
            changeSheet("Unmerge Cells", geometry: true) { sheet in
                sheet.merges.removeAll { merge in selected.contains { $0.intersects(merge) } }
            }
            return
        }
        guard !ranges.isEmpty else { return }
        // Warn when merging would discard values.
        let losesData = ranges.contains { range in
            range.addresses.dropFirst().contains { sheet.hasContent($0) } && (mode != .mergeAcross)
        }
        let perform = { [self] in
            changeSheet(mode == .mergeAndCenter ? "Merge & Center" : "Merge Cells", geometry: true) { sheet in
                var targets: [CellRange] = []
                for range in ranges {
                    if mode == .mergeAcross {
                        for row in range.rows { targets.append(CellRange(rows: row...row, columns: range.columns)) }
                    } else {
                        targets.append(range)
                    }
                }
                for target in targets where !target.isSingleCell {
                    sheet.merges.removeAll { $0.intersects(target) }
                    sheet.merges.append(target)
                    for address in target.addresses.dropFirst() {
                        if var cell = sheet.cells[address] {
                            cell.value = .empty
                            cell.formula = nil
                            sheet[address] = cell
                        }
                    }
                    if mode == .mergeAndCenter {
                        sheet.updateStyle(at: target.start) { $0.horizontal = .center }
                    }
                }
            }
            if let first = ranges.first { select(range: first) }
        }
        if losesData {
            let alert = NSAlert()
            alert.messageText = "Merging cells only keeps the upper-left value."
            alert.informativeText = "The other values will be discarded."
            alert.addButton(withTitle: "Merge")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return }
        }
        perform()
    }

    var selectionIsMerged: Bool {
        sheet.merges.contains { $0 == selection.primary }
    }

    // MARK: - Format painter

    func captureFormatPainter(sticky: Bool) {
        let range = boundedToContent(selection.primary)
        guard range.cellCount <= 10_000 else { return }
        var styles: [[CellStyle]] = []
        for row in range.rows {
            styles.append(range.columns.map { sheet.style(at: CellAddress(row: row, column: $0)) })
        }
        formatPainter = FormatPainter(styles: styles, sticky: sticky)
    }

    func applyFormatPainter() {
        guard let painter = formatPainter, let first = painter.styles.first, !first.isEmpty else { return }
        let target = selection.primary
        let height = painter.styles.count, width = first.count
        let range = target.isSingleCell ? CellRange(target.start, target.start.offset(rows: height - 1, columns: width - 1)) : boundedToContent(target)
        if !painter.sticky { formatPainter = nil }
        changeSheet("Paste Formatting") { sheet in
            for address in range.addresses {
                let style = painter.styles[(address.row - range.minRow) % height][(address.column - range.minColumn) % width]
                var cell = sheet.cells[address] ?? Cell()
                cell.style = style.isPlain ? nil : style
                sheet[address] = cell
            }
        }
    }

    // MARK: - Sizes

    func setColumnWidth(_ width: Double, columns: [Int]) {
        changeSheet("Column Width", geometry: true) { sheet in
            for column in columns {
                sheet.columnWidths[column] = abs(width - Sheet.defaultColumnWidth) < 0.01 ? nil : max(0, width)
                if width <= 0 { sheet.hiddenColumns.insert(column); sheet.columnWidths[column] = nil } else { sheet.hiddenColumns.remove(column) }
            }
        }
    }

    func setRowHeight(_ height: Double, rows: [Int]) {
        changeSheet("Row Height", geometry: true) { sheet in
            for row in rows {
                sheet.rowHeights[row] = abs(height - Sheet.defaultRowHeight) < 0.01 ? nil : max(0, height)
                if height <= 0 { sheet.hiddenRows.insert(row); sheet.rowHeights[row] = nil } else { sheet.hiddenRows.remove(row) }
            }
        }
        var auto = autoSizedRows
        auto.subtract(rows)
        autoSizedRows = auto
    }

    /// The width that fits a column's widest value.
    func fittingWidth(forColumn column: Int) -> Double {
        var width: Double = 0
        let sheet = self.sheet
        for (address, cell) in sheet.cells where address.column == column && cell.hasContent {
            if sheet.merge(containing: address) != nil { continue }
            let style = sheet.style(at: address)
            let text = NumberFormat.format(value(at: address), style.numberFormat).text
            let size = (text as NSString).size(withAttributes: [.font: style.font()])
            width = max(width, Double(size.width) + 10 + Double(style.indent) * 9)
        }
        return width == 0 ? Sheet.defaultColumnWidth : min(max(width, 12), 1500)
    }

    func autoFitColumns(_ columns: [Int]) {
        let widths = columns.map { ($0, fittingWidth(forColumn: $0)) }
        changeSheet("AutoFit Column Width", geometry: true) { sheet in
            for (column, width) in widths {
                sheet.columnWidths[column] = abs(width - Sheet.defaultColumnWidth) < 0.5 ? nil : width
                sheet.hiddenColumns.remove(column)
            }
        }
    }

    func autoFitRows(_ rows: [Int]) {
        let heights = rows.map { ($0, fittingHeight(forRow: $0, in: sheet)) }
        changeSheet("AutoFit Row Height", geometry: true) { sheet in
            for (row, height) in heights {
                sheet.rowHeights[row] = abs(height - Sheet.defaultRowHeight) < 0.5 ? nil : height
                sheet.hiddenRows.remove(row)
            }
        }
    }

    /// Columns touched by the selection (bounded to content for whole-row selections).
    var selectedColumnIndices: [Int] {
        var set = Set<Int>()
        for range in selection.ranges {
            let bounded = range.isWholeRows ? boundedToContent(range) : range
            if bounded.columnCount > 20_000 { continue }
            set.formUnion(bounded.columns)
        }
        return set.sorted()
    }

    var selectedRowIndices: [Int] {
        var set = Set<Int>()
        for range in selection.ranges {
            let bounded = range.isWholeColumns ? boundedToContent(range) : range
            if bounded.rowCount > 200_000 { continue }
            set.formUnion(bounded.rows)
        }
        return set.sorted()
    }
}
