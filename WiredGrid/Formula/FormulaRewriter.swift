import Foundation

/// A row/column insertion or deletion on one sheet.
enum StructuralChange: Equatable {
    case insertRows(at: Int, count: Int)
    case deleteRows(at: Int, count: Int)
    case insertColumns(at: Int, count: Int)
    case deleteColumns(at: Int, count: Int)

    var affectsRows: Bool {
        switch self {
        case .insertRows, .deleteRows: true
        default: false
        }
    }

    /// Where an index along the changed axis moves to; nil if it was deleted.
    func map(_ index: Int) -> Int? {
        switch self {
        case .insertRows(let at, let count), .insertColumns(let at, let count):
            return index >= at ? index + count : index
        case .deleteRows(let at, let count), .deleteColumns(let at, let count):
            if index < at { return index }
            if index < at + count { return nil }
            return index - count
        }
    }

    private func mapSpan(_ low: Int, _ high: Int) -> (Int, Int)? {
        switch self {
        case .insertRows(let at, let count), .insertColumns(let at, let count):
            return (low >= at ? low + count : low, high >= at ? high + count : high)
        case .deleteRows(let at, let count), .deleteColumns(let at, let count):
            let newLow = low < at ? low : (low < at + count ? at : low - count)
            let newHigh = high < at ? high : (high < at + count ? at - 1 : high - count)
            return newHigh >= newLow ? (newLow, newHigh) : nil
        }
    }

    func map(_ address: CellAddress) -> CellAddress? {
        if affectsRows {
            return map(address.row).map { CellAddress(row: $0, column: address.column) }
        }
        return map(address.column).map { CellAddress(row: address.row, column: $0) }
    }

    /// A range after the change: it grows, shrinks or disappears.
    func map(_ range: CellRange) -> CellRange? {
        if affectsRows {
            if range.isWholeRows == false && range.isWholeColumns { return range }
            guard let (a, b) = mapSpan(range.minRow, range.maxRow), a < SheetLimits.rows else { return nil }
            return CellRange(rows: a...min(b, SheetLimits.rows - 1), columns: range.columns)
        }
        if range.isWholeColumns == false && range.isWholeRows { return range }
        guard let (a, b) = mapSpan(range.minColumn, range.maxColumn), a < SheetLimits.columns else { return nil }
        return CellRange(rows: range.rows, columns: a...min(b, SheetLimits.columns - 1))
    }
}

/// Rewrites the references inside formula text.
enum FormulaRewriter {
    /// Replaces every cell or range token using `transform`, which returns new text (or nil to keep it).
    static func rewrite(_ formula: String, _ transform: (FormulaToken.Kind) -> String?) -> String {
        guard let tokens = try? FormulaLexer.tokenize(formula) else { return formula }
        var result = ""
        for token in tokens {
            switch token.kind {
            case .cell, .range:
                result += transform(token.kind) ?? token.text
            default:
                result += token.text
            }
        }
        return result
    }

    /// Copying a formula: relative references move by the offset.
    static func shift(_ formula: String, rows: Int, columns: Int) -> String {
        if rows == 0 && columns == 0 { return formula }
        return rewrite(formula) { kind in
            switch kind {
            case .cell(var r):
                if !r.rowAbsolute { r.row += rows }
                if !r.columnAbsolute { r.column += columns }
                guard r.address.isValid else { return refError(r.sheet) }
                return r.text()
            case .range(var r):
                switch r.kind {
                case .cells:
                    if !r.start.rowAbsolute { r.start.row += rows }
                    if !r.start.columnAbsolute { r.start.column += columns }
                    if !r.end.rowAbsolute { r.end.row += rows }
                    if !r.end.columnAbsolute { r.end.column += columns }
                    guard r.start.address.isValid, r.end.address.isValid else { return refError(r.sheet) }
                case .columns:
                    if !r.start.columnAbsolute { r.start.column += columns }
                    if !r.end.columnAbsolute { r.end.column += columns }
                    guard r.start.column >= 0, r.end.column >= 0, r.start.column < SheetLimits.columns, r.end.column < SheetLimits.columns else { return refError(r.sheet) }
                case .rows:
                    if !r.start.rowAbsolute { r.start.row += rows }
                    if !r.end.rowAbsolute { r.end.row += rows }
                    guard r.start.row >= 0, r.end.row >= 0, r.start.row < SheetLimits.rows, r.end.row < SheetLimits.rows else { return refError(r.sheet) }
                }
                return r.text()
            default:
                return nil
            }
        }
    }

    private static func refError(_ sheet: String?) -> String {
        (sheet.map { quotedSheetName($0) + "!" } ?? "") + "#REF!"
    }

    private static func applies(_ referencedSheet: String?, formulaSheet: String, targetSheet: String) -> Bool {
        (referencedSheet ?? formulaSheet).caseInsensitiveCompare(targetSheet) == .orderedSame
    }

    /// Inserting or deleting rows/columns on `targetSheet`, for a formula living on `formulaSheet`.
    static func adjust(_ formula: String, formulaSheet: String, targetSheet: String, change: StructuralChange) -> String {
        rewrite(formula) { kind in
            switch kind {
            case .cell(var r):
                guard applies(r.sheet, formulaSheet: formulaSheet, targetSheet: targetSheet) else { return nil }
                guard let moved = change.map(r.address) else { return refError(r.sheet) }
                if moved == r.address { return nil }
                r.row = moved.row
                r.column = moved.column
                return r.text()
            case .range(var r):
                guard applies(r.sheet, formulaSheet: formulaSheet, targetSheet: targetSheet) else { return nil }
                if r.kind == .columns && change.affectsRows { return nil }
                if r.kind == .rows && !change.affectsRows { return nil }
                guard let moved = change.map(r.range) else { return refError(r.sheet) }
                if moved == r.range { return nil }
                r.start.row = r.kind == .columns ? r.start.row : moved.minRow
                r.end.row = r.kind == .columns ? r.end.row : moved.maxRow
                r.start.column = r.kind == .rows ? r.start.column : moved.minColumn
                r.end.column = r.kind == .rows ? r.end.column : moved.maxColumn
                return r.text()
            default:
                return nil
            }
        }
    }

    /// Cut and paste: references into `source` on `sheet` follow the cells to their new place.
    static func move(_ formula: String, formulaSheet: String, sheet: String, source: CellRange, rows: Int, columns: Int) -> String {
        rewrite(formula) { kind in
            switch kind {
            case .cell(var r):
                guard applies(r.sheet, formulaSheet: formulaSheet, targetSheet: sheet), source.contains(r.address) else { return nil }
                r.row += rows
                r.column += columns
                return r.text()
            case .range(var r):
                guard r.kind == .cells, applies(r.sheet, formulaSheet: formulaSheet, targetSheet: sheet), source.contains(r.range) else { return nil }
                r.start.row += rows; r.end.row += rows
                r.start.column += columns; r.end.column += columns
                return r.text()
            default:
                return nil
            }
        }
    }

    /// Renaming a sheet updates every reference to it.
    static func renameSheet(_ formula: String, from old: String, to new: String) -> String {
        rewrite(formula) { kind in
            switch kind {
            case .cell(var r):
                guard let sheet = r.sheet, sheet.caseInsensitiveCompare(old) == .orderedSame else { return nil }
                r.sheet = new
                return r.text()
            case .range(var r):
                guard let sheet = r.sheet, sheet.caseInsensitiveCompare(old) == .orderedSame else { return nil }
                r.sheet = new
                r.start.sheet = new
                r.end.sheet = new
                return r.text()
            default:
                return nil
            }
        }
    }

    /// Deleting a sheet turns references to it into #REF!.
    static func removeSheet(_ formula: String, named name: String) -> String {
        rewrite(formula) { kind in
            switch kind {
            case .cell(let r):
                guard let sheet = r.sheet, sheet.caseInsensitiveCompare(name) == .orderedSame else { return nil }
                return "#REF!"
            case .range(let r):
                guard let sheet = r.sheet, sheet.caseInsensitiveCompare(name) == .orderedSame else { return nil }
                return "#REF!"
            default:
                return nil
            }
        }
    }

    /// Cycles the reference under the caret through $A$1 → A$1 → $A1 → A1 (the F4 key).
    static func toggleAbsolute(_ formula: String, caret: Int) -> (String, NSRange)? {
        guard let tokens = try? FormulaLexer.tokenize(formula) else { return nil }
        for token in tokens where token.range.location <= caret && caret <= NSMaxRange(token.range) {
            func cycle(_ r: inout CellReference) {
                switch (r.columnAbsolute, r.rowAbsolute) {
                case (false, false): r.columnAbsolute = true; r.rowAbsolute = true
                case (true, true): r.columnAbsolute = false; r.rowAbsolute = true
                case (false, true): r.columnAbsolute = true; r.rowAbsolute = false
                case (true, false): r.columnAbsolute = false; r.rowAbsolute = false
                }
            }
            var replacement: String?
            switch token.kind {
            case .cell(var r):
                cycle(&r)
                replacement = r.text()
            case .range(var r):
                cycle(&r.start)
                r.end.columnAbsolute = r.start.columnAbsolute
                r.end.rowAbsolute = r.start.rowAbsolute
                replacement = r.text()
            default:
                continue
            }
            guard let replacement else { continue }
            let ns = formula as NSString
            let updated = ns.replacingCharacters(in: token.range, with: replacement)
            return (updated, NSRange(location: token.range.location, length: (replacement as NSString).length))
        }
        return nil
    }
}
