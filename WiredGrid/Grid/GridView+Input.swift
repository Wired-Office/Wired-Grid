import AppKit

extension GridView {
    enum Region {
        case corner
        case columnHeader(Int)
        case columnBorder(Int)
        case rowHeader(Int)
        case rowBorder(Int)
        case fillHandle
        case selectionEdge
        case filterButton(Int)
        case cell(CellAddress)
        case none
    }

    enum DragMode {
        case none
        case selecting
        case columns(anchor: Int)
        case rows(anchor: Int)
        case resizeColumn(column: Int, startX: CGFloat, startWidth: CGFloat)
        case resizeRow(row: Int, startY: CGFloat, startHeight: CGFloat)
        case fill(source: CellRange)
        case move(source: CellRange, grab: CellAddress)
        case point(anchor: CellAddress)
        /// A press on the fill handle or selection border that hasn't moved far enough to count as a drag.
        case pending(fill: Bool, start: CGPoint, cell: CellAddress, source: CellRange, grab: CellAddress)

        var isActive: Bool {
            if case .none = self { return false }
            return true
        }
    }

    /// How far the pointer must travel before a press on the handle or border becomes a drag.
    private static let dragThreshold: CGFloat = 4

    func region(at point: CGPoint) -> Region {
        guard let controller else { return .none }
        let g = geometry
        if point.x < g.headerWidth && point.y < g.headerHeight { return .corner }
        if point.y < g.headerHeight {
            let column = g.column(atX: point.x)
            let edge = g.x(column) + g.columns.size(column)
            let startEdge = g.x(column)
            if abs(point.x - edge) <= 4 { return .columnBorder(column) }
            if abs(point.x - startEdge) <= 3, column > 0 {
                // The border on the left belongs to the previous visible column.
                var previous = column - 1
                while previous > 0 && g.columns.isHidden(previous) { previous -= 1 }
                return .columnBorder(previous)
            }
            return .columnHeader(column)
        }
        if point.x < g.headerWidth {
            let row = g.row(atY: point.y)
            let edge = g.y(row) + g.rows.size(row)
            if abs(point.y - edge) <= 3 { return .rowBorder(row) }
            if abs(point.y - g.y(row)) <= 2, row > 0 {
                var previous = row - 1
                while previous > 0 && g.rows.isHidden(previous) { previous -= 1 }
                return .rowBorder(previous)
            }
            return .rowHeader(row)
        }
        if !controller.isEditing, !controller.selection.isMultiple, fillHandleRect(g).insetBy(dx: -2, dy: -2).contains(point),
           !controller.selection.primary.isWholeColumns, !controller.selection.primary.isWholeRows {
            return .fillHandle
        }
        if let filter = controller.sheet.filter {
            let row = g.row(atY: point.y)
            if row == filter.range.minRow {
                let column = g.column(atX: point.x)
                if filter.range.columns.contains(column), filterButtonRect(column: column, filter: filter, geometry: g).contains(point) {
                    return .filterButton(column)
                }
            }
        }
        if !controller.isEditing, !controller.selection.isMultiple {
            let rect = clampedRect(controller.selection.primary, g)
            let outer = rect.insetBy(dx: -2, dy: -2), inner = rect.insetBy(dx: 2, dy: 2)
            if outer.contains(point) && !inner.contains(point) && !controller.selection.primary.isWholeColumns && !controller.selection.primary.isWholeRows {
                return .selectionEdge
            }
        }
        return .cell(g.address(at: point))
    }

    // MARK: - Cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateCursor(at: point)
        container?.updateHover(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        container?.updateHover(at: nil)
    }

    func updateCursor(at point: CGPoint) {
        switch region(at: point) {
        case .columnBorder: NSCursor.resizeLeftRight.set()
        case .rowBorder: NSCursor.resizeUpDown.set()
        case .fillHandle: NSCursor.crosshair.set()
        case .selectionEdge: NSCursor.openHand.set()
        case .columnHeader: GridCursors.downArrow.set()
        case .rowHeader: GridCursors.rightArrow.set()
        case .corner, .filterButton, .none: NSCursor.arrow.set()
        case .cell(let address):
            if let controller, controller.sheet.cells[address]?.link != nil, NSEvent.modifierFlags.contains(.command) {
                NSCursor.pointingHand.set()
            } else {
                GridCursors.plus.set()
            }
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard let controller, let container else { return }
        let point = convert(event.locationInWindow, from: nil)
        let region = region(at: point)
        let shift = event.modifierFlags.contains(.shift)
        let command = event.modifierFlags.contains(.command)
        let editor = container.editing

        // Pointing at cells while typing a formula inserts references.
        if controller.isEditing, editor.canInsertReference, case .cell(let address) = region {
            editor.insertReference(CellRange(address), extend: false)
            dragMode = .point(anchor: address)
            return
        }
        if controller.isEditing, case .cell(let address) = region, address == editor.address, event.clickCount >= 1 {
            // Clicking inside the cell being edited is handled by the editor.
            return
        }
        if controller.isEditing {
            guard controller.commitEditingIfNeeded() else { return }
        }
        window?.makeFirstResponder(self)
        controller.validateMarquee()

        switch region {
        case .corner:
            controller.select(range: .all, active: controller.selection.active, scroll: false)
        case .columnHeader(let column):
            if shift, controller.selection.primary.isWholeColumns {
                let anchor = controller.selection.anchor.column
                controller.selectColumns(min(anchor, column)...max(anchor, column))
                var s = controller.selection
                s.anchor = CellAddress(row: 0, column: anchor)
                controller.setSelection(s, scroll: false)
                dragMode = .columns(anchor: anchor)
            } else {
                controller.selectColumns(column...column, add: command)
                dragMode = .columns(anchor: column)
            }
        case .rowHeader(let row):
            if shift, controller.selection.primary.isWholeRows {
                let anchor = controller.selection.anchor.row
                controller.selectRows(min(anchor, row)...max(anchor, row))
                var s = controller.selection
                s.anchor = CellAddress(row: anchor, column: 0)
                controller.setSelection(s, scroll: false)
                dragMode = .rows(anchor: anchor)
            } else {
                controller.selectRows(row...row, add: command)
                dragMode = .rows(anchor: row)
            }
        case .columnBorder(let column):
            if event.clickCount == 2 {
                let columns = controller.selection.selectedColumns.contains(column) ? controller.selection.selectedColumns.sorted() : [column]
                controller.autoFitColumns(columns)
                dragMode = .none
            } else {
                dragMode = .resizeColumn(column: column, startX: point.x, startWidth: geometry.columns.size(column) / zoom)
                resizeGuide = point
            }
        case .rowBorder(let row):
            if event.clickCount == 2 {
                let rows = controller.selection.selectedRows.contains(row) ? controller.selection.selectedRows.sorted() : [row]
                controller.autoFitRows(rows)
                dragMode = .none
            } else {
                dragMode = .resizeRow(row: row, startY: point.y, startHeight: geometry.rows.size(row) / zoom)
                resizeGuide = point
            }
        case .fillHandle, .selectionEdge:
            var isFill = false
            if case .fillHandle = region { isFill = true }
            let address = geometry.address(at: point)
            dragMode = .pending(fill: isFill, start: point, cell: address, source: controller.selection.primary, grab: address)
        case .filterButton(let column):
            container.showFilterPopover(column: column, from: filterButtonRect(column: column, filter: controller.sheet.filter!, geometry: geometry))
            dragMode = .none
        case .cell(let address):
            if command, controller.sheet.cells[address]?.link != nil, !shift {
                controller.openLink(at: address)
                dragMode = .none
                return
            }
            if event.clickCount == 2 {
                controller.select(address, scroll: false)
                container.beginEditing(initial: nil, mode: .edit, clickPoint: point)
                dragMode = .none
                return
            }
            controller.select(address, extend: shift, add: command && !shift, scroll: false)
            dragMode = .selecting
        case .none:
            dragMode = .none
        }
        lastDragPoint = point
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastDragPoint = point
        handleDrag(at: point)
        startAutoScrollIfNeeded(point)
    }

    func handleDrag(at point: CGPoint) {
        guard let controller else { return }
        let g = geometry
        let address = g.address(at: CGPoint(x: max(point.x, g.headerWidth + 1), y: max(point.y, g.headerHeight + 1)))
        if case .pending(let fill, let start, _, let source, let grab) = dragMode {
            guard hypot(point.x - start.x, point.y - start.y) >= Self.dragThreshold else { return }
            dragMode = fill ? .fill(source: source) : .move(source: source, grab: grab)
            if !fill { NSCursor.closedHand.set() }
        }
        switch dragMode {
        case .none, .pending:
            break
        case .selecting:
            controller.select(address, extend: true, scroll: false)
        case .columns(let anchor):
            let column = address.column
            var s = controller.selection
            s.ranges[s.ranges.count - 1] = .wholeColumns(min(anchor, column)...max(anchor, column))
            controller.setSelection(s, scroll: false)
        case .rows(let anchor):
            let row = address.row
            var s = controller.selection
            s.ranges[s.ranges.count - 1] = .wholeRows(min(anchor, row)...max(anchor, row))
            controller.setSelection(s, scroll: false)
        case .resizeColumn, .resizeRow:
            resizeGuide = point
            needsDisplay = true
        case .fill(let source):
            // Extend along whichever axis the pointer moved farther.
            let rect = g.rect(source)
            let dx = point.x > rect.maxX ? point.x - rect.maxX : (point.x < rect.minX ? rect.minX - point.x : 0)
            let dy = point.y > rect.maxY ? point.y - rect.maxY : (point.y < rect.minY ? rect.minY - point.y : 0)
            var target = source
            if dy >= dx {
                if address.row > source.maxRow { target = CellRange(source.start, CellAddress(row: address.row, column: source.maxColumn)) }
                else if address.row < source.minRow { target = CellRange(CellAddress(row: address.row, column: source.minColumn), source.end) }
                else if address.row < source.maxRow && point.y < rect.maxY && point.y > rect.minY { target = CellRange(source.start, CellAddress(row: address.row, column: source.maxColumn)) }
            } else {
                if address.column > source.maxColumn { target = CellRange(source.start, CellAddress(row: source.maxRow, column: address.column)) }
                else if address.column < source.minColumn { target = CellRange(CellAddress(row: source.minRow, column: address.column), source.end) }
            }
            dragPreview = target == source ? nil : target
        case .move(let source, let grab):
            let dr = address.row - grab.row, dc = address.column - grab.column
            let moved = source.offset(rows: dr, columns: dc)
            if moved.start.isValid && moved.end.isValid { dragPreview = moved }
            NSCursor.closedHand.set()
        case .point(let anchor):
            container?.editing.insertReference(CellRange(anchor, address), extend: true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        stopAutoScroll()
        guard let controller else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch dragMode {
        case .resizeColumn(let column, let startX, let startWidth):
            let width = max(0, startWidth + (point.x - startX) / zoom)
            let columns = controller.selection.selectedColumns.contains(column) ? controller.selection.selectedColumns.sorted() : [column]
            controller.setColumnWidth(width, columns: columns)
        case .resizeRow(let row, let startY, let startHeight):
            let height = max(0, startHeight + (point.y - startY) / zoom)
            let rows = controller.selection.selectedRows.contains(row) ? controller.selection.selectedRows.sorted() : [row]
            controller.setRowHeight(height, rows: rows)
        case .fill(let source):
            if let target = dragPreview {
                controller.autoFill(from: source, to: target, copyOnly: event.modifierFlags.contains(.option))
            }
        case .move(let source, _):
            if let target = dragPreview, target != source {
                controller.moveCells(source, to: target.start, copy: event.modifierFlags.contains(.option))
            }
        case .pending(_, _, let cell, _, _):
            // It was a click after all: select the cell under the pointer.
            controller.select(cell, extend: event.modifierFlags.contains(.shift), scroll: false)
        case .selecting:
            if controller.formatPainter != nil { controller.applyFormatPainter() }
        default:
            break
        }
        dragMode = .none
        dragPreview = nil
        resizeGuide = nil
        needsDisplay = true
        updateCursor(at: point)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let controller else { return }
        let point = convert(event.locationInWindow, from: nil)
        if controller.isEditing { guard controller.commitEditingIfNeeded() else { return } }
        window?.makeFirstResponder(self)
        switch region(at: point) {
        case .cell(let address):
            if !controller.selection.contains(address) { controller.select(address, scroll: false) }
            NSMenu.popUpContextMenu(container?.contextMenu(for: .cell) ?? NSMenu(), with: event, for: self)
        case .columnHeader(let column):
            if !controller.selection.selectedColumns.contains(column) { controller.selectColumns(column...column) }
            NSMenu.popUpContextMenu(container?.contextMenu(for: .column) ?? NSMenu(), with: event, for: self)
        case .rowHeader(let row):
            if !controller.selection.selectedRows.contains(row) { controller.selectRows(row...row) }
            NSMenu.popUpContextMenu(container?.contextMenu(for: .row) ?? NSMenu(), with: event, for: self)
        default:
            NSMenu.popUpContextMenu(container?.contextMenu(for: .cell) ?? NSMenu(), with: event, for: self)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control), let controller {
            let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.005 : 0.05)
            controller.setZoom(controller.sheet.zoom * (1 + delta))
            return
        }
        container?.scrollView.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        guard let controller else { return }
        controller.setZoom(controller.sheet.zoom * (1 + event.magnification))
    }

    override func smartMagnify(with event: NSEvent) {
        guard let controller else { return }
        controller.setZoom(abs(controller.sheet.zoom - 1) < 0.01 ? 1.5 : 1)
    }

    // MARK: - Auto-scroll

    private func startAutoScrollIfNeeded(_ point: CGPoint) {
        let body = geometry.cellAreaRect
        let outside = !body.contains(point)
        guard outside else { stopAutoScroll(); return }
        if autoScrollTimer == nil {
            autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
                self?.autoScrollStep()
            }
        }
    }

    private func autoScrollStep() {
        guard let point = lastDragPoint, let container else { return }
        if case .resizeColumn = dragMode { return }
        if case .resizeRow = dragMode { return }
        let g = geometry
        let body = g.bodyRect
        var dx: CGFloat = 0, dy: CGFloat = 0
        if point.x > body.maxX { dx = min(point.x - body.maxX, 120) }
        if point.x < body.minX, g.scroll.x > 0 { dx = -min(body.minX - point.x, 120) }
        if point.y > body.maxY { dy = min(point.y - body.maxY, 120) }
        if point.y < body.minY, g.scroll.y > 0 { dy = -min(body.minY - point.y, 120) }
        guard dx != 0 || dy != 0 else { return }
        container.scroll(by: CGSize(width: dx * 0.5, height: dy * 0.5))
        handleDrag(at: point)
    }

    func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let controller, let container else { return }
        let flags = event.modifierFlags.intersection([.shift, .command, .control, .option])
        let shift = flags.contains(.shift)
        let command = flags.contains(.command)
        controller.validateMarquee()

        switch event.keyCode {
        case 123, 124, 125, 126:
            let (dr, dc): (Int, Int) = [123: (0, -1), 124: (0, 1), 125: (1, 0), 126: (-1, 0)][event.keyCode]!
            if command || flags.contains(.control) {
                controller.jumpSelection(rows: dr, columns: dc, extend: shift)
            } else {
                controller.moveSelection(rows: dr, columns: dc, extend: shift)
            }
            return
        case 36, 76: // Return, Enter
            if flags.contains(.control) || (command && !shift) {
                container.beginEditing(initial: nil, mode: .edit, clickPoint: nil)
            } else {
                controller.moveAfterEnter(reverse: shift)
            }
            return
        case 48: // Tab
            controller.advanceWithinSelection(forward: !shift, vertical: false)
            return
        case 51, 117: // Delete, Forward Delete
            if flags.isEmpty || flags == [.shift] {
                controller.clearContents()
                return
            }
        case 53: // Escape
            if controller.clipboardMarquee != nil { controller.clipboardMarquee = nil; updateMarchingAnts(); return }
            if controller.formatPainter != nil { controller.formatPainter = nil; return }
            if controller.selectedChartID != nil { controller.selectedChartID = nil; return }
        case 115: // Home
            if command { controller.select(CellAddress(row: controller.sheet.frozenRows, column: controller.sheet.frozenColumns)) }
            else { controller.select(CellAddress(row: controller.selection.active.row, column: 0), extend: shift) }
            return
        case 119: // End
            if command { controller.select(controller.sheet.contentExtent, extend: shift) }
            return
        case 116, 121: // Page Up/Down
            let g = geometry
            let rows = max(g.visibleRows.count - 2, 1)
            if flags.contains(.option) {
                let columns = max(g.visibleColumns.count - 2, 1)
                controller.moveSelection(rows: 0, columns: event.keyCode == 116 ? -columns : columns, extend: shift)
            } else {
                controller.moveSelection(rows: event.keyCode == 116 ? -rows : rows, columns: 0, extend: shift)
                container.scroll(by: CGSize(width: 0, height: (event.keyCode == 116 ? -1 : 1) * CGFloat(rows) * g.rows.defaultSize))
            }
            return
        case 120: // F2
            container.beginEditing(initial: nil, mode: .edit, clickPoint: nil)
            return
        case 49 where flags == [.control]: // Ctrl-Space: select column
            let c = controller.selection.primary.columns
            controller.selectColumns(c)
            return
        case 49 where flags == [.shift]: // Shift-Space: select row
            let r = controller.selection.primary.rows
            controller.selectRows(r)
            return
        case 32 where flags == [.control]: // Ctrl-U: edit (Excel for Mac)
            container.beginEditing(initial: nil, mode: .edit, clickPoint: nil)
            return
        default:
            break
        }

        // Typing starts editing and replaces the cell's contents.
        if !command && !flags.contains(.control), let characters = event.characters, !characters.isEmpty,
           characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
            container.beginEditing(initial: "", mode: .enter, clickPoint: nil)
            container.editing.editorView.keyDown(with: event)
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        super.performKeyEquivalent(with: event)
    }
}

/// Spreadsheet cursors.
enum GridCursors {
    static let plus: NSCursor = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let arm: CGFloat = 3, length: CGFloat = 15
            let center = CGPoint(x: 9, y: 9)
            let vertical = CGRect(x: center.x - arm / 2, y: center.y - length / 2, width: arm, height: length)
            let horizontal = CGRect(x: center.x - length / 2, y: center.y - arm / 2, width: length, height: arm)
            let path = NSBezierPath(rect: vertical)
            path.append(NSBezierPath(rect: horizontal))
            NSColor.black.setStroke()
            path.lineWidth = 2
            path.stroke()
            NSColor.white.setFill()
            vertical.fill()
            horizontal.fill()
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: 9, y: 9))
    }()

    static func arrow(rotation: CGFloat) -> NSCursor {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size, flipped: true) { _ in
            let context = NSGraphicsContext.current!.cgContext
            context.translateBy(x: 7, y: 7)
            context.rotate(by: rotation)
            let path = NSBezierPath()
            path.move(to: CGPoint(x: 0, y: 6))
            path.line(to: CGPoint(x: -5, y: 0))
            path.line(to: CGPoint(x: -2, y: 0))
            path.line(to: CGPoint(x: -2, y: -6))
            path.line(to: CGPoint(x: 2, y: -6))
            path.line(to: CGPoint(x: 2, y: 0))
            path.line(to: CGPoint(x: 5, y: 0))
            path.close()
            NSColor.black.setFill()
            path.fill()
            NSColor.white.setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: 7, y: 7))
    }

    static let downArrow = arrow(rotation: 0)
    static let rightArrow = arrow(rotation: -.pi / 2)
}
