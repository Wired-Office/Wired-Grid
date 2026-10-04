import AppKit

/// Draws the worksheet: cells, gridlines, headers, selection and overlays.
///
/// The view sits over an NSScrollView that only provides scrolling; the grid
/// reads the scroll offset and draws the visible cells itself, so headers and
/// frozen panes stay put and the full 1,048,576 × 16,384 sheet costs nothing.
final class GridView: NSView {
    weak var controller: WorkbookController?
    weak var container: GridContainerView?
    let conditional = ConditionalFormatter()

    var scrollOffset: CGPoint = .zero {
        didSet { if scrollOffset != oldValue { needsDisplay = true; container?.layoutObjects() } }
    }

    /// Colored reference boxes shown while editing a formula.
    var referenceHighlights: [(sheet: Int, range: CellRange, color: NSColor)] = [] {
        didSet { needsDisplay = true }
    }
    /// Dashed outline while dragging the fill handle or moving cells.
    var dragPreview: CellRange? { didSet { needsDisplay = true } }
    var marchingPhase: CGFloat = 0
    private var marchingTimer: Timer?
    var hoverAddress: CellAddress?
    var dragMode: DragMode = .none
    var lastDragPoint: CGPoint?
    var autoScrollTimer: Timer?
    /// Where the column/row resize guide is drawn while dragging a header border.
    var resizeGuide: CGPoint?

    private var fontCache: [FontKey: NSFont] = [:]
    private var fontCacheZoom: CGFloat = 1

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        setAccessibilityRole(.table)
        setAccessibilityLabel("Worksheet")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var zoom: CGFloat { CGFloat(controller?.sheet.zoom ?? 1) }

    var geometry: GridGeometry {
        guard let controller else {
            return GridGeometry(sheet: Sheet(name: ""), zoom: 1, scroll: .zero, bounds: bounds, showHeadings: true)
        }
        return GridGeometry(sheet: controller.sheet, zoom: zoom, scroll: scrollOffset, bounds: bounds, showHeadings: controller.sheet.showHeadings)
    }

    // MARK: - Marching ants

    func updateMarchingAnts() {
        let active = controller?.clipboardMarquee != nil
        if active && marchingTimer == nil {
            marchingTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.marchingPhase = (self.marchingPhase + 1).truncatingRemainder(dividingBy: 8)
                if let marquee = self.controller?.clipboardMarquee, marquee.sheet == self.controller?.sheet.id {
                    self.setNeedsDisplay(self.geometry.rect(marquee.range).insetBy(dx: -3, dy: -3))
                }
            }
        } else if !active {
            marchingTimer?.invalidate()
            marchingTimer = nil
        }
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let controller, let context = NSGraphicsContext.current?.cgContext else { return }
        let g = geometry
        let sheet = controller.sheet

        Theme.cellBackground.setFill()
        dirtyRect.intersection(bounds).fill()

        // Quadrants: scrolled body, frozen top, frozen left, frozen corner.
        var quadrants: [(ClosedRange<Int>, ClosedRange<Int>, CGRect)] = [(g.visibleRows, g.visibleColumns, g.bodyRect)]
        if let frozenRows = g.frozenRowRange {
            quadrants.append((frozenRows, g.visibleColumns, CGRect(x: g.bodyOrigin.x, y: g.headerHeight, width: g.bodyRect.width, height: g.frozenHeight)))
        }
        if let frozenColumns = g.frozenColumnRange {
            quadrants.append((g.visibleRows, frozenColumns, CGRect(x: g.headerWidth, y: g.bodyOrigin.y, width: g.frozenWidth, height: g.bodyRect.height)))
        }
        if let frozenRows = g.frozenRowRange, let frozenColumns = g.frozenColumnRange {
            quadrants.append((frozenRows, frozenColumns, CGRect(x: g.headerWidth, y: g.headerHeight, width: g.frozenWidth, height: g.frozenHeight)))
        }

        for (rows, columns, clip) in quadrants where clip.intersects(dirtyRect) && clip.width > 0 && clip.height > 0 {
            context.saveGState()
            context.clip(to: clip)
            drawCells(rows: rows, columns: columns, clip: clip, geometry: g, sheet: sheet, controller: controller)
            drawOverlays(geometry: g, sheet: sheet, controller: controller)
            context.restoreGState()
        }

        if sheet.showHeadings { drawHeaders(g, sheet: sheet, controller: controller) }

        drawResizeGuide(g)

        // Frozen pane dividers.
        if g.frozenRows > 0 || g.frozenColumns > 0 {
            Theme.headerLine.blended(withFraction: 0.35, of: .gray)?.setFill()
            if g.frozenRows > 0 { CGRect(x: g.headerWidth, y: g.bodyOrigin.y - 1, width: bounds.width, height: 1.5).fill() }
            if g.frozenColumns > 0 { CGRect(x: g.bodyOrigin.x - 1, y: g.headerHeight, width: 1.5, height: bounds.height).fill() }
        }
    }

    private func drawResizeGuide(_ g: GridGeometry) {
        guard let guide = resizeGuide else { return }
        let label: String
        NSColor.secondaryLabelColor.setFill()
        switch dragMode {
        case .resizeColumn(_, let startX, let startWidth):
            let width = max(0, startWidth + (guide.x - startX) / g.zoom)
            CGRect(x: guide.x, y: 0, width: 1, height: bounds.height).fill()
            label = String(format: "Width: %.0f pt", width)
        case .resizeRow(_, let startY, let startHeight):
            let height = max(0, startHeight + (guide.y - startY) / g.zoom)
            CGRect(x: 0, y: guide.y, width: bounds.width, height: 1).fill()
            label = String(format: "Height: %.0f pt", height)
        default:
            return
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor]
        let size = (label as NSString).size(withAttributes: attrs)
        let box = CGRect(x: guide.x + 10, y: guide.y + 12, width: size.width + 12, height: size.height + 6)
        NSColor.windowBackgroundColor.setFill()
        let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
        (label as NSString).draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3), withAttributes: attrs)
    }

    private struct FontKey: Hashable {
        var name: String
        var size: Double
        var bold: Bool
        var italic: Bool
    }

    private func font(for style: CellStyle, bold: Bool, italic: Bool, zoom: CGFloat) -> NSFont {
        if fontCacheZoom != zoom { fontCache.removeAll(); fontCacheZoom = zoom }
        let key = FontKey(name: style.effectiveFontName, size: style.effectiveFontSize, bold: style.bold || bold, italic: style.italic || italic)
        if let cached = fontCache[key] { return cached }
        var s = style
        s.bold = key.bold
        s.italic = key.italic
        let font = s.font(zoom: zoom)
        fontCache[key] = font
        return font
    }

    /// The fill and table styling of a cell, before conditional formatting.
    private func tableStyle(at address: CellAddress, sheet: Sheet) -> (fill: RGBColor?, text: RGBColor?, bold: Bool, line: RGBColor?)? {
        guard let table = sheet.tables.first(where: { $0.range.contains(address) }) else { return nil }
        let headerRow = table.showHeader ? table.range.minRow : -1
        if address.row == headerRow {
            return (table.style.header, .white, true, nil)
        }
        if table.showTotals && address.row == table.range.maxRow {
            return (nil, nil, true, table.style.header)
        }
        let dataIndex = address.row - table.range.minRow - (table.showHeader ? 1 : 0)
        if table.bandedRows && dataIndex % 2 == 0 {
            return (table.style.band, nil, false, nil)
        }
        return (nil, nil, false, nil)
    }

    func appearance(at address: CellAddress, value: CellValue, sheet: Sheet, controller: WorkbookController, zoom: CGFloat, forEditing: Bool = false) -> CellAppearance {
        let style = sheet.style(at: address)
        let look = conditional.look(at: address, sheetIndex: controller.activeSheetIndex, controller: controller)
        let table = tableStyle(at: address, sheet: sheet)
        let formatted: FormattedValue
        if controller.showFormulas, let formula = sheet.cells[address]?.formula {
            formatted = FormattedValue(text: "=" + formula)
        } else {
            formatted = NumberFormat.format(value, style.numberFormat)
        }
        var color: NSColor
        if let c = look?.text { color = c.nsColor }
        else if let c = formatted.color { color = c.nsColor }
        else if let c = style.textColor { color = Self.legible(c, onFill: style.fillColor ?? table?.fill) }
        else if let c = table?.text, style.fillColor == nil { color = c.nsColor }
        else if sheet.cells[address]?.link != nil { color = Theme.linkText }
        else { color = Theme.cellText }
        var fill = style.fillColor?.nsColor ?? table?.fill?.nsColor
        if let f = look?.fill { fill = f.nsColor }
        // Keep "automatic" text legible on dark fills and in dark mode on light fills.
        if style.textColor == nil && look?.text == nil && formatted.color == nil, let f = style.fillColor ?? look?.fill ?? table?.fill {
            if table?.text == nil || style.fillColor != nil { color = f.luminance < 0.45 ? .white : .black }
        }
        let isNumber = value.number != nil && !controller.showFormulas
        return CellAppearance(
            text: formatted.text,
            font: font(for: style, bold: (look?.bold ?? false) || (table?.bold ?? false), italic: look?.italic ?? false, zoom: zoom),
            color: color,
            fill: fill,
            horizontal: style.horizontal,
            vertical: style.vertical,
            wrap: style.wrap,
            underline: style.underline || sheet.cells[address]?.link != nil,
            doubleUnderline: style.doubleUnderline,
            strikethrough: style.strikethrough,
            indent: CGFloat(style.indent) * 9 * zoom,
            rotation: style.rotation,
            isNumber: isNumber,
            isGeneral: style.numberFormat == NumberFormat.generalCode,
            fillSplit: formatted.fillSplit,
            fillCharacter: formatted.fillCharacter,
            dataBar: look?.dataBar,
            icon: look?.icon,
            cfBorder: look?.border
        )
    }

    /// Very dark explicit text on the dark sheet is lightened so it stays readable.
    static func legible(_ color: RGBColor, onFill fill: RGBColor?) -> NSColor {
        guard fill == nil, Theme.isDark, color.luminance < 0.3 else { return color.nsColor }
        return color.mixed(with: .white, 0.6).nsColor
    }

    private func drawCells(rows: ClosedRange<Int>, columns: ClosedRange<Int>, clip: CGRect, geometry g: GridGeometry, sheet: Sheet, controller: WorkbookController) {
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        let region = CellRange(rows: rows, columns: columns)
        let merges = sheet.merges.filter { $0.intersects(region) }
        func mergeFor(_ a: CellAddress) -> CellRange? { merges.first { $0.contains(a) } }

        // 1. Gridlines.
        if sheet.showGridlines {
            Theme.gridline.setFill()
            let top = max(g.y(rows.lowerBound), clip.minY), bottom = min(g.y(rows.upperBound) + g.rows.size(rows.upperBound), clip.maxY)
            let left = max(g.x(columns.lowerBound), clip.minX), right = min(g.x(columns.upperBound) + g.columns.size(columns.upperBound), clip.maxX)
            for column in columns where !g.columns.isHidden(column) {
                let x = g.x(column) + g.columns.size(column) - pixel
                CGRect(x: x, y: top, width: pixel, height: bottom - top).fill()
            }
            for row in rows where !g.rows.isHidden(row) {
                let y = g.y(row) + g.rows.size(row) - pixel
                CGRect(x: left, y: y, width: right - left, height: pixel).fill()
            }
        }

        // 2. Fills (cells, tables, conditional formats) and merged areas.
        var appearances: [(CellAddress, CGRect, CellValue, CellAppearance)] = []
        for merge in merges {
            let anchor = merge.start
            let rect = g.rect(merge)
            let value = controller.value(at: anchor)
            let a = appearance(at: anchor, value: value, sheet: sheet, controller: controller, zoom: g.zoom)
            if let fill = a.fill {
                fill.setFill()
                CGRect(x: rect.minX - pixel, y: rect.minY - pixel, width: rect.width + pixel, height: rect.height + pixel).fill()
            } else {
                // Hide the interior gridlines, keeping the outer edges.
                Theme.cellBackground.setFill()
                CGRect(x: rect.minX, y: rect.minY, width: rect.width - pixel, height: rect.height - pixel).fill()
            }
            appearances.append((anchor, rect, value, a))
        }
        let textColumns = max(columns.lowerBound - 6, 0)...columns.upperBound
        for row in rows where !g.rows.isHidden(row) {
            for column in textColumns where !g.columns.isHidden(column) {
                let address = CellAddress(row: row, column: column)
                let rect = g.rect(address)
                if mergeFor(address) != nil || (!columns.contains(column) && sheet.merge(containing: address) != nil) { continue }
                let inVisibleColumns = columns.contains(column)
                let cell = sheet.cells[address]
                let hasStyle = cell?.style != nil || sheet.rowStyles[row] != nil || sheet.columnStyles[column] != nil
                let value = controller.value(at: address)
                let needsLook = !sheet.conditionalFormats.isEmpty || !sheet.tables.isEmpty
                guard hasStyle || !value.isEmpty || needsLook else { continue }
                let a = appearance(at: address, value: value, sheet: sheet, controller: controller, zoom: g.zoom)
                if inVisibleColumns, let fill = a.fill {
                    fill.setFill()
                    CGRect(x: rect.minX - pixel, y: rect.minY - pixel, width: rect.width + pixel, height: rect.height + pixel).fill()
                }
                if inVisibleColumns, let (fraction, color) = a.dataBar {
                    let bar = CGRect(x: rect.minX + 2, y: rect.minY + 3 * g.zoom, width: max((rect.width - 4) * CGFloat(fraction), 2), height: rect.height - 6 * g.zoom)
                    if let gradient = NSGradient(starting: color.nsColor.withAlphaComponent(0.85), ending: color.nsColor.withAlphaComponent(0.25)) {
                        gradient.draw(in: bar, angle: 0)
                    }
                    color.nsColor.setStroke()
                    let outline = NSBezierPath(rect: bar.insetBy(dx: 0.5, dy: 0.5))
                    outline.lineWidth = 0.5
                    outline.stroke()
                }
                appearances.append((address, rect, value, a))
            }
        }

        // 3. Text, with overflow into empty neighbours.
        for (address, rect, value, a) in appearances where !a.text.isEmpty || a.icon != nil {
            var textClip = rect
            let alignment = CellRenderer.effectiveAlignment(a, value: value)
            let isMerged = mergeFor(address) != nil || sheet.merge(containing: address) != nil
            if !a.wrap && !a.isNumber && !isMerged && a.rotation == 0 {
                let needed = CellRenderer.textWidth(a) + CellRenderer.padding * 2 * g.zoom + a.indent
                if needed > rect.width {
                    let extra = needed - rect.width
                    func isFree(_ c: Int) -> Bool {
                        let neighbour = CellAddress(row: address.row, column: c)
                        return !sheet.hasContent(neighbour) && controller.value(at: neighbour).isEmpty && sheet.merge(containing: neighbour) == nil
                    }
                    if alignment == .left || alignment == .general || alignment == .justify {
                        var right = rect.maxX, c = address.column + 1
                        while right < rect.maxX + extra, c < SheetLimits.columns, isFree(c) {
                            right += g.columns.size(c); c += 1
                        }
                        textClip.size.width = right - rect.minX
                    } else if alignment == .right {
                        var left = rect.minX, c = address.column - 1
                        while left > rect.minX - extra, c >= 0, isFree(c) {
                            left -= g.columns.size(c); c -= 1
                        }
                        textClip = CGRect(x: left, y: rect.minY, width: rect.maxX - left, height: rect.height)
                    } else if alignment == .center {
                        var left = rect.minX, right = rect.maxX
                        var cl = address.column - 1, cr = address.column + 1
                        while left > rect.minX - extra / 2, cl >= 0, isFree(cl) { left -= g.columns.size(cl); cl -= 1 }
                        while right < rect.maxX + extra / 2, cr < SheetLimits.columns, isFree(cr) { right += g.columns.size(cr); cr += 1 }
                        textClip = CGRect(x: left, y: rect.minY, width: right - left, height: rect.height)
                    }
                    // Overflowing text hides the gridlines it crosses.
                    if textClip.width > rect.width {
                        Theme.cellBackground.setFill()
                        var c = g.column(atX: textClip.minX + 1)
                        while c < SheetLimits.columns {
                            let edge = g.x(c) + g.columns.size(c)
                            if edge >= textClip.maxX - 1 { break }
                            let left = CellAddress(row: address.row, column: c), right = CellAddress(row: address.row, column: c + 1)
                            if sheet.style(at: left).fillColor == nil && sheet.style(at: right).fillColor == nil {
                                CGRect(x: edge - pixel, y: rect.minY, width: pixel, height: rect.height - pixel).fill()
                            }
                            c += 1
                        }
                    }
                }
            }
            var drawRect = rect
            if textClip.width > rect.width {
                switch alignment {
                case .right: drawRect = CGRect(x: textClip.minX, y: rect.minY, width: textClip.width, height: rect.height)
                case .center: drawRect = textClip
                default: drawRect = CGRect(x: rect.minX, y: rect.minY, width: textClip.width, height: rect.height)
                }
            }
            CellRenderer.draw(a, value: value, in: drawRect, clip: textClip, zoom: g.zoom)
        }

        // 4. Borders (explicit, table totals and conditional).
        for (address, rect, _, a) in appearances {
            let style = sheet.style(at: address)
            var borders = style.borders
            if let merge = sheet.merge(containing: address), merge.start == address {
                // A merged cell uses the edges of its corner cells.
                borders.right = sheet.style(at: CellAddress(row: merge.minRow, column: merge.maxColumn)).borders.right ?? borders.right
                borders.bottom = sheet.style(at: CellAddress(row: merge.maxRow, column: merge.minColumn)).borders.bottom ?? borders.bottom
            }
            if let line = tableStyle(at: address, sheet: sheet)?.line, borders.top == nil { borders.top = BorderLine(style: .thin, color: line) }
            if let cf = a.cfBorder {
                let line = BorderLine(style: .thin, color: cf)
                borders = CellBorders(top: line, left: line, bottom: line, right: line)
            }
            guard !borders.isEmpty else { continue }
            drawBorders(borders, in: rect, pixel: pixel)
        }

        // 5. Note indicators and filter buttons.
        for (address, _) in sheet.notes where region.contains(address) {
            let rect = g.rect(sheet.merge(containing: address) ?? CellRange(address))
            let size = 6 * g.zoom
            let path = NSBezierPath()
            path.move(to: CGPoint(x: rect.maxX - size, y: rect.minY))
            path.line(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.line(to: CGPoint(x: rect.maxX, y: rect.minY + size))
            path.close()
            NSColor(srgbRed: 0.85, green: 0.15, blue: 0.1, alpha: 1).setFill()
            path.fill()
        }
        if let filter = sheet.filter, rows.contains(filter.range.minRow) {
            for column in filter.range.columns where columns.contains(column) && !g.columns.isHidden(column) {
                drawFilterButton(filterButtonRect(column: column, filter: filter, geometry: g), active: filter.criteria[column] != nil)
            }
        }
        // Hyperlink cursor hint and spilled-range outline for the active cell.
        if let anchor = controller.calculator.spillAnchor(sheet: controller.activeSheetIndex, covering: controller.selection.active),
           let spill = controller.calculator.spillRange(sheet: controller.activeSheetIndex, anchor: anchor) {
            let rect = g.rect(spill).insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 1
            path.setLineDash([3, 2], count: 2, phase: 0)
            NSColor.systemBlue.withAlphaComponent(0.8).setStroke()
            path.stroke()
        }
    }

    private func drawBorders(_ borders: CellBorders, in rect: CGRect, pixel: CGFloat) {
        func edge(_ line: BorderLine?, from: CGPoint, to: CGPoint, offset: CGVector) {
            guard let line else { return }
            let color = line.color == .black ? Theme.cellText : line.color.nsColor
            color.setStroke()
            let path = NSBezierPath()
            let width = max(line.style.width, pixel)
            switch line.style {
            case .dashed: path.setLineDash([4, 2], count: 2, phase: 0)
            case .dotted: path.setLineDash([1, 1.5], count: 2, phase: 0)
            default: break
            }
            if line.style == .double {
                path.lineWidth = 0.8
                for shift in [-1.2, 1.2] as [CGFloat] {
                    let p = NSBezierPath()
                    p.lineWidth = 0.8
                    p.move(to: CGPoint(x: from.x + offset.dx * shift, y: from.y + offset.dy * shift))
                    p.line(to: CGPoint(x: to.x + offset.dx * shift, y: to.y + offset.dy * shift))
                    p.stroke()
                }
                return
            }
            path.lineWidth = width
            path.move(to: from)
            path.line(to: to)
            path.stroke()
        }
        let inset = pixel / 2
        edge(borders.top, from: CGPoint(x: rect.minX - inset, y: rect.minY - inset), to: CGPoint(x: rect.maxX - inset, y: rect.minY - inset), offset: CGVector(dx: 0, dy: 1))
        edge(borders.bottom, from: CGPoint(x: rect.minX - inset, y: rect.maxY - inset), to: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset), offset: CGVector(dx: 0, dy: 1))
        edge(borders.left, from: CGPoint(x: rect.minX - inset, y: rect.minY - inset), to: CGPoint(x: rect.minX - inset, y: rect.maxY - inset), offset: CGVector(dx: 1, dy: 0))
        edge(borders.right, from: CGPoint(x: rect.maxX - inset, y: rect.minY - inset), to: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset), offset: CGVector(dx: 1, dy: 0))
    }

    func filterButtonRect(column: Int, filter: AutoFilter, geometry g: GridGeometry) -> CGRect {
        let cell = g.rect(CellAddress(row: filter.range.minRow, column: column))
        let size = min(cell.height - 4, 17 * g.zoom)
        return CGRect(x: cell.maxX - size - 3, y: cell.midY - size / 2, width: size, height: size)
    }

    private func drawFilterButton(_ rect: CGRect, active: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        (active ? Theme.accent.withAlphaComponent(0.18) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (active ? Theme.accent : NSColor.separatorColor).setStroke()
        path.lineWidth = 1
        path.stroke()
        let symbol = NSImage(systemSymbolName: active ? "line.3.horizontal.decrease" : "chevron.down", accessibilityDescription: "Filter")
        let config = NSImage.SymbolConfiguration(pointSize: rect.height * 0.5, weight: .semibold)
        if let image = symbol?.withSymbolConfiguration(config) {
            let tinted = image.tinted(active ? Theme.accent : NSColor.secondaryLabelColor)
            let size = tinted.size
            tinted.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
        }
    }

    // MARK: - Overlays

    private func drawOverlays(geometry g: GridGeometry, sheet: Sheet, controller: WorkbookController) {
        let selection = controller.selection
        let accent = Theme.selection

        // Formula reference boxes.
        for highlight in referenceHighlights where highlight.sheet == controller.activeSheetIndex {
            let rect = g.rect(highlight.range).insetBy(dx: 0.5, dy: 0.5)
            highlight.color.withAlphaComponent(0.1).setFill()
            rect.fill()
            highlight.color.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 1.5
            path.stroke()
            // Corner handles like Excel's.
            highlight.color.setFill()
            for corner in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] {
                CGRect(x: corner.x - 2, y: corner.y - 2, width: 4, height: 4).fill()
            }
        }

        let editing = controller.isEditing
        // Selection fill: every range, leaving the active cell clear.
        if !(editing && selection.isSingleCell) {
            let path = NSBezierPath()
            path.windingRule = .evenOdd
            for range in selection.ranges where !range.isSingleCell || selection.isMultiple {
                path.appendRect(clampedRect(range, g))
            }
            if !selection.isSingleCell {
                let activeRange = sheet.merge(containing: selection.active) ?? CellRange(selection.active)
                path.appendRect(g.rect(activeRange))
            }
            accent.withAlphaComponent(Theme.isDark ? 0.22 : 0.13).setFill()
            path.fill()
        }

        // Outline of the current range, and the fill handle.
        let primary = clampedRect(selection.primary, g).insetBy(dx: -0.5, dy: -0.5)
        accent.setStroke()
        let outline = NSBezierPath(rect: primary)
        outline.lineWidth = 2
        outline.stroke()
        if selection.isMultiple || !selection.isSingleCell {
            let activeRect = g.rect(sheet.merge(containing: selection.active) ?? CellRange(selection.active)).insetBy(dx: 0.5, dy: 0.5)
            let activePath = NSBezierPath(rect: activeRect)
            activePath.lineWidth = 1
            accent.withAlphaComponent(0.7).setStroke()
            activePath.stroke()
        }
        if !editing && !selection.isMultiple && !selection.primary.isWholeColumns && !selection.primary.isWholeRows {
            let handle = fillHandleRect(g)
            Theme.cellBackground.setFill()
            handle.insetBy(dx: -1, dy: -1).fill()
            accent.setFill()
            handle.fill()
        }

        // Copy marquee.
        if let marquee = controller.clipboardMarquee, marquee.sheet == sheet.id {
            let rect = g.rect(marquee.range).insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 2
            Theme.cellBackground.setStroke()
            path.stroke()
            path.setLineDash([4, 4], count: 2, phase: marchingPhase)
            accent.setStroke()
            path.stroke()
        }

        if let preview = dragPreview {
            let path = NSBezierPath(rect: g.rect(preview).insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1.5
            path.setLineDash([3, 3], count: 2, phase: 0)
            NSColor.secondaryLabelColor.setStroke()
            path.stroke()
        }
    }

    /// Whole-row/column ranges extend just past the visible area rather than to row 1,048,576.
    func clampedRect(_ range: CellRange, _ g: GridGeometry) -> CGRect {
        var r = range
        if range.isWholeColumns || range.isWholeRows {
            let lastRow = min(range.maxRow, g.visibleRows.upperBound + 1)
            let lastColumn = min(range.maxColumn, g.visibleColumns.upperBound + 1)
            r = CellRange(range.start, CellAddress(row: max(lastRow, range.minRow), column: max(lastColumn, range.minColumn)))
        }
        var rect = g.rect(r)
        if range.isWholeColumns { rect.origin.y = min(rect.origin.y, g.headerHeight); rect.size.height = max(rect.height, bounds.height) }
        if range.isWholeRows { rect.origin.x = min(rect.origin.x, g.headerWidth); rect.size.width = max(rect.width, bounds.width) }
        return rect
    }

    func fillHandleRect(_ g: GridGeometry) -> CGRect {
        guard let controller else { return .zero }
        let rect = g.rect(controller.selection.primary)
        return CGRect(x: rect.maxX - 3.5, y: rect.maxY - 3.5, width: 6, height: 6)
    }

    // MARK: - Headers

    private func drawHeaders(_ g: GridGeometry, sheet: Sheet, controller: WorkbookController) {
        let selection = controller.selection
        var selectedColumns = IndexSet(), fullColumns = IndexSet()
        var selectedRows = IndexSet(), fullRows = IndexSet()
        for range in selection.ranges {
            // Only the part of the selection that can be on screen matters; it may be scrolled away entirely.
            let lastColumn = min(range.maxColumn, g.visibleColumns.upperBound + 1)
            let lastRow = min(range.maxRow, g.visibleRows.upperBound + 1)
            if range.minColumn <= lastColumn {
                selectedColumns.insert(integersIn: range.minColumn...lastColumn)
                if range.isWholeColumns { fullColumns.insert(integersIn: range.minColumn...lastColumn) }
            }
            if range.minRow <= lastRow {
                selectedRows.insert(integersIn: range.minRow...lastRow)
                if range.isWholeRows { fullRows.insert(integersIn: range.minRow...lastRow) }
            }
        }
        let font = NSFont.systemFont(ofSize: 11 * max(min(g.zoom, 1.6), 0.8))
        let boldFont = NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)
        let pixel = 1 / (window?.backingScaleFactor ?? 2)

        // Column headers.
        let columnStrip = CGRect(x: g.headerWidth, y: 0, width: bounds.width - g.headerWidth, height: g.headerHeight)
        Theme.headerBackground.setFill()
        columnStrip.fill()
        var columnGroups: [(ClosedRange<Int>, CGRect)] = [(g.visibleColumns, CGRect(x: g.bodyOrigin.x, y: 0, width: bounds.width - g.bodyOrigin.x, height: g.headerHeight))]
        if let frozen = g.frozenColumnRange { columnGroups.append((frozen, CGRect(x: g.headerWidth, y: 0, width: g.frozenWidth, height: g.headerHeight))) }
        for (columns, clip) in columnGroups {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: clip).addClip()
            for column in columns where !g.columns.isHidden(column) {
                let rect = CGRect(x: g.x(column), y: 0, width: g.columns.size(column), height: g.headerHeight)
                let full = fullColumns.contains(column), partial = selectedColumns.contains(column)
                if full { Theme.headerFullySelected.setFill(); rect.fill() } else if partial { Theme.headerSelected.setFill(); rect.fill() }
                let label = CellAddress.columnName(column) as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: partial ? boldFont : font, .foregroundColor: full ? NSColor.white : (partial ? Theme.accent : Theme.headerText)]
                let size = label.size(withAttributes: attrs)
                if rect.width > size.width + 2 {
                    label.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
                }
                Theme.headerLine.setFill()
                CGRect(x: rect.maxX - pixel, y: 3, width: pixel, height: rect.height - 6).fill()
                if partial && !full {
                    Theme.accent.setFill()
                    CGRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2).fill()
                }
                // Hidden neighbours are marked by a double line.
                if column + 1 < SheetLimits.columns, g.columns.isHidden(column + 1) {
                    Theme.headerText.setFill()
                    CGRect(x: rect.maxX - 2, y: 4, width: pixel, height: rect.height - 8).fill()
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        Theme.headerLine.setFill()
        CGRect(x: 0, y: g.headerHeight - pixel, width: bounds.width, height: pixel).fill()

        // Row headers.
        let rowStrip = CGRect(x: 0, y: g.headerHeight, width: g.headerWidth, height: bounds.height - g.headerHeight)
        Theme.headerBackground.setFill()
        rowStrip.fill()
        var rowGroups: [(ClosedRange<Int>, CGRect)] = [(g.visibleRows, CGRect(x: 0, y: g.bodyOrigin.y, width: g.headerWidth, height: bounds.height - g.bodyOrigin.y))]
        if let frozen = g.frozenRowRange { rowGroups.append((frozen, CGRect(x: 0, y: g.headerHeight, width: g.headerWidth, height: g.frozenHeight))) }
        for (rows, clip) in rowGroups {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: clip).addClip()
            for row in rows where !g.rows.isHidden(row) {
                let rect = CGRect(x: 0, y: g.y(row), width: g.headerWidth, height: g.rows.size(row))
                let full = fullRows.contains(row), partial = selectedRows.contains(row)
                if full { Theme.headerFullySelected.setFill(); rect.fill() } else if partial { Theme.headerSelected.setFill(); rect.fill() }
                let filtered = sheet.filter?.dataRows?.contains(row) == true && !(sheet.filter?.criteria.isEmpty ?? true)
                let label = String(row + 1) as NSString
                let color: NSColor = full ? .white : (partial ? Theme.accent : (filtered ? NSColor.systemBlue : Theme.headerText))
                let attrs: [NSAttributedString.Key: Any] = [.font: partial ? boldFont : font, .foregroundColor: color]
                let size = label.size(withAttributes: attrs)
                if rect.height > size.height * 0.6 {
                    label.draw(at: CGPoint(x: rect.maxX - size.width - 6, y: rect.midY - size.height / 2), withAttributes: attrs)
                }
                Theme.headerLine.setFill()
                CGRect(x: 3, y: rect.maxY - pixel, width: rect.width - 6, height: pixel).fill()
                if partial && !full {
                    Theme.accent.setFill()
                    CGRect(x: rect.maxX - 2, y: rect.minY, width: 2, height: rect.height).fill()
                }
                if row + 1 < SheetLimits.rows, g.rows.isHidden(row + 1) {
                    Theme.headerText.setFill()
                    CGRect(x: 4, y: rect.maxY - 2, width: rect.width - 8, height: pixel).fill()
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        Theme.headerLine.setFill()
        CGRect(x: g.headerWidth - pixel, y: 0, width: pixel, height: bounds.height).fill()

        // Corner (select all).
        let corner = CGRect(x: 0, y: 0, width: g.headerWidth - pixel, height: g.headerHeight - pixel)
        Theme.headerBackground.setFill()
        corner.fill()
        let triangle = NSBezierPath()
        triangle.move(to: CGPoint(x: corner.maxX - 4, y: corner.maxY - 12))
        triangle.line(to: CGPoint(x: corner.maxX - 4, y: corner.maxY - 4))
        triangle.line(to: CGPoint(x: corner.maxX - 12, y: corner.maxY - 4))
        triangle.close()
        (selection.primary == .all ? Theme.accent : Theme.headerLine).setFill()
        triangle.fill()
    }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}
