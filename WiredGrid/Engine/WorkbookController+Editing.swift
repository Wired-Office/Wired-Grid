import AppKit

extension WorkbookController {
    enum InputError: Error {
        case invalidFormula(String)
    }

    /// Normalizes formula text the way Excel does on entry: uppercase function names
    /// and references, and closing any parentheses left open.
    static func normalizeFormula(_ body: String) throws -> String {
        var text = body
        let open = text.filter { $0 == "(" }.count - text.filter { $0 == ")" }.count
        if open > 0 { text += String(repeating: ")", count: open) }
        let tokens: [FormulaToken]
        do {
            tokens = try FormulaLexer.tokenize(text)
            _ = try FormulaParser.parse(text)
        } catch {
            throw InputError.invalidFormula(text)
        }
        var result = ""
        for token in tokens {
            switch token.kind {
            case .function(let name): result += name
            case .cell(let r): result += r.text()
            case .range(let r): result += r.text()
            case .bool(let b): result += b ? "TRUE" : "FALSE"
            default: result += token.text
            }
        }
        return result
    }

    /// Builds the cell a user's typed entry produces, keeping existing formatting.
    func cellForInput(_ text: String, existing: Cell?, at address: CellAddress, sheet: Sheet) throws -> Cell? {
        var cell = existing ?? Cell()
        let style = sheet.style(at: address)
        cell.formula = nil
        if text.isEmpty {
            cell.value = .empty
            return cell.isVacant ? nil : cell
        }
        if text.hasPrefix("="), text.count > 1, style.numberFormat != "@" {
            cell.formula = try Self.normalizeFormula(String(text.dropFirst()))
            cell.value = .empty
            return cell
        }
        if text.hasPrefix("+"), text.count > 1, ValueParser.parse(text).value.number == nil, (try? FormulaParser.parse(String(text.dropFirst()))) != nil {
            // "+A1+A2" is a formula in Excel too.
            cell.formula = try Self.normalizeFormula(String(text.dropFirst()))
            return cell
        }
        if text.hasPrefix("'") {
            cell.value = .string(String(text.dropFirst()))
            return cell
        }
        if style.numberFormat == "@" {
            cell.value = .string(text)
            return cell
        }
        let parsed = ValueParser.parse(text)
        cell.value = parsed.value
        if let format = parsed.format, style.numberFormat == NumberFormat.generalCode || (NumberFormat.isDate(format) != NumberFormat.isDate(style.numberFormat)) {
            var newStyle = style
            newStyle.numberFormat = format
            cell.style = newStyle
        }
        if case .string(let s) = parsed.value, s.contains("\n"), !style.wrap {
            var newStyle = cell.style ?? style
            newStyle.wrap = true
            cell.style = newStyle
        }
        if case .string(let s) = parsed.value, Self.looksLikeURL(s) {
            cell.link = s.contains("://") || s.hasPrefix("mailto:") ? s : "https://" + s
        }
        return cell
    }

    static func looksLikeURL(_ s: String) -> Bool {
        guard !s.contains(" "), s.count > 4 else { return false }
        return s.hasPrefix("http://") || s.hasPrefix("https://") || s.hasPrefix("www.") || s.hasPrefix("mailto:")
    }

    /// Commits typed text into a cell. With `fillSelection` (⌘Return) it fills every selected cell.
    @discardableResult
    func setInput(_ text: String, at address: CellAddress, fillSelection: Bool = false) -> Bool {
        let targets: [CellAddress]
        if fillSelection {
            targets = selectedAddresses
        } else {
            targets = [address]
        }
        do {
            // Validate once before touching the model.
            _ = try cellForInput(text, existing: sheet.cells[address], at: address, sheet: sheet)
        } catch InputError.invalidFormula {
            presenter?.presentAlert("There's a problem with this formula.",
                                    info: "Check that every parenthesis is closed, that function names are spelled correctly, and that text is in quotation marks.")
            return false
        } catch {
            return false
        }
        let name = text.hasPrefix("=") ? "Enter Formula" : "Typing"
        changeSheet(name, geometry: false) { sheet in
            for target in targets {
                var entry = text
                if fillSelection, text.hasPrefix("="), target != address {
                    entry = "=" + FormulaRewriter.shift(String(text.dropFirst()), rows: target.row - address.row, columns: target.column - address.column)
                }
                let newCell = try? cellForInput(entry, existing: sheet.cells[target], at: target, sheet: sheet)
                sheet[target] = newCell ?? nil
                if newCell == nil { sheet.cells[target] = nil }
            }
            autoFitRowForWrap(&sheet, rows: Set(targets.map(\.row)))
        }
        return true
    }

    /// Grows rows with wrapped text to fit, unless their height was set by hand.
    func autoFitRowForWrap(_ sheet: inout Sheet, rows: Set<Int>) {
        for row in rows where sheet.rowHeights[row] == nil || autoSizedRows.contains(row) {
            let needed = fittingHeight(forRow: row, in: sheet)
            if needed > Sheet.defaultRowHeight + 0.5 {
                sheet.rowHeights[row] = needed
                autoSizedRows.insert(row)
            } else if autoSizedRows.contains(row) {
                sheet.rowHeights[row] = nil
            }
        }
    }

    /// The height a row needs for its wrapped or large text.
    func fittingHeight(forRow row: Int, in sheet: Sheet) -> Double {
        var height = Sheet.defaultRowHeight
        for (address, cell) in sheet.cells where address.row == row && cell.hasContent {
            let style = sheet.style(at: address)
            let font = style.font()
            let text = displayTextForMeasuring(cell: cell, address: address, sheet: sheet)
            let lineHeight = Double(font.ascender - font.descender + font.leading) + 6
            if style.wrap {
                var width = sheet.columnWidth(address.column)
                if let merge = sheet.merge(containing: address) {
                    width = merge.columns.reduce(0) { $0 + sheet.columnWidth($1) }
                }
                let bounds = (text as NSString).boundingRect(
                    with: NSSize(width: max(width - 6, 10), height: 100_000),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font]
                )
                height = max(height, Double(ceil(bounds.height)) + 6)
            } else {
                let lines = Double(max(text.components(separatedBy: "\n").count, 1))
                height = max(height, lineHeight * (style.wrap ? lines : 1))
            }
        }
        return min(height, 409)
    }

    private func displayTextForMeasuring(cell: Cell, address: CellAddress, sheet: Sheet) -> String {
        if cell.formula != nil, let index = workbook.sheetIndex(id: sheet.id) {
            return NumberFormat.format(calculator.value(sheet: index, at: address), sheet.style(at: address).numberFormat).text
        }
        return NumberFormat.format(cell.value, sheet.style(at: address).numberFormat).text
    }

    /// Rows whose height Wired Grid chose (for wrapped text) rather than the user.
    var autoSizedRows: Set<Int> {
        get { autoSizedRowsBySheet[sheet.id] ?? [] }
        set { autoSizedRowsBySheet[sheet.id] = newValue }
    }

    /// Clears contents (not formatting) of the selection — the Delete key.
    func clearContents() {
        commitEditingIfNeeded()
        let ranges = selection.ranges
        changeSheet("Clear Contents") { sheet in
            for (address, var cell) in sheet.cells where ranges.contains(where: { $0.contains(address) }) {
                cell.value = .empty
                cell.formula = nil
                cell.link = nil
                sheet[address] = cell
            }
        }
    }

    func clearFormats() {
        commitEditingIfNeeded()
        let ranges = selection.ranges
        changeSheet("Clear Formats", geometry: true) { sheet in
            for (address, var cell) in sheet.cells where ranges.contains(where: { $0.contains(address) }) {
                cell.style = nil
                sheet[address] = cell
            }
            for range in ranges {
                if range.isWholeColumns { for c in range.columns { sheet.columnStyles[c] = nil } }
                if range.isWholeRows { for r in range.rows { sheet.rowStyles[r] = nil } }
            }
            sheet.merges.removeAll { merge in ranges.contains { $0.contains(merge) } }
            sheet.conditionalFormats.removeAll { cf in ranges.contains { $0.contains(cf.range) } }
        }
    }

    func clearAll() {
        commitEditingIfNeeded()
        let ranges = selection.ranges
        changeSheet("Clear All", geometry: true) { sheet in
            for address in sheet.cells.keys where ranges.contains(where: { $0.contains(address) }) {
                sheet.cells[address] = nil
            }
            for address in sheet.notes.keys where ranges.contains(where: { $0.contains(address) }) {
                sheet.notes[address] = nil
            }
            for range in ranges {
                if range.isWholeColumns { for c in range.columns { sheet.columnStyles[c] = nil } }
                if range.isWholeRows { for r in range.rows { sheet.rowStyles[r] = nil } }
            }
            sheet.merges.removeAll { merge in ranges.contains { $0.contains(merge) } }
            sheet.conditionalFormats.removeAll { cf in ranges.contains { $0.contains(cf.range) } }
        }
    }

    func clearNotes() {
        let ranges = selection.ranges
        changeSheet("Clear Notes") { sheet in
            for address in sheet.notes.keys where ranges.contains(where: { $0.contains(address) }) {
                sheet.notes[address] = nil
            }
        }
    }

    func clearHyperlinks() {
        let ranges = selection.ranges
        changeSheet("Clear Hyperlinks") { sheet in
            for (address, var cell) in sheet.cells where ranges.contains(where: { $0.contains(address) }) && cell.link != nil {
                cell.link = nil
                sheet[address] = cell
            }
        }
    }

    // MARK: - AutoComplete

    /// A value from the same column that starts with `prefix` (Excel's AutoComplete).
    func autoCompletion(for prefix: String, at address: CellAddress) -> String? {
        guard AppSettings.shared.autoComplete, !prefix.isEmpty, !prefix.hasPrefix("="),
              prefix.first.map({ !$0.isNumber }) ?? false else { return nil }
        var matches = Set<String>()
        var candidate: String?
        // Look at the contiguous block above and below.
        for step in [-1, 1] {
            var row = address.row + step
            var blanks = 0
            while row >= 0, row < address.row + 2000, row > address.row - 2000, blanks < 1 {
                let value = sheet.cells[CellAddress(row: row, column: address.column)]?.value ?? .empty
                if case .string(let s) = value, sheet.cells[CellAddress(row: row, column: address.column)]?.formula == nil {
                    if s.count > prefix.count, s.lowercased().hasPrefix(prefix.lowercased()) {
                        matches.insert(s.lowercased())
                        candidate = candidate ?? s
                    }
                } else if value.isEmpty {
                    blanks += 1
                }
                row += step
            }
        }
        return matches.count == 1 ? candidate : nil
    }

    // MARK: - Quick entry

    func insertCurrentDate() {
        let today = DateSerial.from(Date()).rounded(.down)
        let address = selection.active
        changeSheet("Insert Date") { sheet in
            var cell = sheet.cells[address] ?? Cell()
            cell.formula = nil
            cell.value = .number(today)
            sheet[address] = cell
            if !NumberFormat.isDate(sheet.style(at: address).numberFormat) {
                sheet.updateStyle(at: address) { $0.numberFormat = NumberFormat.shortDate }
            }
        }
    }

    func insertCurrentTime() {
        let now = DateSerial.from(Date())
        let time = now - now.rounded(.down)
        let address = selection.active
        changeSheet("Insert Time") { sheet in
            var cell = sheet.cells[address] ?? Cell()
            cell.formula = nil
            cell.value = .number(time)
            sheet[address] = cell
            sheet.updateStyle(at: address) { $0.numberFormat = "h:mm AM/PM" }
        }
    }

    /// AutoSum: inserts =SUM() (or another function) over the numbers above or to the left.
    func autoSum(_ function: String = "SUM") {
        commitEditingIfNeeded()
        let range = selection.primary
        if !range.isSingleCell {
            // Totals under each column of a multi-cell selection.
            let bounded = boundedToContent(range)
            let totalRow = bounded.maxRow + 1
            let lastRowEmpty = bounded.columns.allSatisfy { !sheet.hasContent(CellAddress(row: bounded.maxRow, column: $0)) }
            let targetRow = lastRowEmpty && bounded.rowCount > 1 ? bounded.maxRow : totalRow
            let dataEnd = targetRow - 1
            guard dataEnd >= bounded.minRow else { return }
            changeSheet("AutoSum") { sheet in
                for column in bounded.columns {
                    let data = CellRange(CellAddress(row: bounded.minRow, column: column), CellAddress(row: dataEnd, column: column))
                    var cell = sheet.cells[CellAddress(row: targetRow, column: column)] ?? Cell()
                    cell.formula = "\(function)(\(data.a1))"
                    sheet[CellAddress(row: targetRow, column: column)] = cell
                }
            }
            select(range: CellRange(CellAddress(row: targetRow, column: bounded.minColumn), CellAddress(row: targetRow, column: bounded.maxColumn)))
            return
        }
        let address = selection.active
        let guess = autoSumRange(for: address)
        let text = "=\(function)(" + (guess?.a1 ?? "") + ")"
        beginEditingHandler?(text, guess.map { _ in NSRange(location: function.count + 2, length: guess!.a1.count) })
    }

    /// The numbers directly above (preferred) or to the left of a cell.
    func autoSumRange(for address: CellAddress) -> CellRange? {
        func isNumber(_ a: CellAddress) -> Bool { value(at: a).number != nil }
        func scan(rowStep: Int, columnStep: Int) -> CellRange? {
            var current = address.offset(rows: rowStep, columns: columnStep)
            guard current.row >= 0, current.column >= 0 else { return nil }
            // Skip a header-like blank directly adjacent? No: must start with a number.
            guard isNumber(current) else { return nil }
            var last = current
            while current.row >= 0, current.column >= 0, isNumber(current) || (sheet.cells[current]?.formula != nil && value(at: current).number != nil) {
                last = current
                current = current.offset(rows: rowStep, columns: columnStep)
                if current.row < 0 || current.column < 0 { break }
            }
            return CellRange(last, address.offset(rows: rowStep, columns: columnStep))
        }
        return scan(rowStep: -1, columnStep: 0) ?? scan(rowStep: 0, columnStep: -1)
    }

    /// Set by the view layer: begins editing the active cell with text and an optional selection.
    var beginEditingHandler: ((String, NSRange?) -> Void)? {
        get { beginEditingHandlerStorage }
        set { beginEditingHandlerStorage = newValue }
    }
}
