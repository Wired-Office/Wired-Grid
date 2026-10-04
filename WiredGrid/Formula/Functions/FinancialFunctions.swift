import Foundation

/// Time-value-of-money helpers shared by the financial functions.
enum Finance {
    static func pmt(_ r: Double, _ n: Double, _ pv: Double, _ fv: Double = 0, _ type: Double = 0) -> Double {
        if r == 0 { return -(pv + fv) / n }
        let f = pow(1 + r, n)
        return -(r * (fv + pv * f)) / ((1 + r * type) * (f - 1))
    }

    static func fv(_ r: Double, _ n: Double, _ pmt: Double, _ pv: Double = 0, _ type: Double = 0) -> Double {
        if r == 0 { return -(pv + pmt * n) }
        let f = pow(1 + r, n)
        return -(pv * f + pmt * (1 + r * type) * (f - 1) / r)
    }

    static func pv(_ r: Double, _ n: Double, _ pmt: Double, _ fv: Double = 0, _ type: Double = 0) -> Double {
        if r == 0 { return -(fv + pmt * n) }
        let f = pow(1 + r, n)
        return -(fv + pmt * (1 + r * type) * (f - 1) / r) / f
    }

    static func ipmt(_ r: Double, _ per: Double, _ n: Double, _ pv: Double, _ fv: Double = 0, _ type: Double = 0) -> Double {
        let payment = pmt(r, n, pv, fv, type)
        if per == 1 { return type == 1 ? 0 : -pv * r }
        if type == 1 { return (Finance.fv(r, per - 2, payment, pv, 1) - payment) * r }
        return Finance.fv(r, per - 1, payment, pv, 0) * r
    }

    /// Newton's method with a bisection-free fallback over several starting guesses.
    static func solve(guess: Double, _ f: (Double) -> Double) throws -> Double {
        for start in [guess, 0.1, 0.01, 0.5, -0.5, 1, -0.9] {
            var x = start
            for _ in 0..<100 {
                let y = f(x)
                if abs(y) < 1e-10 { return x }
                let h = max(abs(x) * 1e-6, 1e-8)
                let slope = (f(x + h) - f(x - h)) / (2 * h)
                guard slope != 0, slope.isFinite else { break }
                let next = x - y / slope
                guard next.isFinite, next > -1 else { break }
                if abs(next - x) < 1e-12 { return next }
                x = next
            }
        }
        throw FormulaError.num
    }
}

extension FunctionLibrary {
    func registerFinancial() {
        let v = FunctionLibrary.variadic

        register("PMT", .financial, "PMT(rate, nper, pv, [fv], [type])", "Returns the periodic payment for a loan.", args: 3...5) { c in
            let n = try c.number(1)
            guard n != 0 else { throw FormulaError.num }
            return numberResult(Finance.pmt(try c.number(0), n, try c.number(2), try c.number(3, default: 0), try c.number(4, default: 0)))
        }
        register("FV", .financial, "FV(rate, nper, pmt, [pv], [type])", "Returns the future value of an investment.", args: 3...5) { c in
            numberResult(Finance.fv(try c.number(0), try c.number(1), try c.number(2), try c.number(3, default: 0), try c.number(4, default: 0)))
        }
        register("PV", .financial, "PV(rate, nper, pmt, [fv], [type])", "Returns the present value of an investment.", args: 3...5) { c in
            numberResult(Finance.pv(try c.number(0), try c.number(1), try c.number(2), try c.number(3, default: 0), try c.number(4, default: 0)))
        }
        register("NPER", .financial, "NPER(rate, pmt, pv, [fv], [type])", "Returns the number of periods for an investment.", args: 3...5) { c in
            let r = try c.number(0), pmt = try c.number(1), pv = try c.number(2)
            let fv = try c.number(3, default: 0), type = try c.number(4, default: 0)
            if r == 0 {
                guard pmt != 0 else { throw FormulaError.num }
                return numberResult(-(pv + fv) / pmt)
            }
            let num = pmt * (1 + r * type) - fv * r
            let den = pv * r + pmt * (1 + r * type)
            guard num / den > 0 else { throw FormulaError.num }
            return numberResult(log(num / den) / log(1 + r))
        }
        register("RATE", .financial, "RATE(nper, pmt, pv, [fv], [type], [guess])", "Returns the interest rate per period of an annuity.", args: 3...6) { c in
            let n = try c.number(0), pmt = try c.number(1), pv = try c.number(2)
            let fv = try c.number(3, default: 0), type = try c.number(4, default: 0), guess = try c.number(5, default: 0.1)
            let rate = try Finance.solve(guess: guess) { r in
                if abs(r) < 1e-12 { return pv + pmt * n + fv }
                let f = pow(1 + r, n)
                return pv * f + pmt * (1 + r * type) * (f - 1) / r + fv
            }
            return numberResult(rate)
        }
        register("IPMT", .financial, "IPMT(rate, per, nper, pv, [fv], [type])", "Returns the interest payment for a given period.", args: 4...6) { c in
            let per = try c.number(1), n = try c.number(2)
            guard per >= 1, per <= n else { throw FormulaError.num }
            return numberResult(Finance.ipmt(try c.number(0), per, n, try c.number(3), try c.number(4, default: 0), try c.number(5, default: 0)))
        }
        register("PPMT", .financial, "PPMT(rate, per, nper, pv, [fv], [type])", "Returns the principal payment for a given period.", args: 4...6) { c in
            let r = try c.number(0), per = try c.number(1), n = try c.number(2), pv = try c.number(3)
            let fv = try c.number(4, default: 0), type = try c.number(5, default: 0)
            guard per >= 1, per <= n else { throw FormulaError.num }
            return numberResult(Finance.pmt(r, n, pv, fv, type) - Finance.ipmt(r, per, n, pv, fv, type))
        }
        register("CUMIPMT", .financial, "CUMIPMT(rate, nper, pv, start_period, end_period, type)", "Returns the cumulative interest paid between two periods.", args: 6...6) { c in
            let r = try c.number(0), n = try c.number(1), pv = try c.number(2)
            let start = try c.int(3), end = try c.int(4), type = try c.number(5)
            guard r > 0, n > 0, pv > 0, start >= 1, end >= start, Double(end) <= n else { throw FormulaError.num }
            return numberResult((start...end).map { Finance.ipmt(r, Double($0), n, pv, 0, type) }.reduce(0, +))
        }
        register("CUMPRINC", .financial, "CUMPRINC(rate, nper, pv, start_period, end_period, type)", "Returns the cumulative principal paid between two periods.", args: 6...6) { c in
            let r = try c.number(0), n = try c.number(1), pv = try c.number(2)
            let start = try c.int(3), end = try c.int(4), type = try c.number(5)
            guard r > 0, n > 0, pv > 0, start >= 1, end >= start, Double(end) <= n else { throw FormulaError.num }
            let payment = Finance.pmt(r, n, pv, 0, type)
            return numberResult((start...end).map { payment - Finance.ipmt(r, Double($0), n, pv, 0, type) }.reduce(0, +))
        }
        register("NPV", .financial, "NPV(rate, value1, [value2], …)", "Returns the net present value of periodic cash flows.", args: 2...v) { c in
            let r = try c.number(0)
            let flows = try c.numbers(from: 1..<c.count)
            return numberResult(flows.enumerated().map { $0.element / pow(1 + r, Double($0.offset + 1)) }.reduce(0, +))
        }
        register("XNPV", .financial, "XNPV(rate, values, dates)", "Returns the net present value of irregular cash flows.", args: 3...3) { c in
            let r = try c.number(0)
            let flows = try c.numbers(from: 1..<2), dates = try c.numbers(from: 2..<3)
            guard flows.count == dates.count, let first = dates.first else { throw FormulaError.num }
            return numberResult(zip(flows, dates).map { $0 / pow(1 + r, ($1 - first) / 365) }.reduce(0, +))
        }
        register("IRR", .financial, "IRR(values, [guess])", "Returns the internal rate of return for periodic cash flows.", args: 1...2) { c in
            let flows = try c.numbers(from: 0..<1)
            guard flows.contains(where: { $0 > 0 }), flows.contains(where: { $0 < 0 }) else { throw FormulaError.num }
            let rate = try Finance.solve(guess: try c.number(1, default: 0.1)) { r in
                flows.enumerated().map { $0.element / pow(1 + r, Double($0.offset)) }.reduce(0, +)
            }
            return numberResult(rate)
        }
        register("XIRR", .financial, "XIRR(values, dates, [guess])", "Returns the internal rate of return for irregular cash flows.", args: 2...3) { c in
            let flows = try c.numbers(from: 0..<1), dates = try c.numbers(from: 1..<2)
            guard flows.count == dates.count, let first = dates.first,
                  flows.contains(where: { $0 > 0 }), flows.contains(where: { $0 < 0 }) else { throw FormulaError.num }
            let rate = try Finance.solve(guess: try c.number(2, default: 0.1)) { r in
                zip(flows, dates).map { $0 / pow(1 + r, ($1 - first) / 365) }.reduce(0, +)
            }
            return numberResult(rate)
        }
        register("SLN", .financial, "SLN(cost, salvage, life)", "Returns straight-line depreciation for one period.", args: 3...3) { c in
            let life = try c.number(2)
            guard life != 0 else { throw FormulaError.div0 }
            return numberResult((try c.number(0) - (try c.number(1))) / life)
        }
        register("SYD", .financial, "SYD(cost, salvage, life, per)", "Returns sum-of-years' digits depreciation.", args: 4...4) { c in
            let cost = try c.number(0), salvage = try c.number(1), life = try c.number(2), per = try c.number(3)
            guard life > 0, per >= 1, per <= life else { throw FormulaError.num }
            return numberResult((cost - salvage) * (life - per + 1) * 2 / (life * (life + 1)))
        }
        register("DDB", .financial, "DDB(cost, salvage, life, period, [factor])", "Returns depreciation using the double-declining balance method.", args: 4...5) { c in
            let cost = try c.number(0), salvage = try c.number(1), life = try c.number(2), period = try c.number(3)
            let factor = try c.number(4, default: 2)
            guard life > 0, period >= 1, period <= life, cost >= 0, salvage >= 0 else { throw FormulaError.num }
            var value = cost, depreciation = 0.0
            for _ in 0..<Int(period.rounded(.up)) {
                depreciation = min(value * factor / life, max(value - salvage, 0))
                value -= depreciation
            }
            return numberResult(depreciation)
        }
        register("DB", .financial, "DB(cost, salvage, life, period, [month])", "Returns depreciation using the fixed-declining balance method.", args: 4...5) { c in
            let cost = try c.number(0), salvage = try c.number(1), life = try c.number(2), period = try c.int(3)
            let month = try c.number(4, default: 12)
            guard cost > 0, life > 0, period >= 1 else { throw FormulaError.num }
            let rate = excelRound(1 - pow(salvage / cost, 1 / life), 3)
            var total = 0.0, depreciation = 0.0
            for p in 1...period {
                if p == 1 { depreciation = cost * rate * month / 12 }
                else if Double(p) == life + 1 { depreciation = (cost - total) * rate * (12 - month) / 12 }
                else { depreciation = (cost - total) * rate }
                total += depreciation
            }
            return numberResult(depreciation)
        }
        register("EFFECT", .financial, "EFFECT(nominal_rate, npery)", "Returns the effective annual interest rate.", args: 2...2) { c in
            let rate = try c.number(0), n = Double(try c.int(1))
            guard rate > 0, n >= 1 else { throw FormulaError.num }
            return numberResult(pow(1 + rate / n, n) - 1)
        }
        register("NOMINAL", .financial, "NOMINAL(effect_rate, npery)", "Returns the nominal annual interest rate.", args: 2...2) { c in
            let rate = try c.number(0), n = Double(try c.int(1))
            guard rate > 0, n >= 1 else { throw FormulaError.num }
            return numberResult(n * (pow(1 + rate, 1 / n) - 1))
        }
        register("RRI", .financial, "RRI(nper, pv, fv)", "Returns an equivalent interest rate for the growth of an investment.", args: 3...3) { c in
            let n = try c.number(0), pv = try c.number(1), fv = try c.number(2)
            guard n > 0, pv != 0 else { throw FormulaError.num }
            return numberResult(pow(fv / pv, 1 / n) - 1)
        }
        register("PDURATION", .financial, "PDURATION(rate, pv, fv)", "Returns the number of periods required to reach a value.", args: 3...3) { c in
            let r = try c.number(0), pv = try c.number(1), fv = try c.number(2)
            guard r > 0, pv > 0, fv > 0 else { throw FormulaError.num }
            return numberResult((log(fv) - log(pv)) / log(1 + r))
        }
    }
}
