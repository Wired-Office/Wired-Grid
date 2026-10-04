import Foundation

/// Interprets what a user types into a cell: numbers, percentages, currency,
/// dates, times, booleans and errors. Suggests a number format when the
/// entry implies one (typing "12%" formats the cell as a percentage).
enum ValueParser {
    struct Parsed {
        var value: CellValue
        var format: String?

        var number: Double? { value.number }
    }

    static func parse(_ raw: String) -> Parsed {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return Parsed(value: raw.isEmpty ? .empty : .string(raw)) }
        switch text.uppercased() {
        case "TRUE": return Parsed(value: .bool(true))
        case "FALSE": return Parsed(value: .bool(false))
        default: break
        }
        if text.hasPrefix("#"), let error = FormulaError.allCases.first(where: { $0.rawValue == text.uppercased() }) {
            return Parsed(value: .error(error))
        }
        if let parsed = parseNumber(text) { return parsed }
        if let parsed = parseDateTime(text) { return parsed }
        return Parsed(value: .string(raw))
    }

    /// A number from text, including dates, times, percentages and currency.
    static func number(from text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let parsed = parseNumber(trimmed) { return parsed.number }
        return parseDateTime(trimmed)?.number
    }

    // MARK: - Numbers

    private static let currencySymbols: [Character] = ["$", "€", "£", "¥"]

    private static func parseNumber(_ input: String) -> Parsed? {
        var s = Substring(input)
        var negative = false
        var currency: Character?
        var percent = false

        if s.hasPrefix("(") && s.hasSuffix(")") {
            negative = true
            s = s.dropFirst().dropLast()
        }
        if s.hasPrefix("-") { negative.toggle(); s = s.dropFirst() } else if s.hasPrefix("+") { s = s.dropFirst() }
        if let first = s.first, currencySymbols.contains(first) {
            currency = first
            s = s.dropFirst()
            if s.hasPrefix("-") { negative.toggle(); s = s.dropFirst() }
        }
        if let last = s.last, currencySymbols.contains(last), currency == nil {
            currency = last
            s = s.dropLast()
        }
        s = Substring(s.trimmingCharacters(in: .whitespaces))
        if s.hasSuffix("%") {
            percent = true
            s = s.dropLast()
            s = Substring(s.trimmingCharacters(in: .whitespaces))
        }
        guard let first = s.first, first.isNumber || first == "." else { return nil }

        // Mixed fraction: "1 1/2" or "0 3/4".
        if !percent && currency == nil, let space = s.firstIndex(of: " ") {
            let whole = s[..<space], fraction = s[s.index(after: space)...]
            let parts = fraction.split(separator: "/")
            if let w = Double(whole), parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d != 0, whole.allSatisfy(\.isNumber) {
                let value = (w + n / d) * (negative ? -1 : 1)
                return Parsed(value: .number(value), format: d < 10 ? "# ?/?" : "# ??/??")
            }
            return nil
        }

        // Thousands separators must be in valid positions.
        var hasGrouping = false
        if s.contains(",") {
            let integerPart = s.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let groups = integerPart.split(separator: ",", omittingEmptySubsequences: false)
            guard groups.count > 1, (1...3).contains(groups[0].count), groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
            hasGrouping = true
            s = Substring(s.replacingOccurrences(of: ",", with: ""))
        }
        guard s.allSatisfy({ $0.isNumber || $0 == "." || $0 == "e" || $0 == "E" || $0 == "+" || $0 == "-" }),
              s.first?.isNumber == true || s.first == ".",
              var value = Double(s)
        else { return nil }
        if negative { value = -value }
        let decimals = s.split(separator: ".").count > 1 && !s.lowercased().contains("e") ? s.split(separator: ".")[1].count : 0

        var format: String?
        if percent {
            value /= 100
            format = decimals > 0 ? "0." + String(repeating: "0", count: min(decimals, 10)) + "%" : "0%"
        } else if let currency {
            let symbol = String(currency)
            format = decimals > 0 ? "\(symbol)#,##0.00" : "\(symbol)#,##0"
            if currency != "$" { format = decimals > 0 ? "#,##0.00 \(symbol)" : "#,##0 \(symbol)" }
            if currency == "£" || currency == "¥" { format = decimals > 0 ? "\(symbol)#,##0.00" : "\(symbol)#,##0" }
        } else if hasGrouping {
            format = decimals > 0 ? "#,##0." + String(repeating: "0", count: min(decimals, 10)) : "#,##0"
        } else if s.lowercased().contains("e") {
            format = "0.00E+00"
        }
        return Parsed(value: .number(value), format: format)
    }

    // MARK: - Dates and times

    private static let monthLookup: [String: Int] = {
        var map: [String: Int] = [:]
        for (i, name) in DateSerial.monthNames.enumerated() {
            map[name.lowercased()] = i + 1
            map[String(name.lowercased().prefix(3))] = i + 1
        }
        map["sept"] = 9
        return map
    }()

    private static func currentYear() -> Int {
        DateSerial.components(DateSerial.from(Date())).year
    }

    private static func parseDateTime(_ input: String) -> Parsed? {
        let text = input.trimmingCharacters(in: .whitespaces)
        // Split off a time part.
        var datePart = text
        var time: (Double, String)?
        if let t = parseTime(text) { return Parsed(value: .number(t.0), format: t.1) }
        if let space = text.lastIndex(of: " ") {
            let tail = String(text[text.index(after: space)...])
            var head = String(text[..<space])
            var timeText = tail
            if ["AM", "PM", "A", "P"].contains(tail.uppercased()), let second = head.lastIndex(of: " ") {
                timeText = String(head[head.index(after: second)...]) + " " + tail
                head = String(head[..<second])
            }
            if let t = parseTime(timeText) {
                time = t
                datePart = head
            }
        }
        if let t = text.firstIndex(of: "T"), text.count > 11, let parsedTime = parseTime(String(text[text.index(after: t)...])) {
            time = parsedTime
            datePart = String(text[..<t])
        }
        guard let (serial, dateFormat) = parseDate(datePart) else { return nil }
        if let (fraction, timeFormat) = time {
            return Parsed(value: .number(serial + fraction), format: dateFormat + " " + timeFormat)
        }
        return Parsed(value: .number(serial), format: dateFormat)
    }

    private static func parseTime(_ text: String) -> (Double, String)? {
        var s = text.trimmingCharacters(in: .whitespaces).uppercased()
        var meridiem: String?
        for suffix in ["AM", "PM", "A", "P"] where s.hasSuffix(suffix) {
            meridiem = suffix.hasPrefix("A") ? "AM" : "PM"
            s = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.count <= 3 || (meridiem == nil && parts.count == 1),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isNumber || $0 == "." } }),
              var hour = Double(parts[0]), let minute = Double(parts[1]), minute < 60
        else {
            // "3 PM"
            if let meridiem, let hour = Int(s), hour >= 1, hour <= 12 {
                let h = hour % 12 + (meridiem == "PM" ? 12 : 0)
                return (Double(h) / 24, "h:mm AM/PM")
            }
            return nil
        }
        let second = parts.count == 3 ? Double(parts[2]) ?? 0 : 0
        guard second < 60 else { return nil }
        if let meridiem {
            guard hour >= 1, hour <= 12 else { return nil }
            hour = hour.truncatingRemainder(dividingBy: 12) + (meridiem == "PM" ? 12 : 0)
        }
        let total = (hour * 3600 + minute * 60 + second) / 86400
        let format: String
        if meridiem != nil {
            format = parts.count == 3 ? "h:mm:ss AM/PM" : "h:mm AM/PM"
        } else if hour >= 24 {
            format = parts.count == 3 ? "[h]:mm:ss" : "[h]:mm"
        } else {
            format = parts.count == 3 ? "h:mm:ss" : "h:mm"
        }
        return (total, format)
    }

    private static func parseDate(_ text: String) -> (Double, String)? {
        let s = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        func valid(_ y: Int, _ m: Int, _ d: Int) -> Bool {
            m >= 1 && m <= 12 && d >= 1 && y >= 1900 && y <= 9999 && d <= DateSerial.daysInMonth(year: y, month: m)
        }
        func expandYear(_ y: Int, digits: Int) -> Int {
            digits <= 2 ? (y < 30 ? 2000 + y : 1900 + y) : y
        }

        // Numeric: 2024-01-15, 2024/1/15, 1/15/2024, 1/15/24, 1/15, 15.01.2024
        for separator in ["-", "/", "."] where s.contains(separator) {
            let parts = s.split(separator: Character(separator), omittingEmptySubsequences: false).map(String.init)
            if parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
                let n = parts.compactMap { Int($0) }
                if parts.count == 3 {
                    if parts[0].count == 4 {
                        guard valid(n[0], n[1], n[2]) else { return nil }
                        return (DateSerial.serial(year: n[0], month: n[1], day: n[2]), separator == "-" ? "yyyy-mm-dd" : "yyyy/m/d")
                    }
                    if separator == "." {
                        let y = expandYear(n[2], digits: parts[2].count)
                        guard valid(y, n[1], n[0]) else { return nil }
                        return (DateSerial.serial(year: y, month: n[1], day: n[0]), "d.m.yyyy")
                    }
                    let y = expandYear(n[2], digits: parts[2].count)
                    guard parts[2].count == 2 || parts[2].count == 4 else { return nil }
                    if valid(y, n[0], n[1]) {
                        return (DateSerial.serial(year: y, month: n[0], day: n[1]), parts[2].count == 2 ? "m/d/yy" : "m/d/yyyy")
                    }
                    if valid(y, n[1], n[0]) {
                        return (DateSerial.serial(year: y, month: n[1], day: n[0]), "d/m/yyyy")
                    }
                    return nil
                }
                if parts.count == 2, separator == "/" {
                    // m/d in the current year, or m/yyyy.
                    if parts[1].count == 4, n[0] >= 1, n[0] <= 12, valid(n[1], n[0], 1) {
                        return (DateSerial.serial(year: n[1], month: n[0], day: 1), "mmm-yy")
                    }
                    let y = currentYear()
                    if valid(y, n[0], n[1]) { return (DateSerial.serial(year: y, month: n[0], day: n[1]), "d-mmm") }
                }
                return nil
            }
        }

        // Textual: 15-Jan-2024, 15 Jan 2024, Jan 15 2024, January 15, 15-Jan, Jan-24
        let tokens = s.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "/" }).map(String.init)
        guard tokens.count >= 2, tokens.count <= 3 else { return nil }
        var month: Int?
        var numbers: [(Int, Int)] = []
        var monthFirst = false
        for (i, token) in tokens.enumerated() {
            if let m = monthLookup[token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))] {
                guard month == nil else { return nil }
                month = m
                monthFirst = i == 0
            } else if let n = Int(token.lowercased().replacingOccurrences(of: "st", with: "").replacingOccurrences(of: "nd", with: "").replacingOccurrences(of: "rd", with: "").replacingOccurrences(of: "th", with: "")) {
                numbers.append((n, token.count))
            } else {
                return nil
            }
        }
        guard let month else { return nil }
        switch numbers.count {
        case 1:
            let (n, digits) = numbers[0]
            if digits == 4 || (monthFirst && n > 31) {
                let y = expandYear(n, digits: digits)
                guard valid(y, month, 1) else { return nil }
                return (DateSerial.serial(year: y, month: month, day: 1), "mmm-yy")
            }
            let y = currentYear()
            guard valid(y, month, n) else {
                // "Jan-24" means January 2024.
                let year = expandYear(n, digits: digits)
                guard valid(year, month, 1) else { return nil }
                return (DateSerial.serial(year: year, month: month, day: 1), "mmm-yy")
            }
            return (DateSerial.serial(year: y, month: month, day: n), "d-mmm")
        case 2:
            let (a, _) = numbers[0], (b, bDigits) = numbers[1]
            let y = expandYear(b, digits: bDigits)
            guard valid(y, month, a) else { return nil }
            return (DateSerial.serial(year: y, month: month, day: a), monthFirst ? "mmmm d, yyyy" : "d-mmm-yy")
        default:
            return nil
        }
    }
}
