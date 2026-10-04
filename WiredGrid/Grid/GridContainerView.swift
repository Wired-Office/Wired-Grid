import AppKit
import Combine
import SwiftUI

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Hosts the scroll view (for scrolling only), the grid drawn over it, the cell
/// editor and floating charts.
final class GridContainerView: NSView {
    let controller: WorkbookController
    let scrollView = NSScrollView()
    private let documentView = FlippedDocumentView()
    let gridView = GridView()
    let objectLayer = ObjectLayerView()
    private(set) lazy var editing = CellEditingController(container: self)
    private var noteBubble: NSView?
    private var noteAddress: CellAddress?
    private var filterPopover: NSPopover?
    private var cancellables = Set<AnyCancellable>()

    /// How far the scrollable content currently reaches; grows as you scroll.
    private var extentRows = 300
    private var extentColumns = 50
    var onSelectionChange: (() -> Void)?
    var formulaBarRefresh: (() -> Void)?

    override var isFlipped: Bool { true }

    init(controller: WorkbookController) {
        self.controller = controller
        super.init(frame: .zero)
        clipsToBounds = true

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.borderType = .noBorder
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = documentView
        scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(scrollView)

        gridView.controller = controller
        gridView.container = self
        addSubview(gridView)
        objectLayer.controller = controller
        objectLayer.gridView = gridView
        objectLayer.wantsLayer = true
        objectLayer.layer?.masksToBounds = true
        gridView.addSubview(objectLayer)

        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(scrollerStyleChanged), name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: AppSettings.didChange, object: nil)

        controller.onGeometryChange = { [weak self] in self?.geometryChanged() }
        controller.onScrollToSelection = { [weak self] _ in self?.scrollToSelection() }
        controller.beginEditingHandler = { [weak self] text, selection in
            self?.beginEditing(initial: text, mode: .edit, clickPoint: nil, selection: selection)
        }

        controller.$revision.receive(on: RunLoop.main).sink { [weak self] _ in self?.contentChanged() }.store(in: &cancellables)
        controller.onSelectionChange = { [weak self] in self?.selectionChanged() }
        controller.$clipboardMarquee.receive(on: RunLoop.main).sink { [weak self] _ in self?.gridView.updateMarchingAnts() }.store(in: &cancellables)
        controller.$selectedChartID.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.objectLayer.sync() }
        }.store(in: &cancellables)
        controller.$showFormulas.receive(on: RunLoop.main).sink { [weak self] _ in self?.gridView.needsDisplay = true }.store(in: &cancellables)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let content = scrollView.contentView.frame
        gridView.frame = convert(content, from: scrollView)
        updateDocumentSize()
        layoutObjects()
        editing.positionEditor()
    }

    func layoutObjects() {
        let g = gridView.geometry
        objectLayer.frame = g.bodyRect
        objectLayer.layoutCharts()
    }

    private func updateDocumentSize() {
        let g = gridView.geometry
        let size = g.contentSize(rowCount: extentRows, columnCount: extentColumns)
        let clip = scrollView.contentView.bounds.size
        let target = NSSize(width: max(size.width, clip.width + 1), height: max(size.height, clip.height + 1))
        if documentView.frame.size != target { documentView.setFrameSize(target) }
    }

    @objc private func clipBoundsChanged() {
        let origin = scrollView.contentView.bounds.origin
        gridView.scrollOffset = CGPoint(x: max(origin.x, 0), y: max(origin.y, 0))
        // Grow the scrollable area as you approach its end, like Excel.
        let visible = scrollView.contentView.bounds
        var grew = false
        if visible.maxY > documentView.frame.height - visible.height, extentRows < SheetLimits.rows {
            extentRows = min(extentRows + max(200, extentRows / 4), SheetLimits.rows)
            grew = true
        }
        if visible.maxX > documentView.frame.width - visible.width, extentColumns < SheetLimits.columns {
            extentColumns = min(extentColumns + 20, SheetLimits.columns)
            grew = true
        }
        if grew { updateDocumentSize() }
        editing.positionEditor()
        hideNoteBubble()
    }

    @objc private func scrollerStyleChanged() {
        scrollView.scrollerStyle = .legacy
        needsLayout = true
    }

    @objc private func settingsChanged() {
        gridView.needsDisplay = true
    }

    func geometryChanged() {
        let used = controller.sheet.contentExtent
        extentRows = max(300, used.row + 100, controller.selection.active.row + 50)
        extentColumns = max(50, used.column + 20, controller.selection.active.column + 10)
        updateDocumentSize()
        layoutObjects()
        objectLayer.sync()
        gridView.needsDisplay = true
        editing.positionEditor()
    }

    private func contentChanged() {
        gridView.needsDisplay = true
        objectLayer.sync()
        formulaBarRefresh?()
    }

    private func selectionChanged() {
        gridView.needsDisplay = true
        if gridView.dragMode.isActive { gridView.displayIfNeeded() }
        onSelectionChange?()
        formulaBarRefresh?()
        if controller.selectedChartID != nil, !controller.isEditing {
            // Clicking cells deselects charts.
            if window?.firstResponder === gridView { controller.selectedChartID = nil }
        }
    }

    func refreshFormulaBar() {
        formulaBarRefresh?()
    }

    // MARK: - Scrolling

    func scroll(by delta: CGSize) {
        var origin = scrollView.contentView.bounds.origin
        origin.x = max(0, origin.x + delta.width)
        origin.y = max(0, origin.y + delta.height)
        let maxX = documentView.frame.width - scrollView.contentView.bounds.width
        let maxY = documentView.frame.height - scrollView.contentView.bounds.height
        if origin.y > maxY - 10 { extentRows = min(extentRows + 500, SheetLimits.rows); updateDocumentSize() }
        if origin.x > maxX - 10 { extentColumns = min(extentColumns + 20, SheetLimits.columns); updateDocumentSize() }
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func scrollToSelection() {
        scrollToCell(controller.selection.active)
    }

    /// Scrolls just enough to show a cell.
    func scrollToCell(_ address: CellAddress) {
        if address.row + 50 > extentRows { extentRows = min(address.row + 200, SheetLimits.rows); updateDocumentSize() }
        if address.column + 10 > extentColumns { extentColumns = min(address.column + 20, SheetLimits.columns); updateDocumentSize() }
        let g = gridView.geometry
        let body = g.bodyRect
        var origin = scrollView.contentView.bounds.origin
        if address.column >= g.frozenColumns {
            let left = g.columns.offset(address.column) - g.frozenWidth
            let right = g.columns.end(address.column) - g.frozenWidth
            if left < origin.x { origin.x = left } else if right > origin.x + body.width { origin.x = min(right - body.width, left) }
        }
        if address.row >= g.frozenRows {
            let top = g.rows.offset(address.row) - g.frozenHeight
            let bottom = g.rows.end(address.row) - g.frozenHeight
            if top < origin.y { origin.y = top } else if bottom > origin.y + body.height { origin.y = min(bottom - body.height, top) }
        }
        origin.x = max(origin.x, 0)
        origin.y = max(origin.y, 0)
        if origin != scrollView.contentView.bounds.origin {
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    // MARK: - Editing

    func beginEditing(initial: String?, mode: CellEditingController.Mode, clickPoint: CGPoint?, selection: NSRange? = nil) {
        guard !controller.isEditing else { return }
        scrollToSelection()
        editing.begin(initial: initial, mode: mode, clickPoint: clickPoint, selection: selection)
    }

    // MARK: - Notes

    func updateHover(at point: CGPoint?) {
        guard let point, !controller.isEditing else { hideNoteBubble(); return }
        let g = gridView.geometry
        guard g.cellAreaRect.contains(point) else { hideNoteBubble(); return }
        let address = g.address(at: point)
        let anchor = controller.sheet.merge(containing: address)?.start ?? address
        if let note = controller.sheet.notes[anchor] {
            if noteAddress != anchor { showNoteBubble(note, at: anchor) }
        } else {
            hideNoteBubble()
        }
        // Links show a tooltip.
        if let link = controller.sheet.cells[anchor]?.link {
            gridView.toolTip = "\(link)\n⌘-click to follow the link."
        } else if let error = controller.value(at: anchor).errorValue {
            gridView.toolTip = error.explanation
        } else {
            gridView.toolTip = nil
        }
    }

    private func showNoteBubble(_ text: String, at address: CellAddress) {
        hideNoteBubble()
        noteAddress = address
        let g = gridView.geometry
        let cell = g.rect(controller.sheet.merge(containing: address) ?? CellRange(address))
        let bubble = NoteBubbleView(text: text, author: AppSettings.shared.authorName)
        let size = bubble.fittingSize
        var origin = CGPoint(x: cell.maxX + 8, y: cell.minY)
        if origin.x + size.width > gridView.bounds.maxX { origin.x = cell.minX - size.width - 8 }
        bubble.frame = CGRect(origin: origin, size: size)
        gridView.addSubview(bubble)
        noteBubble = bubble
    }

    private func hideNoteBubble() {
        noteBubble?.removeFromSuperview()
        noteBubble = nil
        noteAddress = nil
    }

    // MARK: - Filter popover

    func showFilterPopover(column: Int, from rect: CGRect) {
        filterPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        let view = FilterPopoverView(controller: controller, column: column) { [weak popover] in popover?.close() }
        popover.contentViewController = NSHostingController(rootView: view)
        popover.show(relativeTo: rect, of: gridView, preferredEdge: .maxY)
        filterPopover = popover
    }

    // MARK: - Context menus

    enum MenuKind { case cell, column, row }

    func contextMenu(for kind: MenuKind) -> NSMenu {
        let menu = NSMenu()
        let c = controller
        menu.add("Cut", symbol: "scissors") { c.copySelection(cut: true) }
        menu.add("Copy", symbol: "doc.on.doc") { c.copySelection() }
        menu.add("Paste", symbol: "doc.on.clipboard", enabled: c.canPaste) { c.paste() }
        let special = NSMenu(title: "Paste Special")
        for mode in PasteMode.allCases where mode != .all {
            special.add(mode.title, symbol: mode.symbol, enabled: c.canPaste) { c.paste(mode) }
        }
        menu.addSubmenu(special)
        menu.addItem(.separator())
        switch kind {
        case .column:
            menu.add("Insert Columns", symbol: "rectangle.split.3x1") { c.insertSheetColumns() }
            menu.add("Delete Columns", symbol: "minus.rectangle") { c.deleteSheetColumns() }
            menu.add("Clear Contents", symbol: "eraser") { c.clearContents() }
            menu.addItem(.separator())
            menu.add("Column Width…", symbol: "arrow.left.and.right") { [weak self] in self?.promptColumnWidth() }
            menu.add("AutoFit Column Width", symbol: "arrow.left.and.right.square") { c.autoFitColumns(c.selectedColumnIndices) }
            menu.add("Hide", symbol: "eye.slash") { c.hideColumns() }
            menu.add("Unhide", symbol: "eye") { c.unhideColumns() }
        case .row:
            menu.add("Insert Rows", symbol: "rectangle.split.1x2") { c.insertSheetRows() }
            menu.add("Delete Rows", symbol: "minus.rectangle") { c.deleteSheetRows() }
            menu.add("Clear Contents", symbol: "eraser") { c.clearContents() }
            menu.addItem(.separator())
            menu.add("Row Height…", symbol: "arrow.up.and.down") { [weak self] in self?.promptRowHeight() }
            menu.add("AutoFit Row Height", symbol: "arrow.up.and.down.square") { c.autoFitRows(c.selectedRowIndices) }
            menu.add("Hide", symbol: "eye.slash") { c.hideRows() }
            menu.add("Unhide", symbol: "eye") { c.unhideRows() }
        case .cell:
            let insert = NSMenu(title: "Insert")
            insert.add("Shift Cells Right") { c.insertCells(shiftDown: false) }
            insert.add("Shift Cells Down") { c.insertCells(shiftDown: true) }
            insert.add("Entire Row") { c.insertRows(at: c.selection.primary.minRow, count: c.selection.primary.rowCount) }
            insert.add("Entire Column") { c.insertColumns(at: c.selection.primary.minColumn, count: c.selection.primary.columnCount) }
            menu.addSubmenu(insert)
            let delete = NSMenu(title: "Delete")
            delete.add("Shift Cells Left") { c.deleteCells(shiftUp: false) }
            delete.add("Shift Cells Up") { c.deleteCells(shiftUp: true) }
            delete.add("Entire Row") { c.deleteRows(at: c.selection.primary.minRow, count: c.selection.primary.rowCount) }
            delete.add("Entire Column") { c.deleteColumns(at: c.selection.primary.minColumn, count: c.selection.primary.columnCount) }
            menu.addSubmenu(delete)
            menu.add("Clear Contents", symbol: "eraser") { c.clearContents() }
            menu.addItem(.separator())
            let sort = NSMenu(title: "Sort")
            sort.add("Sort A to Z", symbol: "arrow.up") { c.quickSort(ascending: true) }
            sort.add("Sort Z to A", symbol: "arrow.down") { c.quickSort(ascending: false) }
            sort.add("Custom Sort…", symbol: "arrow.up.arrow.down") { c.presenter?.presentSort() }
            menu.addSubmenu(sort)
            menu.add(c.sheet.filter == nil ? "Filter" : "Remove Filter", symbol: "line.3.horizontal.decrease.circle") { c.toggleFilter() }
            menu.addItem(.separator())
            let address = c.selection.active
            if c.note(at: address) != nil {
                menu.add("Edit Note", symbol: "note.text") { c.presenter?.presentNoteEditor(at: address) }
                menu.add("Delete Note", symbol: "note.text.badge.plus") { c.setNote(nil, at: address) }
            } else {
                menu.add("New Note", symbol: "note.text.badge.plus") { c.presenter?.presentNoteEditor(at: address) }
            }
            if c.sheet.cells[address]?.link != nil {
                menu.add("Open Hyperlink", symbol: "link") { c.openLink(at: address) }
                menu.add("Remove Hyperlink", symbol: "link.badge.plus") { c.clearHyperlinks() }
            }
            menu.add("Format Cells…", symbol: "tablecells") { c.presenter?.presentFormatCells(tab: .number) }
            menu.add("Define Name…", symbol: "tag") { c.presenter?.presentNameManager() }
        }
        return menu
    }

    func promptColumnWidth() {
        let c = controller
        let columns = c.selectedColumnIndices
        let current = columns.first.map { c.sheet.columnWidth($0) } ?? Sheet.defaultColumnWidth
        c.presenter?.presentNumberPrompt(title: "Column Width", message: "Width in points:", value: current) { width in
            c.setColumnWidth(width, columns: columns)
        }
    }

    func promptRowHeight() {
        let c = controller
        let rows = c.selectedRowIndices
        let current = rows.first.map { c.sheet.rowHeight($0) } ?? Sheet.defaultRowHeight
        c.presenter?.presentNumberPrompt(title: "Row Height", message: "Height in points:", value: current) { height in
            c.setRowHeight(height, rows: rows)
        }
    }
}

extension CellValue {
    var errorValue: FormulaError? {
        if case .error(let e) = self { return e }
        return nil
    }
}

/// A yellow note, like Excel's comment box.
final class NoteBubbleView: NSView {
    private let text: String
    private let author: String

    init(text: String, author: String) {
        self.text = text
        self.author = author
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 4
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var attributed: NSAttributedString {
        let s = NSMutableAttributedString()
        if !author.isEmpty {
            s.append(NSAttributedString(string: author + ":\n", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.black]))
        }
        s.append(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black]))
        return s
    }

    override var fittingSize: NSSize {
        let bounds = attributed.boundingRect(with: NSSize(width: 220, height: 400), options: [.usesLineFragmentOrigin])
        return NSSize(width: max(ceil(bounds.width), 80) + 16, height: ceil(bounds.height) + 12)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 1, green: 0.98, blue: 0.78, alpha: 1).setFill()
        bounds.fill()
        NSColor(srgbRed: 0.75, green: 0.7, blue: 0.4, alpha: 1).setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
        attributed.draw(with: bounds.insetBy(dx: 8, dy: 6), options: [.usesLineFragmentOrigin])
    }
}
