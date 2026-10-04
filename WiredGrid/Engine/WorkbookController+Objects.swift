import AppKit

extension WorkbookController {
    // MARK: - Notes

    func setNote(_ text: String?, at address: CellAddress) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        changeSheet(trimmed?.isEmpty == false ? "Edit Note" : "Delete Note") { sheet in
            sheet.notes[address] = trimmed?.isEmpty == false ? trimmed : nil
        }
    }

    func note(at address: CellAddress) -> String? { sheet.notes[address] }

    // MARK: - Hyperlinks

    func setLink(_ url: String?, at address: CellAddress, displayText: String?) {
        changeSheet("Hyperlink") { sheet in
            var cell = sheet.cells[address] ?? Cell()
            cell.link = url?.isEmpty == false ? url : nil
            if let displayText, !displayText.isEmpty, cell.formula == nil {
                cell.value = .string(displayText)
            } else if cell.value.isEmpty, let url {
                cell.value = .string(url)
            }
            sheet[address] = cell
        }
    }

    func openLink(at address: CellAddress) {
        guard let link = sheet.cells[address]?.link else { return }
        if link.hasPrefix("#") {
            goTo(String(link.dropFirst()))
        } else if let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Charts

    /// Inserts a chart for the selection (or the data around the active cell).
    func insertChart(_ kind: ChartKind) {
        commitEditingIfNeeded()
        let range = dataRangeForCommand
        guard range.cellCount > 1 || sheet.hasContent(range.start) else {
            presenter?.presentAlert("Select the data you want to chart.", info: "Include column headers to name the series.")
            return
        }
        // Place it beside the data, near the top of the view.
        let x = columnOffset(range.maxColumn + 1) + 20
        let y = rowOffset(range.minRow)
        let chart = ChartObject(kind: kind, dataRange: range, title: defaultChartTitle(for: range),
                                frame: CGRect(x: x, y: y, width: 480, height: 300))
        changeSheet("Insert Chart") { $0.charts.append(chart) }
        selectedChartID = chart.id
    }

    private func defaultChartTitle(for range: CellRange) -> String {
        // A single series uses its header as the title.
        if range.columnCount == 2, looksLikeHeader(range) {
            return value(at: CellAddress(row: range.minRow, column: range.minColumn + 1)).plainText
        }
        return "Chart Title"
    }

    func updateChart(_ chart: ChartObject, actionName: String = "Edit Chart") {
        changeSheet(actionName) { sheet in
            if let index = sheet.charts.firstIndex(where: { $0.id == chart.id }) { sheet.charts[index] = chart }
        }
    }

    func deleteChart(_ id: UUID) {
        changeSheet("Delete Chart") { $0.charts.removeAll { $0.id == id } }
        if selectedChartID == id { selectedChartID = nil }
    }

    func bringChartToFront(_ id: UUID) {
        changeSheet("Bring to Front") { sheet in
            if let index = sheet.charts.firstIndex(where: { $0.id == id }) {
                let chart = sheet.charts.remove(at: index)
                sheet.charts.append(chart)
            }
        }
    }

    func columnOffset(_ column: Int) -> Double {
        var x = Double(column) * Sheet.defaultColumnWidth
        for (c, w) in sheet.columnWidths where c < column { x += w - Sheet.defaultColumnWidth }
        for c in sheet.hiddenColumns where c < column { x -= sheet.columnWidths[c] ?? Sheet.defaultColumnWidth }
        return x
    }

    func rowOffset(_ row: Int) -> Double {
        var y = Double(row) * Sheet.defaultRowHeight
        for (r, h) in sheet.rowHeights where r < row { y += h - Sheet.defaultRowHeight }
        for r in sheet.hiddenRows where r < row { y -= sheet.rowHeights[r] ?? Sheet.defaultRowHeight }
        return y
    }

    // MARK: - Conditional formatting

    func addConditionalFormat(_ rule: ConditionalFormat.Rule, format: HighlightFormat = .lightRed, range: CellRange? = nil) {
        commitEditingIfNeeded()
        let target = range ?? boundedToContent(selection.primary)
        let cf = ConditionalFormat(range: target, rule: rule, format: format)
        changeSheet("Conditional Formatting") { $0.conditionalFormats.insert(cf, at: 0) }
    }

    func updateConditionalFormat(_ format: ConditionalFormat) {
        changeSheet("Edit Rule") { sheet in
            if let index = sheet.conditionalFormats.firstIndex(where: { $0.id == format.id }) { sheet.conditionalFormats[index] = format }
        }
    }

    func deleteConditionalFormat(_ id: UUID) {
        changeSheet("Delete Rule") { $0.conditionalFormats.removeAll { $0.id == id } }
    }

    func clearConditionalFormats(selectionOnly: Bool) {
        let ranges = selection.ranges
        changeSheet("Clear Rules") { sheet in
            if selectionOnly {
                sheet.conditionalFormats.removeAll { cf in ranges.contains { $0.intersects(cf.range) } }
            } else {
                sheet.conditionalFormats.removeAll()
            }
        }
    }

    // MARK: - Tables

    func formatAsTable(_ style: TableStyle) {
        commitEditingIfNeeded()
        let range = dataRangeForCommand
        guard range.rowCount >= 1, !range.isWholeColumns, !range.isWholeRows else { return }
        if sheet.tables.contains(where: { $0.range.intersects(range) }) {
            // Restyle the existing table.
            changeSheet("Table Style") { sheet in
                for i in sheet.tables.indices where sheet.tables[i].range.intersects(range) { sheet.tables[i].style = style }
            }
            return
        }
        var number = sheet.tables.count + 1
        let allTables = workbook.sheets.flatMap(\.tables)
        while allTables.contains(where: { $0.name == "Table\(number)" }) { number += 1 }
        let table = TableObject(name: "Table\(number)", range: range, style: style)
        let hasHeader = looksLikeHeader(range) || range.rowCount > 1
        changeSheet("Format as Table", geometry: true) { sheet in
            var t = table
            t.showHeader = hasHeader
            sheet.tables.append(t)
            if hasHeader && sheet.filter == nil { sheet.filter = AutoFilter(range: range) }
        }
    }

    func removeTable(containing address: CellAddress) {
        changeSheet("Convert to Range", geometry: true) { sheet in
            if let table = sheet.tables.first(where: { $0.range.contains(address) }) {
                sheet.tables.removeAll { $0.id == table.id }
                if sheet.filter?.range == table.range { sheet.filter = nil }
            }
        }
    }

    func updateTable(_ table: TableObject) {
        changeSheet("Table Options", geometry: true) { sheet in
            if let index = sheet.tables.firstIndex(where: { $0.id == table.id }) {
                let old = sheet.tables[index]
                sheet.tables[index] = table
                // A totals row adds SUBTOTAL formulas under numeric columns.
                if table.showTotals != old.showTotals {
                    let totalRow = table.showTotals ? old.range.maxRow + 1 : old.range.maxRow
                    if table.showTotals {
                        sheet.tables[index].range = CellRange(old.range.start, CellAddress(row: totalRow, column: old.range.maxColumn))
                        let firstData = min(old.range.minRow + (table.showHeader ? 1 : 0), old.range.maxRow)
                        let dataRows = firstData...old.range.maxRow
                        for column in old.range.columns {
                            let address = CellAddress(row: totalRow, column: column)
                            let isNumeric = dataRows.contains { self.value(at: CellAddress(row: $0, column: column)).number != nil }
                            var cell = sheet.cells[address] ?? Cell()
                            if column == old.range.minColumn && !isNumeric {
                                cell.value = .string("Total")
                            } else if isNumeric {
                                cell.formula = "SUBTOTAL(109," + CellRange(rows: dataRows, columns: column...column).a1 + ")"
                            }
                            sheet[address] = cell
                        }
                    } else {
                        for column in old.range.columns { sheet.cells[CellAddress(row: totalRow, column: column)] = nil }
                        sheet.tables[index].range = CellRange(old.range.start, CellAddress(row: totalRow - 1, column: old.range.maxColumn))
                    }
                }
            }
        }
    }

    // MARK: - Defined names

    static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_" || first == "\\" else { return false }
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }) else { return false }
        if CellRange(a1: name) != nil { return false }
        if ["TRUE", "FALSE", "R", "C"].contains(name.uppercased()) { return false }
        return true
    }

    @discardableResult
    func defineName(_ name: String, formula: String, comment: String = "", replacing old: String? = nil) -> Bool {
        guard Self.isValidName(name) else {
            presenter?.presentAlert("The name “\(name)” isn't valid.", info: "Names must start with a letter or underscore, contain no spaces, and not look like a cell reference.")
            return false
        }
        if let existing = workbook.definedName(name), existing.name.caseInsensitiveCompare(old ?? "") != .orderedSame {
            presenter?.presentAlert("The name “\(existing.name)” already exists.", info: "Choose a unique name.")
            return false
        }
        var body = formula.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("=") { body.removeFirst() }
        guard (try? FormulaParser.parse(body)) != nil else {
            presenter?.presentAlert("The reference isn't valid.", info: nil)
            return false
        }
        change("Define Name") { workbook in
            if let old { workbook.names.removeAll { $0.name.caseInsensitiveCompare(old) == .orderedSame } }
            workbook.names.append(DefinedName(name: name, formula: body, comment: comment))
            workbook.names.sort { $0.name.lowercased() < $1.name.lowercased() }
        }
        return true
    }

    func deleteName(_ name: String) {
        change("Delete Name") { workbook in
            workbook.names.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
    }

    /// A name for the selection, as the name box creates when you type a new name.
    func nameSelection(_ name: String) -> Bool {
        let reference = quotedSheetName(sheet.name) + "!" + absoluteReference(selection.primary)
        return defineName(name, formula: reference)
    }

    func absoluteReference(_ range: CellRange) -> String {
        func abs(_ a: CellAddress) -> String { "$" + CellAddress.columnName(a.column) + "$" + String(a.row + 1) }
        if range.isWholeColumns { return "$" + CellAddress.columnName(range.minColumn) + ":$" + CellAddress.columnName(range.maxColumn) }
        if range.isWholeRows { return "$\(range.minRow + 1):$\(range.maxRow + 1)" }
        return range.isSingleCell ? abs(range.start) : abs(range.start) + ":" + abs(range.end)
    }

    // MARK: - Page setup

    func updatePageSetup(_ setup: PageSetup) {
        changeSheet("Page Setup") { $0.pageSetup = setup }
    }

    func setPrintArea() {
        let range = boundedToContent(selection.primary)
        changeSheet("Set Print Area") { $0.pageSetup.printArea = range }
    }

    func clearPrintArea() {
        changeSheet("Clear Print Area") { $0.pageSetup.printArea = nil }
    }
}
