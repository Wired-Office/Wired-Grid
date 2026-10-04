import AppKit
import Combine

/// The heart of an open workbook: the model, calculation, selection and every
/// editing command. Views observe it; menus, the ribbon and the grid call into it.
///
/// All model changes go through `change(_:_:)`, which snapshots the workbook for
/// undo, recalculates and notifies the views.
final class WorkbookController: ObservableObject {
    weak var document: GridDocument?

    var workbook: Workbook
    let calculator: Calculator

    /// Bumped after every change to cells or formatting.
    @Published var revision = 0
    @Published var activeSheetIndex = 0
    /// The selection. Views are told about changes synchronously (with the new value)
    /// through `onSelectionChange`; SwiftUI views observe the coalesced `selectionRevision`.
    private(set) var selection = Selection(.origin) {
        didSet { if selection != oldValue { selectionDidChange() } }
    }
    @Published private(set) var selectionRevision = 0
    private var selectionPublishPending = false
    /// Called right after the selection changes, with the new value in place.
    var onSelectionChange: (() -> Void)?
    /// Formula text being edited, mirrored between the cell editor and the formula bar.
    @Published var isEditing = false
    @Published var showFormulas = false
    /// The source of the last Copy/Cut, shown with marching ants.
    @Published var clipboardMarquee: (sheet: UUID, range: CellRange, isCut: Bool)?
    /// Copied formatting waiting to be painted (Format Painter).
    @Published var formatPainter: FormatPainter?
    @Published var statusMessage: String?
    /// The chart with selection handles, if any.
    @Published var selectedChartID: UUID?

    private var selections: [UUID: Selection] = [:]
    var autoSizedRowsBySheet: [UUID: Set<Int>] = [:]
    /// Identifies this open workbook on the pasteboard (to tell Cut-and-Paste within it apart).
    let documentID = UUID()
    var clipboardChangeCount = 0
    var beginEditingHandlerStorage: ((String, NSRange?) -> Void)?
    /// Set by the view layer: inserts "NAME(" into the formula being edited (or starts one).
    var insertFunctionHandler: ((String) -> Void)?
    /// Called when the grid must redraw or re-layout (geometry changed).
    var onGeometryChange: (() -> Void)?
    var onScrollToSelection: ((Bool) -> Void)?
    /// Asks the view layer to present a sheet (dialog).
    weak var presenter: SheetPresenting?

    init(workbook: Workbook) {
        self.workbook = workbook
        calculator = Calculator(workbook: workbook)
        activeSheetIndex = min(workbook.activeSheetIndex, workbook.sheets.count - 1)
        calculator.recalculate()
    }

    var undoManager: UndoManager? { document?.undoManager }

    // MARK: - Loading

    func load(_ workbook: Workbook) {
        self.workbook = workbook
        activeSheetIndex = min(max(workbook.activeSheetIndex, 0), workbook.sheets.count - 1)
        selections = [:]
        selection = Selection(.origin)
        recalculate()
        onGeometryChange?()
    }

    // MARK: - Sheets

    var sheet: Sheet { workbook.sheets[activeSheetIndex] }
    var sheets: [Sheet] { workbook.sheets }

    func activateSheet(_ index: Int) {
        guard workbook.sheets.indices.contains(index), index != activeSheetIndex else { return }
        commitEditingIfNeeded()
        if workbook.sheets.indices.contains(activeSheetIndex) { selections[sheet.id] = selection }
        activeSheetIndex = index
        workbook.activeSheetIndex = index
        selection = selections[workbook.sheets[index].id] ?? Selection(.origin)
        revision += 1
        onGeometryChange?()
        onScrollToSelection?(false)
    }

    // MARK: - Changes

    /// Applies a change to the model with undo support, then recalculates.
    func change(_ actionName: String, geometry: Bool = false, _ body: (inout Workbook) throws -> Void) rethrows {
        let before = workbook
        let beforeSelection = selection
        let beforeSheet = activeSheetIndex
        var updated = workbook
        try body(&updated)
        updated.activeSheetIndex = activeSheetIndex
        commit(updated, geometry: geometry)
        registerUndo(actionName, restoring: before, selection: beforeSelection, sheet: beforeSheet, geometry: geometry)
    }

    /// Changes only the active sheet.
    func changeSheet(_ actionName: String, geometry: Bool = false, _ body: (inout Sheet) throws -> Void) rethrows {
        let index = activeSheetIndex
        try change(actionName, geometry: geometry) { workbook in
            try body(&workbook.sheets[index])
        }
    }

    private func registerUndo(_ name: String, restoring snapshot: Workbook, selection: Selection, sheet: Int, geometry: Bool) {
        guard let undoManager else { return }
        let redoSnapshot = workbook
        let redoSelection = self.selection
        let redoSheet = activeSheetIndex
        undoManager.registerUndo(withTarget: self) { controller in
            controller.restore(snapshot, selection: selection, sheet: sheet)
            controller.registerUndo(name, restoring: redoSnapshot, selection: redoSelection, sheet: redoSheet, geometry: geometry)
        }
        undoManager.setActionName(name)
    }

    private func restore(_ snapshot: Workbook, selection: Selection, sheet: Int) {
        cancelEditing()
        activeSheetIndex = min(sheet, snapshot.sheets.count - 1)
        var restored = snapshot
        restored.activeSheetIndex = activeSheetIndex
        commit(restored, geometry: true)
        self.selection = selection
        onScrollToSelection?(false)
    }

    private func commit(_ updated: Workbook, geometry: Bool) {
        workbook = updated
        if activeSheetIndex >= workbook.sheets.count { activeSheetIndex = workbook.sheets.count - 1 }
        recalculate()
        if geometry { onGeometryChange?() }
    }

    func recalculate() {
        // Keep stored values for formula cells current, so files carry cached results.
        calculator.setWorkbook(workbook)
        calculator.recalculate()
        revision += 1
    }

    /// Writes computed results into formula cells' cached values (used before saving).
    func workbookForSaving() -> Workbook {
        var copy = workbook
        copy.activeSheetIndex = activeSheetIndex
        for index in copy.sheets.indices {
            for (address, cell) in copy.sheets[index].cells where cell.formula != nil {
                copy.sheets[index].cells[address]?.value = calculator.value(sheet: index, at: address)
            }
        }
        return copy
    }

    // MARK: - Values

    func value(at address: CellAddress) -> CellValue {
        calculator.value(sheet: activeSheetIndex, at: address)
    }

    func value(sheet index: Int, at address: CellAddress) -> CellValue {
        calculator.value(sheet: index, at: address)
    }

    /// The effective style of a cell (explicit, row, or column style).
    func style(at address: CellAddress) -> CellStyle {
        sheet.style(at: address)
    }

    var activeStyle: CellStyle { style(at: selection.active) }

    /// The text shown for a cell, after number formatting.
    func displayText(at address: CellAddress) -> String {
        if showFormulas, let formula = sheet.cells[address]?.formula { return "=" + formula }
        return NumberFormat.format(value(at: address), style(at: address).numberFormat).text
    }

    /// What the formula bar and cell editor show for a cell.
    func inputText(at address: CellAddress, sheetIndex: Int? = nil) -> String {
        let index = sheetIndex ?? activeSheetIndex
        let sheet = workbook.sheets[index]
        guard let cell = sheet.cells[address] else { return "" }
        if let formula = cell.formula { return "=" + formula }
        return Self.editingText(for: cell.value, format: sheet.style(at: address).numberFormat)
    }

    static func editingText(for value: CellValue, format: String) -> String {
        switch value {
        case .empty: return ""
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .error(let e): return e.rawValue
        case .string(let s):
            // Text that would read back as a number keeps its apostrophe.
            if format != "@", s.first != "=", ValueParser.parse(s).value != .string(s) { return "'" + s }
            return s
        case .number(let n):
            if NumberFormat.isDate(format) {
                let hasTime = n != n.rounded(.down)
                if NumberFormat.isTime(format) { return NumberFormat.formatNumber(n, n >= 1 ? "m/d/yyyy h:mm:ss AM/PM" : "h:mm:ss AM/PM").text }
                return NumberFormat.formatNumber(n, hasTime ? "m/d/yyyy h:mm:ss AM/PM" : "m/d/yyyy").text
            }
            if NumberFormat.isPercent(format) {
                return NumberFormat.general(n * 100, maxLength: 17) + "%"
            }
            return NumberFormat.general(n, maxLength: 17)
        }
    }

    // MARK: - Selection

    private func selectionDidChange() {
        onSelectionChange?()
        // SwiftUI (ribbon, status bar) re-renders once per burst of changes, not on every drag step.
        guard !selectionPublishPending else { return }
        selectionPublishPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.selectionPublishPending = false
            self.selectionRevision += 1
        }
    }

    func setSelection(_ newSelection: Selection, scroll: Bool = true) {
        var s = newSelection
        s.active = s.active.clamped()
        selection = s
        selections[sheet.id] = s
        if formatPainter != nil, !isEditing { applyFormatPainter() }
        if scroll { onScrollToSelection?(false) }
    }

    /// Selects one cell (expanded to its merge), optionally extending from the anchor or adding a range.
    func select(_ address: CellAddress, extend: Bool = false, add: Bool = false, scroll: Bool = true) {
        let address = address.clamped()
        if extend {
            var s = selection
            let range = sheet.expandedToMerges(CellRange(s.anchor, address))
            s.ranges[s.ranges.count - 1] = range
            setSelection(s, scroll: scroll)
            return
        }
        let range = sheet.expandedToMerges(CellRange(address))
        if add {
            var s = selection
            s.ranges.append(range)
            s.active = range.start
            s.anchor = address
            setSelection(s, scroll: scroll)
        } else {
            var s = Selection(range: range, active: range.start)
            s.anchor = address
            setSelection(s, scroll: scroll)
        }
    }

    func select(range: CellRange, active: CellAddress? = nil, scroll: Bool = true) {
        var s = Selection(range: range, active: active ?? range.start)
        s.anchor = active ?? range.start
        setSelection(s, scroll: scroll)
    }

    func selectAll() {
        let region = sheet.currentRegion(around: selection.active)
        // Like Excel: first ⌘A selects the data region, the second the whole sheet.
        if selection.primary != region, !region.isSingleCell, sheet.hasContent(selection.active) {
            select(range: region, active: selection.active, scroll: false)
        } else {
            select(range: .all, active: selection.active, scroll: false)
        }
    }

    func selectColumns(_ columns: ClosedRange<Int>, add: Bool = false) {
        let range = CellRange.wholeColumns(columns)
        var s = add ? selection : Selection(range: range, active: CellAddress(row: 0, column: columns.lowerBound))
        if add { s.ranges.append(range); s.active = CellAddress(row: 0, column: columns.lowerBound) }
        s.anchor = CellAddress(row: 0, column: columns.lowerBound)
        setSelection(s, scroll: false)
    }

    func selectRows(_ rows: ClosedRange<Int>, add: Bool = false) {
        let range = CellRange.wholeRows(rows)
        var s = add ? selection : Selection(range: range, active: CellAddress(row: rows.lowerBound, column: 0))
        if add { s.ranges.append(range); s.active = CellAddress(row: rows.lowerBound, column: 0) }
        s.anchor = CellAddress(row: rows.lowerBound, column: 0)
        setSelection(s, scroll: false)
    }

    /// Arrow keys: moves (or extends) by one cell, skipping hidden rows and columns.
    func moveSelection(rows: Int, columns: Int, extend: Bool) {
        if extend {
            // Extend the far corner of the current range.
            var s = selection
            let range = s.primary
            let anchor = s.anchor
            var corner = CellAddress(
                row: anchor.row == range.minRow ? range.maxRow : range.minRow,
                column: anchor.column == range.minColumn ? range.maxColumn : range.minColumn
            )
            corner = nextVisible(from: corner, rows: rows, columns: columns)
            s.ranges[s.ranges.count - 1] = sheet.expandedToMerges(CellRange(anchor, corner))
            setSelection(s)
            return
        }
        var start = selection.active
        // Leaving a merged cell moves from its edge.
        if let merge = sheet.merge(containing: start) {
            if rows > 0 { start.row = merge.maxRow }
            if columns > 0 { start.column = merge.maxColumn }
        }
        select(nextVisible(from: start, rows: rows, columns: columns))
    }

    private func nextVisible(from address: CellAddress, rows: Int, columns: Int) -> CellAddress {
        var next = address.offset(rows: rows, columns: columns).clamped()
        var guardCount = 0
        while (sheet.isRowHidden(next.row) || sheet.hiddenColumns.contains(next.column)) && guardCount < 10_000 {
            let candidate = next.offset(rows: rows.signum(), columns: columns.signum()).clamped()
            if candidate == next { break }
            next = candidate
            guardCount += 1
        }
        return next
    }

    /// ⌘-arrow: jumps to the edge of the data region.
    func jumpSelection(rows: Int, columns: Int, extend: Bool) {
        if extend {
            var s = selection
            let range = s.primary
            let anchor = s.anchor
            let corner = CellAddress(
                row: anchor.row == range.minRow ? range.maxRow : range.minRow,
                column: anchor.column == range.minColumn ? range.maxColumn : range.minColumn
            )
            let target = sheet.dataEdge(from: corner, rowStep: rows, columnStep: columns)
            s.ranges[s.ranges.count - 1] = CellRange(anchor, target)
            setSelection(s)
        } else {
            select(sheet.dataEdge(from: selection.active, rowStep: rows, columnStep: columns))
        }
    }

    /// Return/Tab inside a multi-cell selection cycle through its cells.
    func advanceWithinSelection(forward: Bool, vertical: Bool) {
        let range = selection.primary
        guard !range.isSingleCell, selection.ranges.count == 1, range.cellCount < 5_000_000 else {
            let direction = forward ? 1 : -1
            moveSelection(rows: vertical ? direction : 0, columns: vertical ? 0 : direction, extend: false)
            return
        }
        var active = selection.active
        if vertical {
            active.row += forward ? 1 : -1
            if active.row > range.maxRow { active.row = range.minRow; active.column = active.column + 1 > range.maxColumn ? range.minColumn : active.column + 1 }
            if active.row < range.minRow { active.row = range.maxRow; active.column = active.column - 1 < range.minColumn ? range.maxColumn : active.column - 1 }
        } else {
            active.column += forward ? 1 : -1
            if active.column > range.maxColumn { active.column = range.minColumn; active.row = active.row + 1 > range.maxRow ? range.minRow : active.row + 1 }
            if active.column < range.minColumn { active.column = range.maxColumn; active.row = active.row - 1 < range.minRow ? range.maxRow : active.row - 1 }
        }
        var s = selection
        s.active = active
        setSelection(s)
    }

    /// Moves after Return according to Settings ▸ Enter direction.
    func moveAfterEnter(reverse: Bool) {
        let direction = AppSettings.shared.enterDirection
        if direction == .none { return }
        let vertical = direction == .down || direction == .up
        let forward = (direction == .down || direction == .right) != reverse
        advanceWithinSelection(forward: forward, vertical: vertical)
    }

    /// The name box text: "B4" or "A1:C9" (or the defined name that matches).
    var nameBoxText: String {
        let range = selection.primary
        if let name = workbook.names.first(where: { $0.formula.replacingOccurrences(of: "$", with: "") == quotedSheetName(sheet.name) + "!" + range.a1 }) {
            return name.name
        }
        if range.isSingleCell || sheet.merge(containing: selection.active) == range { return selection.active.a1 }
        return range.a1
    }

    /// Goes to a reference or defined name typed into the name box.
    @discardableResult
    func goTo(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        var target = trimmed
        if let name = workbook.definedName(trimmed) { target = name.formula }
        var sheetIndex = activeSheetIndex
        if let bang = target.lastIndex(of: "!") {
            var sheetName = String(target[..<bang])
            if sheetName.hasPrefix("'") && sheetName.hasSuffix("'") {
                sheetName = String(sheetName.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            }
            guard let index = workbook.sheetIndex(named: sheetName) else { return false }
            sheetIndex = index
            target = String(target[target.index(after: bang)...])
        }
        guard let range = CellRange(a1: target) else { return false }
        if sheetIndex != activeSheetIndex { activateSheet(sheetIndex) }
        select(range: range, active: range.start)
        return true
    }

    // MARK: - Editing state

    /// Set by the view layer; commits an in-progress edit before commands run.
    var commitEditingHandler: (() -> Bool)?
    var cancelEditingHandler: (() -> Void)?

    @discardableResult
    func commitEditingIfNeeded() -> Bool {
        guard isEditing else { return true }
        return commitEditingHandler?() ?? true
    }

    func cancelEditing() {
        guard isEditing else { return }
        cancelEditingHandler?()
    }

    // MARK: - Status bar

    struct SelectionSummary {
        var sum: Double?
        var average: Double?
        var count = 0
        var numericalCount = 0
        var minimum: Double?
        var maximum: Double?
    }

    /// Sum, average and count of the selection, for the status bar.
    func selectionSummary() -> SelectionSummary {
        var summary = SelectionSummary()
        var total = 0.0
        var numbers = 0
        var minValue = Double.infinity, maxValue = -Double.infinity
        var visited = Set<CellAddress>()
        let sheet = self.sheet
        for range in selection.ranges {
            let bounded = boundedToContent(range)
            guard bounded.cellCount <= 2_000_000 else { continue }
            // Only visit cells that exist (or spill) to stay fast on huge selections.
            if bounded.cellCount > sheet.cells.count * 2 {
                for (address, _) in sheet.cells where bounded.contains(address) && !sheet.isRowHidden(address.row) && visited.insert(address).inserted {
                    accumulate(value(at: address))
                }
                for (key, range) in calculator.spillRanges where key.sheet == activeSheetIndex {
                    for address in range.addresses where bounded.contains(address) && sheet.cells[address] == nil && visited.insert(address).inserted {
                        accumulate(value(at: address))
                    }
                }
            } else {
                for address in bounded.addresses where !sheet.isRowHidden(address.row) && visited.insert(address).inserted {
                    accumulate(value(at: address))
                }
            }
        }
        func accumulate(_ value: CellValue) {
            guard !value.isEmpty else { return }
            summary.count += 1
            if case .number(let n) = value {
                numbers += 1
                total += n
                minValue = min(minValue, n)
                maxValue = max(maxValue, n)
            }
        }
        summary.numericalCount = numbers
        if numbers > 0 {
            summary.sum = total
            summary.average = total / Double(numbers)
            summary.minimum = minValue
            summary.maximum = maxValue
        }
        return summary
    }

    /// Clips whole-row/column ranges to the used area.
    func boundedToContent(_ range: CellRange) -> CellRange {
        guard range.isWholeColumns || range.isWholeRows else { return range }
        var extent = sheet.contentExtent
        for (key, spill) in calculator.spillRanges where key.sheet == activeSheetIndex {
            extent = CellAddress(row: max(extent.row, spill.maxRow), column: max(extent.column, spill.maxColumn))
        }
        let maxRow = min(range.maxRow, max(extent.row, range.minRow))
        let maxColumn = min(range.maxColumn, max(extent.column, range.minColumn))
        return CellRange(range.start, CellAddress(row: maxRow, column: maxColumn))
    }

    /// Cells of the selection that exist in the sheet, bounded to content.
    var selectedAddresses: [CellAddress] {
        var result: [CellAddress] = []
        var seen = Set<CellAddress>()
        for range in selection.ranges {
            let bounded = boundedToContent(range)
            if bounded.cellCount > 1_000_000 { continue }
            for address in bounded.addresses where seen.insert(address).inserted { result.append(address) }
        }
        return result
    }

    func flash(_ message: String) {
        statusMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.statusMessage == message { self?.statusMessage = nil }
        }
    }
}

/// Formatting captured by the Format Painter.
struct FormatPainter {
    var styles: [[CellStyle]]
    var sticky: Bool
}

/// Something that can present dialogs for the controller.
protocol SheetPresenting: AnyObject {
    func presentFormatCells(tab: FormatCellsTab)
    func presentAlert(_ message: String, info: String?)
    func presentFindReplace(replace: Bool)
    func presentInsertFunction(category: FunctionCategory?)
    func presentChartEditor(_ chart: ChartObject)
    func presentSort()
    func presentConditionalFormat(_ rule: ConditionalFormat.Rule?)
    func presentManageRules()
    func presentNameManager()
    func presentGoTo()
    func presentNumberPrompt(title: String, message: String, value: Double, completion: @escaping (Double) -> Void)
    func presentTextPrompt(title: String, message: String, value: String, completion: @escaping (String) -> Void)
    func presentNoteEditor(at address: CellAddress)
    func presentTextToColumns()
    func presentPageSetup()
}
