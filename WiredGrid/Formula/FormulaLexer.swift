import Foundation

/// A cell reference as written in a formula, e.g. `Sheet2!$B$4`.
struct CellReference: Hashable {
    var sheet: String?
    var row: Int
    var column: Int
    var rowAbsolute = false
    var columnAbsolute = false

    var address: CellAddress { CellAddress(row: row, column: column) }

    func text(includeSheet: Bool = true) -> String {
        var s = ""
        if includeSheet, let sheet { s += quotedSheetName(sheet) + "!" }
        s += (columnAbsolute ? "$" : "") + CellAddress.columnName(column)
        s += (rowAbsolute ? "$" : "") + String(row + 1)
        return s
    }
}

/// A rectangular reference: `A1:B9`, `A:A` or `3:4`.
struct RangeReference: Hashable {
    enum Kind: Hashable { case cells, columns, rows }
    var sheet: String?
    var kind: Kind = .cells
    var start: CellReference
    var end: CellReference

    var range: CellRange {
        switch kind {
        case .cells: CellRange(start.address, end.address)
        case .columns: .wholeColumns(min(start.column, end.column)...max(start.column, end.column))
        case .rows: .wholeRows(min(start.row, end.row)...max(start.row, end.row))
        }
    }

    func text() -> String {
        let prefix = sheet.map { quotedSheetName($0) + "!" } ?? ""
        switch kind {
        case .cells:
            return prefix + start.text(includeSheet: false) + ":" + end.text(includeSheet: false)
        case .columns:
            return prefix + (start.columnAbsolute ? "$" : "") + CellAddress.columnName(start.column) + ":"
                + (end.columnAbsolute ? "$" : "") + CellAddress.columnName(end.column)
        case .rows:
            return prefix + (start.rowAbsolute ? "$" : "") + String(start.row + 1) + ":"
                + (end.rowAbsolute ? "$" : "") + String(end.row + 1)
        }
    }
}

struct FormulaToken: Equatable {
    enum Kind: Equatable {
        case number(Double)
        case string(String)
        case bool(Bool)
        case error(FormulaError)
        case cell(CellReference)
        case range(RangeReference)
        /// A function name (always followed by "(").
        case function(String)
        /// A defined name or unknown identifier.
        case name(String)
        case op(String)
        case leftParen, rightParen, comma, semicolon, leftBrace, rightBrace
        case whitespace
    }

    var kind: Kind
    /// Where the token sits in the source, in UTF-16 offsets (for editor coloring and rewriting).
    var range: NSRange
    var text: String
}

/// Splits formula text into tokens. The input excludes the leading "=".
enum FormulaLexer {
    static func tokenize(_ source: String) throws -> [FormulaToken] {
        let chars = Array(source.utf16)
        var tokens: [FormulaToken] = []
        var i = 0

        func char(_ offset: Int = 0) -> UInt16? {
            let index = i + offset
            return index < chars.count ? chars[index] : nil
        }
        func text(_ from: Int, _ to: Int) -> String {
            String(decoding: chars[from..<to], as: UTF16.self)
        }
        func add(_ kind: FormulaToken.Kind, from start: Int) {
            tokens.append(FormulaToken(kind: kind, range: NSRange(location: start, length: i - start), text: text(start, i)))
        }

        while i < chars.count {
            let start = i
            let c = chars[i]

            // Whitespace
            if c == 32 || c == 9 || c == 10 || c == 13 {
                while let d = char(), d == 32 || d == 9 || d == 10 || d == 13 { i += 1 }
                add(.whitespace, from: start)
                continue
            }

            // String literal
            if c == 34 { // "
                i += 1
                var value = ""
                var closed = false
                while i < chars.count {
                    if chars[i] == 34 {
                        if char(1) == 34 { value += "\""; i += 2; continue }
                        i += 1
                        closed = true
                        break
                    }
                    let segmentStart = i
                    while i < chars.count && chars[i] != 34 { i += 1 }
                    value += text(segmentStart, i)
                }
                if !closed { throw FormulaError.value }
                add(.string(value), from: start)
                continue
            }

            // Error literal
            if c == 35 { // #
                let rest = text(i, chars.count).uppercased()
                if let error = FormulaError.allCases.sorted(by: { $0.rawValue.count > $1.rawValue.count }).first(where: { rest.hasPrefix($0.rawValue) }) {
                    i += error.rawValue.utf16.count
                    add(.error(error), from: start)
                    continue
                }
                throw FormulaError.name
            }

            // Quoted sheet name: 'My Sheet'!A1
            if c == 39 { // '
                i += 1
                var units: [UInt16] = []
                while i < chars.count {
                    if chars[i] == 39 {
                        if char(1) == 39 { units.append(39); i += 2; continue }
                        break
                    }
                    units.append(chars[i])
                    i += 1
                }
                let name = String(decoding: units, as: UTF16.self)
                guard char() == 39, char(1) == 33 else { throw FormulaError.ref } // '!
                i += 2
                guard let kind = scanReference(chars, &i, sheet: name) else { throw FormulaError.ref }
                add(kind, from: start)
                continue
            }

            // Number
            if isDigit(c) || (c == 46 && char(1).map(isDigit) == true) {
                // Could be a row range like 3:5.
                let save = i
                if let kind = scanReference(chars, &i, sheet: nil), case .range = kind {
                    add(kind, from: start)
                    continue
                }
                i = save
                while let d = char(), isDigit(d) { i += 1 }
                if char() == 46 { i += 1; while let d = char(), isDigit(d) { i += 1 } }
                if let e = char(), e == 69 || e == 101, let n = char(1), isDigit(n) || ((n == 43 || n == 45) && char(2).map(isDigit) == true) {
                    i += 2
                    while let d = char(), isDigit(d) { i += 1 }
                }
                guard let value = Double(text(start, i)) else { throw FormulaError.value }
                add(.number(value), from: start)
                continue
            }

            // Identifier, reference or function
            if isIdentifierStart(c) || c == 36 { // $
                let save = i
                // Scan the full identifier to check for a sheet prefix or function call.
                while let d = char(), isIdentifierChar(d) || d == 36 { i += 1 }
                let word = text(start, i)
                if char() == 33, !word.contains("$") { // Sheet!Ref
                    i += 1
                    guard let kind = scanReference(chars, &i, sheet: word) else { throw FormulaError.ref }
                    add(kind, from: start)
                    continue
                }
                if char() == 40, !word.contains("$") { // (
                    add(.function(word.uppercased()), from: start)
                    continue
                }
                i = save
                if let kind = scanReference(chars, &i, sheet: nil) {
                    // A reference must not run into more identifier characters (e.g. "A1B").
                    if let d = char(), isIdentifierChar(d) {
                        i = save
                    } else {
                        add(kind, from: start)
                        continue
                    }
                }
                i = save
                while let d = char(), isIdentifierChar(d) { i += 1 }
                guard i > start else { throw FormulaError.name }
                let name = text(start, i)
                switch name.uppercased() {
                case "TRUE": add(.bool(true), from: start)
                case "FALSE": add(.bool(false), from: start)
                default: add(.name(name), from: start)
                }
                continue
            }

            // Operators and punctuation
            i += 1
            switch c {
            case 40: add(.leftParen, from: start)
            case 41: add(.rightParen, from: start)
            case 44: add(.comma, from: start)
            case 59: add(.semicolon, from: start)
            case 123: add(.leftBrace, from: start)
            case 125: add(.rightBrace, from: start)
            case 60: // <
                if char() == 61 || char() == 62 { i += 1 }
                add(.op(text(start, i)), from: start)
            case 62: // >
                if char() == 61 { i += 1 }
                add(.op(text(start, i)), from: start)
            case 43, 45, 42, 47, 94, 38, 61, 37, 58: // + - * / ^ & = % :
                add(.op(text(start, i)), from: start)
            default:
                throw FormulaError.name
            }
        }
        return tokens
    }

    // MARK: - References

    /// Scans a cell, cell range, column range or row range at `i`.
    private static func scanReference(_ chars: [UInt16], _ i: inout Int, sheet: String?) -> FormulaToken.Kind? {
        let start = i
        if let first = scanCell(chars, &i) {
            // Cell range A1:B2 (the second part may not carry a sheet).
            let afterFirst = i
            if i < chars.count, chars[i] == 58 {
                i += 1
                if let second = scanCell(chars, &i) {
                    var a = first, b = second
                    a.sheet = sheet
                    b.sheet = sheet
                    return .range(RangeReference(sheet: sheet, kind: .cells, start: a, end: b))
                }
            }
            i = afterFirst
            var cell = first
            cell.sheet = sheet
            return .cell(cell)
        }
        i = start
        // Column range A:C
        if let (c1, abs1) = scanColumn(chars, &i), i < chars.count, chars[i] == 58 {
            i += 1
            if let (c2, abs2) = scanColumn(chars, &i) {
                let a = CellReference(sheet: sheet, row: 0, column: c1, rowAbsolute: true, columnAbsolute: abs1)
                let b = CellReference(sheet: sheet, row: SheetLimits.rows - 1, column: c2, rowAbsolute: true, columnAbsolute: abs2)
                return .range(RangeReference(sheet: sheet, kind: .columns, start: a, end: b))
            }
        }
        i = start
        // Row range 3:5
        if let (r1, abs1) = scanRow(chars, &i), i < chars.count, chars[i] == 58 {
            i += 1
            if let (r2, abs2) = scanRow(chars, &i) {
                let a = CellReference(sheet: sheet, row: r1, column: 0, rowAbsolute: abs1, columnAbsolute: true)
                let b = CellReference(sheet: sheet, row: r2, column: SheetLimits.columns - 1, rowAbsolute: abs2, columnAbsolute: true)
                return .range(RangeReference(sheet: sheet, kind: .rows, start: a, end: b))
            }
        }
        i = start
        return nil
    }

    private static func scanCell(_ chars: [UInt16], _ i: inout Int) -> CellReference? {
        let start = i
        guard let (column, columnAbs) = scanColumn(chars, &i), let (row, rowAbs) = scanRow(chars, &i) else {
            i = start
            return nil
        }
        if i < chars.count, isIdentifierChar(chars[i]) || chars[i] == 40 { i = start; return nil }
        return CellReference(sheet: nil, row: row, column: column, rowAbsolute: rowAbs, columnAbsolute: columnAbs)
    }

    private static func scanColumn(_ chars: [UInt16], _ i: inout Int) -> (Int, Bool)? {
        let start = i
        var absolute = false
        if i < chars.count, chars[i] == 36 { absolute = true; i += 1 }
        let lettersStart = i
        while i < chars.count, isLetter(chars[i]), i - lettersStart < 4 { i += 1 }
        let letters = String(decoding: chars[lettersStart..<i], as: UTF16.self)
        guard !letters.isEmpty, letters.count <= 3, let column = CellAddress.columnIndex(letters) else { i = start; return nil }
        return (column, absolute)
    }

    private static func scanRow(_ chars: [UInt16], _ i: inout Int) -> (Int, Bool)? {
        let start = i
        var absolute = false
        if i < chars.count, chars[i] == 36 { absolute = true; i += 1 }
        let digitsStart = i
        while i < chars.count, isDigit(chars[i]) { i += 1 }
        guard i > digitsStart, i - digitsStart <= 7,
              let row = Int(String(decoding: chars[digitsStart..<i], as: UTF16.self)),
              row >= 1, row <= SheetLimits.rows
        else { i = start; return nil }
        return (row - 1, absolute)
    }

    // MARK: - Character classes

    static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    static func isLetter(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
    static func isIdentifierStart(_ c: UInt16) -> Bool { isLetter(c) || c == 95 || c == 92 || c > 127 }
    static func isIdentifierChar(_ c: UInt16) -> Bool { isIdentifierStart(c) || isDigit(c) || c == 46 }
}
