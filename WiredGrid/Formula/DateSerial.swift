import Foundation

/// Excel date serial numbers: whole days since 1899-12-30, with the time of day as the fraction.
enum DateSerial {
    /// Days since 1970-01-01 for a proleptic Gregorian date (Hinnant's algorithm).
    private static func daysFromCivil(_ y: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y - 1 : y
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (m + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    private static func civilFromDays(_ z: Int) -> (year: Int, month: Int, day: Int) {
        let z = z + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }

    /// 1899-12-30 is 25569 days before 1970-01-01.
    private static let epochOffset = 25569

    /// DATE(y, m, d) with Excel's overflow rules (month 13 → next year, day 0 → last day of previous month).
    static func serial(year: Int, month: Int, day: Int) -> Double {
        var y = year
        if y < 1900 { y += 1900 }
        let totalMonths = y * 12 + (month - 1)
        let normalizedYear = Int((Double(totalMonths) / 12).rounded(.down))
        let normalizedMonth = totalMonths - normalizedYear * 12 + 1
        let days = daysFromCivil(normalizedYear, normalizedMonth, 1) + (day - 1)
        return Double(days + epochOffset)
    }

    static func components(_ serial: Double) -> (year: Int, month: Int, day: Int) {
        civilFromDays(Int(serial.rounded(.down)) - epochOffset)
    }

    /// Hours, minutes, seconds of the fractional part (rounded to the nearest second).
    static func time(_ serial: Double) -> (hour: Int, minute: Int, second: Int) {
        let fraction = serial - serial.rounded(.down)
        var seconds = Int((fraction * 86400).rounded())
        if seconds >= 86400 { seconds = 86399 }
        return (seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }

    /// 1 = Sunday … 7 = Saturday.
    static func weekday(_ serial: Double) -> Int {
        let days = Int(serial.rounded(.down))
        return ((days + 6) % 7 + 7) % 7 + 1
    }

    static func daysInMonth(year: Int, month: Int) -> Int {
        Int(serial(year: year, month: month + 1, day: 1) - serial(year: year, month: month, day: 1))
    }

    static func isLeap(_ year: Int) -> Bool { (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 }

    static func from(_ date: Date, timeZone: TimeZone = .current) -> Double {
        let seconds = date.timeIntervalSince1970 + Double(timeZone.secondsFromGMT(for: date))
        return seconds / 86400 + Double(epochOffset)
    }

    static func date(_ serial: Double, timeZone: TimeZone = .current) -> Date {
        let seconds = (serial - Double(epochOffset)) * 86400
        let guess = Date(timeIntervalSince1970: seconds)
        return Date(timeIntervalSince1970: seconds - Double(timeZone.secondsFromGMT(for: guess)))
    }

    static func addMonths(_ start: Double, _ months: Int) -> Double {
        let (y, m, d) = components(start)
        let target = serial(year: y, month: m + months, day: 1)
        let (ty, tm, _) = components(target)
        return target + Double(min(d, daysInMonth(year: ty, month: tm)) - 1)
    }

    static let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    static let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
}
