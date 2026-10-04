import Foundation

/// Evaluates every formula in a workbook and caches the results.
///
/// A full recalculation runs after each change. Formula cells are visited in
/// row-major order so the common top-down chains resolve without deep recursion,
/// and the pass runs on a thread with a large stack as a safety net for long
/// bottom-up chains. Dynamic-array results "spill" into the cells beside them.
final class Calculator {
    struct Key: Hashable {
        let sheet: Int
        let address: CellAddress
    }

    private struct Parsed {
        let text: String
        let result: Result<Expr, FormulaError>
    }

    private(set) var workbook: Workbook
    private var cache: [Key: CellValue] = [:]
    private var inProgress: Set<Key> = []
    private var parsed: [Key: Parsed] = [:]
    private(set) var spillValues: [Key: CellValue] = [:]
    private(set) var spillRanges: [Key: CellRange] = [:]
    private var previousSpillRanges: [Key: CellRange] = [:]
    private(set) var generation = 0
    /// NOW() and TODAY() are fixed for the length of one recalculation.
    private(set) var now = Date()

    init(workbook: Workbook) {
        self.workbook = workbook
    }

    func setWorkbook(_ workbook: Workbook) {
        self.workbook = workbook
    }

    // MARK: - Recalculation

    func recalculate() {
        let work = { [self] in
            now = Date()
            for _ in 0..<2 {
                previousSpillRanges = spillRanges
                cache.removeAll(keepingCapacity: true)
                spillValues.removeAll(keepingCapacity: true)
                spillRanges.removeAll(keepingCapacity: true)
                for (index, sheet) in workbook.sheets.enumerated() {
                    let formulas = sheet.cells.compactMap { $0.value.formula != nil ? $0.key : nil }.sorted()
                    for address in formulas { _ = value(sheet: index, at: address) }
                }
                // New or moved spills can change cells computed before them; one more pass settles it.
                if spillRanges == previousSpillRanges { break }
            }
            generation += 1
        }
        Calculator.runWithLargeStack(work)
    }

    /// Runs `body` synchronously on a thread with a 512 MB stack.
    static func runWithLargeStack(_ body: @escaping () -> Void) {
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            body()
            done.signal()
        }
        thread.stackSize = 512 << 20
        thread.start()
        done.wait()
    }

    // MARK: - Values

    func value(sheet: Int, at address: CellAddress) -> CellValue {
        guard workbook.sheets.indices.contains(sheet) else { return .error(.ref) }
        let key = Key(sheet: sheet, address: address)
        let cell = workbook.sheets[sheet].cells[address]
        if let formula = cell?.formula {
            if let cached = cache[key] { return cached }
            if inProgress.contains(key) { return .error(.circular) }
            inProgress.insert(key)
            let result = evaluateFormulaCell(key: key, formula: formula)
            inProgress.remove(key)
            cache[key] = result
            return result
        }
        if let cell, cell.hasContent { return cell.value }
        if let spilled = spillValues[key] { return spilled }
        if !previousSpillRanges.isEmpty {
            // This cell may belong to a spill whose anchor hasn't been computed yet.
            for (anchor, range) in previousSpillRanges where anchor.sheet == sheet && anchor != key && range.contains(address) {
                _ = value(sheet: anchor.sheet, at: anchor.address)
                if let spilled = spillValues[key] { return spilled }
            }
        }
        return .empty
    }

    /// The parsed formula of a cell, if it has one and it parses.
    func expression(sheet: Int, at address: CellAddress) -> Expr? {
        guard workbook.sheets.indices.contains(sheet),
              let formula = workbook.sheets[sheet].cells[address]?.formula else { return nil }
        return try? parse(Key(sheet: sheet, address: address), formula).get()
    }

    /// The spill range anchored at a cell, if its result spilled.
    func spillRange(sheet: Int, anchor: CellAddress) -> CellRange? {
        spillRanges[Key(sheet: sheet, address: anchor)]
    }

    /// The anchor of the spill covering a cell, if any.
    func spillAnchor(sheet: Int, covering address: CellAddress) -> CellAddress? {
        for (anchor, range) in spillRanges where anchor.sheet == sheet && range.contains(address) {
            return anchor.address
        }
        return nil
    }

    /// Evaluates a formula as if it were in the given cell, without storing it.
    func evaluate(formula: String, sheet: Int, at address: CellAddress) -> CellValue {
        let expression: Expr
        do { expression = try FormulaParser.parse(formula) } catch { return .error(error as? FormulaError ?? .name) }
        // Dependencies are already cached after a recalculation, so this stays shallow.
        let evaluator = Evaluator(calculator: self, sheet: sheet, origin: address)
        do {
            return collapse(try evaluator.evaluate(expression), evaluator: evaluator)
        } catch {
            return .error(error as? FormulaError ?? .value)
        }
    }

    private func collapse(_ value: FValue, evaluator: Evaluator) -> CellValue {
        let scalar = evaluator.scalar(value)
        return scalar.isEmpty ? .number(0) : scalar
    }

    // MARK: - Formula cells

    private func parse(_ key: Key, _ formula: String) -> Result<Expr, FormulaError> {
        if let existing = parsed[key], existing.text == formula { return existing.result }
        let result: Result<Expr, FormulaError>
        do {
            result = .success(try FormulaParser.parse(formula))
        } catch {
            result = .failure(error as? FormulaError ?? .name)
        }
        parsed[key] = Parsed(text: formula, result: result)
        return result
    }

    private func evaluateFormulaCell(key: Key, formula: String) -> CellValue {
        let expression: Expr
        switch parse(key, formula) {
        case .success(let e): expression = e
        case .failure(let error): return .error(error)
        }
        let evaluator = Evaluator(calculator: self, sheet: key.sheet, origin: key.address)
        let result: FValue
        do {
            result = try evaluator.evaluate(expression)
        } catch {
            return .error(error as? FormulaError ?? .value)
        }
        switch result {
        case .scalar(let v):
            return v.isEmpty ? .number(0) : v
        case .reference(let sheet, let range):
            if range.isSingleCell {
                let v = value(sheet: sheet, at: range.start)
                return v.isEmpty ? .number(0) : v
            }
            return spill(evaluator.matrix(result), from: key)
        case .matrix(let m):
            if m.rows == 1 && m.columns == 1 {
                return m.values[0].isEmpty ? .number(0) : m.values[0]
            }
            if m.count == 0 { return .error(.calc) }
            return spill(m, from: key)
        }
    }

    private func spill(_ matrix: Matrix, from key: Key) -> CellValue {
        let anchor = key.address
        let end = anchor.offset(rows: matrix.rows - 1, columns: matrix.columns - 1)
        guard end.isValid else { return .error(.spill) }
        let target = CellRange(anchor, end)
        let sheet = workbook.sheets[key.sheet]
        for address in target.addresses where address != anchor {
            if sheet.cells[address]?.hasContent == true { return .error(.spill) }
        }
        for (other, range) in spillRanges where other.sheet == key.sheet && other != key && range.intersects(target) {
            return .error(.spill)
        }
        spillRanges[key] = target
        for r in 0..<matrix.rows {
            for c in 0..<matrix.columns where r > 0 || c > 0 {
                let v = matrix[r, c]
                spillValues[Key(sheet: key.sheet, address: anchor.offset(rows: r, columns: c))] = v.isEmpty ? .number(0) : v
            }
        }
        return matrix.values[0].isEmpty ? .number(0) : matrix.values[0]
    }
}

// MARK: - Evaluator

/// Evaluates one expression in the context of a cell.
final class Evaluator {
    unowned let calculator: Calculator
    let sheet: Int
    let origin: CellAddress
    private var scopes: [[String: FValue]] = []

    init(calculator: Calculator, sheet: Int, origin: CellAddress) {
        self.calculator = calculator
        self.sheet = sheet
        self.origin = origin
    }

    var workbook: Workbook { calculator.workbook }

    func sheetIndex(_ name: String?) throws -> Int {
        guard let name else { return sheet }
        guard let index = workbook.sheetIndex(named: name) else { throw FormulaError.ref }
        return index
    }

    func evaluate(_ expression: Expr) throws -> FValue {
        switch expression {
        case .number(let v): return .scalar(.number(v))
        case .string(let s): return .scalar(.string(s))
        case .bool(let b): return .scalar(.bool(b))
        case .error(let e): return .scalar(.error(e))
        case .missing: return .empty
        case .cell(let r):
            return .reference(sheet: try sheetIndex(r.sheet), range: CellRange(r.address))
        case .range(let r):
            return .reference(sheet: try sheetIndex(r.sheet), range: r.range)
        case .name(let name):
            return try resolveName(name)
        case .unary(let op, let operand):
            let value = try evaluate(operand)
            return try map(value) { v in
                if case .error = v { return v }
                let n = try v.asNumber()
                return .number(op == "-" ? -n : n)
            }
        case .percent(let operand):
            return try map(try evaluate(operand)) { v in
                if case .error = v { return v }
                return .number(try v.asNumber() / 100)
            }
        case .binary(":", let a, let b):
            guard case .reference(let s1, let r1) = try evaluate(a),
                  case .reference(let s2, let r2) = try evaluate(b), s1 == s2 else { throw FormulaError.value }
            return .reference(sheet: s1, range: r1.union(r2))
        case .binary(let op, let a, let b):
            return try binary(op, try evaluate(a), try evaluate(b))
        case .call(let name, let args):
            return try call(name, args)
        case .array(let rows):
            var values: [[CellValue]] = []
            for row in rows {
                values.append(try row.map { scalar(try evaluate($0)) })
            }
            return .matrix(Matrix(values))
        }
    }

    // MARK: Names and LET

    func withScope<T>(_ bindings: [String: FValue], _ body: () throws -> T) rethrows -> T {
        scopes.append(bindings)
        defer { scopes.removeLast() }
        return try body()
    }

    func bind(_ name: String, _ value: FValue) {
        if scopes.isEmpty { scopes.append([:]) }
        scopes[scopes.count - 1][name.uppercased()] = value
    }

    private func resolveName(_ name: String) throws -> FValue {
        let key = name.uppercased()
        for scope in scopes.reversed() {
            if let value = scope[key] { return value }
        }
        if let defined = workbook.definedName(name) {
            let expression = try FormulaParser.parse(defined.formula)
            return try evaluate(expression)
        }
        throw FormulaError.name
    }

    // MARK: Functions

    private func call(_ rawName: String, _ args: [Expr]) throws -> FValue {
        var name = rawName
        for prefix in ["_XLFN._XLWS.", "_XLFN.", "_XLWS."] where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
        }
        guard let spec = FunctionLibrary.shared.function(named: name) else { throw FormulaError.name }
        if args.count < spec.minArgs || args.count > spec.maxArgs {
            throw FormulaError.value
        }
        return try spec.implementation(FunctionCall(evaluator: self, args: args))
    }

    // MARK: Materializing

    /// A reference's cells as values (whole rows/columns are trimmed to the used area).
    func matrix(sheet index: Int, range: CellRange) -> Matrix {
        let range = trimmed(range, sheet: index)
        var values: [CellValue] = []
        values.reserveCapacity(range.cellCount)
        for row in range.rows {
            for column in range.columns {
                values.append(calculator.value(sheet: index, at: CellAddress(row: row, column: column)))
            }
        }
        return Matrix(rows: range.rowCount, columns: range.columnCount, values: values)
    }

    func trimmed(_ range: CellRange, sheet index: Int) -> CellRange {
        guard range.isWholeColumns || range.isWholeRows, workbook.sheets.indices.contains(index) else { return range }
        var extent = workbook.sheets[index].contentExtent
        for (anchor, spill) in calculator.spillRanges where anchor.sheet == index {
            extent = CellAddress(row: max(extent.row, spill.maxRow), column: max(extent.column, spill.maxColumn))
        }
        let maxRow = range.isWholeColumns ? min(range.maxRow, max(extent.row, range.minRow)) : range.maxRow
        let maxColumn = range.isWholeRows ? min(range.maxColumn, max(extent.column, range.minColumn)) : range.maxColumn
        return CellRange(range.start, CellAddress(row: maxRow, column: maxColumn))
    }

    func matrix(_ value: FValue) -> Matrix {
        switch value {
        case .scalar(let v): return Matrix(rows: 1, columns: 1, values: [v])
        case .matrix(let m): return m
        case .reference(let s, let r): return matrix(sheet: s, range: r)
        }
    }

    /// A single value; multi-cell references use implicit intersection with the formula's row or column.
    func scalar(_ value: FValue) -> CellValue {
        switch value {
        case .scalar(let v): return v
        case .matrix(let m): return m.values.first ?? .empty
        case .reference(let s, let r):
            if r.isSingleCell { return calculator.value(sheet: s, at: r.start) }
            if r.columnCount == 1, r.rows.contains(origin.row) {
                return calculator.value(sheet: s, at: CellAddress(row: origin.row, column: r.minColumn))
            }
            if r.rowCount == 1, r.columns.contains(origin.column) {
                return calculator.value(sheet: s, at: CellAddress(row: r.minRow, column: origin.column))
            }
            return calculator.value(sheet: s, at: r.start)
        }
    }

    func isSingle(_ value: FValue) -> Bool {
        switch value {
        case .scalar: true
        case .matrix(let m): m.count == 1
        case .reference(_, let r): r.isSingleCell
        }
    }

    /// Applies `transform` to every element (or the single value).
    func map(_ value: FValue, _ transform: (CellValue) throws -> CellValue) throws -> FValue {
        if isSingle(value) {
            return .scalar(try guarded(scalar(value), transform))
        }
        var m = matrix(value)
        for i in m.values.indices { m.values[i] = try guarded(m.values[i], transform) }
        return .matrix(m)
    }

    private func guarded(_ v: CellValue, _ transform: (CellValue) throws -> CellValue) throws -> CellValue {
        do {
            return try transform(v)
        } catch let error as FormulaError {
            return .error(error)
        }
    }

    // MARK: Operators

    func binary(_ op: String, _ left: FValue, _ right: FValue) throws -> FValue {
        if isSingle(left) && isSingle(right) {
            return .scalar(Evaluator.apply(op, scalar(left), scalar(right)))
        }
        let a = matrix(left), b = matrix(right)
        let rows = max(a.rows, b.rows), columns = max(a.columns, b.columns)
        func element(_ m: Matrix, _ r: Int, _ c: Int) -> CellValue {
            let rr = m.rows == 1 ? 0 : r, cc = m.columns == 1 ? 0 : c
            guard rr < m.rows, cc < m.columns else { return .error(.na) }
            return m[rr, cc]
        }
        var result = Matrix(rows: rows, columns: columns)
        for r in 0..<rows {
            for c in 0..<columns {
                result[r, c] = Evaluator.apply(op, element(a, r, c), element(b, r, c))
            }
        }
        return .matrix(result)
    }

    static func apply(_ op: String, _ a: CellValue, _ b: CellValue) -> CellValue {
        if case .error = a { return a }
        if case .error = b { return b }
        switch op {
        case "&":
            return .string(((try? a.asText()) ?? "") + ((try? b.asText()) ?? ""))
        case "=": return .bool(compareValues(a, b) == 0)
        case "<>": return .bool(compareValues(a, b) != 0)
        case "<": return .bool(compareValues(a, b) < 0)
        case ">": return .bool(compareValues(a, b) > 0)
        case "<=": return .bool(compareValues(a, b) <= 0)
        case ">=": return .bool(compareValues(a, b) >= 0)
        default: break
        }
        guard let x = try? a.asNumber(), let y = try? b.asNumber() else { return .error(.value) }
        let result: Double
        switch op {
        case "+": result = x + y
        case "-": result = x - y
        case "*": result = x * y
        case "/":
            if y == 0 { return .error(.div0) }
            result = x / y
        case "^":
            if x == 0 && y < 0 { return .error(.div0) }
            result = pow(x, y)
        default: return .error(.value)
        }
        return result.isFinite ? .number(result) : .error(.num)
    }
}
