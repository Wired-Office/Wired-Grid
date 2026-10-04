import Foundation

extension FunctionLibrary {
    func registerDate() {
        register("DATE", .date, "DATE(year, month, day)", "Returns the serial number of a particular date.", args: 3...3) { c in
            let y = try c.int(0), m = try c.int(1), d = try c.int(2)
            guard y >= 0, y < 10000 else { throw FormulaError.num }
            let serial = DateSerial.serial(year: y, month: m, day: d)
            guard serial >= 0 else { throw FormulaError.num }
            return .number(serial)
        }
        register("TIME", .date, "TIME(hour, minute, second)", "Returns the serial number of a particular time.", args: 3...3) { c in
            let seconds = try c.number(0) * 3600 + (try c.number(1)) * 60 + (try c.number(2))
            guard seconds >= 0 else { throw FormulaError.num }
            return .number((seconds / 86400).truncatingRemainder(dividingBy: 1))
        }
        register("TODAY", .date, "TODAY()", "Returns the serial number of today's date.", args: 0...0) { c in
            .number(DateSerial.from(c.evaluator.calculator.now).rounded(.down))
        }
        register("NOW", .date, "NOW()", "Returns the serial number of the current date and time.", args: 0...0) { c in
            .number(DateSerial.from(c.evaluator.calculator.now))
        }
        let serialArgument: (CellValue) throws -> Double = { v in
            if case .string(let s) = v {
                guard let parsed = ValueParser.parse(s).number else { throw FormulaError.value }
                return parsed
            }
            let n = try v.asNumber()
            guard n >= 0 else { throw FormulaError.num }
            return n
        }
        let part: (String, String, @escaping (Double) -> Int) -> Void = { name, summary, extract in
            self.register(name, .date, "\(name)(serial_number)", summary, args: 1...1) { c in
                try c.lift(0) { v in
                    if case .error = v { return v }
                    return .number(Double(extract(try serialArgument(v))))
                }
            }
        }
        part("YEAR", "Returns the year of a date.") { DateSerial.components($0).year }
        part("MONTH", "Returns the month of a date, from 1 to 12.") { DateSerial.components($0).month }
        part("DAY", "Returns the day of the month, from 1 to 31.") { DateSerial.components($0).day }
        part("HOUR", "Returns the hour of a time, from 0 to 23.") { DateSerial.time($0).hour }
        part("MINUTE", "Returns the minute of a time, from 0 to 59.") { DateSerial.time($0).minute }
        part("SECOND", "Returns the second of a time, from 0 to 59.") { DateSerial.time($0).second }

        register("WEEKDAY", .date, "WEEKDAY(serial_number, [return_type])", "Returns the day of the week as a number.", args: 1...2) { c in
            let serial = try serialArgument(try c.strictScalar(0))
            let type = try c.int(1, default: 1)
            let day = DateSerial.weekday(serial) // 1 = Sunday
            switch type {
            case 1, 17: return .number(Double(day))
            case 2, 11: return .number(Double((day + 5) % 7 + 1))
            case 3: return .number(Double((day + 5) % 7))
            case 12...16: return .number(Double((day - (type - 10) + 7) % 7 + 1))
            default: throw FormulaError.num
            }
        }
        register("WEEKNUM", .date, "WEEKNUM(serial_number, [return_type])", "Returns the week number of a date in the year.", args: 1...2) { c in
            let serial = try serialArgument(try c.strictScalar(0))
            let type = try c.int(1, default: 1)
            if type == 21 { return .number(Double(Self.isoWeek(serial))) }
            let startDay = type == 2 || type == 11 ? 2 : 1
            let (y, _, _) = DateSerial.components(serial)
            let jan1 = DateSerial.serial(year: y, month: 1, day: 1)
            let offset = (DateSerial.weekday(jan1) - startDay + 7) % 7
            return .number(Double(Int((serial.rounded(.down) - jan1 + Double(offset)) / 7) + 1))
        }
        register("ISOWEEKNUM", .date, "ISOWEEKNUM(date)", "Returns the ISO week number of the year.", args: 1...1) { c in
            .number(Double(Self.isoWeek(try serialArgument(try c.strictScalar(0)))))
        }
        register("EDATE", .date, "EDATE(start_date, months)", "Returns the date that is a number of months before or after a date.", args: 2...2) { c in
            .number(DateSerial.addMonths(try serialArgument(try c.strictScalar(0)).rounded(.down), try c.int(1)))
        }
        register("EOMONTH", .date, "EOMONTH(start_date, months)", "Returns the last day of the month a number of months away.", args: 2...2) { c in
            let (y, m, _) = DateSerial.components(try serialArgument(try c.strictScalar(0)))
            return .number(DateSerial.serial(year: y, month: m + (try c.int(1)) + 1, day: 0))
        }
        register("DATEDIF", .date, "DATEDIF(start_date, end_date, unit)", "Calculates the days, months or years between two dates.", args: 3...3) { c in
            let start = try serialArgument(try c.strictScalar(0)).rounded(.down)
            let end = try serialArgument(try c.strictScalar(1)).rounded(.down)
            guard end >= start else { throw FormulaError.num }
            let (y1, m1, d1) = DateSerial.components(start)
            let (y2, m2, d2) = DateSerial.components(end)
            var months = (y2 - y1) * 12 + (m2 - m1)
            if d2 < d1 { months -= 1 }
            switch try c.text(2).uppercased() {
            case "D": return .number(end - start)
            case "M": return .number(Double(months))
            case "Y": return .number(Double(months / 12))
            case "YM": return .number(Double(months % 12))
            case "MD":
                var days = d2 - d1
                if days < 0 { days += DateSerial.daysInMonth(year: m2 == 1 ? y2 - 1 : y2, month: m2 == 1 ? 12 : m2 - 1) }
                return .number(Double(days))
            case "YD":
                var anniversary = DateSerial.serial(year: y2, month: m1, day: d1)
                if anniversary > end { anniversary = DateSerial.serial(year: y2 - 1, month: m1, day: d1) }
                return .number(end - anniversary)
            default: throw FormulaError.num
            }
        }
        register("DAYS", .date, "DAYS(end_date, start_date)", "Returns the number of days between two dates.", args: 2...2) { c in
            .number(try serialArgument(try c.strictScalar(0)).rounded(.down) - (try serialArgument(try c.strictScalar(1))).rounded(.down))
        }
        register("DAYS360", .date, "DAYS360(start_date, end_date, [method])", "Days between two dates based on a 360-day year.", args: 2...3) { c in
            var (y1, m1, d1) = DateSerial.components(try serialArgument(try c.strictScalar(0)))
            var (y2, m2, d2) = DateSerial.components(try serialArgument(try c.strictScalar(1)))
            let european = try c.bool(2, default: false)
            if european {
                d1 = min(d1, 30); d2 = min(d2, 30)
            } else {
                if d1 == 31 { d1 = 30 }
                if d2 == 31 && d1 >= 30 { d2 = 30 }
            }
            _ = (y1, y2)
            return .number(Double((y2 - y1) * 360 + (m2 - m1) * 30 + (d2 - d1)))
        }
        let holidays: (FunctionCall, Int) throws -> Set<Int> = { c, index in
            guard !c.isMissing(index) else { return [] }
            return Set(try c.flat(index).compactMap { $0.number.map { Int($0) } })
        }
        let isWorkday: (Int, Set<Int>) -> Bool = { day, holidays in
            let weekday = DateSerial.weekday(Double(day))
            return weekday != 1 && weekday != 7 && !holidays.contains(day)
        }
        register("NETWORKDAYS", .date, "NETWORKDAYS(start_date, end_date, [holidays])", "Returns the number of whole workdays between two dates.", args: 2...3) { c in
            let a = Int(try serialArgument(try c.strictScalar(0))), b = Int(try serialArgument(try c.strictScalar(1)))
            let skip = try holidays(c, 2)
            let range = a <= b ? a...b : b...a
            guard range.count < 1_000_000 else { throw FormulaError.num }
            let count = range.filter { isWorkday($0, skip) }.count
            return .number(Double(a <= b ? count : -count))
        }
        register("WORKDAY", .date, "WORKDAY(start_date, days, [holidays])", "Returns the date a number of workdays away.", args: 2...3) { c in
            var day = Int(try serialArgument(try c.strictScalar(0)))
            var remaining = try c.int(1)
            let skip = try holidays(c, 2)
            let step = remaining >= 0 ? 1 : -1
            guard abs(remaining) < 1_000_000 else { throw FormulaError.num }
            while remaining != 0 {
                day += step
                if isWorkday(day, skip) { remaining -= step }
            }
            return .number(Double(day))
        }
        register("DATEVALUE", .date, "DATEVALUE(date_text)", "Converts a date in the form of text to a serial number.", args: 1...1) { c in
            guard let n = ValueParser.parse(try c.text(0)).number else { throw FormulaError.value }
            return .number(n.rounded(.down))
        }
        register("TIMEVALUE", .date, "TIMEVALUE(time_text)", "Converts a time in the form of text to a serial number.", args: 1...1) { c in
            guard let n = ValueParser.parse(try c.text(0)).number else { throw FormulaError.value }
            return .number(n - n.rounded(.down))
        }
        register("YEARFRAC", .date, "YEARFRAC(start_date, end_date, [basis])", "Returns the fraction of the year between two dates.", args: 2...3) { c in
            var a = try serialArgument(try c.strictScalar(0)).rounded(.down)
            var b = try serialArgument(try c.strictScalar(1)).rounded(.down)
            if a > b { swap(&a, &b) }
            let basis = try c.int(2, default: 0)
            switch basis {
            case 0:
                var (y1, m1, d1) = DateSerial.components(a)
                var (y2, m2, d2) = DateSerial.components(b)
                if d1 == 31 { d1 = 30 }
                if d2 == 31 && d1 == 30 { d2 = 30 }
                _ = (y1, m1); _ = (y2, m2)
                return .number(Double((y2 - y1) * 360 + (m2 - m1) * 30 + (d2 - d1)) / 360)
            case 1:
                let (y1, _, _) = DateSerial.components(a), (y2, _, _) = DateSerial.components(b)
                let years = (y1...y2).map { DateSerial.isLeap($0) ? 366.0 : 365.0 }
                return .number((b - a) / (years.reduce(0, +) / Double(years.count)))
            case 2: return .number((b - a) / 360)
            case 3: return .number((b - a) / 365)
            case 4:
                var (y1, m1, d1) = DateSerial.components(a)
                var (y2, m2, d2) = DateSerial.components(b)
                d1 = min(d1, 30); d2 = min(d2, 30)
                _ = (y1, m1); _ = (y2, m2)
                return .number(Double((y2 - y1) * 360 + (m2 - m1) * 30 + (d2 - d1)) / 360)
            default: throw FormulaError.num
            }
        }
    }

    static func isoWeek(_ serial: Double) -> Int {
        let day = serial.rounded(.down)
        let weekday = (DateSerial.weekday(day) + 5) % 7 + 1 // Monday = 1
        let thursday = day - Double(weekday) + 4
        let (year, _, _) = DateSerial.components(thursday)
        let jan1 = DateSerial.serial(year: year, month: 1, day: 1)
        return Int((thursday - jan1) / 7) + 1
    }
}
