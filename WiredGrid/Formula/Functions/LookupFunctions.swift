import Foundation

private enum MatchMode { case exact, wildcard, exactOrSmaller, exactOrLarger }
private enum SearchMode { case forward, backward, binaryAscending, binaryDescending }

private func equalForLookup(_ a: CellValue, _ b: CellValue) -> Bool {
    switch (a, b) {
    case (.number(let x), .number(let y)): return x == y
    case (.string(let x), .string(let y)): return x.caseInsensitiveCompare(y) == .orderedSame
    case (.bool(let x), .bool(let y)): return x == y
    case (.empty, .empty): return true
    case (.string(let x), .empty), (.empty, .string(let x)): return x.isEmpty
    default: return false
    }
}

private func sameKind(_ a: CellValue, _ b: CellValue) -> Bool {
    switch (a, b) {
    case (.number, .number), (.string, .string), (.bool, .bool): return true
    default: return false
    }
}

/// Finds `lookup` in `values`, returning the zero-based index.
private func findIndex(_ lookup: CellValue, in values: [CellValue], match: MatchMode, search: SearchMode) -> Int? {
    switch search {
    case .binaryAscending, .binaryDescending:
        // Sorted data: scan in order and stop once past the lookup value, as a binary search would.
        if match == .exact || match == .wildcard {
            return findIndex(lookup, in: values, match: match, search: .forward)
        }
        let descending = search == .binaryDescending
        var best: Int?
        for (i, v) in values.enumerated() where sameKind(v, lookup) {
            let c = compareValues(v, lookup)
            switch (descending, match) {
            case (false, .exactOrSmaller):
                if c <= 0 { best = i } else { return best }
            case (false, _):
                if c >= 0 { return i }
            case (true, .exactOrLarger):
                if c >= 0 { best = i } else { return best }
            case (true, _):
                if c <= 0 { return i }
            }
        }
        return best
    case .forward, .backward:
        let indices: [Int] = search == .forward ? Array(values.indices) : values.indices.reversed()
        let pattern: NSRegularExpression? = {
            guard match == .wildcard, case .string(let s) = lookup else { return nil }
            return Criterion.wildcard(s)
        }()
        var best: Int?
        for i in indices {
            let v = values[i]
            if let pattern {
                let text = v.plainText
                if v.isText, pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { return i }
                continue
            }
            if equalForLookup(v, lookup) { return i }
            guard sameKind(v, lookup) else { continue }
            let c = compareValues(v, lookup)
            if match == .exactOrSmaller, c < 0 {
                if best == nil || compareValues(v, values[best!]) > 0 { best = i }
            } else if match == .exactOrLarger, c > 0 {
                if best == nil || compareValues(v, values[best!]) < 0 { best = i }
            }
        }
        return best
    }
}

private func wantsWildcard(_ lookup: CellValue) -> Bool {
    if case .string(let s) = lookup { return s.contains("*") || s.contains("?") }
    return false
}

extension FunctionLibrary {
    func registerLookup() {
        let v = FunctionLibrary.variadic

        register("VLOOKUP", .lookup, "VLOOKUP(lookup_value, table_array, col_index_num, [range_lookup])", "Looks for a value in the first column of a table and returns a value in the same row from another column.", args: 3...4) { c in
            let lookup = try c.strictScalar(0)
            let table = try c.matrix(1)
            let column = try c.int(2)
            let approximate = try c.bool(3, default: true)
            guard column >= 1 else { throw FormulaError.value }
            guard column <= table.columns else { throw FormulaError.ref }
            let keys = table.column(0)
            let index = approximate
                ? findIndex(lookup, in: keys, match: .exactOrSmaller, search: .binaryAscending)
                : findIndex(lookup, in: keys, match: wantsWildcard(lookup) ? .wildcard : .exact, search: .forward)
            guard let index else { throw FormulaError.na }
            return .scalar(table[index, column - 1])
        }
        register("HLOOKUP", .lookup, "HLOOKUP(lookup_value, table_array, row_index_num, [range_lookup])", "Looks for a value in the top row of a table and returns a value in the same column from another row.", args: 3...4) { c in
            let lookup = try c.strictScalar(0)
            let table = try c.matrix(1)
            let row = try c.int(2)
            let approximate = try c.bool(3, default: true)
            guard row >= 1 else { throw FormulaError.value }
            guard row <= table.rows else { throw FormulaError.ref }
            let keys = table.row(0)
            let index = approximate
                ? findIndex(lookup, in: keys, match: .exactOrSmaller, search: .binaryAscending)
                : findIndex(lookup, in: keys, match: wantsWildcard(lookup) ? .wildcard : .exact, search: .forward)
            guard let index else { throw FormulaError.na }
            return .scalar(table[row - 1, index])
        }
        register("XLOOKUP", .lookup, "XLOOKUP(lookup_value, lookup_array, return_array, [if_not_found], [match_mode], [search_mode])", "Searches a range for a match and returns the corresponding item from another range.", args: 3...6) { c in
            let lookupArray = try c.matrix(1)
            guard lookupArray.isVector else { throw FormulaError.value }
            let returnArray = try c.value(2)
            let returnMatrix = c.evaluator.matrix(returnArray)
            let matchMode = try c.int(4, default: 0)
            let searchMode = try c.int(5, default: 1)
            let match: MatchMode
            switch matchMode {
            case 0: match = .exact
            case -1: match = .exactOrSmaller
            case 1: match = .exactOrLarger
            case 2: match = .wildcard
            default: throw FormulaError.value
            }
            let search: SearchMode
            switch searchMode {
            case 1: search = .forward
            case -1: search = .backward
            case 2: search = .binaryAscending
            case -2: search = .binaryDescending
            default: throw FormulaError.value
            }
            let vertical = lookupArray.columns == 1
            let keys = lookupArray.values
            let lookupValue = try c.value(0)
            func resolve(_ lookup: CellValue) throws -> FValue {
                guard let index = findIndex(lookup, in: keys, match: match, search: search) else {
                    if c.count > 3 && !c.isMissing(3) { return try c.value(3) }
                    throw FormulaError.na
                }
                if vertical {
                    guard index < returnMatrix.rows else { throw FormulaError.value }
                    if case .reference(let sheet, let range) = returnArray {
                        return .reference(sheet: sheet, range: CellRange(rows: (range.minRow + index)...(range.minRow + index), columns: range.columns))
                    }
                    return returnMatrix.columns == 1 ? .scalar(returnMatrix[index, 0]) : .matrix(Matrix(row: returnMatrix.row(index)))
                }
                guard index < returnMatrix.columns else { throw FormulaError.value }
                if case .reference(let sheet, let range) = returnArray {
                    return .reference(sheet: sheet, range: CellRange(rows: range.rows, columns: (range.minColumn + index)...(range.minColumn + index)))
                }
                return returnMatrix.rows == 1 ? .scalar(returnMatrix[0, index]) : .matrix(Matrix(column: returnMatrix.column(index)))
            }
            if c.evaluator.isSingle(lookupValue) {
                let lookup = c.evaluator.scalar(lookupValue)
                if case .error(let e) = lookup { throw e }
                return try resolve(lookup)
            }
            // Several lookup values: one result each.
            var lookups = c.evaluator.matrix(lookupValue)
            for i in lookups.values.indices {
                do { lookups.values[i] = c.evaluator.scalar(try resolve(lookups.values[i])) } catch let e as FormulaError { lookups.values[i] = .error(e) }
            }
            return .matrix(lookups)
        }
        register("MATCH", .lookup, "MATCH(lookup_value, lookup_array, [match_type])", "Returns the relative position of an item in an array.", args: 2...3) { c in
            let lookup = try c.strictScalar(0)
            let array = try c.matrix(1)
            guard array.isVector else { throw FormulaError.na }
            let type = try c.int(2, default: 1)
            let index: Int?
            switch type {
            case 0: index = findIndex(lookup, in: array.values, match: wantsWildcard(lookup) ? .wildcard : .exact, search: .forward)
            case 1...: index = findIndex(lookup, in: array.values, match: .exactOrSmaller, search: .binaryAscending)
            default: index = findIndex(lookup, in: array.values, match: .exactOrLarger, search: .binaryDescending)
            }
            guard let index else { throw FormulaError.na }
            return .number(Double(index + 1))
        }
        register("XMATCH", .lookup, "XMATCH(lookup_value, lookup_array, [match_mode], [search_mode])", "Returns the relative position of an item in an array.", args: 2...4) { c in
            let lookup = try c.strictScalar(0)
            let array = try c.matrix(1)
            guard array.isVector else { throw FormulaError.value }
            let match: MatchMode = [0: .exact, -1: .exactOrSmaller, 1: .exactOrLarger, 2: .wildcard][try c.int(2, default: 0)] ?? .exact
            let search: SearchMode = [1: .forward, -1: .backward, 2: .binaryAscending, -2: .binaryDescending][try c.int(3, default: 1)] ?? .forward
            guard let index = findIndex(lookup, in: array.values, match: match, search: search) else { throw FormulaError.na }
            return .number(Double(index + 1))
        }
        register("LOOKUP", .lookup, "LOOKUP(lookup_value, lookup_vector, [result_vector])", "Looks up a value in a vector and returns the matching value from another vector.", args: 2...3) { c in
            let lookup = try c.strictScalar(0)
            let lookupMatrix = try c.matrix(1)
            let keys: [CellValue]
            let results: [CellValue]
            if c.count > 2 {
                keys = lookupMatrix.values
                results = try c.flat(2)
            } else if lookupMatrix.isVector {
                keys = lookupMatrix.values
                results = keys
            } else if lookupMatrix.columns >= lookupMatrix.rows {
                keys = lookupMatrix.row(0)
                results = lookupMatrix.row(lookupMatrix.rows - 1)
            } else {
                keys = lookupMatrix.column(0)
                results = lookupMatrix.column(lookupMatrix.columns - 1)
            }
            guard let index = findIndex(lookup, in: keys, match: .exactOrSmaller, search: .binaryAscending), index < results.count else {
                throw FormulaError.na
            }
            return .scalar(results[index])
        }
        register("INDEX", .lookup, "INDEX(array, row_num, [column_num])", "Returns a value or reference from a position in a range.", args: 2...3) { c in
            let source = try c.value(0)
            let m = c.evaluator.matrix(source)
            var row = try c.int(1)
            var column = try c.int(2, default: 0)
            if m.rows == 1 && c.count == 2 { column = row; row = 0 }
            if m.columns == 1 && c.count == 2 { column = 1 }
            guard row >= 0, column >= 0, row <= m.rows, column <= m.columns else { throw FormulaError.ref }
            if case .reference(let sheet, let range) = source {
                let rows = row == 0 ? range.rows : (range.minRow + row - 1)...(range.minRow + row - 1)
                let columns = column == 0 ? range.columns : (range.minColumn + column - 1)...(range.minColumn + column - 1)
                return .reference(sheet: sheet, range: CellRange(rows: rows, columns: columns))
            }
            if row == 0 { return .matrix(Matrix(column: m.column(max(column, 1) - 1))) }
            if column == 0 { return m.columns == 1 ? .scalar(m[row - 1, 0]) : .matrix(Matrix(row: m.row(row - 1))) }
            return .scalar(m[row - 1, column - 1])
        }
        register("CHOOSE", .lookup, "CHOOSE(index_num, value1, [value2], …)", "Chooses a value from a list based on an index number.", args: 2...v) { c in
            let index = try c.int(0)
            guard index >= 1, index < c.count else { throw FormulaError.value }
            return try c.value(index)
        }
        register("OFFSET", .lookup, "OFFSET(reference, rows, cols, [height], [width])", "Returns a reference offset from a given reference.", args: 3...5) { c in
            let (sheet, range) = try c.reference(0)
            let rows = try c.int(1), columns = try c.int(2)
            let height = try c.int(3, default: range.rowCount), width = try c.int(4, default: range.columnCount)
            guard height >= 1, width >= 1 else { throw FormulaError.ref }
            let start = range.start.offset(rows: rows, columns: columns)
            let end = start.offset(rows: height - 1, columns: width - 1)
            guard start.isValid, end.isValid else { throw FormulaError.ref }
            return .reference(sheet: sheet, range: CellRange(start, end))
        }
        register("INDIRECT", .lookup, "INDIRECT(ref_text, [a1])", "Returns the reference specified by a text string.", args: 1...2) { c in
            let text = try c.text(0).trimmingCharacters(in: .whitespaces)
            guard let expression = try? FormulaParser.parse(text) else { throw FormulaError.ref }
            switch expression {
            case .cell, .range: return try c.evaluator.evaluate(expression)
            case .name(let name):
                guard c.evaluator.workbook.definedName(name) != nil else { throw FormulaError.ref }
                return try c.evaluator.evaluate(expression)
            default: throw FormulaError.ref
            }
        }
        register("ROW", .lookup, "ROW([reference])", "Returns the row number of a reference.", args: 0...1) { c in
            if c.isMissing(0) { return .number(Double(c.evaluator.origin.row + 1)) }
            let (_, range) = try c.reference(0)
            if range.rowCount == 1 || range.isWholeColumns { return .number(Double(range.minRow + 1)) }
            return .matrix(Matrix(column: range.rows.map { .number(Double($0 + 1)) }))
        }
        register("COLUMN", .lookup, "COLUMN([reference])", "Returns the column number of a reference.", args: 0...1) { c in
            if c.isMissing(0) { return .number(Double(c.evaluator.origin.column + 1)) }
            let (_, range) = try c.reference(0)
            if range.columnCount == 1 || range.isWholeRows { return .number(Double(range.minColumn + 1)) }
            return .matrix(Matrix(row: range.columns.map { .number(Double($0 + 1)) }))
        }
        register("ROWS", .lookup, "ROWS(array)", "Returns the number of rows in a reference or array.", args: 1...1) { c in
            if case .reference(_, let range) = try c.value(0) { return .number(Double(range.rowCount)) }
            return .number(Double(try c.matrix(0).rows))
        }
        register("COLUMNS", .lookup, "COLUMNS(array)", "Returns the number of columns in a reference or array.", args: 1...1) { c in
            if case .reference(_, let range) = try c.value(0) { return .number(Double(range.columnCount)) }
            return .number(Double(try c.matrix(0).columns))
        }
        register("ADDRESS", .lookup, "ADDRESS(row_num, column_num, [abs_num], [a1], [sheet_text])", "Returns a reference as text.", args: 2...5) { c in
            let row = try c.int(0), column = try c.int(1), kind = try c.int(2, default: 1)
            guard row >= 1, column >= 1, row <= SheetLimits.rows, column <= SheetLimits.columns else { throw FormulaError.value }
            let a1 = try c.bool(3, default: true)
            var text: String
            if a1 {
                let absColumn = kind == 1 || kind == 3, absRow = kind == 1 || kind == 2
                text = (absColumn ? "$" : "") + CellAddress.columnName(column - 1) + (absRow ? "$" : "") + String(row)
            } else {
                text = kind == 1 ? "R\(row)C\(column)" : kind == 2 ? "R\(row)C[\(column)]" : kind == 3 ? "R[\(row)]C\(column)" : "R[\(row)]C[\(column)]"
            }
            if !c.isMissing(4) { text = quotedSheetName(try c.text(4)) + "!" + text }
            return .string(text)
        }
        register("TRANSPOSE", .lookup, "TRANSPOSE(array)", "Returns the transpose of an array.", args: 1...1) { c in
            .matrix(try c.matrix(0).transposed)
        }
        register("SORT", .lookup, "SORT(array, [sort_index], [sort_order], [by_col])", "Sorts the contents of a range or array.", args: 1...4) { c in
            let m = try c.matrix(0)
            let index = try c.int(1, default: 1)
            let descending = try c.int(2, default: 1) == -1
            let byColumn = try c.bool(3, default: false)
            let source = byColumn ? m.transposed : m
            guard index >= 1, index <= source.columns else { throw FormulaError.value }
            let rows = source.rowArrays.sorted { a, b in
                let order = compareValues(a[index - 1], b[index - 1])
                return descending ? order > 0 : order < 0
            }
            let sorted = Matrix(rows)
            return .matrix(byColumn ? sorted.transposed : sorted)
        }
        register("SORTBY", .lookup, "SORTBY(array, by_array1, [sort_order1], …)", "Sorts a range based on the values in a corresponding range.", args: 2...v) { c in
            let m = try c.matrix(0)
            var keys: [([CellValue], Bool)] = []
            var i = 1
            while i < c.count {
                let key = try c.flat(i)
                guard key.count == m.rows else { throw FormulaError.value }
                let descending = i + 1 < c.count ? try c.int(i + 1, default: 1) == -1 : false
                keys.append((key, descending))
                i += 2
            }
            let order = (0..<m.rows).sorted { a, b in
                for (key, descending) in keys {
                    let r = compareValues(key[a], key[b])
                    if r != 0 { return descending ? r > 0 : r < 0 }
                }
                return a < b
            }
            return .matrix(Matrix(order.map { m.row($0) }))
        }
        register("UNIQUE", .lookup, "UNIQUE(array, [by_col], [exactly_once])", "Returns the unique values from a range or array.", args: 1...3) { c in
            let m = try c.matrix(0)
            let byColumn = try c.bool(1, default: false)
            let exactlyOnce = try c.bool(2, default: false)
            let source = byColumn ? m.transposed : m
            let rows = source.rowArrays
            func key(_ row: [CellValue]) -> String { row.map { $0.plainText.lowercased() }.joined(separator: "\u{1F}") }
            var counts: [String: Int] = [:]
            for row in rows { counts[key(row), default: 0] += 1 }
            var seen = Set<String>()
            var result: [[CellValue]] = []
            for row in rows {
                let k = key(row)
                if exactlyOnce && counts[k] != 1 { continue }
                if seen.insert(k).inserted { result.append(row) }
            }
            guard !result.isEmpty else { throw FormulaError.calc }
            let unique = Matrix(result)
            return .matrix(byColumn ? unique.transposed : unique)
        }
        register("FILTER", .lookup, "FILTER(array, include, [if_empty])", "Filters a range of data based on criteria you define.", args: 2...3) { c in
            let m = try c.matrix(0)
            let include = try c.matrix(1)
            let keep: (CellValue) throws -> Bool = { v in
                if case .error(let e) = v { throw e }
                return (try? v.asBool()) ?? false
            }
            var result: Matrix?
            if include.rows == m.rows && include.columns == 1 {
                let rows = try (0..<m.rows).filter { try keep(include[$0, 0]) }.map { m.row($0) }
                if !rows.isEmpty { result = Matrix(rows) }
            } else if include.columns == m.columns && include.rows == 1 {
                let columns = try (0..<m.columns).filter { try keep(include[0, $0]) }.map { m.column($0) }
                if !columns.isEmpty { result = Matrix(columns).transposed }
            } else {
                throw FormulaError.value
            }
            if let result { return .matrix(result) }
            if c.count > 2 { return try c.value(2) }
            throw FormulaError.calc
        }
        register("TAKE", .lookup, "TAKE(array, rows, [columns])", "Returns rows or columns from the start or end of an array.", args: 2...3) { c in
            let m = try c.matrix(0)
            let rows = c.isMissing(1) ? m.rows : try c.int(1)
            let columns = c.isMissing(2) ? m.columns : try c.int(2)
            let rowRange = rows >= 0 ? 0..<min(rows, m.rows) : max(m.rows + rows, 0)..<m.rows
            let columnRange = columns >= 0 ? 0..<min(columns, m.columns) : max(m.columns + columns, 0)..<m.columns
            guard !rowRange.isEmpty, !columnRange.isEmpty else { throw FormulaError.calc }
            return .matrix(Matrix(rowRange.map { r in columnRange.map { m[r, $0] } }))
        }
        register("DROP", .lookup, "DROP(array, rows, [columns])", "Excludes rows or columns from the start or end of an array.", args: 2...3) { c in
            let m = try c.matrix(0)
            let rows = try c.int(1, default: 0), columns = try c.int(2, default: 0)
            let rowRange = rows >= 0 ? min(rows, m.rows)..<m.rows : 0..<max(m.rows + rows, 0)
            let columnRange = columns >= 0 ? min(columns, m.columns)..<m.columns : 0..<max(m.columns + columns, 0)
            guard !rowRange.isEmpty, !columnRange.isEmpty else { throw FormulaError.calc }
            return .matrix(Matrix(rowRange.map { r in columnRange.map { m[r, $0] } }))
        }
        register("CHOOSECOLS", .lookup, "CHOOSECOLS(array, col_num1, [col_num2], …)", "Returns the specified columns from an array.", args: 2...v) { c in
            let m = try c.matrix(0)
            let picks = try (1..<c.count).map { i -> Int in
                let n = try c.int(i)
                let index = n > 0 ? n - 1 : m.columns + n
                guard index >= 0, index < m.columns else { throw FormulaError.value }
                return index
            }
            return .matrix(Matrix((0..<m.rows).map { r in picks.map { m[r, $0] } }))
        }
        register("CHOOSEROWS", .lookup, "CHOOSEROWS(array, row_num1, [row_num2], …)", "Returns the specified rows from an array.", args: 2...v) { c in
            let m = try c.matrix(0)
            let picks = try (1..<c.count).map { i -> Int in
                let n = try c.int(i)
                let index = n > 0 ? n - 1 : m.rows + n
                guard index >= 0, index < m.rows else { throw FormulaError.value }
                return index
            }
            return .matrix(Matrix(picks.map { m.row($0) }))
        }
        register("VSTACK", .lookup, "VSTACK(array1, [array2], …)", "Stacks arrays vertically.", args: 1...v) { c in
            let arrays = try (0..<c.count).map { try c.matrix($0) }
            let width = arrays.map(\.columns).max() ?? 0
            var rows: [[CellValue]] = []
            for m in arrays {
                for r in m.rowArrays { rows.append(r + Array(repeating: .error(.na), count: width - r.count)) }
            }
            return .matrix(Matrix(rows))
        }
        register("HSTACK", .lookup, "HSTACK(array1, [array2], …)", "Stacks arrays horizontally.", args: 1...v) { c in
            let arrays = try (0..<c.count).map { try c.matrix($0).transposed }
            let height = arrays.map(\.columns).max() ?? 0
            var columns: [[CellValue]] = []
            for m in arrays {
                for r in m.rowArrays { columns.append(r + Array(repeating: .error(.na), count: height - r.count)) }
            }
            return .matrix(Matrix(columns).transposed)
        }
        register("TOCOL", .lookup, "TOCOL(array, [ignore])", "Returns the array as one column.", args: 1...2) { c in
            let ignore = try c.int(1, default: 0)
            let values = try c.flat(0).filter { v in
                (ignore == 1 || ignore == 3) && v.isEmpty ? false : ((ignore == 2 || ignore == 3) && v.isError ? false : true)
            }
            return .matrix(Matrix(column: values))
        }
        register("TOROW", .lookup, "TOROW(array, [ignore])", "Returns the array as one row.", args: 1...2) { c in
            let ignore = try c.int(1, default: 0)
            let values = try c.flat(0).filter { v in
                (ignore == 1 || ignore == 3) && v.isEmpty ? false : ((ignore == 2 || ignore == 3) && v.isError ? false : true)
            }
            return .matrix(Matrix(row: values))
        }
    }
}
