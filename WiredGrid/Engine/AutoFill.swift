import Foundation

/// Extends a pattern of cells the way Excel's fill handle does: number and date
/// series, "Item 1, Item 2…", weekday and month names, and formulas with
/// relative references shifted.
enum AutoFill {
    /// Generates cells for `count` new positions after (or before, when `reverse`) the source cells.
    static func extend(_ source: [Cell?], styles: [CellStyle], count: Int, reverse: Bool, sourceOffsets: [Int], step axisStep: (rows: Int, columns: Int), copyOnly: Bool) -> [Cell?] {
        guard !source.isEmpty, count > 0 else { return [] }
        let n = source.count
        let series = copyOnly ? nil : detectSeries(source, styles: styles)
        var result: [Cell?] = []
        for k in 1...count {
            // Position relative to the source start (negative when filling up/left).
            let position = reverse ? -k : n - 1 + k
            let sourceIndex = ((position % n) + n) % n
            var cell = source[sourceIndex]
            let style = styles[sourceIndex]
            if let formula = cell?.formula {
                let distance = position - sourceIndex
                cell?.formula = FormulaRewriter.shift(formula, rows: distance * axisStep.rows, columns: distance * axisStep.columns)
            } else if let series {
                cell = cell ?? Cell()
                cell?.value = series(position)
            }
            if cell != nil || !style.isPlain {
                var filled = cell ?? Cell()
                filled.style = style.isPlain ? nil : style
                result.append(filled)
            } else {
                result.append(nil)
            }
        }
        return result
    }

    private static let dayNames = DateSerial.dayNames
    private static let monthNames = DateSerial.monthNames

    /// A function from position (0 = first source cell) to value, if the source forms a series.
    private static func detectSeries(_ source: [Cell?], styles: [CellStyle]) -> ((Int) -> CellValue)? {
        let values = source.map { $0?.formula == nil ? ($0?.value ?? .empty) : .empty }
        if source.contains(where: { $0?.formula != nil }) { return nil }

        // Numbers (and dates).
        let numbers = values.compactMap(\.number)
        if numbers.count == values.count {
            let isDate = styles.first.map { NumberFormat.isDate($0.numberFormat) && !NumberFormat.isTime($0.numberFormat) } ?? false
            if numbers.count == 1 {
                if isDate { return { .number(numbers[0] + Double($0)) } }
                return nil // a single number is copied
            }
            if isDate {
                // Same day of month, different months → monthly steps.
                let parts = numbers.map { DateSerial.components($0) }
                let months = parts.map { $0.year * 12 + $0.month }
                let monthStep = months[1] - months[0]
                if parts.allSatisfy({ $0.day == parts[0].day }), monthStep != 0,
                   zip(months, months.dropFirst()).allSatisfy({ $1 - $0 == monthStep }) {
                    let first = numbers[0]
                    return { .number(DateSerial.addMonths(first, $0 * monthStep)) }
                }
            }
            // Least-squares linear trend, as Excel does.
            let xs = numbers.indices.map(Double.init)
            guard let fit = try? Statistics.regression(numbers, xs) else { return nil }
            return { position in
                let v = fit.intercept + fit.slope * Double(position)
                return .number((v * 1e10).rounded() / 1e10)
            }
        }

        // Weekday and month names.
        for (names, cycle) in [(dayNames, 7), (monthNames, 12)] {
            let full = names.map { $0.lowercased() }
            let short = names.map { String($0.prefix(3)).lowercased() }
            let texts = values.compactMap { v -> String? in if case .string(let s) = v { return s }; return nil }
            guard texts.count == values.count else { break }
            let indices = texts.map { t -> (Int, Bool)? in
                if let i = full.firstIndex(of: t.lowercased()) { return (i, false) }
                if let i = short.firstIndex(of: t.lowercased()) { return (i, true) }
                return nil
            }
            if indices.allSatisfy({ $0 != nil }), let first = indices[0] {
                let step = indices.count > 1 ? ((indices[1]!.0 - first.0) % cycle + cycle) % cycle : 1
                let uppercase = texts[0] == texts[0].uppercased()
                let lowercase = texts[0] == texts[0].lowercased()
                return { position in
                    let index = ((first.0 + position * max(step, 1)) % cycle + cycle) % cycle
                    var name = first.1 ? String(names[index].prefix(3)) : names[index]
                    if uppercase { name = name.uppercased() } else if lowercase { name = name.lowercased() }
                    return .string(name)
                }
            }
        }

        // Text ending (or starting) in a number: "Item 1", "Q1", "1st".
        let pieces = values.map { v -> (prefix: String, number: Int, width: Int, suffix: String)? in
            guard case .string(let s) = v else { return nil }
            return splitTrailingNumber(s)
        }
        if pieces.allSatisfy({ $0 != nil }), let first = pieces[0], pieces.allSatisfy({ $0!.prefix == first.prefix && $0!.suffix == first.suffix }) {
            let step = pieces.count > 1 ? pieces[1]!.number - first.number : 1
            return { position in
                let n = first.number + position * step
                var digits = String(abs(n))
                if digits.count < first.width { digits = String(repeating: "0", count: first.width - digits.count) + digits }
                return .string(first.prefix + (n < 0 ? "-" : "") + digits + first.suffix)
            }
        }
        return nil
    }

    private static func splitTrailingNumber(_ s: String) -> (prefix: String, number: Int, width: Int, suffix: String)? {
        let chars = Array(s)
        guard let lastDigit = chars.lastIndex(where: \.isNumber) else { return nil }
        var firstDigit = lastDigit
        while firstDigit > 0 && chars[firstDigit - 1].isNumber { firstDigit -= 1 }
        let digits = String(chars[firstDigit...lastDigit])
        guard digits.count <= 9, let number = Int(digits) else { return nil }
        let suffix = String(chars[(lastDigit + 1)...])
        // Only short suffixes like "st"/"th" count, otherwise it's just text.
        guard suffix.count <= 3 else { return nil }
        return (String(chars[..<firstDigit]), number, digits.hasPrefix("0") ? digits.count : 1, suffix)
    }
}
