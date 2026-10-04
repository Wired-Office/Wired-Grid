import Foundation

extension FunctionLibrary {
    func registerLogical() {
        let v = FunctionLibrary.variadic

        register("IF", .logical, "IF(logical_test, [value_if_true], [value_if_false])", "Checks whether a condition is met, and returns one value if TRUE and another if FALSE.", args: 1...3) { c in
            let test = try c.value(0)
            let ev = c.evaluator
            if ev.isSingle(test) {
                let condition = ev.scalar(test)
                if case .error(let e) = condition { throw e }
                if try condition.asBool() {
                    return c.isMissing(1) ? (c.count > 1 ? .number(0) : .bool(true)) : try c.value(1)
                }
                return c.count > 2 ? (c.isMissing(2) ? .number(0) : try c.value(2)) : .bool(false)
            }
            // Array condition: choose element by element.
            let mask = ev.matrix(test)
            let yes = c.count > 1 ? ev.matrix(try c.value(1)) : Matrix(rows: 1, columns: 1, fill: .bool(true))
            let no = c.count > 2 ? ev.matrix(try c.value(2)) : Matrix(rows: 1, columns: 1, fill: .bool(false))
            var result = mask
            func pick(_ m: Matrix, _ r: Int, _ col: Int) -> CellValue {
                m[m.rows == 1 ? 0 : min(r, m.rows - 1), m.columns == 1 ? 0 : min(col, m.columns - 1)]
            }
            for r in 0..<mask.rows {
                for col in 0..<mask.columns {
                    let condition = mask[r, col]
                    if case .error = condition { result[r, col] = condition; continue }
                    let flag = (try? condition.asBool()) ?? false
                    result[r, col] = flag ? pick(yes, r, col) : pick(no, r, col)
                }
            }
            return .matrix(result)
        }
        register("IFS", .logical, "IFS(logical_test1, value_if_true1, …)", "Checks conditions in order and returns the value for the first TRUE one.", args: 2...v) { c in
            guard c.count % 2 == 0 else { throw FormulaError.value }
            var i = 0
            while i < c.count {
                if try c.strictScalar(i).asBool() { return try c.value(i + 1) }
                i += 2
            }
            throw FormulaError.na
        }
        register("IFERROR", .logical, "IFERROR(value, value_if_error)", "Returns value_if_error if the expression is an error, otherwise the value.", args: 2...2) { c in
            let value: FValue
            do { value = try c.value(0) } catch { return try c.value(1) }
            if c.evaluator.isSingle(value) {
                if case .error = c.evaluator.scalar(value) { return try c.value(1) }
                return value
            }
            let fallback = c.evaluator.scalar(try c.value(1))
            var m = c.evaluator.matrix(value)
            for i in m.values.indices { if case .error = m.values[i] { m.values[i] = fallback } }
            return .matrix(m)
        }
        register("IFNA", .logical, "IFNA(value, value_if_na)", "Returns value_if_na if the expression resolves to #N/A.", args: 2...2) { c in
            let value: FValue
            do { value = try c.value(0) } catch FormulaError.na { return try c.value(1) }
            if c.evaluator.isSingle(value) {
                if case .error(.na) = c.evaluator.scalar(value) { return try c.value(1) }
                return value
            }
            let fallback = c.evaluator.scalar(try c.value(1))
            var m = c.evaluator.matrix(value)
            for i in m.values.indices { if case .error(.na) = m.values[i] { m.values[i] = fallback } }
            return .matrix(m)
        }
        let logicalValues: (FunctionCall) throws -> [Bool] = { c in
            var result: [Bool] = []
            for i in 0..<c.count where !c.isMissing(i) {
                let value = try c.value(i)
                if case .scalar(let s) = value {
                    if case .error(let e) = s { throw e }
                    result.append(try s.asBool())
                } else {
                    for element in c.evaluator.matrix(value).values {
                        switch element {
                        case .bool(let b): result.append(b)
                        case .number(let n): result.append(n != 0)
                        case .error(let e): throw e
                        default: break
                        }
                    }
                }
            }
            guard !result.isEmpty else { throw FormulaError.value }
            return result
        }
        register("AND", .logical, "AND(logical1, [logical2], …)", "Returns TRUE if all arguments are TRUE.", args: 1...v) { c in
            .bool(try logicalValues(c).allSatisfy { $0 })
        }
        register("OR", .logical, "OR(logical1, [logical2], …)", "Returns TRUE if any argument is TRUE.", args: 1...v) { c in
            .bool(try logicalValues(c).contains(true))
        }
        register("XOR", .logical, "XOR(logical1, [logical2], …)", "Returns TRUE if an odd number of arguments are TRUE.", args: 1...v) { c in
            .bool(try logicalValues(c).filter { $0 }.count % 2 == 1)
        }
        register("NOT", .logical, "NOT(logical)", "Reverses the logic of its argument.", args: 1...1) { c in
            try c.lift(0) { v in
                if case .error = v { return v }
                return .bool(!(try v.asBool()))
            }
        }
        register("TRUE", .logical, "TRUE()", "Returns the logical value TRUE.", args: 0...0) { _ in .bool(true) }
        register("FALSE", .logical, "FALSE()", "Returns the logical value FALSE.", args: 0...0) { _ in .bool(false) }
        register("SWITCH", .logical, "SWITCH(expression, value1, result1, …, [default])", "Evaluates an expression against a list of values and returns the first match's result.", args: 3...v) { c in
            let target = try c.strictScalar(0)
            var i = 1
            while i + 1 < c.count {
                if compareValues(target, try c.scalar(i)) == 0 { return try c.value(i + 1) }
                i += 2
            }
            if i < c.count { return try c.value(i) }
            throw FormulaError.na
        }
        register("LET", .logical, "LET(name1, value1, [name2, value2], …, calculation)", "Assigns names to calculation results for use inside the formula.", args: 3...v) { c in
            guard c.count % 2 == 1 else { throw FormulaError.value }
            return try c.evaluator.withScope([:]) {
                var i = 0
                while i + 1 < c.count {
                    guard case .name(let name) = c.args[i] else { throw FormulaError.value }
                    c.evaluator.bind(name, try c.evaluator.evaluate(c.args[i + 1]))
                    i += 2
                }
                return try c.evaluator.evaluate(c.args[c.count - 1])
            }
        }
    }

    func registerInformation() {
        func test(_ name: String, _ summary: String, _ predicate: @escaping (CellValue) -> Bool) {
            register(name, .information, "\(name)(value)", summary, args: 1...1) { c in
                let value: FValue
                do { value = try c.value(0) } catch let e as FormulaError { return .bool(predicate(.error(e))) }
                return try c.evaluator.map(value) { .bool(predicate($0)) }
            }
        }
        test("ISBLANK", "Returns TRUE if the value is empty.") { $0.isEmpty }
        test("ISNUMBER", "Returns TRUE if the value is a number.") { $0.number != nil }
        test("ISTEXT", "Returns TRUE if the value is text.") { $0.isText }
        test("ISNONTEXT", "Returns TRUE if the value is not text.") { !$0.isText }
        test("ISLOGICAL", "Returns TRUE if the value is a logical value.") { if case .bool = $0 { return true }; return false }
        test("ISERROR", "Returns TRUE if the value is any error value.") { $0.isError }
        test("ISERR", "Returns TRUE if the value is any error except #N/A.") { if case .error(let e) = $0 { return e != .na }; return false }
        test("ISNA", "Returns TRUE if the value is the #N/A error.") { $0 == .error(.na) }

        register("ISEVEN", .information, "ISEVEN(number)", "Returns TRUE if the number is even.", args: 1...1) { c in
            .bool(Int(try c.number(0).rounded(.towardZero)) % 2 == 0)
        }
        register("ISODD", .information, "ISODD(number)", "Returns TRUE if the number is odd.", args: 1...1) { c in
            .bool(Int(try c.number(0).rounded(.towardZero)) % 2 != 0)
        }
        register("ISREF", .information, "ISREF(value)", "Returns TRUE if the value is a reference.", args: 1...1) { c in
            .bool((try? c.isReference(0)) ?? false)
        }
        register("ISFORMULA", .information, "ISFORMULA(reference)", "Returns TRUE if the referenced cell contains a formula.", args: 1...1) { c in
            let (sheet, range) = try c.reference(0)
            return .bool(c.evaluator.workbook.sheets[sheet].cells[range.start]?.formula != nil)
        }
        register("FORMULATEXT", .information, "FORMULATEXT(reference)", "Returns the formula in a cell as text.", args: 1...1) { c in
            let (sheet, range) = try c.reference(0)
            guard let formula = c.evaluator.workbook.sheets[sheet].cells[range.start]?.formula else { throw FormulaError.na }
            return .string("=" + formula)
        }
        register("N", .information, "N(value)", "Returns a value converted to a number.", args: 1...1) { c in
            switch try c.scalar(0) {
            case .number(let n): return .number(n)
            case .bool(let b): return .number(b ? 1 : 0)
            case .error(let e): throw e
            default: return .number(0)
            }
        }
        register("NA", .information, "NA()", "Returns the error value #N/A.", args: 0...0) { _ in .error(.na) }
        register("TYPE", .information, "TYPE(value)", "Returns a number indicating the data type of a value.", args: 1...1) { c in
            let value = try c.value(0)
            if !c.evaluator.isSingle(value) { return .number(64) }
            switch c.evaluator.scalar(value) {
            case .number, .empty: return .number(1)
            case .string: return .number(2)
            case .bool: return .number(4)
            case .error: return .number(16)
            }
        }
        register("ERROR.TYPE", .information, "ERROR.TYPE(error_val)", "Returns a number corresponding to an error type.", args: 1...1) { c in
            let value: CellValue
            do { value = try c.scalar(0) } catch let e as FormulaError { value = .error(e) }
            guard case .error(let e) = value else { throw FormulaError.na }
            return .number(Double(e.typeNumber))
        }
        register("SHEET", .information, "SHEET([value])", "Returns the sheet number of the referenced sheet.", args: 0...1) { c in
            if c.isMissing(0) { return .number(Double(c.evaluator.sheet + 1)) }
            if case .reference(let sheet, _) = try c.value(0) { return .number(Double(sheet + 1)) }
            let name = try c.text(0)
            guard let index = c.evaluator.workbook.sheetIndex(named: name) else { throw FormulaError.na }
            return .number(Double(index + 1))
        }
        register("SHEETS", .information, "SHEETS([reference])", "Returns the number of sheets in the workbook.", args: 0...1) { c in
            .number(Double(c.isMissing(0) ? c.evaluator.workbook.sheets.count : 1))
        }
        register("CELL", .information, "CELL(info_type, [reference])", "Returns information about the formatting, location or contents of a cell.", args: 1...2) { c in
            let info = try c.text(0).lowercased()
            let (sheetIndex, range) = c.isMissing(1) ? (c.evaluator.sheet, CellRange(c.evaluator.origin)) : try c.reference(1)
            let sheet = c.evaluator.workbook.sheets[sheetIndex]
            let address = range.start
            switch info {
            case "address": return .string("$" + CellAddress.columnName(address.column) + "$" + String(address.row + 1))
            case "row": return .number(Double(address.row + 1))
            case "col": return .number(Double(address.column + 1))
            case "contents": return .scalar(c.evaluator.calculator.value(sheet: sheetIndex, at: address))
            case "type":
                let v = c.evaluator.calculator.value(sheet: sheetIndex, at: address)
                return .string(v.isEmpty ? "b" : (v.isText ? "l" : "v"))
            case "format": return .string(sheet.style(at: address).numberFormat)
            case "width": return .number((sheet.columnWidth(address.column) / 7).rounded())
            case "filename": return .string(sheet.name)
            default: throw FormulaError.value
            }
        }
    }
}
