import Foundation

enum FunctionCategory: String, CaseIterable, Identifiable {
    case math = "Math & Trig"
    case statistical = "Statistical"
    case logical = "Logical"
    case text = "Text"
    case date = "Date & Time"
    case lookup = "Lookup & Reference"
    case financial = "Financial"
    case information = "Information"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .math: "function"
        case .statistical: "chart.bar.xaxis"
        case .logical: "questionmark.diamond"
        case .text: "textformat"
        case .date: "calendar"
        case .lookup: "magnifyingglass"
        case .financial: "banknote"
        case .information: "info.circle"
        }
    }
}

/// A built-in worksheet function: its implementation plus the help shown in the UI.
struct FunctionSpec {
    let name: String
    let category: FunctionCategory
    /// e.g. "SUM(number1, [number2], …)"
    let syntax: String
    let summary: String
    let minArgs: Int
    let maxArgs: Int
    let implementation: (FunctionCall) throws -> FValue

    /// Argument names parsed from the syntax, for the signature hint.
    var parameters: [String] {
        guard let open = syntax.firstIndex(of: "("), let close = syntax.lastIndex(of: ")"), open < close else { return [] }
        let inner = syntax[syntax.index(after: open)..<close]
        return inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Every function the formula engine knows.
final class FunctionLibrary {
    static let shared = FunctionLibrary()

    private(set) var functions: [String: FunctionSpec] = [:]

    private init() {
        registerMath()
        registerStatistical()
        registerLogical()
        registerText()
        registerDate()
        registerLookup()
        registerFinancial()
        registerInformation()
    }

    func function(named name: String) -> FunctionSpec? {
        functions[name.uppercased()]
    }

    var sortedNames: [String] { functions.keys.sorted() }

    func functions(in category: FunctionCategory) -> [FunctionSpec] {
        functions.values.filter { $0.category == category }.sorted { $0.name < $1.name }
    }

    func completions(for prefix: String) -> [FunctionSpec] {
        let upper = prefix.uppercased()
        guard !upper.isEmpty else { return [] }
        return functions.values.filter { $0.name.hasPrefix(upper) }.sorted { a, b in
            // Common functions first, then alphabetical.
            let ra = FunctionLibrary.popular.firstIndex(of: a.name) ?? Int.max
            let rb = FunctionLibrary.popular.firstIndex(of: b.name) ?? Int.max
            return ra != rb ? ra < rb : a.name < b.name
        }
    }

    static let popular = ["SUM", "AVERAGE", "IF", "COUNT", "MAX", "MIN", "VLOOKUP", "XLOOKUP", "COUNTIF", "SUMIF",
                          "ROUND", "CONCAT", "TODAY", "NOW", "INDEX", "MATCH", "IFERROR", "AND", "OR", "LEFT", "RIGHT",
                          "LEN", "TEXT", "DATE", "PMT", "FILTER", "SORT", "UNIQUE"]

    func register(_ name: String, _ category: FunctionCategory, _ syntax: String, _ summary: String,
                  args: ClosedRange<Int>, _ implementation: @escaping (FunctionCall) throws -> FValue) {
        functions[name] = FunctionSpec(name: name, category: category, syntax: syntax, summary: summary,
                                       minArgs: args.lowerBound, maxArgs: args.upperBound, implementation: implementation)
    }

    static let variadic = 255
}

/// The arguments of one function call, with Excel-style coercion helpers.
final class FunctionCall {
    let evaluator: Evaluator
    let args: [Expr]
    private var evaluated: [Int: FValue] = [:]

    init(evaluator: Evaluator, args: [Expr]) {
        self.evaluator = evaluator
        self.args = args
    }

    var count: Int { args.count }

    func isMissing(_ index: Int) -> Bool {
        guard index < args.count else { return true }
        if case .missing = args[index] { return true }
        return false
    }

    /// Evaluates an argument once (lazily, so IF only evaluates the branch it takes).
    func value(_ index: Int) throws -> FValue {
        guard index < args.count else { return .empty }
        if let cached = evaluated[index] { return cached }
        let result = try evaluator.evaluate(args[index])
        evaluated[index] = result
        return result
    }

    /// A single value; errors are returned, not thrown.
    func scalar(_ index: Int) throws -> CellValue {
        evaluator.scalar(try value(index))
    }

    /// A single value, throwing if it's an error.
    func strictScalar(_ index: Int) throws -> CellValue {
        let v = try scalar(index)
        if case .error(let e) = v { throw e }
        return v
    }

    func number(_ index: Int, default fallback: Double? = nil) throws -> Double {
        if isMissing(index), let fallback { return fallback }
        return try scalar(index).asNumber()
    }

    func int(_ index: Int, default fallback: Int? = nil) throws -> Int {
        if isMissing(index), let fallback { return fallback }
        let n = try number(index)
        guard n.isFinite, abs(n) < 1e15 else { throw FormulaError.num }
        return Int(n.rounded(.towardZero))
    }

    func text(_ index: Int, default fallback: String? = nil) throws -> String {
        if isMissing(index), let fallback { return fallback }
        return try scalar(index).asText()
    }

    func bool(_ index: Int, default fallback: Bool? = nil) throws -> Bool {
        if isMissing(index), let fallback { return fallback }
        return try scalar(index).asBool()
    }

    func matrix(_ index: Int) throws -> Matrix {
        evaluator.matrix(try value(index))
    }

    func reference(_ index: Int) throws -> (sheet: Int, range: CellRange) {
        guard case .reference(let sheet, let range) = try value(index) else { throw FormulaError.value }
        return (sheet, range)
    }

    func isReference(_ index: Int) throws -> Bool {
        if case .reference = try value(index) { return true }
        return false
    }

    /// Every value in the argument as a flat list, row by row.
    func flat(_ index: Int) throws -> [CellValue] {
        try matrix(index).values
    }

    /// Numbers the way SUM and AVERAGE collect them: references and arrays contribute only
    /// numbers (errors propagate); values typed directly as arguments are coerced.
    func numbers(from indices: Range<Int>? = nil, includeTextAndLogicals: Bool = false) throws -> [Double] {
        var result: [Double] = []
        for index in indices ?? 0..<count where !isMissing(index) {
            let v = try value(index)
            switch v {
            case .scalar(let s):
                if case .error(let e) = s { throw e }
                if case .empty = s { if includeTextAndLogicals { result.append(0) }; continue }
                result.append(try s.asNumber())
            case .matrix, .reference:
                for element in evaluator.matrix(v).values {
                    switch element {
                    case .number(let n): result.append(n)
                    case .error(let e): throw e
                    case .bool(let b): if includeTextAndLogicals { result.append(b ? 1 : 0) }
                    case .string: if includeTextAndLogicals { result.append(0) }
                    case .empty: break
                    }
                }
            }
        }
        return result
    }

    /// A lifted one-argument function: applied to each element of an array argument.
    func lift(_ index: Int, _ transform: (CellValue) throws -> CellValue) throws -> FValue {
        try evaluator.map(try value(index), transform)
    }

    /// Lifts a function over its first argument, with the remaining arguments as scalars.
    func liftNumber(_ index: Int = 0, _ transform: @escaping (Double) throws -> Double) throws -> FValue {
        try lift(index) { v in
            if case .error = v { return v }
            let result = try transform(try v.asNumber())
            return result.isFinite ? .number(result) : .error(.num)
        }
    }

    func liftText(_ index: Int = 0, _ transform: @escaping (String) throws -> CellValue) throws -> FValue {
        try lift(index) { v in
            if case .error = v { return v }
            return try transform(try v.asText())
        }
    }
}

extension FValue {
    var asMatrixResult: FValue { self }
}

/// Wraps a numeric result, turning infinities and NaN into #NUM!.
func numberResult(_ value: Double) -> FValue {
    value.isFinite ? .scalar(.number(value)) : .scalar(.error(.num))
}
