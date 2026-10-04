import Foundation

/// Spreadsheet error values, displayed exactly as Excel shows them.
enum FormulaError: String, Error, Codable, CaseIterable {
    case null = "#NULL!"
    case div0 = "#DIV/0!"
    case value = "#VALUE!"
    case ref = "#REF!"
    case name = "#NAME?"
    case num = "#NUM!"
    case na = "#N/A"
    case spill = "#SPILL!"
    case calc = "#CALC!"
    case circular = "#CIRCULAR!"

    /// The number ERROR.TYPE returns.
    var typeNumber: Int {
        switch self {
        case .null: 1
        case .div0: 2
        case .value: 3
        case .ref: 4
        case .name: 5
        case .num: 6
        case .na: 7
        case .spill: 9
        case .calc: 14
        case .circular: 8
        }
    }

    var explanation: String {
        switch self {
        case .null: "The ranges don't intersect."
        case .div0: "The formula divides by zero or an empty cell."
        case .value: "An argument has the wrong type of value."
        case .ref: "The formula refers to a cell that isn't valid."
        case .name: "The formula uses a name or function that isn't recognized."
        case .num: "The formula produces a number that is too large, too small or invalid."
        case .na: "A value isn't available to the formula."
        case .spill: "The result can't spill because cells in its way aren't empty."
        case .calc: "The calculation produced an empty result."
        case .circular: "The formula refers to its own cell, directly or indirectly."
        }
    }
}

/// A computed or literal cell value.
enum CellValue: Equatable {
    case empty
    case number(Double)
    case string(String)
    case bool(Bool)
    case error(FormulaError)

    var isEmpty: Bool {
        if case .empty = self { return true }
        return false
    }

    var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var isError: Bool {
        if case .error = self { return true }
        return false
    }

    var isText: Bool {
        if case .string = self { return true }
        return false
    }

    /// Plain text used for sorting, filtering, TSV export and comparisons.
    var plainText: String {
        switch self {
        case .empty: ""
        case .number(let value): NumberFormat.general(value)
        case .string(let text): text
        case .bool(let flag): flag ? "TRUE" : "FALSE"
        case .error(let error): error.rawValue
        }
    }

    /// Excel's ordering for sorting: numbers < text < logical < errors < blanks.
    static func sortOrder(_ a: CellValue, _ b: CellValue) -> Bool {
        func rank(_ v: CellValue) -> Int {
            switch v {
            case .number: 0
            case .string: 1
            case .bool: 2
            case .error: 3
            case .empty: 4
            }
        }
        let ra = rank(a), rb = rank(b)
        if ra != rb { return ra < rb }
        switch (a, b) {
        case (.number(let x), .number(let y)): return x < y
        case (.string(let x), .string(let y)): return x.localizedStandardCompare(y) == .orderedAscending
        case (.bool(let x), .bool(let y)): return !x && y
        default: return false
        }
    }
}

extension CellValue: Codable {
    private enum CodingKeys: String, CodingKey { case n, s, b, e }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let number = try container.decodeIfPresent(Double.self, forKey: .n) {
            self = .number(number)
        } else if let text = try container.decodeIfPresent(String.self, forKey: .s) {
            self = .string(text)
        } else if let flag = try container.decodeIfPresent(Bool.self, forKey: .b) {
            self = .bool(flag)
        } else if let error = try container.decodeIfPresent(FormulaError.self, forKey: .e) {
            self = .error(error)
        } else {
            self = .empty
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .empty: break
        case .number(let value): try container.encode(value, forKey: .n)
        case .string(let text): try container.encode(text, forKey: .s)
        case .bool(let flag): try container.encode(flag, forKey: .b)
        case .error(let error): try container.encode(error, forKey: .e)
        }
    }
}
