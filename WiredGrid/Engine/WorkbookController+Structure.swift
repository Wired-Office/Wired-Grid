import AppKit

extension WorkbookController {
    // MARK: - Rows and columns

    func insertRows(at row: Int, count: Int) {
        applyStructural(.insertRows(at: row, count: count), name: count == 1 ? "Insert Row" : "Insert Rows")
    }

    func deleteRows(at row: Int, count: Int) {
        applyStructural(.deleteRows(at: row, count: count), name: count == 1 ? "Delete Row" : "Delete Rows")
    }

    func insertColumns(at column: Int, count: Int) {
        applyStructural(.insertColumns(at: column, count: count), name: count == 1 ? "Insert Column" : "Insert Columns")
    }

    func deleteColumns(at column: Int, count: Int) {
        applyStructural(.deleteColumns(at: column, count: count), name: count == 1 ? "Delete Column" : "Delete Columns")
    }

    /// Insert rows above / columns left of the selection (Home ▸ Insert).
    func insertSheetRows() {
        commitEditingIfNeeded()
        let range = selection.primary
        insertRows(at: range.minRow, count: range.isWholeColumns ? 1 : range.rowCount)
    }

    func insertSheetColumns() {
        commitEditingIfNeeded()
        let range = selection.primary
        insertColumns(at: range.minColumn, count: range.isWholeRows ? 1 : range.columnCount)
    }

    func deleteSheetRows() {
        commitEditingIfNeeded()
        let range = selection.primary
        guard !range.isWholeColumns else { return }
        deleteRows(at: range.minRow, count: range.rowCount)
        select(CellAddress(row: range.minRow, column: selection.active.column))
    }

    func deleteSheetColumns() {
        commitEditingIfNeeded()
        let range = selection.primary
        guard !range.isWholeRows else { return }
        deleteColumns(at: range.minColumn, count: range.columnCount)
        select(CellAddress(row: selection.active.row, column: range.minColumn))
    }

    /// The Insert/Delete commands pick rows, columns or cells from what's selected.
    func insertForSelection() {
        let range = selection.primary
        if range.isWholeRows { insertSheetRows() } else if range.isWholeColumns { insertSheetColumns() } else { insertCells(shiftDown: true) }
    }

    func deleteForSelection() {
        let range = selection.primary
        if range.isWholeRows { deleteSheetRows() } else if range.isWholeColumns { deleteSheetColumns() } else { deleteCells(shiftUp: true) }
    }

    private func applyStructural(_ structural: StructuralChange, name: String) {
        let target = sheet.name
        let index = activeSheetIndex
        change(name, geometry: true) { workbook in
            Self.rewriteFormulas(in: &workbook) { formula, formulaSheet in
                FormulaRewriter.adjust(formula, formulaSheet: formulaSheet, targetSheet: target, change: structural)
            }
            for i in workbook.names.indices {
                workbook.names[i].formula = FormulaRewriter.adjust(workbook.names[i].formula, formulaSheet: target, targetSheet: target, change: structural)
            }
            Self.remap(&workbook.sheets[index], structural)
        }
        var auto = Set<Int>()
        for row in autoSizedRows {
            if structural.affectsRows { if let moved = structural.map(row) { auto.insert(moved) } } else { auto.insert(row) }
        }
        autoSizedRows = auto
    }

    /// Applies `transform` to every formula in the workbook.
    static func rewriteFormulas(in workbook: inout Workbook, _ transform: (String, String) -> String) {
        for s in workbook.sheets.indices {
            let sheetName = workbook.sheets[s].name
            for (address, cell) in workbook.sheets[s].cells {
                guard let formula = cell.formula else { continue }
                let updated = transform(formula, sheetName)
                if updated != formula { workbook.sheets[s].cells[address]?.formula = updated }
            }
            for i in workbook.sheets[s].conditionalFormats.indices {
                if case .formula(let f) = workbook.sheets[s].conditionalFormats[i].rule {
                    workbook.sheets[s].conditionalFormats[i].rule = .formula(transform(f, sheetName))
                }
            }
        }
    }

    /// Moves everything on a sheet for an insertion or deletion.
    static func remap(_ sheet: inout Sheet, _ change: StructuralChange) {
        var cells: [CellAddress: Cell] = [:]
        cells.reserveCapacity(sheet.cells.count)
        for (address, cell) in sheet.cells {
            if let moved = change.map(address), moved.isValid { cells[moved] = cell }
        }
        sheet.cells = cells

        var notes: [CellAddress: String] = [:]
        for (address, note) in sheet.notes {
            if let moved = change.map(address), moved.isValid { notes[moved] = note }
        }
        sheet.notes = notes

        func remapIndex<T>(_ dictionary: [Int: T]) -> [Int: T] {
            var result: [Int: T] = [:]
            for (index, value) in dictionary { if let moved = change.map(index) { result[moved] = value } }
            return result
        }
        func remapSet(_ set: Set<Int>) -> Set<Int> { Set(set.compactMap { change.map($0) }) }

        if change.affectsRows {
            sheet.rowHeights = remapIndex(sheet.rowHeights)
            sheet.rowStyles = remapIndex(sheet.rowStyles)
            sheet.hiddenRows = remapSet(sheet.hiddenRows)
        } else {
            sheet.columnWidths = remapIndex(sheet.columnWidths)
            sheet.columnStyles = remapIndex(sheet.columnStyles)
            sheet.hiddenColumns = remapSet(sheet.hiddenColumns)
        }
        sheet.merges = sheet.merges.compactMap { change.map($0) }.filter { !$0.isSingleCell }
        sheet.conditionalFormats = sheet.conditionalFormats.compactMap { cf in
            var copy = cf
            guard let range = change.map(cf.range) else { return nil }
            copy.range = range
            return copy
        }
        sheet.charts = sheet.charts.compactMap { chart in
            var copy = chart
            guard let range = change.map(chart.dataRange) else { return nil }
            copy.dataRange = range
            return copy
        }
        sheet.tables = sheet.tables.compactMap { table in
            var copy = table
            guard let range = change.map(table.range) else { return nil }
            copy.range = range
            return copy
        }
        if var filter = sheet.filter {
            if let range = change.map(filter.range) {
                filter.range = range
                if change.affectsRows {
                    filter.hiddenRows = remapSet(filter.hiddenRows)
                } else {
                    var criteria: [Int: FilterCriterion] = [:]
                    for (column, c) in filter.criteria { if let moved = change.map(column) { criteria[moved] = c } }
                    filter.criteria = criteria
                }
                sheet.filter = filter
            } else {
                sheet.filter = nil
            }
        }
    }

    // MARK: - Cells (shift)

    func insertCells(shiftDown: Bool) {
        commitEditingIfNeeded()
        let range = selection.primary
        shiftBlock(range, insert: true, vertical: shiftDown, name: "Insert Cells")
    }

    func deleteCells(shiftUp: Bool) {
        commitEditingIfNeeded()
        let range = selection.primary
        shiftBlock(range, insert: false, vertical: shiftUp, name: "Delete Cells")
    }

    /// Inserts or deletes a block of cells, shifting the rest of the strip.
    private func shiftBlock(_ range: CellRange, insert: Bool, vertical: Bool, name: String) {
        let amount = vertical ? range.rowCount : range.columnCount
        let target = sheet.name
        let index = activeSheetIndex
        // Maps an address in the affected strip; nil = deleted.
        let map: (CellAddress) -> CellAddress? = { a in
            if vertical {
                guard range.columns.contains(a.column), a.row >= range.minRow else { return a }
                if insert { return a.offset(rows: amount) }
                if a.row <= range.maxRow { return nil }
                return a.offset(rows: -amount)
            }
            guard range.rows.contains(a.row), a.column >= range.minColumn else { return a }
            if insert { return a.offset(columns: amount) }
            if a.column <= range.maxColumn { return nil }
            return a.offset(columns: -amount)
        }
        change(name, geometry: true) { workbook in
            Self.rewriteFormulas(in: &workbook) { formula, formulaSheet in
                FormulaRewriter.rewrite(formula) { kind in
                    switch kind {
                    case .cell(var r):
                        guard (r.sheet ?? formulaSheet).caseInsensitiveCompare(target) == .orderedSame else { return nil }
                        guard let moved = map(r.address) else { return "#REF!" }
                        if moved == r.address { return nil }
                        r.row = moved.row; r.column = moved.column
                        return moved.isValid ? r.text() : "#REF!"
                    case .range(var r):
                        guard r.kind == .cells, (r.sheet ?? formulaSheet).caseInsensitiveCompare(target) == .orderedSame else { return nil }
                        // Only ranges inside the strip move with it.
                        let strip = vertical ? CellRange(rows: range.minRow...(SheetLimits.rows - 1), columns: range.columns)
                                             : CellRange(rows: range.rows, columns: range.minColumn...(SheetLimits.columns - 1))
                        guard strip.contains(r.range) else { return nil }
                        guard let a = map(r.start.address) ?? (insert ? nil : r.start.address), let b = map(r.end.address) else { return "#REF!" }
                        r.start.row = a.row; r.start.column = a.column
                        r.end.row = b.row; r.end.column = b.column
                        return r.text()
                    default:
                        return nil
                    }
                }
            }
            var sheet = workbook.sheets[index]
            var cells: [CellAddress: Cell] = [:]
            for (address, cell) in sheet.cells {
                if let moved = map(address), moved.isValid { cells[moved] = cell }
            }
            sheet.cells = cells
            var notes: [CellAddress: String] = [:]
            for (address, note) in sheet.notes {
                if let moved = map(address), moved.isValid { notes[moved] = note }
            }
            sheet.notes = notes
            sheet.merges = sheet.merges.compactMap { m in
                guard let a = map(m.start), let b = map(m.end) else { return nil }
                return CellRange(a, b)
            }
            workbook.sheets[index] = sheet
        }
    }

    // MARK: - Hide and unhide

    func hideColumns() {
        let columns = selectedColumnIndices
        changeSheet("Hide Columns", geometry: true) { sheet in sheet.hiddenColumns.formUnion(columns) }
    }

    func unhideColumns() {
        let range = selection.primary
        let low = max(range.minColumn - 1, 0), high = range.maxColumn + 1
        changeSheet("Unhide Columns", geometry: true) { sheet in
            if range.isWholeRows { sheet.hiddenColumns.removeAll() } else { sheet.hiddenColumns = sheet.hiddenColumns.filter { $0 < low || $0 > high } }
        }
    }

    func hideRows() {
        let rows = selectedRowIndices
        changeSheet("Hide Rows", geometry: true) { sheet in sheet.hiddenRows.formUnion(rows) }
    }

    func unhideRows() {
        let range = selection.primary
        let low = max(range.minRow - 1, 0), high = range.maxRow + 1
        changeSheet("Unhide Rows", geometry: true) { sheet in
            if range.isWholeColumns { sheet.hiddenRows.removeAll() } else { sheet.hiddenRows = sheet.hiddenRows.filter { $0 < low || $0 > high } }
        }
    }

    // MARK: - Freeze panes

    func freezePanes() {
        let active = selection.active
        if sheet.frozenRows > 0 || sheet.frozenColumns > 0 {
            unfreezePanes()
            return
        }
        let rows = active.row, columns = active.column
        guard rows > 0 || columns > 0 else { freezeTopRow(); return }
        changeSheet("Freeze Panes", geometry: true) { sheet in
            sheet.frozenRows = rows
            sheet.frozenColumns = columns
        }
    }

    func freezeTopRow() {
        changeSheet("Freeze Top Row", geometry: true) { sheet in
            sheet.frozenRows = 1
            sheet.frozenColumns = 0
        }
    }

    func freezeFirstColumn() {
        changeSheet("Freeze First Column", geometry: true) { sheet in
            sheet.frozenRows = 0
            sheet.frozenColumns = 1
        }
    }

    func unfreezePanes() {
        changeSheet("Unfreeze Panes", geometry: true) { sheet in
            sheet.frozenRows = 0
            sheet.frozenColumns = 0
        }
    }

    var hasFrozenPanes: Bool { sheet.frozenRows > 0 || sheet.frozenColumns > 0 }

    // MARK: - Sheets

    func addSheet(after index: Int? = nil) {
        commitEditingIfNeeded()
        let position = (index ?? activeSheetIndex) + 1
        let name = workbook.nextSheetName()
        change("Insert Sheet", geometry: true) { workbook in
            workbook.sheets.insert(Sheet(name: name), at: min(position, workbook.sheets.count))
        }
        activateSheet(min(position, workbook.sheets.count - 1))
    }

    func deleteSheet(_ index: Int) {
        guard workbook.sheets.count > 1, workbook.sheets.indices.contains(index) else { return }
        commitEditingIfNeeded()
        let name = workbook.sheets[index].name
        let hasContent = !workbook.sheets[index].cells.isEmpty
        if hasContent {
            let alert = NSAlert()
            alert.messageText = "Delete “\(name)”?"
            alert.informativeText = "The sheet and everything on it will be removed. Formulas that refer to it will show #REF!."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let newActive = min(index, workbook.sheets.count - 2)
        change("Delete Sheet", geometry: true) { workbook in
            workbook.sheets.remove(at: index)
            Self.rewriteFormulas(in: &workbook) { formula, _ in FormulaRewriter.removeSheet(formula, named: name) }
        }
        activeSheetIndex = -1
        activateSheet(max(newActive, 0))
    }

    @discardableResult
    func renameSheet(_ index: Int, to proposed: String) -> Bool {
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard workbook.sheets.indices.contains(index), !name.isEmpty, name.count <= 31,
              !name.contains(where: { "[]:*?/\\".contains($0) }) else {
            presenter?.presentAlert("That sheet name isn't valid.", info: "Names can be up to 31 characters and can't contain : \\ / ? * [ or ].")
            return false
        }
        let old = workbook.sheets[index].name
        guard old != name else { return true }
        if let existing = workbook.sheetIndex(named: name), existing != index {
            presenter?.presentAlert("A sheet named “\(name)” already exists.", info: "Choose a different name.")
            return false
        }
        change("Rename Sheet") { workbook in
            workbook.sheets[index].name = name
            Self.rewriteFormulas(in: &workbook) { formula, _ in FormulaRewriter.renameSheet(formula, from: old, to: name) }
            for i in workbook.names.indices {
                workbook.names[i].formula = FormulaRewriter.renameSheet(workbook.names[i].formula, from: old, to: name)
            }
        }
        return true
    }

    func duplicateSheet(_ index: Int) {
        guard workbook.sheets.indices.contains(index) else { return }
        commitEditingIfNeeded()
        var copy = workbook.sheets[index]
        copy.id = UUID()
        copy.name = workbook.uniqueSheetName(copy.name)
        copy.charts = copy.charts.map { var c = $0; c.id = UUID(); return c }
        let newName = copy.name
        let oldName = workbook.sheets[index].name
        change("Duplicate Sheet", geometry: true) { workbook in
            // References to the original sheet inside the copy point at the copy.
            for (address, cell) in copy.cells {
                if let formula = cell.formula {
                    copy.cells[address]?.formula = FormulaRewriter.renameSheet(formula, from: oldName, to: newName)
                }
            }
            workbook.sheets.insert(copy, at: index + 1)
        }
        activateSheet(index + 1)
    }

    func moveSheet(from source: Int, to destination: Int) {
        guard source != destination, workbook.sheets.indices.contains(source) else { return }
        let activeID = sheet.id
        change("Move Sheet") { workbook in
            let moved = workbook.sheets.remove(at: source)
            workbook.sheets.insert(moved, at: min(max(destination, 0), workbook.sheets.count))
        }
        if let index = workbook.sheetIndex(id: activeID) {
            activeSheetIndex = index
            workbook.activeSheetIndex = index
            revision += 1
        }
    }

    func setTabColor(_ color: RGBColor?, sheet index: Int) {
        change("Tab Color") { workbook in workbook.sheets[index].tabColor = color }
    }

    // MARK: - View options (stored per sheet)

    func setZoom(_ zoom: Double) {
        let clamped = min(max(zoom, 0.1), 4)
        guard abs(clamped - sheet.zoom) > 0.001 else { return }
        // Zoom isn't an undoable edit.
        workbook.sheets[activeSheetIndex].zoom = clamped
        calculator.setWorkbook(workbook)
        document?.updateChangeCount(.changeDone)
        revision += 1
        onGeometryChange?()
    }

    func toggleGridlines() {
        workbook.sheets[activeSheetIndex].showGridlines.toggle()
        calculator.setWorkbook(workbook)
        document?.updateChangeCount(.changeDone)
        revision += 1
    }

    func toggleHeadings() {
        workbook.sheets[activeSheetIndex].showHeadings.toggle()
        calculator.setWorkbook(workbook)
        document?.updateChangeCount(.changeDone)
        revision += 1
        onGeometryChange?()
    }
}
