import Foundation

/// A parsed formula.
indirect enum Expr {
    case number(Double)
    case string(String)
    case bool(Bool)
    case error(FormulaError)
    case cell(CellReference)
    case range(RangeReference)
    case name(String)
    case unary(String, Expr)
    case percent(Expr)
    case binary(String, Expr, Expr)
    case call(String, [Expr])
    case array([[Expr]])
    /// An omitted argument, as in `IF(A1,,2)`.
    case missing
}

/// Recursive-descent parser following Excel's operator precedence:
/// `:` › negation › `%` › `^` › `* /` › `+ -` › `&` › comparisons.
struct FormulaParser {
    private var tokens: [FormulaToken]
    private var position = 0

    static func parse(_ source: String) throws -> Expr {
        var parser = FormulaParser(tokens: try FormulaLexer.tokenize(source).filter { $0.kind != .whitespace })
        guard !parser.tokens.isEmpty else { throw FormulaError.value }
        let expression = try parser.parseComparison()
        guard parser.position == parser.tokens.count else { throw FormulaError.value }
        return expression
    }

    private init(tokens: [FormulaToken]) {
        self.tokens = tokens
    }

    private var current: FormulaToken.Kind? {
        position < tokens.count ? tokens[position].kind : nil
    }

    private mutating func advance() { position += 1 }

    private func isOperator(_ symbols: Set<String>) -> String? {
        if case .op(let op)? = current, symbols.contains(op) { return op }
        return nil
    }

    private mutating func parseComparison() throws -> Expr {
        var left = try parseConcat()
        while let op = isOperator(["=", "<>", "<", ">", "<=", ">="]) {
            advance()
            left = .binary(op, left, try parseConcat())
        }
        return left
    }

    private mutating func parseConcat() throws -> Expr {
        var left = try parseAdditive()
        while isOperator(["&"]) != nil {
            advance()
            left = .binary("&", left, try parseAdditive())
        }
        return left
    }

    private mutating func parseAdditive() throws -> Expr {
        var left = try parseMultiplicative()
        while let op = isOperator(["+", "-"]) {
            advance()
            left = .binary(op, left, try parseMultiplicative())
        }
        return left
    }

    private mutating func parseMultiplicative() throws -> Expr {
        var left = try parsePower()
        while let op = isOperator(["*", "/"]) {
            advance()
            left = .binary(op, left, try parsePower())
        }
        return left
    }

    private mutating func parsePower() throws -> Expr {
        var left = try parseUnary()
        while isOperator(["^"]) != nil {
            advance()
            left = .binary("^", left, try parseUnary())
        }
        return left
    }

    private mutating func parseUnary() throws -> Expr {
        if let op = isOperator(["-", "+"]) {
            advance()
            return .unary(op, try parseUnary())
        }
        return try parsePercent()
    }

    private mutating func parsePercent() throws -> Expr {
        var expression = try parseRangeOperator()
        while isOperator(["%"]) != nil {
            advance()
            expression = .percent(expression)
        }
        return expression
    }

    private mutating func parseRangeOperator() throws -> Expr {
        var left = try parsePrimary()
        while isOperator([":"]) != nil {
            advance()
            left = .binary(":", left, try parsePrimary())
        }
        return left
    }

    private mutating func parsePrimary() throws -> Expr {
        guard let token = current else { throw FormulaError.value }
        switch token {
        case .number(let value): advance(); return .number(value)
        case .string(let text): advance(); return .string(text)
        case .bool(let flag): advance(); return .bool(flag)
        case .error(let error): advance(); return .error(error)
        case .cell(let reference): advance(); return .cell(reference)
        case .range(let reference): advance(); return .range(reference)
        case .name(let name): advance(); return .name(name)
        case .leftParen:
            advance()
            let inner = try parseComparison()
            guard current == .rightParen else { throw FormulaError.value }
            advance()
            return inner
        case .function(let name):
            advance()
            guard current == .leftParen else { throw FormulaError.value }
            advance()
            var arguments: [Expr] = []
            if current == .rightParen {
                advance()
                return .call(name, arguments)
            }
            while true {
                if current == .comma || current == .semicolon {
                    arguments.append(.missing)
                } else if current == .rightParen {
                    arguments.append(.missing)
                } else {
                    arguments.append(try parseComparison())
                }
                if current == .comma || current == .semicolon {
                    advance()
                    continue
                }
                guard current == .rightParen else { throw FormulaError.value }
                advance()
                break
            }
            return .call(name, arguments)
        case .leftBrace:
            advance()
            var rows: [[Expr]] = [[]]
            while true {
                rows[rows.count - 1].append(try parseUnary())
                if current == .comma { advance(); continue }
                if current == .semicolon { advance(); rows.append([]); continue }
                guard current == .rightBrace else { throw FormulaError.value }
                advance()
                break
            }
            guard let width = rows.first?.count, rows.allSatisfy({ $0.count == width }) else { throw FormulaError.value }
            return .array(rows)
        default:
            throw FormulaError.value
        }
    }
}

extension Expr {
    /// Every reference the expression mentions, for dependency highlighting.
    var references: [(sheet: String?, range: CellRange)] {
        var result: [(String?, CellRange)] = []
        func walk(_ e: Expr) {
            switch e {
            case .cell(let r): result.append((r.sheet, CellRange(r.address)))
            case .range(let r): result.append((r.sheet, r.range))
            case .unary(_, let a), .percent(let a): walk(a)
            case .binary(_, let a, let b): walk(a); walk(b)
            case .call(_, let args): args.forEach(walk)
            case .array(let rows): rows.forEach { $0.forEach(walk) }
            default: break
            }
        }
        walk(self)
        return result
    }

    /// True when the formula uses NOW, RAND or other functions that change on every recalculation.
    var isVolatile: Bool {
        switch self {
        case .call(let name, let args):
            if ["NOW", "TODAY", "RAND", "RANDBETWEEN", "RANDARRAY", "OFFSET", "INDIRECT"].contains(name) { return true }
            return args.contains { $0.isVolatile }
        case .unary(_, let a), .percent(let a): return a.isVolatile
        case .binary(_, let a, let b): return a.isVolatile || b.isVolatile
        default: return false
        }
    }
}
