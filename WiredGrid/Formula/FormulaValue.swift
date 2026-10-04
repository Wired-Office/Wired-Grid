import Foundation

/// A 2-D block of values, row-major.
struct Matrix: Equatable {
    var rows: Int
    var columns: Int
    var values: [CellValue]

    init(rows: Int, columns: Int, values: [CellValue]) {
        self.rows = rows
        self.columns = columns
        self.values = values
    }

    init(rows: Int, columns: Int, fill: CellValue = .empty) {
        self.init(rows: rows, columns: columns, values: Array(repeating: fill, count: rows * columns))
    }

    init(column: [CellValue]) {
        self.init(rows: column.count, columns: 1, values: column)
    }

    init(row: [CellValue]) {
        self.init(rows: 1, columns: row.count, values: row)
    }

    init(_ grid: [[CellValue]]) {
        let width = grid.map(\.count).max() ?? 0
        var values: [CellValue] = []
        for line in grid { values += line + Array(repeating: .empty, count: width - line.count) }
        self.init(rows: grid.count, columns: width, values: values)
    }

    subscript(row: Int, column: Int) -> CellValue {
        get { values[row * columns + column] }
        set { values[row * columns + column] = newValue }
    }

    func row(_ r: Int) -> [CellValue] { Array(values[(r * columns)..<((r + 1) * columns)]) }
    func column(_ c: Int) -> [CellValue] { (0..<rows).map { self[$0, c] } }
    var rowArrays: [[CellValue]] { (0..<rows).map(row) }

    var transposed: Matrix {
        var result = Matrix(rows: columns, columns: rows)
        for r in 0..<rows { for c in 0..<columns { result[c, r] = self[r, c] } }
        return result
    }

    var isVector: Bool { rows == 1 || columns == 1 }
    var count: Int { values.count }
}

/// What evaluating an expression produces: a single value, an array, or a reference.
enum FValue {
    case scalar(CellValue)
    case matrix(Matrix)
    case reference(sheet: Int, range: CellRange)

    static let empty = FValue.scalar(.empty)
    static func number(_ v: Double) -> FValue { v.isFinite ? .scalar(.number(v)) : .scalar(.error(.num)) }
    static func string(_ s: String) -> FValue { .scalar(.string(s)) }
    static func bool(_ b: Bool) -> FValue { .scalar(.bool(b)) }
    static func error(_ e: FormulaError) -> FValue { .scalar(.error(e)) }
}

// MARK: - Coercion

extension CellValue {
    /// Numeric value with Excel's coercions; throws the error to propagate.
    func asNumber() throws -> Double {
        switch self {
        case .number(let v): return v
        case .bool(let b): return b ? 1 : 0
        case .empty: return 0
        case .string(let s):
            if let parsed = ValueParser.number(from: s) { return parsed }
            throw FormulaError.value
        case .error(let e): throw e
        }
    }

    func asText() throws -> String {
        switch self {
        case .number(let v): return NumberFormat.general(v, maxLength: 20)
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .empty: return ""
        case .string(let s): return s
        case .error(let e): throw e
        }
    }

    func asBool() throws -> Bool {
        switch self {
        case .bool(let b): return b
        case .number(let v): return v != 0
        case .empty: return false
        case .string(let s):
            switch s.uppercased() {
            case "TRUE": return true
            case "FALSE": return false
            default: throw FormulaError.value
            }
        case .error(let e): throw e
        }
    }
}

/// Excel comparison: numbers < text < booleans; text ignores case. Returns -1, 0 or 1.
func compareValues(_ a: CellValue, _ b: CellValue) -> Int {
    func normalized(_ v: CellValue, other: CellValue) -> CellValue {
        guard case .empty = v else { return v }
        switch other {
        case .string: return .string("")
        case .bool: return .bool(false)
        default: return .number(0)
        }
    }
    let x = normalized(a, other: b), y = normalized(b, other: a)
    func rank(_ v: CellValue) -> Int {
        switch v {
        case .number, .empty: 0
        case .string: 1
        case .bool: 2
        case .error: 3
        }
    }
    let rx = rank(x), ry = rank(y)
    if rx != ry { return rx < ry ? -1 : 1 }
    switch (x, y) {
    case (.number(let p), .number(let q)): return p < q ? -1 : (p > q ? 1 : 0)
    case (.string(let p), .string(let q)):
        let r = p.compare(q, options: [.caseInsensitive], locale: nil)
        return r == .orderedAscending ? -1 : (r == .orderedDescending ? 1 : 0)
    case (.bool(let p), .bool(let q)): return p == q ? 0 : (!p ? -1 : 1)
    default: return 0
    }
}

// MARK: - Criteria (COUNTIF, SUMIF, …)

/// A parsed criterion such as `">=10"`, `"<>apple"` or `"a*"`.
struct Criterion {
    private enum Op { case eq, ne, lt, le, gt, ge }
    private let op: Op
    private let number: Double?
    private let text: String
    private let pattern: NSRegularExpression?

    init(_ value: CellValue) {
        switch value {
        case .number(let n):
            op = .eq; number = n; text = NumberFormat.general(n); pattern = nil
            return
        case .bool(let b):
            op = .eq; number = nil; text = b ? "TRUE" : "FALSE"; pattern = nil
            return
        case .empty:
            op = .eq; number = nil; text = ""; pattern = nil
            return
        case .error(let e):
            op = .eq; number = nil; text = e.rawValue; pattern = nil
            return
        case .string(let s):
            var rest = Substring(s)
            var parsedOp = Op.eq
            for (prefix, candidate) in [("<=", Op.le), (">=", .ge), ("<>", .ne), ("<", .lt), (">", .gt), ("=", .eq)] where rest.hasPrefix(prefix) {
                parsedOp = candidate
                rest = rest.dropFirst(prefix.count)
                break
            }
            op = parsedOp
            text = String(rest)
            number = ValueParser.number(from: text)
            if number == nil, text.contains(where: { $0 == "*" || $0 == "?" }), op == .eq || op == .ne {
                pattern = Criterion.wildcard(text)
            } else {
                pattern = nil
            }
        }
    }

    static func wildcard(_ text: String) -> NSRegularExpression? {
        var regex = "^"
        var escape = false
        for ch in text {
            if escape { regex += NSRegularExpression.escapedPattern(for: String(ch)); escape = false; continue }
            switch ch {
            case "~": escape = true
            case "*": regex += ".*"
            case "?": regex += "."
            default: regex += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        return try? NSRegularExpression(pattern: regex + "$", options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    func matches(_ value: CellValue) -> Bool {
        if let pattern {
            let s = value.plainText
            let hit = pattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
            return op == .eq ? hit : !hit
        }
        if text.isEmpty {
            switch op {
            case .eq: return value.isEmpty || value == .string("")
            case .ne: return !(value.isEmpty || value == .string(""))
            default: return false
            }
        }
        if let number {
            let cellNumber: Double?
            switch value {
            case .number(let n): cellNumber = n
            case .string(let s) where op == .eq || op == .ne: cellNumber = ValueParser.number(from: s)
            default: cellNumber = nil
            }
            guard let n = cellNumber else { return op == .ne }
            switch op {
            case .eq: return n == number
            case .ne: return n != number
            case .lt: return n < number
            case .le: return n <= number
            case .gt: return n > number
            case .ge: return n >= number
            }
        }
        let c: Int
        switch value {
        case .number: if op == .ne { return true } else if op == .eq { return false } else { return false }
        case .empty:
            c = compareValues(.string(""), .string(text))
        default:
            c = compareValues(.string(value.plainText), .string(text))
        }
        switch op {
        case .eq: return c == 0
        case .ne: return c != 0
        case .lt: return c < 0
        case .le: return c <= 0
        case .gt: return c > 0
        case .ge: return c >= 0
        }
    }
}
