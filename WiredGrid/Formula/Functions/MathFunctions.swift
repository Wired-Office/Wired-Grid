import Foundation

/// Excel-style rounding: half away from zero, after trimming binary noise to 15 digits.
func excelRound(_ x: Double, _ digits: Int, mode: FloatingPointRoundingRule = .toNearestOrAwayFromZero) -> Double {
    let factor = pow(10, Double(digits))
    var scaled = x * factor
    if let cleaned = Double(String(format: "%.15g", scaled)) { scaled = cleaned }
    return scaled.rounded(mode) / factor
}

private func factorial(_ n: Int) -> Double {
    guard n >= 0 else { return .nan }
    if n > 170 { return .infinity }
    return n < 2 ? 1 : (2...n).reduce(1.0) { $0 * Double($1) }
}

private func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? abs(a) : gcd(b, a % b) }

extension FunctionLibrary {
    func registerMath() {
        let v = FunctionLibrary.variadic

        register("SUM", .math, "SUM(number1, [number2], …)", "Adds all the numbers in a range of cells.", args: 1...v) { c in
            numberResult(try c.numbers().reduce(0, +))
        }
        register("SUMSQ", .math, "SUMSQ(number1, [number2], …)", "Returns the sum of the squares of the arguments.", args: 1...v) { c in
            numberResult(try c.numbers().reduce(0) { $0 + $1 * $1 })
        }
        register("PRODUCT", .math, "PRODUCT(number1, [number2], …)", "Multiplies all the numbers given as arguments.", args: 1...v) { c in
            let numbers = try c.numbers()
            return numberResult(numbers.isEmpty ? 0 : numbers.reduce(1, *))
        }
        register("ABS", .math, "ABS(number)", "Returns the absolute value of a number.", args: 1...1) { c in
            try c.liftNumber { abs($0) }
        }
        register("SIGN", .math, "SIGN(number)", "Returns the sign of a number: 1, 0 or -1.", args: 1...1) { c in
            try c.liftNumber { $0 > 0 ? 1 : ($0 < 0 ? -1 : 0) }
        }
        register("SQRT", .math, "SQRT(number)", "Returns a positive square root.", args: 1...1) { c in
            try c.liftNumber { n in guard n >= 0 else { throw FormulaError.num }; return n.squareRoot() }
        }
        register("SQRTPI", .math, "SQRTPI(number)", "Returns the square root of (number × π).", args: 1...1) { c in
            try c.liftNumber { n in guard n >= 0 else { throw FormulaError.num }; return (n * .pi).squareRoot() }
        }
        register("POWER", .math, "POWER(number, power)", "Returns the result of a number raised to a power.", args: 2...2) { c in
            let b = try c.number(0), e = try c.number(1)
            if b == 0 && e < 0 { throw FormulaError.div0 }
            return numberResult(pow(b, e))
        }
        register("EXP", .math, "EXP(number)", "Returns e raised to the power of a given number.", args: 1...1) { c in
            try c.liftNumber { exp($0) }
        }
        register("LN", .math, "LN(number)", "Returns the natural logarithm of a number.", args: 1...1) { c in
            try c.liftNumber { n in guard n > 0 else { throw FormulaError.num }; return log(n) }
        }
        register("LOG10", .math, "LOG10(number)", "Returns the base-10 logarithm of a number.", args: 1...1) { c in
            try c.liftNumber { n in guard n > 0 else { throw FormulaError.num }; return log10(n) }
        }
        register("LOG", .math, "LOG(number, [base])", "Returns the logarithm of a number to the base you specify.", args: 1...2) { c in
            let n = try c.number(0), b = try c.number(1, default: 10)
            guard n > 0, b > 0, b != 1 else { throw FormulaError.num }
            return numberResult(log(n) / log(b))
        }
        register("MOD", .math, "MOD(number, divisor)", "Returns the remainder after a number is divided by a divisor.", args: 2...2) { c in
            let n = try c.number(0), d = try c.number(1)
            guard d != 0 else { throw FormulaError.div0 }
            return numberResult(n - d * (n / d).rounded(.down))
        }
        register("QUOTIENT", .math, "QUOTIENT(numerator, denominator)", "Returns the integer portion of a division.", args: 2...2) { c in
            let n = try c.number(0), d = try c.number(1)
            guard d != 0 else { throw FormulaError.div0 }
            return numberResult((n / d).rounded(.towardZero))
        }
        register("INT", .math, "INT(number)", "Rounds a number down to the nearest integer.", args: 1...1) { c in
            try c.liftNumber { $0.rounded(.down) }
        }
        register("TRUNC", .math, "TRUNC(number, [num_digits])", "Truncates a number to an integer or to a number of digits.", args: 1...2) { c in
            let digits = try c.int(1, default: 0)
            return try c.liftNumber { excelRound($0, digits, mode: .towardZero) }
        }
        register("ROUND", .math, "ROUND(number, num_digits)", "Rounds a number to a specified number of digits.", args: 2...2) { c in
            let digits = try c.int(1)
            return try c.liftNumber { excelRound($0, digits) }
        }
        register("ROUNDUP", .math, "ROUNDUP(number, num_digits)", "Rounds a number up, away from zero.", args: 2...2) { c in
            let digits = try c.int(1)
            return try c.liftNumber { excelRound($0, digits, mode: .awayFromZero) }
        }
        register("ROUNDDOWN", .math, "ROUNDDOWN(number, num_digits)", "Rounds a number down, toward zero.", args: 2...2) { c in
            let digits = try c.int(1)
            return try c.liftNumber { excelRound($0, digits, mode: .towardZero) }
        }
        register("MROUND", .math, "MROUND(number, multiple)", "Returns a number rounded to the desired multiple.", args: 2...2) { c in
            let n = try c.number(0), m = try c.number(1)
            if m == 0 { return .number(0) }
            guard n * m >= 0 else { throw FormulaError.num }
            return numberResult(excelRound(n / m, 0) * m)
        }
        let ceiling: (Double, Double) throws -> Double = { n, s in
            if s == 0 { return 0 }
            if n > 0 && s < 0 { throw FormulaError.num }
            return (n / s).rounded(.up) * s
        }
        register("CEILING", .math, "CEILING(number, significance)", "Rounds a number up to the nearest multiple of significance.", args: 2...2) { c in
            numberResult(try ceiling(try c.number(0), try c.number(1)))
        }
        register("CEILING.MATH", .math, "CEILING.MATH(number, [significance], [mode])", "Rounds a number up to the nearest integer or multiple.", args: 1...3) { c in
            let n = try c.number(0), s = abs(try c.number(1, default: 1)), mode = try c.number(2, default: 0)
            if s == 0 { return .number(0) }
            if n < 0 && mode != 0 { return numberResult((n / s).rounded(.down) * s) }
            return numberResult((n / s).rounded(.up) * s)
        }
        register("FLOOR", .math, "FLOOR(number, significance)", "Rounds a number down toward zero to a multiple of significance.", args: 2...2) { c in
            let n = try c.number(0), s = try c.number(1)
            if s == 0 { throw FormulaError.div0 }
            if n > 0 && s < 0 { throw FormulaError.num }
            return numberResult((n / s).rounded(.down) * s)
        }
        register("FLOOR.MATH", .math, "FLOOR.MATH(number, [significance], [mode])", "Rounds a number down to the nearest integer or multiple.", args: 1...3) { c in
            let n = try c.number(0), s = abs(try c.number(1, default: 1)), mode = try c.number(2, default: 0)
            if s == 0 { return .number(0) }
            if n < 0 && mode != 0 { return numberResult((n / s).rounded(.up) * s) }
            return numberResult((n / s).rounded(.down) * s)
        }
        register("EVEN", .math, "EVEN(number)", "Rounds a number up to the nearest even integer.", args: 1...1) { c in
            try c.liftNumber { n in
                let r = (abs(n) / 2).rounded(.up) * 2
                return n < 0 ? -r : r
            }
        }
        register("ODD", .math, "ODD(number)", "Rounds a number up to the nearest odd integer.", args: 1...1) { c in
            try c.liftNumber { n in
                var r = abs(n).rounded(.up)
                if r.truncatingRemainder(dividingBy: 2) == 0 { r += 1 }
                return n < 0 ? -r : r
            }
        }
        register("PI", .math, "PI()", "Returns the value of π.", args: 0...0) { _ in .number(.pi) }
        register("RAND", .math, "RAND()", "Returns a random number between 0 and 1.", args: 0...0) { _ in
            .number(Double.random(in: 0..<1))
        }
        register("RANDBETWEEN", .math, "RANDBETWEEN(bottom, top)", "Returns a random integer between the numbers you specify.", args: 2...2) { c in
            let low = try c.number(0).rounded(.up), high = try c.number(1).rounded(.down)
            guard low <= high else { throw FormulaError.num }
            return .number(Double(Int.random(in: Int(low)...Int(high))))
        }
        register("RANDARRAY", .math, "RANDARRAY([rows], [columns], [min], [max], [integer])", "Returns an array of random numbers.", args: 0...5) { c in
            let rows = try c.int(0, default: 1), columns = try c.int(1, default: 1)
            let low = try c.number(2, default: 0), high = try c.number(3, default: 1)
            let integer = try c.bool(4, default: false)
            guard rows > 0, columns > 0, rows * columns <= 1_000_000, low <= high else { throw FormulaError.value }
            let values = (0..<(rows * columns)).map { _ -> CellValue in
                integer ? .number(Double(Int.random(in: Int(low)...Int(high)))) : .number(Double.random(in: low..<max(high, low + .ulpOfOne)))
            }
            return .matrix(Matrix(rows: rows, columns: columns, values: values))
        }
        register("SEQUENCE", .math, "SEQUENCE(rows, [columns], [start], [step])", "Generates a list of sequential numbers in an array.", args: 1...4) { c in
            let rows = try c.int(0), columns = try c.int(1, default: 1)
            let start = try c.number(2, default: 1), step = try c.number(3, default: 1)
            guard rows > 0, columns > 0, rows * columns <= 1_000_000 else { throw FormulaError.value }
            let values = (0..<(rows * columns)).map { CellValue.number(start + Double($0) * step) }
            return .matrix(Matrix(rows: rows, columns: columns, values: values))
        }
        register("FACT", .math, "FACT(number)", "Returns the factorial of a number.", args: 1...1) { c in
            let n = try c.number(0)
            guard n >= 0 else { throw FormulaError.num }
            return numberResult(factorial(Int(n)))
        }
        register("FACTDOUBLE", .math, "FACTDOUBLE(number)", "Returns the double factorial of a number.", args: 1...1) { c in
            let n = Int(try c.number(0))
            guard n >= -1 else { throw FormulaError.num }
            var r = 1.0
            var k = n
            while k > 1 { r *= Double(k); k -= 2 }
            return numberResult(r)
        }
        register("COMBIN", .math, "COMBIN(number, number_chosen)", "Returns the number of combinations for a given number of items.", args: 2...2) { c in
            let n = Int(try c.number(0)), k = Int(try c.number(1))
            guard n >= 0, k >= 0, k <= n else { throw FormulaError.num }
            var r = 1.0
            for i in 0..<min(k, n - k) { r = r * Double(n - i) / Double(i + 1) }
            return numberResult(r.rounded())
        }
        register("COMBINA", .math, "COMBINA(number, number_chosen)", "Returns the number of combinations with repetitions.", args: 2...2) { c in
            let n = Int(try c.number(0)), k = Int(try c.number(1))
            guard n >= 0, k >= 0 else { throw FormulaError.num }
            if n == 0 && k == 0 { return .number(1) }
            let total = n + k - 1
            var r = 1.0
            for i in 0..<min(k, total - k) { r = r * Double(total - i) / Double(i + 1) }
            return numberResult(r.rounded())
        }
        register("PERMUT", .math, "PERMUT(number, number_chosen)", "Returns the number of permutations for a given number of objects.", args: 2...2) { c in
            let n = Int(try c.number(0)), k = Int(try c.number(1))
            guard n >= 0, k >= 0, k <= n else { throw FormulaError.num }
            var r = 1.0
            for i in 0..<k { r *= Double(n - i) }
            return numberResult(r)
        }
        register("GCD", .math, "GCD(number1, [number2], …)", "Returns the greatest common divisor.", args: 1...v) { c in
            let numbers = try c.numbers().map { Int($0) }
            guard numbers.allSatisfy({ $0 >= 0 }) else { throw FormulaError.num }
            return .number(Double(numbers.reduce(0, gcd)))
        }
        register("LCM", .math, "LCM(number1, [number2], …)", "Returns the least common multiple.", args: 1...v) { c in
            let numbers = try c.numbers().map { Int($0) }
            guard numbers.allSatisfy({ $0 >= 0 }) else { throw FormulaError.num }
            if numbers.contains(0) { return .number(0) }
            return numberResult(Double(numbers.reduce(1) { a, b in a / gcd(a, b) * b }))
        }
        register("DEGREES", .math, "DEGREES(angle)", "Converts radians to degrees.", args: 1...1) { c in
            try c.liftNumber { $0 * 180 / .pi }
        }
        register("RADIANS", .math, "RADIANS(angle)", "Converts degrees to radians.", args: 1...1) { c in
            try c.liftNumber { $0 * .pi / 180 }
        }
        let trig: [(String, String, (Double) throws -> Double)] = [
            ("SIN", "Returns the sine of an angle.", { sin($0) }),
            ("COS", "Returns the cosine of an angle.", { cos($0) }),
            ("TAN", "Returns the tangent of an angle.", { tan($0) }),
            ("ASIN", "Returns the arcsine of a number.", { n in guard abs(n) <= 1 else { throw FormulaError.num }; return asin(n) }),
            ("ACOS", "Returns the arccosine of a number.", { n in guard abs(n) <= 1 else { throw FormulaError.num }; return acos(n) }),
            ("ATAN", "Returns the arctangent of a number.", { atan($0) }),
            ("SINH", "Returns the hyperbolic sine of a number.", { sinh($0) }),
            ("COSH", "Returns the hyperbolic cosine of a number.", { cosh($0) }),
            ("TANH", "Returns the hyperbolic tangent of a number.", { tanh($0) }),
            ("ASINH", "Returns the inverse hyperbolic sine of a number.", { asinh($0) }),
            ("ACOSH", "Returns the inverse hyperbolic cosine of a number.", { n in guard n >= 1 else { throw FormulaError.num }; return acosh(n) }),
            ("ATANH", "Returns the inverse hyperbolic tangent of a number.", { n in guard abs(n) < 1 else { throw FormulaError.num }; return atanh(n) }),
            ("COT", "Returns the cotangent of an angle.", { n in guard n != 0 else { throw FormulaError.div0 }; return 1 / tan(n) }),
            ("CSC", "Returns the cosecant of an angle.", { n in guard n != 0 else { throw FormulaError.div0 }; return 1 / sin(n) }),
            ("SEC", "Returns the secant of an angle.", { 1 / cos($0) }),
        ]
        for (name, summary, f) in trig {
            register(name, .math, "\(name)(number)", summary, args: 1...1) { c in try c.liftNumber(0, f) }
        }
        register("ATAN2", .math, "ATAN2(x_num, y_num)", "Returns the arctangent from x- and y-coordinates.", args: 2...2) { c in
            let x = try c.number(0), y = try c.number(1)
            guard x != 0 || y != 0 else { throw FormulaError.div0 }
            return numberResult(atan2(y, x))
        }
        register("SUMPRODUCT", .math, "SUMPRODUCT(array1, [array2], …)", "Returns the sum of the products of corresponding array components.", args: 1...v) { c in
            let arrays = try (0..<c.count).map { try c.matrix($0) }
            guard let first = arrays.first, arrays.allSatisfy({ $0.rows == first.rows && $0.columns == first.columns }) else {
                throw FormulaError.value
            }
            var total = 0.0
            for i in 0..<first.count {
                var product = 1.0
                for array in arrays {
                    switch array.values[i] {
                    case .number(let n): product *= n
                    case .error(let e): throw e
                    default: product = 0
                    }
                }
                total += product
            }
            return numberResult(total)
        }
        register("SUMIF", .math, "SUMIF(range, criteria, [sum_range])", "Adds the cells specified by a given condition.", args: 2...3) { c in
            let range = try c.matrix(0)
            let criterion = Criterion(try c.strictScalar(1))
            let sums = c.isMissing(2) ? range : try Self.resized(c, 2, like: range)
            var total = 0.0
            for i in 0..<range.count where criterion.matches(range.values[i]) {
                if case .number(let n) = sums.values[i] { total += n }
            }
            return numberResult(total)
        }
        register("SUMIFS", .math, "SUMIFS(sum_range, criteria_range1, criteria1, …)", "Adds the cells that meet multiple conditions.", args: 3...v) { c in
            let sums = try c.matrix(0)
            let mask = try Self.criteriaMask(c, from: 1, size: sums)
            var total = 0.0
            for i in 0..<sums.count where mask[i] {
                if case .number(let n) = sums.values[i] { total += n }
            }
            return numberResult(total)
        }
        register("SUBTOTAL", .math, "SUBTOTAL(function_num, ref1, [ref2], …)", "Returns a subtotal, ignoring rows hidden by filters.", args: 2...v) { c in
            let code = try c.int(0)
            let ignoreManual = code > 100
            let function = code % 100
            var values: [Double] = []
            var countA = 0
            for index in 1..<c.count {
                let (sheetIndex, range) = try c.reference(index)
                let sheet = c.evaluator.workbook.sheets[sheetIndex]
                let trimmed = c.evaluator.trimmed(range, sheet: sheetIndex)
                for row in trimmed.rows {
                    if sheet.filter?.hiddenRows.contains(row) == true { continue }
                    if ignoreManual && sheet.hiddenRows.contains(row) { continue }
                    for column in trimmed.columns {
                        let address = CellAddress(row: row, column: column)
                        // Skip nested SUBTOTALs, as Excel does.
                        if let formula = sheet.cells[address]?.formula, formula.uppercased().contains("SUBTOTAL(") { continue }
                        let value = c.evaluator.calculator.value(sheet: sheetIndex, at: address)
                        if case .error(let e) = value { throw e }
                        if !value.isEmpty { countA += 1 }
                        if case .number(let n) = value { values.append(n) }
                    }
                }
            }
            return try Statistics.aggregate(function, values, countA: countA)
        }
        register("AGGREGATE", .math, "AGGREGATE(function_num, options, ref1, …)", "Returns an aggregate, optionally ignoring errors and hidden rows.", args: 3...v) { c in
            let function = try c.int(0)
            let options = try c.int(1)
            let ignoreErrors = [2, 3, 6, 7].contains(options)
            var values: [Double] = []
            var countA = 0
            for index in 2..<c.count {
                for value in try c.flat(index) {
                    switch value {
                    case .number(let n): values.append(n); countA += 1
                    case .error(let e): if !ignoreErrors { throw e }
                    case .empty: break
                    default: countA += 1
                    }
                }
            }
            if function >= 14 && function <= 19 && c.count > 3 {
                let k = try c.number(3)
                let sorted = values.sorted()
                guard !sorted.isEmpty else { throw FormulaError.num }
                switch function {
                case 14: guard k >= 1, Int(k) <= sorted.count else { throw FormulaError.num }; return .number(sorted[sorted.count - Int(k)])
                case 15: guard k >= 1, Int(k) <= sorted.count else { throw FormulaError.num }; return .number(sorted[Int(k) - 1])
                case 16, 18: return numberResult(try Statistics.percentile(sorted, k, exclusive: function == 18))
                default: return numberResult(try Statistics.percentile(sorted, k / 4, exclusive: function == 19))
                }
            }
            return try Statistics.aggregate(function, values, countA: countA)
        }
        register("ROMAN", .math, "ROMAN(number)", "Converts an Arabic numeral to Roman, as text.", args: 1...2) { c in
            var n = try c.int(0)
            guard n >= 0, n < 4000 else { throw FormulaError.value }
            let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
                                          (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
            var result = ""
            for (value, numeral) in table { while n >= value { result += numeral; n -= value } }
            return .string(result)
        }
        register("ARABIC", .math, "ARABIC(text)", "Converts a Roman numeral to Arabic.", args: 1...1) { c in
            let text = try c.text(0).uppercased().trimmingCharacters(in: .whitespaces)
            let values: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000]
            var total = 0, previous = 0
            for ch in text.reversed() {
                guard let value = values[ch] else { throw FormulaError.value }
                total += value < previous ? -value : value
                previous = max(previous, value)
            }
            return .number(Double(total))
        }
        register("BASE", .math, "BASE(number, radix, [min_length])", "Converts a number into text in the given base.", args: 2...3) { c in
            let n = try c.int(0), radix = try c.int(1), length = try c.int(2, default: 0)
            guard n >= 0, (2...36).contains(radix) else { throw FormulaError.num }
            var s = String(n, radix: radix).uppercased()
            if s.count < length { s = String(repeating: "0", count: length - s.count) + s }
            return .string(s)
        }
        register("DECIMAL", .math, "DECIMAL(text, radix)", "Converts text in a given base to a decimal number.", args: 2...2) { c in
            let text = try c.text(0), radix = try c.int(1)
            guard (2...36).contains(radix), let n = Int(text, radix: radix) else { throw FormulaError.num }
            return .number(Double(n))
        }
        register("MMULT", .math, "MMULT(array1, array2)", "Returns the matrix product of two arrays.", args: 2...2) { c in
            let a = try c.matrix(0), b = try c.matrix(1)
            guard a.columns == b.rows else { throw FormulaError.value }
            var result = Matrix(rows: a.rows, columns: b.columns)
            for i in 0..<a.rows {
                for j in 0..<b.columns {
                    var sum = 0.0
                    for k in 0..<a.columns {
                        guard case .number(let x) = a[i, k], case .number(let y) = b[k, j] else { throw FormulaError.value }
                        sum += x * y
                    }
                    result[i, j] = .number(sum)
                }
            }
            return .matrix(result)
        }
    }

    /// A range the same shape as `like`, starting at the top-left of argument `index`.
    static func resized(_ c: FunctionCall, _ index: Int, like: Matrix) throws -> Matrix {
        if case .reference(let sheet, let range) = try c.value(index) {
            let resized = CellRange(range.start, range.start.offset(rows: like.rows - 1, columns: like.columns - 1))
            return c.evaluator.matrix(sheet: sheet, range: resized)
        }
        let m = try c.matrix(index)
        guard m.rows == like.rows, m.columns == like.columns else { throw FormulaError.value }
        return m
    }

    /// For the *IFS functions: which cells meet every (range, criterion) pair starting at `from`.
    static func criteriaMask(_ c: FunctionCall, from: Int, size: Matrix) throws -> [Bool] {
        guard (c.count - from) % 2 == 0 else { throw FormulaError.value }
        var mask = Array(repeating: true, count: size.count)
        var index = from
        while index < c.count {
            let range = try c.matrix(index)
            guard range.rows == size.rows, range.columns == size.columns else { throw FormulaError.value }
            let criterion = Criterion(try c.strictScalar(index + 1))
            for i in 0..<range.count where mask[i] && !criterion.matches(range.values[i]) { mask[i] = false }
            index += 2
        }
        return mask
    }
}
