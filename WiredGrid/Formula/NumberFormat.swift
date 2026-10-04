import Foundation

/// The result of applying a number format.
struct FormattedValue: Equatable {
    var text: String
    var color: RGBColor?
    /// For formats with a `*` fill (Accounting): text before and after the fill point.
    var fillSplit: (left: String, right: String)?
    var fillCharacter: Character = " "

    static func == (a: FormattedValue, b: FormattedValue) -> Bool {
        a.text == b.text && a.color == b.color && a.fillSplit?.left == b.fillSplit?.left && a.fillSplit?.right == b.fillSplit?.right
    }
}

/// Excel number format codes: sections, digit placeholders, grouping, percent,
/// scientific, fractions, text, colors, literals, fills and date/time tokens.
enum NumberFormat {
    // MARK: - Presets

    static let generalCode = "General"
    static let number = "#,##0.00"
    static let currency = "$#,##0.00"
    static let accounting = "_($* #,##0.00_);_($* (#,##0.00);_($* \"-\"??_);_(@_)"
    static let shortDate = "m/d/yyyy"
    static let longDate = "dddd, mmmm d, yyyy"
    static let time = "h:mm:ss AM/PM"
    static let percent = "0.00%"
    static let fraction = "# ?/?"
    static let scientific = "0.00E+00"
    static let text = "@"

    // MARK: - General

    /// Excel's General format: up to `maxLength` characters, switching to scientific when needed.
    static func general(_ value: Double, maxLength: Int = 11) -> String {
        if value == 0 { return "0" }
        guard value.isFinite else { return FormulaError.num.rawValue }
        let magnitude = abs(value)
        if magnitude >= 1e-9 && magnitude < 1e11 || (maxLength > 11 && magnitude < 1e15 && magnitude >= 1e-9) {
            if value == value.rounded(), magnitude < 1e15 {
                let s = String(Int64(value))
                if s.count <= maxLength { return s }
            }
            let integerDigits = magnitude >= 1 ? Int(log10(magnitude)) + 1 : 1
            var decimals = max(0, min(15 - integerDigits, 14))
            while decimals >= 0 {
                let s = trimZeros(String(format: "%.\(decimals)f", value))
                if s.count <= maxLength && s != "0" && s != "-0" { return s }
                decimals -= 1
            }
        }
        // Scientific: 1.23457E+11
        var decimals = 5
        while decimals >= 0 {
            var s = String(format: "%.\(decimals)E", value)
            if let e = s.firstIndex(of: "E") {
                let mantissa = trimZeros(String(s[..<e]))
                s = mantissa + s[e...]
            }
            if s.count <= max(maxLength, 7) { return s }
            decimals -= 1
        }
        return String(format: "%.0E", value)
    }

    private static func trimZeros(_ s: String) -> String {
        guard s.contains(".") else { return s }
        var t = s
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }

    // MARK: - Formatting

    static func format(_ value: CellValue, _ code: String) -> FormattedValue {
        switch value {
        case .empty: return FormattedValue(text: "")
        case .bool(let b): return FormattedValue(text: b ? "TRUE" : "FALSE")
        case .error(let e): return FormattedValue(text: e.rawValue)
        case .string(let s):
            let sections = parsed(code)
            if let textSection = sections.count >= 4 ? sections[3] : sections.first(where: { $0.hasText }) {
                return render(textSection, text: s)
            }
            return FormattedValue(text: s)
        case .number(let n):
            return formatNumber(n, code)
        }
    }

    static func formatNumber(_ n: Double, _ code: String) -> FormattedValue {
        let sections = parsed(code)
        guard !sections.isEmpty else { return FormattedValue(text: general(n)) }
        var section: Section
        var value = n
        var autoMinus = false
        // Explicit conditions such as [>=100] pick their own sections.
        if sections.contains(where: { $0.condition != nil }) {
            section = sections.first { $0.condition?(n) ?? false } ?? sections.first { $0.condition == nil && !$0.isTextOnly } ?? sections[0]
            value = abs(n)
            autoMinus = n < 0
        } else {
            let numeric = sections.filter { !$0.isTextOnly }
            switch numeric.count {
            case 0:
                return FormattedValue(text: general(n))
            case 1:
                section = numeric[0]
                autoMinus = n < 0
                value = abs(n)
            case 2:
                section = n < 0 ? numeric[1] : numeric[0]
                value = abs(n)
            default:
                section = n < 0 ? numeric[1] : (n == 0 ? numeric[2] : numeric[0])
                value = abs(n)
            }
        }
        var result = render(section, number: value)
        if autoMinus, !section.isDate, result.text.contains(where: { $0.isNumber && $0 != "0" }) || (section.isGeneral && n != 0) {
            result.text = "-" + result.text
            if let split = result.fillSplit { result.fillSplit = ("-" + split.left, split.right) }
        }
        return result
    }

    // MARK: - Parsing

    fileprivate enum Token {
        case literal(String)
        case digit(Character)          // 0 # ?
        case decimalPoint
        case comma
        case percent
        case exponent(String)          // "E+" or "E-"
        case slash
        case text                       // @
        case skip(Character)            // _x
        case fill(Character)            // *x
        case general
        case date(String)               // yyyy, mm, d, h, ss, AM/PM …
    }

    fileprivate struct Section {
        var tokens: [Token] = []
        var color: RGBColor?
        var condition: ((Double) -> Bool)?
        var elapsed = false

        var hasText: Bool { tokens.contains { if case .text = $0 { return true }; return false } }
        var isGeneral: Bool { tokens.contains { if case .general = $0 { return true }; return false } }
        var isDate: Bool { tokens.contains { if case .date = $0 { return true }; return false } }
        var hasDigits: Bool { tokens.contains { if case .digit = $0 { return true }; return false } }
        var isTextOnly: Bool { hasText && !hasDigits && !isGeneral && !isDate }
    }

    private static var cache: [String: [Section]] = [:]
    private static let cacheLock = NSLock()

    private static func parsed(_ code: String) -> [Section] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cache[code] { return cached }
        let sections = parse(code)
        if cache.count > 500 { cache.removeAll() }
        cache[code] = sections
        return sections
    }

    private static let colorNames: [String: RGBColor] = [
        "BLACK": RGBColor(0x000000), "WHITE": RGBColor(0xFFFFFF), "RED": RGBColor(0xFF0000), "GREEN": RGBColor(0x00A000),
        "BLUE": RGBColor(0x0000FF), "YELLOW": RGBColor(0xC8A000), "MAGENTA": RGBColor(0xFF00FF), "CYAN": RGBColor(0x00A0C0),
    ]

    private static func parse(_ code: String) -> [Section] {
        if code.isEmpty || code.caseInsensitiveCompare("General") == .orderedSame {
            return [Section(tokens: [.general])]
        }
        var sections: [Section] = []
        var section = Section()
        let chars = Array(code)
        var i = 0
        var literal = ""

        func flush() {
            if !literal.isEmpty { section.tokens.append(.literal(literal)); literal = "" }
        }

        while i < chars.count {
            let ch = chars[i]
            let lower = Character(ch.lowercased())
            switch ch {
            case ";":
                flush()
                sections.append(section)
                section = Section()
                i += 1
            case "\"":
                i += 1
                while i < chars.count && chars[i] != "\"" { literal.append(chars[i]); i += 1 }
                i += 1
            case "\\":
                if i + 1 < chars.count { literal.append(chars[i + 1]) }
                i += 2
            case "_":
                flush()
                if i + 1 < chars.count { section.tokens.append(.skip(chars[i + 1])) }
                i += 2
            case "*":
                flush()
                if i + 1 < chars.count { section.tokens.append(.fill(chars[i + 1])) }
                i += 2
            case "[":
                var content = ""
                i += 1
                while i < chars.count && chars[i] != "]" { content.append(chars[i]); i += 1 }
                i += 1
                let upper = content.uppercased()
                if let color = colorNames[upper] {
                    section.color = color
                } else if upper.hasPrefix("COLOR"), let n = Int(upper.dropFirst(5)) {
                    section.color = [RGBColor(0x000000), RGBColor(0xFFFFFF), RGBColor(0xFF0000), RGBColor(0x00FF00), RGBColor(0x0000FF), RGBColor(0xFFFF00), RGBColor(0xFF00FF), RGBColor(0x00FFFF)][max(0, min(7, n - 1))]
                } else if content.hasPrefix("$") {
                    flush()
                    let symbol = content.dropFirst().split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
                    section.tokens.append(.literal(symbol))
                } else if let first = upper.first, first == "H" || first == "M" || first == "S", upper.allSatisfy({ $0 == first }) {
                    flush()
                    section.elapsed = true
                    section.tokens.append(.date("[" + upper.lowercased() + "]"))
                } else if let condition = parseCondition(content) {
                    section.condition = condition
                }
            case "0", "#", "?":
                flush()
                section.tokens.append(.digit(ch))
                i += 1
            case ".":
                flush()
                // A decimal point in a time format means fractional seconds.
                if section.isDate, i + 1 < chars.count, chars[i + 1] == "0" {
                    var zeros = ""
                    i += 1
                    while i < chars.count && chars[i] == "0" { zeros.append("0"); i += 1 }
                    section.tokens.append(.date("." + zeros))
                } else {
                    section.tokens.append(.decimalPoint)
                    i += 1
                }
            case ",":
                flush()
                section.tokens.append(.comma)
                i += 1
            case "%":
                flush()
                section.tokens.append(.percent)
                i += 1
            case "/":
                flush()
                section.tokens.append(section.isDate ? .literal("/") : .slash)
                i += 1
            case "@":
                flush()
                section.tokens.append(.text)
                i += 1
            case "E", "e":
                if i + 1 < chars.count, chars[i + 1] == "+" || chars[i + 1] == "-" {
                    flush()
                    section.tokens.append(.exponent("E" + String(chars[i + 1])))
                    i += 2
                } else {
                    literal.append(ch)
                    i += 1
                }
            case "G", "g":
                if String(chars[i..<min(i + 7, chars.count)]).caseInsensitiveCompare("General") == .orderedSame {
                    flush()
                    section.tokens.append(.general)
                    i += 7
                } else {
                    literal.append(ch)
                    i += 1
                }
            case "A", "a":
                let rest = String(chars[i..<min(i + 5, chars.count)]).uppercased()
                if rest.hasPrefix("AM/PM") {
                    flush()
                    section.tokens.append(.date("AM/PM"))
                    i += 5
                } else if rest.hasPrefix("A/P") {
                    flush()
                    section.tokens.append(.date("A/P"))
                    i += 3
                } else {
                    literal.append(ch)
                    i += 1
                }
            default:
                if "ymdhs".contains(lower) {
                    flush()
                    var run = String(lower)
                    i += 1
                    while i < chars.count, Character(chars[i].lowercased()) == lower { run.append(lower); i += 1 }
                    section.tokens.append(.date(run))
                } else {
                    literal.append(ch)
                    i += 1
                }
            }
        }
        flush()
        sections.append(section)
        return sections.map(resolveMinutes)
    }

    /// "m" after an hour or before a second means minutes, not months.
    private static func resolveMinutes(_ section: Section) -> Section {
        var s = section
        let dateIndices = s.tokens.indices.filter { if case .date = s.tokens[$0] { return true }; return false }
        for (position, index) in dateIndices.enumerated() {
            guard case .date(let run) = s.tokens[index], run.first == "m", run.count <= 2 else { continue }
            var previous: String?
            var next: String?
            if position > 0, case .date(let p) = s.tokens[dateIndices[position - 1]] { previous = p }
            if position + 1 < dateIndices.count, case .date(let n) = s.tokens[dateIndices[position + 1]] { next = n }
            if previous?.first == "h" || previous?.hasPrefix("[h") == true || next?.first == "s" {
                s.tokens[index] = .date(run == "m" ? "n" : "nn")
            }
        }
        return s
    }

    private static func parseCondition(_ content: String) -> ((Double) -> Bool)? {
        for op in [">=", "<=", "<>", "=", ">", "<"] where content.hasPrefix(op) {
            guard let limit = Double(content.dropFirst(op.count)) else { return nil }
            switch op {
            case ">=": return { $0 >= limit }
            case "<=": return { $0 <= limit }
            case "<>": return { $0 != limit }
            case "=": return { $0 == limit }
            case ">": return { $0 > limit }
            default: return { $0 < limit }
            }
        }
        return nil
    }

    // MARK: - Rendering

    private static func render(_ section: Section, text: String) -> FormattedValue {
        var out = ""
        var fill: (String, Character)?
        for token in section.tokens {
            switch token {
            case .literal(let s): out += s
            case .text: out += text
            case .skip: out += " "
            case .fill(let ch): fill = (out, ch)
            default: break
            }
        }
        var result = FormattedValue(text: out, color: section.color)
        if let (left, ch) = fill {
            result.fillSplit = (left, String(out.dropFirst(left.count)))
            result.fillCharacter = ch
        }
        return result
    }

    private static func render(_ section: Section, number: Double) -> FormattedValue {
        if section.isDate { return renderDate(section, serial: number) }
        if section.isGeneral && !section.hasDigits {
            var out = ""
            for token in section.tokens {
                switch token {
                case .general: out += general(number)
                case .literal(let s): out += s
                case .skip: out += " "
                default: break
                }
            }
            return FormattedValue(text: out, color: section.color)
        }

        let tokens = section.tokens
        // Locate structure.
        let decimalIndex = tokens.firstIndex { if case .decimalPoint = $0 { return true }; return false }
        let exponentIndex = tokens.firstIndex { if case .exponent = $0 { return true }; return false }
        let slashIndex = tokens.firstIndex { if case .slash = $0 { return true }; return false }
        let percentCount = tokens.filter { if case .percent = $0 { return true }; return false }.count
        let digitIndices = tokens.indices.filter { if case .digit = tokens[$0] { return true }; return false }

        var value = number * pow(100, Double(percentCount))

        if let slashIndex, !digitIndices.isEmpty {
            return renderFraction(section, value: value, slashIndex: slashIndex)
        }

        let integerEnd = decimalIndex ?? exponentIndex ?? tokens.count
        let integerDigitIndices = digitIndices.filter { $0 < integerEnd }
        let fractionDigitIndices = digitIndices.filter { $0 > (decimalIndex ?? Int.max) && $0 < (exponentIndex ?? Int.max) }
        let exponentDigitIndices = digitIndices.filter { $0 > (exponentIndex ?? Int.max) }

        // Commas: between integer digits → grouping; right after the last integer digit → scale by 1000.
        var grouping = false
        var scaleCount = 0
        if let lastIntegerDigit = integerDigitIndices.last {
            for index in tokens.indices where index < integerEnd {
                guard case .comma = tokens[index] else { continue }
                if index < lastIntegerDigit, let firstIntegerDigit = integerDigitIndices.first, index > firstIntegerDigit { grouping = true }
                else if index > lastIntegerDigit { scaleCount += 1 }
            }
        }
        value /= pow(1000, Double(scaleCount))

        var exponentValue = 0
        if exponentIndex != nil {
            if value != 0 {
                let integerPlaces = max(integerDigitIndices.count, 1)
                exponentValue = Int(floor(log10(abs(value)))) - (integerPlaces - 1)
                // Engineering-style formats (##0.0E+0) use multiples of the integer width.
                if integerPlaces > 1, integerDigitIndices.contains(where: { if case .digit("#") = tokens[$0] { return true }; return false }) {
                    exponentValue = Int(floor(Double(Int(floor(log10(abs(value))))) / Double(integerPlaces))) * integerPlaces
                }
                value /= pow(10, Double(exponentValue))
            }
        }

        let fractionPlaces = fractionDigitIndices.count
        var rounded = excelRound(value, fractionPlaces)
        if exponentIndex != nil, abs(rounded) >= pow(10, Double(max(integerDigitIndices.count, 1))) {
            rounded /= 10
            exponentValue += 1
        }
        let fixed = String(format: "%.\(fractionPlaces)f", abs(rounded))
        let parts = fixed.split(separator: ".", omittingEmptySubsequences: false)
        var integerDigits = String(parts[0])
        if integerDigits == "0" { integerDigits = "" }
        let fractionDigits = parts.count > 1 ? Array(parts[1]) : []

        // Integer part: fill placeholders from the right.
        var integerOutput: [Int: String] = [:]
        let minimumZeros = integerDigitIndices.filter { if case .digit("0") = tokens[$0] { return true }; return false }.count
        if grouping {
            var digits = integerDigits
            if digits.count < minimumZeros { digits = String(repeating: "0", count: minimumZeros - digits.count) + digits }
            if let first = integerDigitIndices.first {
                integerOutput[first] = groupThousands(digits)
                for index in integerDigitIndices.dropFirst() { integerOutput[index] = "" }
            }
        } else {
            var remaining = Array(integerDigits)
            for index in integerDigitIndices.reversed() {
                guard case .digit(let kind) = tokens[index] else { continue }
                if let last = remaining.popLast() {
                    integerOutput[index] = String(last)
                } else {
                    integerOutput[index] = kind == "0" ? "0" : (kind == "?" ? " " : "")
                }
            }
            if let first = integerDigitIndices.first, !remaining.isEmpty {
                integerOutput[first] = String(remaining) + (integerOutput[first] ?? "")
            }
        }

        // Fraction part: fill from the left, trimming optional trailing zeros.
        var fractionOutput: [Int: String] = [:]
        var lastSignificant = -1
        for (position, digit) in fractionDigits.enumerated() where digit != "0" { lastSignificant = position }
        for (position, index) in fractionDigitIndices.enumerated() {
            guard case .digit(let kind) = tokens[index] else { continue }
            let digit = position < fractionDigits.count ? fractionDigits[position] : "0"
            if position > lastSignificant && kind != "0" {
                fractionOutput[index] = kind == "?" ? " " : ""
            } else {
                fractionOutput[index] = String(digit)
            }
        }

        // Exponent digits.
        var exponentOutput: [Int: String] = [:]
        if !exponentDigitIndices.isEmpty {
            var digits = String(abs(exponentValue))
            let minimum = exponentDigitIndices.count
            if digits.count < minimum { digits = String(repeating: "0", count: minimum - digits.count) + digits }
            exponentOutput[exponentDigitIndices[0]] = digits
            for index in exponentDigitIndices.dropFirst() { exponentOutput[index] = "" }
        }

        var out = ""
        var fill: (String, Character)?
        let showDecimalPoint = !fractionDigitIndices.isEmpty
        for (index, token) in tokens.enumerated() {
            switch token {
            case .literal(let s): out += s
            case .digit:
                out += integerOutput[index] ?? fractionOutput[index] ?? exponentOutput[index] ?? ""
            case .decimalPoint:
                if showDecimalPoint || decimalIndex == index { out += "." }
            case .comma: break
            case .percent: out += "%"
            case .exponent(let e):
                out += exponentValue < 0 ? "E-" : (e == "E+" ? "E+" : "E")
            case .skip: out += " "
            case .fill(let ch): fill = (out, ch)
            case .general: out += general(number)
            case .text, .slash, .date: break
            }
        }
        var result = FormattedValue(text: out, color: section.color)
        if let (left, ch) = fill {
            result.fillSplit = (left, String(out.dropFirst(left.count)))
            result.fillCharacter = ch
        }
        return result
    }

    private static func groupThousands(_ digits: String) -> String {
        guard digits.count > 3 else { return digits }
        var result = ""
        for (i, ch) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { result += "," }
            result.append(ch)
        }
        return result
    }

    private static func renderFraction(_ section: Section, value: Double, slashIndex: Int) -> FormattedValue {
        let tokens = section.tokens
        let digitIndices = tokens.indices.filter { if case .digit = tokens[$0] { return true }; return false }
        let denominatorIndices = digitIndices.filter { $0 > slashIndex }
        // Literal digits after the slash give a fixed denominator ("# ?/8").
        var fixedDenominator: Int?
        if let literalAfter = tokens[(slashIndex + 1)...].first(where: { if case .literal = $0 { return true }; if case .digit = $0 { return true }; return false }),
           case .literal(let text) = literalAfter, let n = Int(text.trimmingCharacters(in: .whitespaces)) {
            fixedDenominator = n
        }
        // Whole part if there's a digit group separated by a literal before the numerator.
        let numeratorIndices = digitIndices.filter { $0 < slashIndex }
        var wholeIndices: [Int] = []
        var numeratorGroup: [Int] = numeratorIndices
        if let breakIndex = numeratorIndices.indices.last(where: { $0 > 0 && numeratorIndices[$0] - numeratorIndices[$0 - 1] > 1 }) {
            wholeIndices = Array(numeratorIndices[..<breakIndex])
            numeratorGroup = Array(numeratorIndices[breakIndex...])
        }
        let whole = wholeIndices.isEmpty ? 0 : Int(value.rounded(.towardZero))
        let remainder = value - Double(whole)
        var numerator = 0, denominator = 1
        if let fixedDenominator {
            denominator = fixedDenominator
            numerator = Int((remainder * Double(denominator)).rounded())
        } else {
            let maxDenominator = Int(pow(10, Double(max(denominatorIndices.count, 1)))) - 1
            var bestError = Double.infinity
            for d in 1...max(maxDenominator, 1) {
                let n = (remainder * Double(d)).rounded()
                let error = abs(remainder - n / Double(d))
                if error < bestError - 1e-12 { bestError = error; numerator = Int(n); denominator = d }
                if error < 1e-12 { break }
            }
        }
        var wholeValue = whole
        if numerator == denominator && !wholeIndices.isEmpty { wholeValue += 1; numerator = 0 }

        var out = ""
        var wroteWhole = false
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if wholeIndices.contains(index) {
                if !wroteWhole {
                    out += wholeValue == 0 && numerator != 0 ? "" : String(wholeValue)
                    wroteWhole = true
                }
            } else if numeratorGroup.first == index {
                if numerator == 0 && !wholeIndices.isEmpty {
                    // "5" rather than "5 0/1"
                    return FormattedValue(text: out.trimmingCharacters(in: .whitespaces).isEmpty ? "0" : String(wholeValue), color: section.color)
                }
                let width = numeratorGroup.count
                let text = String(numerator)
                out += String(repeating: " ", count: max(0, width - text.count)) + text
            } else if numeratorGroup.contains(index) {
                // consumed
            } else if case .slash = token {
                out += "/"
            } else if denominatorIndices.first == index {
                let text = String(denominator)
                out += text + String(repeating: " ", count: max(0, denominatorIndices.count - text.count))
            } else if denominatorIndices.contains(index) {
                // consumed
            } else if case .literal(let s) = token {
                if fixedDenominator != nil, index > slashIndex, Int(s.trimmingCharacters(in: .whitespaces)) != nil {
                    out += String(denominator)
                } else {
                    out += s
                }
            } else if case .skip = token {
                out += " "
            }
            index += 1
        }
        return FormattedValue(text: out, color: section.color)
    }

    private static func renderDate(_ section: Section, serial: Double) -> FormattedValue {
        guard serial >= 0, serial < 2_958_466 else { return FormattedValue(text: String(repeating: "#", count: 8)) }
        let (year, month, day) = DateSerial.components(serial)
        let hasMeridiem = section.tokens.contains { if case .date(let t) = $0 { return t == "AM/PM" || t == "A/P" }; return false }
        let fractionDigits = section.tokens.compactMap { token -> Int? in
            if case .date(let t) = token, t.hasPrefix(".") { return t.count - 1 }
            return nil
        }.first ?? 0
        let totalSeconds = serial * 86400
        let roundedSeconds = fractionDigits > 0 ? totalSeconds : totalSeconds.rounded()
        let secondsOfDay = roundedSeconds - (serial.rounded(.down) * 86400)
        let hour = Int(secondsOfDay / 3600) % 24
        let minute = Int(secondsOfDay.truncatingRemainder(dividingBy: 3600) / 60)
        let second = Int(secondsOfDay.truncatingRemainder(dividingBy: 60))
        let weekday = DateSerial.weekday(serial)

        func pad(_ n: Int, _ width: Int) -> String {
            let s = String(n)
            return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
        }

        var out = ""
        var fill: (String, Character)?
        for token in section.tokens {
            switch token {
            case .literal(let s): out += s
            case .skip: out += " "
            case .fill(let ch): fill = (out, ch)
            case .digit(let ch): out += ch == "0" ? "0" : ""
            case .decimalPoint: out += "."
            case .comma: out += ","
            case .percent: out += "%"
            case .date(let t):
                switch t {
                case "yyyy", "yyy": out += pad(year, 4)
                case "yy", "y": out += pad(year % 100, 2)
                case let s where s.first == "y": out += pad(year, 4)
                case "m": out += String(month)
                case "mm": out += pad(month, 2)
                case "mmm": out += String(DateSerial.monthNames[month - 1].prefix(3))
                case "mmmmm": out += String(DateSerial.monthNames[month - 1].prefix(1))
                case let s where s.first == "m": out += DateSerial.monthNames[month - 1]
                case "d": out += String(day)
                case "dd": out += pad(day, 2)
                case "ddd": out += String(DateSerial.dayNames[weekday - 1].prefix(3))
                case let s where s.first == "d": out += DateSerial.dayNames[weekday - 1]
                case "h": out += String(hasMeridiem ? (hour % 12 == 0 ? 12 : hour % 12) : hour)
                case let s where s.first == "h": out += pad(hasMeridiem ? (hour % 12 == 0 ? 12 : hour % 12) : hour, 2)
                case "n": out += String(minute)
                case "nn": out += pad(minute, 2)
                case "s": out += String(second)
                case let s where s.first == "s": out += pad(second, 2)
                case "AM/PM": out += hour < 12 ? "AM" : "PM"
                case "A/P": out += hour < 12 ? "A" : "P"
                case "[h]", "[hh]": out += pad(Int(totalSeconds / 3600), t.count - 2)
                case "[m]", "[mm]": out += pad(Int(totalSeconds / 60), t.count - 2)
                case "[s]", "[ss]": out += pad(Int(totalSeconds), t.count - 2)
                case let s where s.hasPrefix("."):
                    let fraction = totalSeconds - totalSeconds.rounded(.down)
                    let digits = s.count - 1
                    let scaled = Int((fraction * pow(10, Double(digits))).rounded(.down))
                    out += "." + pad(scaled, digits)
                default: out += t
                }
            default: break
            }
        }
        var result = FormattedValue(text: out, color: section.color)
        if let (left, ch) = fill {
            result.fillSplit = (left, String(out.dropFirst(left.count)))
            result.fillCharacter = ch
        }
        return result
    }

    // MARK: - Introspection

    static func isDate(_ code: String) -> Bool {
        parsed(code).first?.isDate ?? false
    }

    static func isTime(_ code: String) -> Bool {
        guard let section = parsed(code).first, section.isDate else { return false }
        return section.tokens.contains { if case .date(let t) = $0 { return t.first == "h" || t.first == "n" || t.first == "s" || t.hasPrefix("[") }; return false }
            && !section.tokens.contains { if case .date(let t) = $0 { return t.first == "d" || t.first == "y" || t.first == "m" }; return false }
    }

    static func isText(_ code: String) -> Bool { code == "@" }

    static func isPercent(_ code: String) -> Bool {
        parsed(code).first?.tokens.contains { if case .percent = $0 { return true }; return false } ?? false
    }

    /// Number of decimal places in the first section.
    static func decimals(_ code: String) -> Int {
        guard let section = parsed(code).first else { return 0 }
        guard let point = section.tokens.firstIndex(where: { if case .decimalPoint = $0 { return true }; return false }) else { return 0 }
        var count = 0
        for token in section.tokens[(point + 1)...] {
            if case .digit = token { count += 1 } else if case .exponent = token { break }
        }
        return count
    }

    /// Adds or removes one decimal place in every numeric section.
    static func adjustingDecimals(_ code: String, by delta: Int, sampleValue: Double?) -> String {
        var base = code
        if code == generalCode || code.isEmpty {
            // Start from the value's current General rendering.
            let places: Int = {
                guard let v = sampleValue else { return 0 }
                let s = general(v)
                guard let dot = s.firstIndex(of: "."), !s.contains("E") else { return 0 }
                return s.distance(from: dot, to: s.endIndex) - 1
            }()
            base = places > 0 ? "0." + String(repeating: "0", count: places) : "0"
        }
        let sections = splitSections(base)
        let adjusted = sections.map { section -> String in
            if section.contains("@") && !section.contains("0") { return section }
            return adjustSection(section, by: delta)
        }
        return adjusted.joined(separator: ";")
    }

    private static func splitSections(_ code: String) -> [String] {
        var sections: [String] = []
        var current = ""
        var inQuote = false
        var escape = false
        for ch in code {
            if escape { current.append(ch); escape = false; continue }
            if ch == "\\" { escape = true; current.append(ch); continue }
            if ch == "\"" { inQuote.toggle() }
            if ch == ";" && !inQuote { sections.append(current); current = ""; continue }
            current.append(ch)
        }
        sections.append(current)
        return sections
    }

    private static func adjustSection(_ section: String, by delta: Int) -> String {
        let chars = Array(section)
        // Find the last digit placeholder run (before any exponent) outside quotes.
        var inQuote = false
        var lastDigit: Int?
        var decimalPoint: Int?
        var exponent: Int?
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "\"" { inQuote.toggle() }
            if !inQuote {
                if ch == "\\" || ch == "_" || ch == "*" { i += 2; continue }
                if ch == "[" { while i < chars.count && chars[i] != "]" { i += 1 } }
                if (ch == "E" || ch == "e"), i + 1 < chars.count, chars[i + 1] == "+" || chars[i + 1] == "-" { exponent = i; break }
                if "0#?".contains(ch) { lastDigit = i }
                if ch == "." { decimalPoint = i }
            }
            i += 1
        }
        guard let lastDigit else { return section }
        var result = chars
        if delta > 0 {
            if decimalPoint == nil || decimalPoint! > lastDigit {
                result.insert(contentsOf: Array(".0"), at: lastDigit + 1)
            } else {
                result.insert("0", at: lastDigit + 1)
            }
        } else if let point = decimalPoint, point < lastDigit {
            result.remove(at: lastDigit)
            if lastDigit - 1 == point { result.remove(at: point) }
        }
        _ = exponent
        return String(result)
    }
}
