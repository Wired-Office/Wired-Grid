import AppKit



/// Cells on the pasteboard, as Wired Grid's private type.
struct ClipboardPayload: Codable {
    var documentID: UUID
    var sheetID: UUID
    var sheetName: String
    var range: CellRange
    var cells: [[Cell?]]
    var computed: [[CellValue]]
    var columnWidths: [Double]
    var isCut: Bool

    static let type = NSPasteboard.PasteboardType("com.wiredgrid.cells")
}

enum PasteMode: String, CaseIterable {
    case all, formulas, values, formats, transpose, valuesAndNumberFormats, noBorders, columnWidths, link

    var title: String {
        switch self {
        case .all: "Paste"
        case .formulas: "Paste Formulas"
        case .values: "Paste Values"
        case .formats: "Paste Formatting"
        case .transpose: "Paste Transposed"
        case .valuesAndNumberFormats: "Paste Values & Number Formats"
        case .noBorders: "Paste Without Borders"
        case .columnWidths: "Paste Column Widths"
        case .link: "Paste Link"
        }
    }

    var symbol: String {
        switch self {
        case .all: "doc.on.clipboard"
        case .formulas: "function"
        case .values: "123.rectangle"
        case .formats: "paintbrush"
        case .transpose: "arrow.up.left.and.arrow.down.right"
        case .valuesAndNumberFormats: "number"
        case .noBorders: "square.dashed"
        case .columnWidths: "arrow.left.and.right"
        case .link: "link"
        }
    }
}

extension WorkbookController {
    // MARK: - Copy

    func copySelection(cut: Bool = false) {
        commitEditingIfNeeded()
        guard selection.ranges.count == 1 else {
            presenter?.presentAlert("This action won't work on multiple selections.", info: "Select a single range and try again.")
            return
        }
        let range = boundedToContent(selection.primary)
        guard range.cellCount <= 2_000_000 else { return }
        var cells: [[Cell?]] = []
        var computed: [[CellValue]] = []
        var lines: [String] = []
        var html = "<table style=\"border-collapse:collapse\">"
        for row in range.rows {
            var cellRow: [Cell?] = []
            var valueRow: [CellValue] = []
            var textRow: [String] = []
            html += "<tr>"
            for column in range.columns {
                let address = CellAddress(row: row, column: column)
                var cell = sheet.cells[address]
                if cell == nil, sheet.rowStyles[row] != nil || sheet.columnStyles[column] != nil {
                    cell = Cell(style: sheet.style(at: address))
                }
                cellRow.append(cell)
                let v = value(at: address)
                valueRow.append(v)
                let text = displayText(at: address)
                textRow.append(text.contains("\t") || text.contains("\n") ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text)
                html += Self.htmlCell(text, style: sheet.style(at: address))
            }
            cells.append(cellRow)
            computed.append(valueRow)
            lines.append(textRow.joined(separator: "\t"))
            html += "</tr>"
        }
        html += "</table>"
        let payload = ClipboardPayload(
            documentID: documentID, sheetID: sheet.id, sheetName: sheet.name, range: range,
            cells: cells, computed: computed, columnWidths: range.columns.map { sheet.columnWidth($0) }, isCut: cut
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let data = try? JSONEncoder().encode(payload) { pasteboard.setData(data, forType: ClipboardPayload.type) }
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
        pasteboard.setString(lines.joined(separator: "\n"), forType: .tabularText)
        pasteboard.setString(html, forType: .html)
        clipboardMarquee = (sheet.id, range, cut)
        clipboardChangeCount = pasteboard.changeCount
    }

    private static func htmlCell(_ text: String, style: CellStyle) -> String {
        var css = ""
        if style.bold { css += "font-weight:bold;" }
        if style.italic { css += "font-style:italic;" }
        if style.underline { css += "text-decoration:underline;" }
        if let color = style.textColor { css += "color:\(color.hex);" }
        if let fill = style.fillColor { css += "background:\(fill.hex);" }
        if let size = style.fontSize { css += "font-size:\(Int(size))pt;" }
        switch style.horizontal {
        case .center: css += "text-align:center;"
        case .right: css += "text-align:right;"
        default: break
        }
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return "<td style=\"\(css)\">\(escaped)</td>"
    }

    var canPaste: Bool {
        let pasteboard = NSPasteboard.general
        return pasteboard.data(forType: ClipboardPayload.type) != nil || pasteboard.string(forType: .string) != nil
    }

    /// Whether the marching ants still match the pasteboard.
    func validateMarquee() {
        if clipboardMarquee != nil, NSPasteboard.general.changeCount != clipboardChangeCount {
            clipboardMarquee = nil
        }
    }

    // MARK: - Paste

    func paste(_ mode: PasteMode = .all) {
        commitEditingIfNeeded()
        let pasteboard = NSPasteboard.general
        if let data = pasteboard.data(forType: ClipboardPayload.type), let payload = try? JSONDecoder().decode(ClipboardPayload.self, from: data) {
            pastePayload(payload, mode: mode)
        } else if let text = pasteboard.string(forType: .string) {
            pasteText(text)
        }
    }

    private func pastePayload(_ payload: ClipboardPayload, mode: PasteMode) {
        var source = payload
        if mode == .transpose {
            let rows = payload.cells.count, columns = payload.cells.first?.count ?? 0
            var cells = Array(repeating: Array(repeating: Cell?.none, count: rows), count: columns)
            var computed = Array(repeating: Array(repeating: CellValue.empty, count: rows), count: columns)
            for r in 0..<rows {
                for c in 0..<columns {
                    cells[c][r] = payload.cells[r][c]
                    computed[c][r] = payload.computed[r][c]
                }
            }
            source.cells = cells
            source.computed = computed
            source.range = CellRange(payload.range.start, payload.range.start.offset(rows: columns - 1, columns: rows - 1))
        }
        let height = source.cells.count, width = source.cells.first?.count ?? 0
        guard height > 0, width > 0 else { return }

        // Tile the source over a larger selection that's a whole multiple of it.
        let target = selection.primary
        var destination = CellRange(target.start, target.start.offset(rows: height - 1, columns: width - 1))
        if target.rowCount % height == 0 && target.columnCount % width == 0 && !target.isWholeColumns && !target.isWholeRows {
            destination = target
        }
        guard destination.end.isValid else {
            presenter?.presentAlert("The content doesn't fit on the sheet.", info: nil)
            return
        }
        let isCut = payload.isCut && payload.documentID == documentID && mode == .all
        let sameSheet = payload.sheetID == sheet.id
        let targetSheetName = sheet.name
        let index = activeSheetIndex
        let sourceSheetIndex = workbook.sheetIndex(id: payload.sheetID)

        change(mode == .all ? (isCut ? "Move" : "Paste") : mode.title, geometry: mode == .columnWidths || mode == .all) { workbook in
            var sheet = workbook.sheets[index]
            // Cut: clear the source first (it may overlap the destination).
            if isCut, let sourceIndex = sourceSheetIndex {
                for address in payload.range.addresses {
                    if sourceIndex == index { sheet.cells[address] = nil } else { workbook.sheets[sourceIndex].cells[address] = nil }
                }
            }
            for address in destination.addresses {
                let r = (address.row - destination.minRow) % height
                let c = (address.column - destination.minColumn) % width
                let original = source.cells[r][c]
                let computedValue = source.computed[r][c]
                let sourceAddress = mode == .transpose
                    ? CellAddress(row: payload.range.minRow + c, column: payload.range.minColumn + r)
                    : CellAddress(row: payload.range.minRow + r, column: payload.range.minColumn + c)
                var cell = sheet.cells[address] ?? Cell()
                switch mode {
                case .all, .transpose, .noBorders:
                    cell = original ?? Cell()
                    if let formula = original?.formula, !isCut {
                        cell.formula = FormulaRewriter.shift(formula, rows: address.row - sourceAddress.row, columns: address.column - sourceAddress.column)
                    }
                    if mode == .noBorders { cell.style?.borders = CellBorders() }
                case .formulas:
                    cell.value = original?.value ?? .empty
                    cell.formula = original?.formula.map { FormulaRewriter.shift($0, rows: address.row - sourceAddress.row, columns: address.column - sourceAddress.column) }
                case .values:
                    cell.formula = nil
                    cell.value = computedValue
                case .valuesAndNumberFormats:
                    cell.formula = nil
                    cell.value = computedValue
                    var style = cell.style ?? sheet.style(at: address)
                    style.numberFormat = original?.style?.numberFormat ?? NumberFormat.generalCode
                    cell.style = style
                case .formats:
                    cell.style = original?.style
                case .columnWidths:
                    break
                case .link:
                    let prefix = sameSheet ? "" : quotedSheetName(payload.sheetName) + "!"
                    cell.formula = prefix + sourceAddress.a1
                    cell.value = .empty
                }
                sheet[address] = cell
            }
            if mode == .columnWidths || (mode == .all && payload.range.isWholeColumns) {
                for column in destination.columns {
                    let width = payload.columnWidths[(column - destination.minColumn) % max(payload.columnWidths.count, 1)]
                    sheet.columnWidths[column] = width == Sheet.defaultColumnWidth ? nil : width
                }
            }
            // Merges inside the source come along.
            if mode == .all, let sourceIndex = sourceSheetIndex {
                let sourceMerges = workbook.sheets[sourceIndex].merges.filter { payload.range.contains($0) }
                for merge in sourceMerges {
                    let moved = merge.offset(rows: destination.minRow - payload.range.minRow, columns: destination.minColumn - payload.range.minColumn)
                    sheet.merges.removeAll { $0.intersects(moved) }
                    sheet.merges.append(moved)
                }
                if isCut && sourceIndex == index { sheet.merges.removeAll { payload.range.contains($0) && !destination.contains($0) } }
            }
            workbook.sheets[index] = sheet
            if isCut, sourceSheetIndex != nil {
                // Formulas that pointed at the moved cells follow them.
                let dr = destination.minRow - payload.range.minRow, dc = destination.minColumn - payload.range.minColumn
                if sameSheet {
                    Self.rewriteFormulas(in: &workbook) { formula, formulaSheet in
                        FormulaRewriter.move(formula, formulaSheet: formulaSheet, sheet: targetSheetName, source: payload.range, rows: dr, columns: dc)
                    }
                }
            }
        }
        if isCut {
            clipboardMarquee = nil
            NSPasteboard.general.clearContents()
        }
        select(range: destination, active: destination.start)
    }

    /// Pastes plain text, splitting rows on newlines and columns on tabs.
    func pasteText(_ text: String) {
        let rows = Self.parseDelimited(text, separator: "\t")
        guard !rows.isEmpty else { return }
        let start = selection.active
        let width = rows.map(\.count).max() ?? 1
        let destination = CellRange(start, start.offset(rows: rows.count - 1, columns: width - 1))
        guard destination.end.isValid else { return }
        changeSheet("Paste") { sheet in
            for (r, row) in rows.enumerated() {
                for (c, text) in row.enumerated() {
                    let address = start.offset(rows: r, columns: c)
                    let cell = (try? cellForInput(text, existing: sheet.cells[address], at: address, sheet: sheet)) ?? Cell(value: .string(text))
                    sheet[address] = cell
                }
            }
        }
        select(range: destination, active: start)
    }

    /// Splits delimited text (CSV/TSV), honouring quoted fields.
    static func parseDelimited(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var atFieldStart = true
        var iterator = text.makeIterator()
        var pending: Character?
        func next() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }
        while let ch = next() {
            if inQuotes {
                if ch == "\"" {
                    if let following = next() {
                        if following == "\"" { field.append("\"") } else { inQuotes = false; pending = following }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
                continue
            }
            switch ch {
            case "\"" where atFieldStart:
                inQuotes = true
                atFieldStart = false
            case separator:
                row.append(field); field = ""; atFieldStart = true
            case "\r\n", "\n", "\r":
                row.append(field); field = ""; atFieldStart = true
                rows.append(row); row = []
            default:
                field.append(ch)
                atFieldStart = false
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    // MARK: - Moving cells by dragging

    /// Drags the selection to a new place (or copies with Option).
    func moveCells(_ source: CellRange, to destinationStart: CellAddress, copy: Bool) {
        let destination = CellRange(destinationStart, destinationStart.offset(rows: source.rowCount - 1, columns: source.columnCount - 1))
        guard destination.end.isValid, destination != source else { return }
        let dr = destination.minRow - source.minRow, dc = destination.minColumn - source.minColumn
        let overwrites = destination.addresses.contains { !source.contains($0) && sheet.hasContent($0) }
        if overwrites {
            let alert = NSAlert()
            alert.messageText = "There's already data here. Do you want to replace it?"
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let sheetName = sheet.name
        change(copy ? "Copy Cells" : "Move Cells", geometry: true) { workbook in
            let index = activeSheetIndex
            var sheet = workbook.sheets[index]
            var moved: [(CellAddress, Cell?)] = []
            for address in source.addresses {
                var cell = sheet.cells[address]
                if copy, let formula = cell?.formula { cell?.formula = FormulaRewriter.shift(formula, rows: dr, columns: dc) }
                moved.append((address.offset(rows: dr, columns: dc), cell))
            }
            var notes: [(CellAddress, String)] = []
            if !copy {
                for address in source.addresses {
                    sheet.cells[address] = nil
                    if let note = sheet.notes.removeValue(forKey: address) { notes.append((address.offset(rows: dr, columns: dc), note)) }
                }
            }
            for (address, cell) in moved { sheet.cells[address] = cell }
            for (address, note) in notes { sheet.notes[address] = note }
            if !copy {
                sheet.merges = sheet.merges.map { source.contains($0) ? $0.offset(rows: dr, columns: dc) : $0 }
            }
            workbook.sheets[index] = sheet
            if !copy {
                Self.rewriteFormulas(in: &workbook) { formula, formulaSheet in
                    FormulaRewriter.move(formula, formulaSheet: formulaSheet, sheet: sheetName, source: source, rows: dr, columns: dc)
                }
            }
        }
        select(range: destination)
    }
}
