import AppKit

struct SortKey: Hashable, Identifiable {
    var id = UUID()
    /// Absolute column index.
    var column: Int
    var ascending = true
}

struct FindOptions: Equatable {
    var text = ""
    var replacement = ""
    var matchCase = false
    var entireCell = false
    var searchFormulas = true
    var wholeWorkbook = false
}

extension WorkbookController {
    // MARK: - AutoFill

    /// Fills `target` (which contains `source`) by extending the source pattern.
    func autoFill(from source: CellRange, to target: CellRange, copyOnly: Bool = false) {
        commitEditingIfNeeded()
        if source.contains(target) && source != target {
            // Dragging the handle back over the selection clears the excess.
            let keep = target
            changeSheet("Clear Contents") { sheet in
                for address in source.addresses where !keep.contains(address) {
                    if var cell = sheet.cells[address] {
                        cell.value = .empty
                        cell.formula = nil
                        sheet[address] = cell
                    }
                }
            }
            select(range: keep)
            return
        }
        guard target != source else { return }
        let vertical = target.rowCount != source.rowCount
        let reverse = vertical ? target.minRow < source.minRow : target.minColumn < source.minColumn
        let count = vertical ? target.rowCount - source.rowCount : target.columnCount - source.columnCount
        let sheetSnapshot = sheet
        changeSheet("AutoFill") { sheet in
            let lines = vertical ? Array(source.columns) : Array(source.rows)
            for line in lines {
                let sourceAddresses: [CellAddress] = vertical
                    ? source.rows.map { CellAddress(row: $0, column: line) }
                    : source.columns.map { CellAddress(row: line, column: $0) }
                let cells = sourceAddresses.map { sheetSnapshot.cells[$0] }
                let styles = sourceAddresses.map { sheetSnapshot.style(at: $0) }
                let generated = AutoFill.extend(cells, styles: styles, count: count, reverse: reverse,
                                                sourceOffsets: Array(0..<cells.count),
                                                step: vertical ? (1, 0) : (0, 1), copyOnly: copyOnly)
                for (k, cell) in generated.enumerated() {
                    let offset = k + 1
                    let address: CellAddress
                    if vertical {
                        address = CellAddress(row: reverse ? source.minRow - offset : source.maxRow + offset, column: line)
                    } else {
                        address = CellAddress(row: line, column: reverse ? source.minColumn - offset : source.maxColumn + offset)
                    }
                    guard address.isValid else { continue }
                    sheet.cells[address] = cell
                }
            }
        }
        select(range: target, active: selection.active)
    }

    /// ⌘D / ⌘R: copies the first row (column) of the selection into the rest.
    func fill(down: Bool) {
        commitEditingIfNeeded()
        var range = boundedToContent(selection.primary)
        if down && range.rowCount == 1 {
            guard range.minRow > 0 else { return }
            range = CellRange(range.start.offset(rows: -1), range.end)
        } else if !down && range.columnCount == 1 {
            guard range.minColumn > 0 else { return }
            range = CellRange(range.start.offset(columns: -1), range.end)
        }
        let snapshot = sheet
        changeSheet(down ? "Fill Down" : "Fill Right") { sheet in
            for address in range.addresses {
                let sourceAddress = down ? CellAddress(row: range.minRow, column: address.column) : CellAddress(row: address.row, column: range.minColumn)
                guard sourceAddress != address else { continue }
                var cell = snapshot.cells[sourceAddress]
                if let formula = cell?.formula {
                    cell?.formula = FormulaRewriter.shift(formula, rows: address.row - sourceAddress.row, columns: address.column - sourceAddress.column)
                }
                sheet.cells[address] = cell
            }
        }
    }

    /// Fills the selection with a linear series (Home ▸ Fill ▸ Series).
    func fillSeries(step: Double, vertical: Bool) {
        let range = selection.primary
        let start = value(at: range.start).number ?? 1
        changeSheet("Fill Series") { sheet in
            var k = 0.0
            for address in range.addresses where vertical ? address.column == range.minColumn : address.row == range.minRow {
                _ = address
            }
            if vertical {
                for column in range.columns {
                    k = 0
                    let base = self.value(at: CellAddress(row: range.minRow, column: column)).number ?? start
                    for row in range.rows {
                        var cell = sheet.cells[CellAddress(row: row, column: column)] ?? Cell()
                        cell.formula = nil
                        cell.value = .number(base + k * step)
                        sheet[CellAddress(row: row, column: column)] = cell
                        k += 1
                    }
                }
            } else {
                for row in range.rows {
                    k = 0
                    let base = self.value(at: CellAddress(row: row, column: range.minColumn)).number ?? start
                    for column in range.columns {
                        var cell = sheet.cells[CellAddress(row: row, column: column)] ?? Cell()
                        cell.formula = nil
                        cell.value = .number(base + k * step)
                        sheet[CellAddress(row: row, column: column)] = cell
                        k += 1
                    }
                }
            }
        }
    }

    // MARK: - Sorting

    /// The range a quick sort or filter acts on: the selection, or the data around the active cell.
    var dataRangeForCommand: CellRange {
        let primary = selection.primary
        if !primary.isSingleCell { return boundedToContent(primary) }
        return sheet.currentRegion(around: selection.active)
    }

    /// Whether the first row of a range looks like a header row.
    func looksLikeHeader(_ range: CellRange) -> Bool {
        guard range.rowCount > 1 else { return false }
        if let table = sheet.tables.first(where: { $0.range == range }) { return table.showHeader }
        if let filter = sheet.filter, filter.range.minRow == range.minRow { return true }
        var headerTextCount = 0, dataNumberCount = 0
        for column in range.columns {
            let top = value(at: CellAddress(row: range.minRow, column: column))
            let next = value(at: CellAddress(row: range.minRow + 1, column: column))
            if top.isText { headerTextCount += 1 }
            if next.number != nil { dataNumberCount += 1 }
            if sheet.style(at: CellAddress(row: range.minRow, column: column)).bold && !sheet.style(at: CellAddress(row: range.minRow + 1, column: column)).bold {
                return true
            }
        }
        return headerTextCount == range.columnCount && (dataNumberCount > 0 || range.columnCount == 1 && false)
    }

    func quickSort(ascending: Bool) {
        commitEditingIfNeeded()
        let range = dataRangeForCommand
        let hasHeader = looksLikeHeader(range)
        sort(range, keys: [SortKey(column: selection.active.column, ascending: ascending)], hasHeader: hasHeader)
    }

    func sort(_ range: CellRange, keys: [SortKey], hasHeader: Bool) {
        let dataRows = hasHeader ? (range.minRow + 1)...max(range.maxRow, range.minRow + 1) : range.rows
        guard hasHeader ? range.rowCount > 1 : true, !keys.isEmpty else { return }
        let dataRange = CellRange(rows: dataRows, columns: range.columns)
        let rows = Array(dataRange.rows)
        let values: [Int: [Int: CellValue]] = Dictionary(uniqueKeysWithValues: rows.map { row in
            (row, Dictionary(uniqueKeysWithValues: keys.map { ($0.column, value(at: CellAddress(row: row, column: $0.column))) }))
        })
        let order = rows.sorted { a, b in
            for key in keys {
                let x = values[a]![key.column]!, y = values[b]![key.column]!
                // Blanks always sort last.
                if x.isEmpty != y.isEmpty { return !x.isEmpty }
                let c = compareValues(x, y)
                if c != 0 { return key.ascending ? c < 0 : c > 0 }
            }
            return a < b
        }
        guard order != rows else { return }
        let snapshot = sheet
        changeSheet("Sort") { sheet in
            for (targetOffset, sourceRow) in order.enumerated() {
                let targetRow = dataRange.minRow + targetOffset
                for column in dataRange.columns {
                    let from = CellAddress(row: sourceRow, column: column), to = CellAddress(row: targetRow, column: column)
                    var cell = snapshot.cells[from]
                    if let formula = cell?.formula { cell?.formula = FormulaRewriter.shift(formula, rows: targetRow - sourceRow, columns: 0) }
                    sheet.cells[to] = cell
                    sheet.notes[to] = snapshot.notes[from]
                }
                if snapshot.rowHeights[sourceRow] != nil || snapshot.rowHeights[targetRow] != nil {
                    sheet.rowHeights[targetRow] = snapshot.rowHeights[sourceRow]
                }
            }
        }
        flash("Sorted \(rows.count) rows")
    }

    // MARK: - Filtering

    func toggleFilter() {
        commitEditingIfNeeded()
        if sheet.filter != nil {
            changeSheet("Remove Filter", geometry: true) { $0.filter = nil }
            return
        }
        let range = dataRangeForCommand
        guard range.rowCount > 1 || !range.isSingleCell else {
            presenter?.presentAlert("Select a range with data to filter.", info: "Filters go on the first row of the range.")
            return
        }
        changeSheet("Filter", geometry: true) { $0.filter = AutoFilter(range: range) }
    }

    func setFilterCriterion(_ criterion: FilterCriterion?, column: Int) {
        guard var filter = sheet.filter else { return }
        filter.criteria[column] = criterion
        filter.hiddenRows = hiddenRows(for: filter)
        let updated = filter
        changeSheet("Filter", geometry: true) { $0.filter = updated }
    }

    func clearFilters() {
        guard var filter = sheet.filter else { return }
        filter.criteria = [:]
        filter.hiddenRows = []
        let updated = filter
        changeSheet("Clear Filter", geometry: true) { $0.filter = updated }
    }

    func reapplyFilter() {
        guard var filter = sheet.filter else { return }
        // Grow to include rows added under the data.
        let region = sheet.currentRegion(around: filter.range.start)
        if region.minRow == filter.range.minRow { filter.range = filter.range.union(region) }
        filter.hiddenRows = hiddenRows(for: filter)
        let updated = filter
        changeSheet("Reapply Filter", geometry: true) { $0.filter = updated }
    }

    func hiddenRows(for filter: AutoFilter) -> Set<Int> {
        guard let rows = filter.dataRows, !filter.criteria.isEmpty else { return [] }
        var hidden = Set<Int>()
        for row in rows {
            for (column, criterion) in filter.criteria {
                let address = CellAddress(row: row, column: column)
                let v = value(at: address)
                if !Self.matches(criterion, value: v, text: displayText(at: address), stats: nil) {
                    hidden.insert(row)
                    break
                }
            }
        }
        return hidden
    }

    static func matches(_ criterion: FilterCriterion, value: CellValue, text: String, stats: ConditionalStats?) -> Bool {
        switch criterion {
        case .values(let allowed):
            return allowed.contains(value.isEmpty ? "" : text)
        case .condition(let rule):
            return ConditionalEvaluator.matches(rule, value: value, stats: stats)
        }
    }

    /// The distinct display texts in a filter column, with counts.
    func filterValues(column: Int) -> [(text: String, count: Int)] {
        guard let filter = sheet.filter, let rows = filter.dataRows else { return [] }
        var counts: [String: Int] = [:]
        var samples: [String: CellValue] = [:]
        for row in rows {
            // Rows hidden by other columns' criteria don't contribute.
            if filter.hiddenRows.contains(row) {
                let hiddenByOthers = filter.criteria.contains { col, criterion in
                    col != column && !Self.matches(criterion, value: value(at: CellAddress(row: row, column: col)), text: displayText(at: CellAddress(row: row, column: col)), stats: nil)
                }
                if hiddenByOthers { continue }
            }
            let address = CellAddress(row: row, column: column)
            let v = value(at: address)
            let text = v.isEmpty ? "" : displayText(at: address)
            counts[text, default: 0] += 1
            samples[text] = v
        }
        return counts.keys.sorted { a, b in
            if a.isEmpty != b.isEmpty { return !a.isEmpty }
            let c = compareValues(samples[a] ?? .empty, samples[b] ?? .empty)
            return c != 0 ? c < 0 : a < b
        }.map { ($0, counts[$0]!) }
    }

    // MARK: - Data tools

    func removeDuplicates(columns: [Int]? = nil, hasHeader: Bool? = nil) {
        commitEditingIfNeeded()
        let range = dataRangeForCommand
        let header = hasHeader ?? looksLikeHeader(range)
        let keys = columns ?? Array(range.columns)
        let dataRows = header ? Array((range.minRow + 1)...max(range.maxRow, range.minRow + 1)).filter { $0 <= range.maxRow } : Array(range.rows)
        var seen = Set<String>()
        var keep: [Int] = []
        for row in dataRows {
            let key = keys.map { value(at: CellAddress(row: row, column: $0)).plainText.lowercased() }.joined(separator: "\u{1F}")
            if seen.insert(key).inserted { keep.append(row) }
        }
        let removed = dataRows.count - keep.count
        guard removed > 0 else {
            presenter?.presentAlert("No duplicate values found.", info: nil)
            return
        }
        let snapshot = sheet
        let firstRow = dataRows.first ?? range.minRow
        changeSheet("Remove Duplicates") { sheet in
            for (offset, sourceRow) in keep.enumerated() {
                for column in range.columns {
                    var cell = snapshot.cells[CellAddress(row: sourceRow, column: column)]
                    if let formula = cell?.formula { cell?.formula = FormulaRewriter.shift(formula, rows: firstRow + offset - sourceRow, columns: 0) }
                    sheet.cells[CellAddress(row: firstRow + offset, column: column)] = cell
                }
            }
            for row in (firstRow + keep.count)..<(firstRow + dataRows.count) {
                for column in range.columns { sheet.cells[CellAddress(row: row, column: column)] = nil }
            }
        }
        presenter?.presentAlert("\(removed) duplicate value\(removed == 1 ? "" : "s") found and removed; \(keep.count) unique value\(keep.count == 1 ? "" : "s") remain.", info: nil)
    }

    /// Splits the selected column into several at a delimiter.
    func textToColumns(delimiter: String) {
        commitEditingIfNeeded()
        let range = boundedToContent(selection.primary)
        let column = range.minColumn
        guard !delimiter.isEmpty else { return }
        changeSheet("Text to Columns") { sheet in
            for row in range.rows {
                let address = CellAddress(row: row, column: column)
                guard let cell = sheet.cells[address], cell.formula == nil, case .string(let text) = cell.value else { continue }
                let parts = text.components(separatedBy: delimiter)
                for (offset, part) in parts.enumerated() {
                    let target = CellAddress(row: row, column: column + offset)
                    let entry = part.trimmingCharacters(in: .whitespaces)
                    let newCell = (try? cellForInput(entry, existing: offset == 0 ? cell : sheet.cells[target], at: target, sheet: sheet)) ?? nil
                    sheet.cells[target] = newCell
                }
            }
        }
    }

    // MARK: - Find and replace

    private func cellMatches(_ address: CellAddress, sheetIndex: Int, options: FindOptions) -> Bool {
        let sheet = workbook.sheets[sheetIndex]
        let text: String
        if options.searchFormulas, let formula = sheet.cells[address]?.formula {
            text = "=" + formula
        } else {
            text = NumberFormat.format(calculator.value(sheet: sheetIndex, at: address), sheet.style(at: address).numberFormat).text
        }
        if options.entireCell {
            return options.matchCase ? text == options.text : text.caseInsensitiveCompare(options.text) == .orderedSame
        }
        return text.range(of: options.text, options: options.matchCase ? [] : [.caseInsensitive]) != nil
    }

    /// Selects the next match after the active cell. Returns false when there are none.
    @discardableResult
    func findNext(_ options: FindOptions, backwards: Bool = false) -> Bool {
        guard !options.text.isEmpty else { return false }
        let sheetOrder = options.wholeWorkbook
            ? Array(activeSheetIndex..<workbook.sheets.count) + Array(0..<activeSheetIndex)
            : [activeSheetIndex]
        let order = backwards ? Array(sheetOrder.reversed()) : sheetOrder
        let start = selection.active
        for (position, sheetIndex) in order.enumerated() {
            let addresses = workbook.sheets[sheetIndex].cells.keys.filter { !workbook.sheets[sheetIndex].isRowHidden($0.row) }.sorted()
            var candidates = backwards ? Array(addresses.reversed()) : addresses
            if position == 0 {
                let after = candidates.filter { backwards ? $0 < start : $0 > start }
                let before = candidates.filter { backwards ? $0 >= start : $0 <= start }
                candidates = after + (order.count == 1 ? before : [])
            }
            if let match = candidates.first(where: { cellMatches($0, sheetIndex: sheetIndex, options: options) }) {
                if sheetIndex != activeSheetIndex { activateSheet(sheetIndex) }
                select(match)
                return true
            }
        }
        if order.count > 1, let match = workbook.sheets[activeSheetIndex].cells.keys.sorted().first(where: { cellMatches($0, sheetIndex: activeSheetIndex, options: options) }) {
            select(match)
            return true
        }
        return false
    }

    func findAll(_ options: FindOptions) -> [(sheet: Int, address: CellAddress)] {
        guard !options.text.isEmpty else { return [] }
        var results: [(Int, CellAddress)] = []
        let sheetIndices = options.wholeWorkbook ? Array(workbook.sheets.indices) : [activeSheetIndex]
        for index in sheetIndices {
            for address in workbook.sheets[index].cells.keys.sorted() where cellMatches(address, sheetIndex: index, options: options) {
                results.append((index, address))
            }
        }
        return results
    }

    private func replaced(_ text: String, options: FindOptions) -> String {
        if options.entireCell { return options.replacement }
        return text.replacingOccurrences(of: options.text, with: options.replacement, options: options.matchCase ? [] : [.caseInsensitive])
    }

    /// Replaces the match in the active cell, then finds the next one.
    func replaceCurrent(_ options: FindOptions) {
        let address = selection.active
        if cellMatches(address, sheetIndex: activeSheetIndex, options: options) {
            let current = inputText(at: address)
            let updated = replaced(current, options: options)
            if updated != current { setInput(updated, at: address) }
        }
        findNext(options)
    }

    @discardableResult
    func replaceAll(_ options: FindOptions) -> Int {
        let matches = findAll(options)
        guard !matches.isEmpty else { return 0 }
        var count = 0
        change("Replace All") { workbook in
            for (sheetIndex, address) in matches {
                let current = inputText(at: address, sheetIndex: sheetIndex)
                let updated = replaced(current, options: options)
                guard updated != current else { continue }
                let sheet = workbook.sheets[sheetIndex]
                if let cell = try? cellForInput(updated, existing: sheet.cells[address], at: address, sheet: sheet) {
                    workbook.sheets[sheetIndex][address] = cell
                    count += 1
                }
            }
        }
        return count
    }

    // MARK: - Go To Special

    enum SpecialTarget { case formulas, constants, blanks, notes, errors, conditionalFormats }

    func selectSpecial(_ target: SpecialTarget) {
        let range = selection.isSingleCell ? (sheet.usedRange ?? CellRange(.origin)) : boundedToContent(selection.primary)
        var matches: [CellAddress] = []
        for address in range.addresses {
            let cell = sheet.cells[address]
            switch target {
            case .formulas: if cell?.formula != nil { matches.append(address) }
            case .constants: if cell?.formula == nil && cell?.hasContent == true { matches.append(address) }
            case .blanks: if cell?.hasContent != true { matches.append(address) }
            case .notes: if sheet.notes[address] != nil { matches.append(address) }
            case .errors: if value(at: address).isError { matches.append(address) }
            case .conditionalFormats: if sheet.conditionalFormats.contains(where: { $0.range.contains(address) }) { matches.append(address) }
            }
            if matches.count > 5000 { break }
        }
        guard let first = matches.first else {
            presenter?.presentAlert("No cells were found.", info: nil)
            return
        }
        var s = Selection(first)
        s.ranges = matches.map { CellRange($0) }
        s.ranges.removeLast()
        s.ranges.append(CellRange(first))
        s.ranges = matches.dropFirst().map { CellRange($0) } + [CellRange(first)]
        setSelection(s)
    }
}
