import Foundation

/// Shared statistics used by several functions.
enum Statistics {
    static func mean(_ x: [Double]) -> Double { x.reduce(0, +) / Double(x.count) }

    static func variance(_ x: [Double], sample: Bool) throws -> Double {
        let n = Double(x.count)
        guard x.count > (sample ? 1 : 0) else { throw FormulaError.div0 }
        let m = mean(x)
        return x.reduce(0) { $0 + ($1 - m) * ($1 - m) } / (sample ? n - 1 : n)
    }

    static func median(_ x: [Double]) throws -> Double {
        guard !x.isEmpty else { throw FormulaError.num }
        let s = x.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func percentile(_ sorted: [Double], _ k: Double, exclusive: Bool) throws -> Double {
        let n = Double(sorted.count)
        guard !sorted.isEmpty else { throw FormulaError.num }
        let rank: Double
        if exclusive {
            guard k > 0, k < 1 else { throw FormulaError.num }
            rank = k * (n + 1) - 1
            guard rank >= 0, rank <= n - 1 else { throw FormulaError.num }
        } else {
            guard k >= 0, k <= 1 else { throw FormulaError.num }
            rank = k * (n - 1)
        }
        let lower = Int(rank.rounded(.down))
        let fraction = rank - Double(lower)
        if lower + 1 >= sorted.count { return sorted[sorted.count - 1] }
        return sorted[lower] + fraction * (sorted[lower + 1] - sorted[lower])
    }

    static func mode(_ x: [Double]) throws -> Double {
        var counts: [Double: Int] = [:]
        var order: [Double] = []
        for v in x {
            if counts[v] == nil { order.append(v) }
            counts[v, default: 0] += 1
        }
        guard let best = order.max(by: { counts[$0]! < counts[$1]! }), counts[best]! > 1 else { throw FormulaError.na }
        return order.first { counts[$0]! == counts[best]! }!
    }

    /// SUBTOTAL/AGGREGATE function numbers 1–13.
    static func aggregate(_ function: Int, _ values: [Double], countA: Int) throws -> FValue {
        switch function {
        case 1: guard !values.isEmpty else { throw FormulaError.div0 }; return numberResult(mean(values))
        case 2: return .number(Double(values.count))
        case 3: return .number(Double(countA))
        case 4: return .number(values.max() ?? 0)
        case 5: return .number(values.min() ?? 0)
        case 6: return numberResult(values.isEmpty ? 0 : values.reduce(1, *))
        case 7: return numberResult(try variance(values, sample: true).squareRoot())
        case 8: return numberResult(try variance(values, sample: false).squareRoot())
        case 9: return numberResult(values.reduce(0, +))
        case 10: return numberResult(try variance(values, sample: true))
        case 11: return numberResult(try variance(values, sample: false))
        case 12: return numberResult(try median(values))
        case 13: return numberResult(try mode(values))
        default: throw FormulaError.value
        }
    }

    // MARK: Distributions

    static func erf(_ x: Double) -> Double { Foundation.erf(x) }

    static func normalCDF(_ z: Double) -> Double { 0.5 * erfc(-z / 2.squareRoot()) }

    static func normalPDF(_ z: Double) -> Double { exp(-z * z / 2) / (2 * .pi).squareRoot() }

    /// Acklam's rational approximation of the inverse normal CDF, refined by one Newton step.
    static func inverseNormal(_ p: Double) throws -> Double {
        guard p > 0, p < 1 else { throw FormulaError.num }
        let a = [-3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02, 1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00]
        let b = [-5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02, 6.680131188771972e+01, -1.328068155288572e+01]
        let c = [-7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00, -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00]
        let d = [7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00, 3.754408661907416e+00]
        let low = 0.02425, high = 1 - low
        var x: Double
        if p < low {
            let q = (-2 * log(p)).squareRoot()
            x = (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        } else if p <= high {
            let q = p - 0.5, r = q * q
            x = (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q / (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1)
        } else {
            let q = (-2 * log(1 - p)).squareRoot()
            x = -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        }
        let e = normalCDF(x) - p
        let u = e * (2 * .pi).squareRoot() * exp(x * x / 2)
        x -= u / (1 + x * u / 2)
        return x
    }

    static func logGamma(_ x: Double) -> Double { lgamma(x) }

    static func binomial(_ n: Int, _ k: Int) -> Double {
        exp(lgamma(Double(n + 1)) - lgamma(Double(k + 1)) - lgamma(Double(n - k + 1)))
    }

    static func pairs(_ c: FunctionCall, _ a: Int, _ b: Int) throws -> ([Double], [Double]) {
        let x = try c.matrix(a), y = try c.matrix(b)
        guard x.count == y.count else { throw FormulaError.na }
        var xs: [Double] = [], ys: [Double] = []
        for i in 0..<x.count {
            if case .error(let e) = x.values[i] { throw e }
            if case .error(let e) = y.values[i] { throw e }
            if case .number(let p) = x.values[i], case .number(let q) = y.values[i] {
                xs.append(p)
                ys.append(q)
            }
        }
        return (xs, ys)
    }

    static func covariance(_ x: [Double], _ y: [Double], sample: Bool) throws -> Double {
        guard x.count > (sample ? 1 : 0) else { throw FormulaError.div0 }
        let mx = mean(x), my = mean(y)
        var s = 0.0
        for i in x.indices { s += (x[i] - mx) * (y[i] - my) }
        return s / Double(sample ? x.count - 1 : x.count)
    }

    static func correlation(_ x: [Double], _ y: [Double]) throws -> Double {
        let sx = try variance(x, sample: false).squareRoot(), sy = try variance(y, sample: false).squareRoot()
        guard sx > 0, sy > 0 else { throw FormulaError.div0 }
        return try covariance(x, y, sample: false) / (sx * sy)
    }

    /// Least-squares slope and intercept of y on x.
    static func regression(_ ys: [Double], _ xs: [Double]) throws -> (slope: Double, intercept: Double) {
        guard xs.count >= 1 else { throw FormulaError.div0 }
        let mx = mean(xs), my = mean(ys)
        var num = 0.0, den = 0.0
        for i in xs.indices {
            num += (xs[i] - mx) * (ys[i] - my)
            den += (xs[i] - mx) * (xs[i] - mx)
        }
        guard den != 0 else { throw FormulaError.div0 }
        let slope = num / den
        return (slope, my - slope * mx)
    }
}

extension FunctionLibrary {
    func registerStatistical() {
        let v = FunctionLibrary.variadic

        register("AVERAGE", .statistical, "AVERAGE(number1, [number2], …)", "Returns the average (arithmetic mean) of its arguments.", args: 1...v) { c in
            let x = try c.numbers()
            guard !x.isEmpty else { throw FormulaError.div0 }
            return numberResult(Statistics.mean(x))
        }
        register("AVERAGEA", .statistical, "AVERAGEA(value1, [value2], …)", "Returns the average, counting text as 0 and TRUE as 1.", args: 1...v) { c in
            let x = try c.numbers(includeTextAndLogicals: true)
            guard !x.isEmpty else { throw FormulaError.div0 }
            return numberResult(Statistics.mean(x))
        }
        register("AVERAGEIF", .statistical, "AVERAGEIF(range, criteria, [average_range])", "Averages the cells that meet a condition.", args: 2...3) { c in
            let range = try c.matrix(0)
            let criterion = Criterion(try c.strictScalar(1))
            let values = c.isMissing(2) ? range : try Self.resized(c, 2, like: range)
            var x: [Double] = []
            for i in 0..<range.count where criterion.matches(range.values[i]) {
                if case .number(let n) = values.values[i] { x.append(n) }
            }
            guard !x.isEmpty else { throw FormulaError.div0 }
            return numberResult(Statistics.mean(x))
        }
        register("AVERAGEIFS", .statistical, "AVERAGEIFS(average_range, criteria_range1, criteria1, …)", "Averages the cells that meet multiple conditions.", args: 3...v) { c in
            let values = try c.matrix(0)
            let mask = try Self.criteriaMask(c, from: 1, size: values)
            var x: [Double] = []
            for i in 0..<values.count where mask[i] {
                if case .number(let n) = values.values[i] { x.append(n) }
            }
            guard !x.isEmpty else { throw FormulaError.div0 }
            return numberResult(Statistics.mean(x))
        }
        register("COUNT", .statistical, "COUNT(value1, [value2], …)", "Counts how many cells contain numbers.", args: 1...v) { c in
            var n = 0
            for i in 0..<c.count where !c.isMissing(i) {
                let value = try c.value(i)
                if case .scalar(let s) = value {
                    if case .number = s { n += 1 } else if case .bool = s { n += 1 } else if case .string(let t) = s, ValueParser.number(from: t) != nil { n += 1 }
                } else {
                    n += c.evaluator.matrix(value).values.filter { $0.number != nil }.count
                }
            }
            return .number(Double(n))
        }
        register("COUNTA", .statistical, "COUNTA(value1, [value2], …)", "Counts how many cells are not empty.", args: 1...v) { c in
            var n = 0
            for i in 0..<c.count where !c.isMissing(i) {
                n += try c.flat(i).filter { !$0.isEmpty }.count
            }
            return .number(Double(n))
        }
        register("COUNTBLANK", .statistical, "COUNTBLANK(range)", "Counts the empty cells in a range.", args: 1...1) { c in
            .number(Double(try c.flat(0).filter { $0.isEmpty || $0 == .string("") }.count))
        }
        register("COUNTIF", .statistical, "COUNTIF(range, criteria)", "Counts the cells that meet a condition.", args: 2...2) { c in
            let criterion = Criterion(try c.strictScalar(1))
            return .number(Double(try c.flat(0).filter { criterion.matches($0) }.count))
        }
        register("COUNTIFS", .statistical, "COUNTIFS(criteria_range1, criteria1, …)", "Counts the cells that meet multiple conditions.", args: 2...v) { c in
            let first = try c.matrix(0)
            return .number(Double(try Self.criteriaMask(c, from: 0, size: first).filter { $0 }.count))
        }
        register("MAX", .statistical, "MAX(number1, [number2], …)", "Returns the largest value in a set of values.", args: 1...v) { c in
            .number(try c.numbers().max() ?? 0)
        }
        register("MIN", .statistical, "MIN(number1, [number2], …)", "Returns the smallest value in a set of values.", args: 1...v) { c in
            .number(try c.numbers().min() ?? 0)
        }
        register("MAXA", .statistical, "MAXA(value1, [value2], …)", "Returns the largest value, including text and logicals.", args: 1...v) { c in
            .number(try c.numbers(includeTextAndLogicals: true).max() ?? 0)
        }
        register("MINA", .statistical, "MINA(value1, [value2], …)", "Returns the smallest value, including text and logicals.", args: 1...v) { c in
            .number(try c.numbers(includeTextAndLogicals: true).min() ?? 0)
        }
        register("MAXIFS", .statistical, "MAXIFS(max_range, criteria_range1, criteria1, …)", "Returns the maximum among cells that meet conditions.", args: 3...v) { c in
            let values = try c.matrix(0)
            let mask = try Self.criteriaMask(c, from: 1, size: values)
            return .number((0..<values.count).compactMap { mask[$0] ? values.values[$0].number : nil }.max() ?? 0)
        }
        register("MINIFS", .statistical, "MINIFS(min_range, criteria_range1, criteria1, …)", "Returns the minimum among cells that meet conditions.", args: 3...v) { c in
            let values = try c.matrix(0)
            let mask = try Self.criteriaMask(c, from: 1, size: values)
            return .number((0..<values.count).compactMap { mask[$0] ? values.values[$0].number : nil }.min() ?? 0)
        }
        register("MEDIAN", .statistical, "MEDIAN(number1, [number2], …)", "Returns the median of the given numbers.", args: 1...v) { c in
            numberResult(try Statistics.median(try c.numbers()))
        }
        for name in ["MODE", "MODE.SNGL"] {
            register(name, .statistical, "\(name)(number1, [number2], …)", "Returns the most frequently occurring value.", args: 1...v) { c in
                numberResult(try Statistics.mode(try c.numbers()))
            }
        }
        for (name, sample, summary) in [("STDEV", true, "Estimates standard deviation based on a sample."),
                                        ("STDEV.S", true, "Estimates standard deviation based on a sample."),
                                        ("STDEVP", false, "Calculates standard deviation based on the entire population."),
                                        ("STDEV.P", false, "Calculates standard deviation based on the entire population.")] {
            register(name, .statistical, "\(name)(number1, [number2], …)", summary, args: 1...v) { c in
                numberResult(try Statistics.variance(try c.numbers(), sample: sample).squareRoot())
            }
        }
        for (name, sample, summary) in [("VAR", true, "Estimates variance based on a sample."),
                                        ("VAR.S", true, "Estimates variance based on a sample."),
                                        ("VARP", false, "Calculates variance based on the entire population."),
                                        ("VAR.P", false, "Calculates variance based on the entire population.")] {
            register(name, .statistical, "\(name)(number1, [number2], …)", summary, args: 1...v) { c in
                numberResult(try Statistics.variance(try c.numbers(), sample: sample))
            }
        }
        register("LARGE", .statistical, "LARGE(array, k)", "Returns the k-th largest value in a data set.", args: 2...2) { c in
            let x = try c.numbers(from: 0..<1).sorted(by: >)
            let k = try c.int(1)
            guard k >= 1, k <= x.count else { throw FormulaError.num }
            return .number(x[k - 1])
        }
        register("SMALL", .statistical, "SMALL(array, k)", "Returns the k-th smallest value in a data set.", args: 2...2) { c in
            let x = try c.numbers(from: 0..<1).sorted()
            let k = try c.int(1)
            guard k >= 1, k <= x.count else { throw FormulaError.num }
            return .number(x[k - 1])
        }
        for name in ["RANK", "RANK.EQ", "RANK.AVG"] {
            register(name, .statistical, "\(name)(number, ref, [order])", "Returns the rank of a number in a list of numbers.", args: 2...3) { c in
                let n = try c.number(0)
                let x = try c.numbers(from: 1..<2)
                let ascending = try c.number(2, default: 0) != 0
                guard x.contains(n) else { throw FormulaError.na }
                let better = x.filter { ascending ? $0 < n : $0 > n }.count
                if name == "RANK.AVG" {
                    let ties = x.filter { $0 == n }.count
                    return .number(Double(better) + Double(ties + 1) / 2)
                }
                return .number(Double(better + 1))
            }
        }
        for (name, exclusive) in [("PERCENTILE", false), ("PERCENTILE.INC", false), ("PERCENTILE.EXC", true)] {
            register(name, .statistical, "\(name)(array, k)", "Returns the k-th percentile of values in a range.", args: 2...2) { c in
                numberResult(try Statistics.percentile(try c.numbers(from: 0..<1).sorted(), try c.number(1), exclusive: exclusive))
            }
        }
        for (name, exclusive) in [("QUARTILE", false), ("QUARTILE.INC", false), ("QUARTILE.EXC", true)] {
            register(name, .statistical, "\(name)(array, quart)", "Returns the quartile of a data set.", args: 2...2) { c in
                let q = try c.int(1)
                guard (0...4).contains(q) else { throw FormulaError.num }
                return numberResult(try Statistics.percentile(try c.numbers(from: 0..<1).sorted(), Double(q) / 4, exclusive: exclusive))
            }
        }
        for name in ["PERCENTRANK", "PERCENTRANK.INC"] {
            register(name, .statistical, "\(name)(array, x, [significance])", "Returns the rank of a value as a percentage of the data set.", args: 2...3) { c in
                let x = try c.numbers(from: 0..<1).sorted()
                let value = try c.number(1)
                let digits = try c.int(2, default: 3)
                guard let first = x.first, let last = x.last, value >= first, value <= last, x.count > 1 else { throw FormulaError.na }
                let below = Double(x.filter { $0 < value }.count)
                var rank: Double
                if x.contains(value) {
                    rank = below / Double(x.count - 1)
                } else {
                    let i = x.lastIndex { $0 < value }!
                    let fraction = (value - x[i]) / (x[i + 1] - x[i])
                    rank = (Double(i) + fraction) / Double(x.count - 1)
                }
                rank = excelRound(rank, digits, mode: .towardZero)
                return .number(rank)
            }
        }
        for name in ["CORREL", "PEARSON"] {
            register(name, .statistical, "\(name)(array1, array2)", "Returns the correlation coefficient between two data sets.", args: 2...2) { c in
                let (x, y) = try Statistics.pairs(c, 0, 1)
                return numberResult(try Statistics.correlation(x, y))
            }
        }
        register("RSQ", .statistical, "RSQ(known_y's, known_x's)", "Returns the square of the Pearson correlation coefficient.", args: 2...2) { c in
            let (y, x) = try Statistics.pairs(c, 0, 1)
            let r = try Statistics.correlation(x, y)
            return numberResult(r * r)
        }
        for (name, sample) in [("COVAR", false), ("COVARIANCE.P", false), ("COVARIANCE.S", true)] {
            register(name, .statistical, "\(name)(array1, array2)", "Returns covariance, the average of the products of paired deviations.", args: 2...2) { c in
                let (x, y) = try Statistics.pairs(c, 0, 1)
                return numberResult(try Statistics.covariance(x, y, sample: sample))
            }
        }
        register("SLOPE", .statistical, "SLOPE(known_y's, known_x's)", "Returns the slope of the linear regression line.", args: 2...2) { c in
            let (y, x) = try Statistics.pairs(c, 0, 1)
            return numberResult(try Statistics.regression(y, x).slope)
        }
        register("INTERCEPT", .statistical, "INTERCEPT(known_y's, known_x's)", "Returns the intercept of the linear regression line.", args: 2...2) { c in
            let (y, x) = try Statistics.pairs(c, 0, 1)
            return numberResult(try Statistics.regression(y, x).intercept)
        }
        for name in ["FORECAST", "FORECAST.LINEAR"] {
            register(name, .statistical, "\(name)(x, known_y's, known_x's)", "Predicts a value along a linear trend.", args: 3...3) { c in
                let target = try c.number(0)
                let (y, x) = try Statistics.pairs(c, 1, 2)
                let fit = try Statistics.regression(y, x)
                return numberResult(fit.intercept + fit.slope * target)
            }
        }
        register("TREND", .statistical, "TREND(known_y's, [known_x's], [new_x's])", "Returns values along a linear trend.", args: 1...3) { c in
            let ys = try c.numbers(from: 0..<1)
            let xs = c.isMissing(1) ? (1...ys.count).map(Double.init) : try c.numbers(from: 1..<2)
            guard xs.count == ys.count else { throw FormulaError.ref }
            let fit = try Statistics.regression(ys, xs)
            let targets: Matrix
            if !c.isMissing(2) {
                targets = try c.matrix(2)
            } else if !c.isMissing(1) {
                targets = try c.matrix(1)
            } else {
                targets = Matrix(column: xs.map { .number($0) })
            }
            var result = targets
            for i in 0..<targets.count {
                let x = (try? targets.values[i].asNumber()) ?? 0
                result.values[i] = .number(fit.intercept + fit.slope * x)
            }
            return .matrix(result)
        }
        register("GEOMEAN", .statistical, "GEOMEAN(number1, [number2], …)", "Returns the geometric mean.", args: 1...v) { c in
            let x = try c.numbers()
            guard !x.isEmpty, x.allSatisfy({ $0 > 0 }) else { throw FormulaError.num }
            return numberResult(exp(x.map(log).reduce(0, +) / Double(x.count)))
        }
        register("HARMEAN", .statistical, "HARMEAN(number1, [number2], …)", "Returns the harmonic mean.", args: 1...v) { c in
            let x = try c.numbers()
            guard !x.isEmpty, x.allSatisfy({ $0 > 0 }) else { throw FormulaError.num }
            return numberResult(Double(x.count) / x.map { 1 / $0 }.reduce(0, +))
        }
        register("AVEDEV", .statistical, "AVEDEV(number1, [number2], …)", "Returns the average of absolute deviations from the mean.", args: 1...v) { c in
            let x = try c.numbers()
            guard !x.isEmpty else { throw FormulaError.num }
            let m = Statistics.mean(x)
            return numberResult(x.map { abs($0 - m) }.reduce(0, +) / Double(x.count))
        }
        register("DEVSQ", .statistical, "DEVSQ(number1, [number2], …)", "Returns the sum of squares of deviations.", args: 1...v) { c in
            let x = try c.numbers()
            guard !x.isEmpty else { throw FormulaError.num }
            let m = Statistics.mean(x)
            return numberResult(x.map { ($0 - m) * ($0 - m) }.reduce(0, +))
        }
        register("SKEW", .statistical, "SKEW(number1, [number2], …)", "Returns the skewness of a distribution.", args: 1...v) { c in
            let x = try c.numbers()
            let n = Double(x.count)
            guard n >= 3 else { throw FormulaError.div0 }
            let m = Statistics.mean(x), s = try Statistics.variance(x, sample: true).squareRoot()
            guard s > 0 else { throw FormulaError.div0 }
            return numberResult(n / ((n - 1) * (n - 2)) * x.map { pow(($0 - m) / s, 3) }.reduce(0, +))
        }
        register("KURT", .statistical, "KURT(number1, [number2], …)", "Returns the kurtosis of a data set.", args: 1...v) { c in
            let x = try c.numbers()
            let n = Double(x.count)
            guard n >= 4 else { throw FormulaError.div0 }
            let m = Statistics.mean(x), s = try Statistics.variance(x, sample: true).squareRoot()
            guard s > 0 else { throw FormulaError.div0 }
            let sum = x.map { pow(($0 - m) / s, 4) }.reduce(0, +)
            return numberResult(n * (n + 1) / ((n - 1) * (n - 2) * (n - 3)) * sum - 3 * (n - 1) * (n - 1) / ((n - 2) * (n - 3)))
        }
        register("STANDARDIZE", .statistical, "STANDARDIZE(x, mean, standard_dev)", "Returns a normalized value.", args: 3...3) { c in
            let sd = try c.number(2)
            guard sd > 0 else { throw FormulaError.num }
            return numberResult((try c.number(0) - (try c.number(1))) / sd)
        }
        for name in ["NORM.DIST", "NORMDIST"] {
            register(name, .statistical, "\(name)(x, mean, standard_dev, cumulative)", "Returns the normal distribution.", args: 4...4) { c in
                let x = try c.number(0), m = try c.number(1), sd = try c.number(2), cumulative = try c.bool(3)
                guard sd > 0 else { throw FormulaError.num }
                let z = (x - m) / sd
                return numberResult(cumulative ? Statistics.normalCDF(z) : Statistics.normalPDF(z) / sd)
            }
        }
        register("NORM.S.DIST", .statistical, "NORM.S.DIST(z, cumulative)", "Returns the standard normal distribution.", args: 2...2) { c in
            let z = try c.number(0)
            return numberResult(try c.bool(1) ? Statistics.normalCDF(z) : Statistics.normalPDF(z))
        }
        register("NORMSDIST", .statistical, "NORMSDIST(z)", "Returns the standard normal cumulative distribution.", args: 1...1) { c in
            numberResult(Statistics.normalCDF(try c.number(0)))
        }
        for name in ["NORM.INV", "NORMINV"] {
            register(name, .statistical, "\(name)(probability, mean, standard_dev)", "Returns the inverse of the normal cumulative distribution.", args: 3...3) { c in
                let sd = try c.number(2)
                guard sd > 0 else { throw FormulaError.num }
                return numberResult(try Statistics.inverseNormal(try c.number(0)) * sd + (try c.number(1)))
            }
        }
        for name in ["NORM.S.INV", "NORMSINV"] {
            register(name, .statistical, "\(name)(probability)", "Returns the inverse of the standard normal distribution.", args: 1...1) { c in
                numberResult(try Statistics.inverseNormal(try c.number(0)))
            }
        }
        register("CONFIDENCE.NORM", .statistical, "CONFIDENCE.NORM(alpha, standard_dev, size)", "Returns the confidence interval for a population mean.", args: 3...3) { c in
            let alpha = try c.number(0), sd = try c.number(1), n = try c.number(2)
            guard alpha > 0, alpha < 1, sd > 0, n >= 1 else { throw FormulaError.num }
            return numberResult(try Statistics.inverseNormal(1 - alpha / 2) * sd / n.squareRoot())
        }
        for name in ["BINOM.DIST", "BINOMDIST"] {
            register(name, .statistical, "\(name)(number_s, trials, probability_s, cumulative)", "Returns the binomial distribution probability.", args: 4...4) { c in
                let k = try c.int(0), n = try c.int(1), p = try c.number(2), cumulative = try c.bool(3)
                guard k >= 0, n >= k, p >= 0, p <= 1 else { throw FormulaError.num }
                func pmf(_ i: Int) -> Double { Statistics.binomial(n, i) * pow(p, Double(i)) * pow(1 - p, Double(n - i)) }
                return numberResult(cumulative ? (0...k).map(pmf).reduce(0, +) : pmf(k))
            }
        }
        for name in ["POISSON.DIST", "POISSON"] {
            register(name, .statistical, "\(name)(x, mean, cumulative)", "Returns the Poisson distribution.", args: 3...3) { c in
                let k = try c.int(0), m = try c.number(1), cumulative = try c.bool(2)
                guard k >= 0, m >= 0 else { throw FormulaError.num }
                func pmf(_ i: Int) -> Double { exp(Double(i) * log(max(m, .leastNonzeroMagnitude)) - m - lgamma(Double(i + 1))) }
                return numberResult(cumulative ? (0...k).map(pmf).reduce(0, +) : pmf(k))
            }
        }
        for name in ["EXPON.DIST", "EXPONDIST"] {
            register(name, .statistical, "\(name)(x, lambda, cumulative)", "Returns the exponential distribution.", args: 3...3) { c in
                let x = try c.number(0), lambda = try c.number(1), cumulative = try c.bool(2)
                guard x >= 0, lambda > 0 else { throw FormulaError.num }
                return numberResult(cumulative ? 1 - exp(-lambda * x) : lambda * exp(-lambda * x))
            }
        }
        register("FREQUENCY", .statistical, "FREQUENCY(data_array, bins_array)", "Counts how often values occur within ranges of values.", args: 2...2) { c in
            let data = try c.numbers(from: 0..<1)
            let bins = try c.numbers(from: 1..<2)
            let sortedBins = bins.sorted()
            var counts = Array(repeating: 0.0, count: bins.count + 1)
            for value in data {
                let index = sortedBins.firstIndex { value <= $0 } ?? bins.count
                counts[index] += 1
            }
            // Report counts in the order the bins were given.
            var result: [CellValue] = bins.map { bin in .number(counts[sortedBins.firstIndex(of: bin)!]) }
            result.append(.number(counts[bins.count]))
            return .matrix(Matrix(column: result))
        }
    }
}
