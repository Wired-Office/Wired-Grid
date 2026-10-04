import Foundation

/// Range-wide statistics some rules need (averages, top-N thresholds, duplicates).
struct ConditionalStats {
    var minimum = 0.0
    var maximum = 0.0
    var average = 0.0
    var sortedNumbers: [Double] = []
    var textCounts: [String: Int] = [:]

    init(values: [CellValue]) {
        sortedNumbers = values.compactMap(\.number).sorted()
        minimum = sortedNumbers.first ?? 0
        maximum = sortedNumbers.last ?? 0
        average = sortedNumbers.isEmpty ? 0 : sortedNumbers.reduce(0, +) / Double(sortedNumbers.count)
        for v in values where !v.isEmpty {
            textCounts[v.plainText.lowercased(), default: 0] += 1
        }
    }

    func threshold(top: Bool, count: Int, percent: Bool) -> Double? {
        guard !sortedNumbers.isEmpty else { return nil }
        let n = percent ? max(1, Int((Double(sortedNumbers.count) * Double(count) / 100).rounded(.down))) : count
        guard n > 0 else { return nil }
        let clamped = min(n, sortedNumbers.count)
        return top ? sortedNumbers[sortedNumbers.count - clamped] : sortedNumbers[clamped - 1]
    }
}

/// What conditional formatting changes about one cell.
struct ConditionalLook {
    var fill: RGBColor?
    var text: RGBColor?
    var bold = false
    var italic = false
    var border: RGBColor?
    /// Fraction of the cell width, and color.
    var dataBar: (Double, RGBColor)?
    var icon: (ConditionalFormat.IconSet, Int)?

    var isEmpty: Bool { fill == nil && text == nil && !bold && !italic && border == nil && dataBar == nil && icon == nil }
}

enum ConditionalEvaluator {
    static func matches(_ rule: ConditionalFormat.Rule, value: CellValue, stats: ConditionalStats?) -> Bool {
        let number = value.number
        switch rule {
        case .greaterThan(let limit): return number.map { $0 > limit } ?? false
        case .lessThan(let limit): return number.map { $0 < limit } ?? false
        case .between(let a, let b): return number.map { $0 >= min(a, b) && $0 <= max(a, b) } ?? false
        case .equalTo(let text):
            if let n = number, let t = ValueParser.number(from: text) { return n == t }
            return value.plainText.caseInsensitiveCompare(text) == .orderedSame
        case .notEqualTo(let text):
            if let n = number, let t = ValueParser.number(from: text) { return n != t }
            return value.plainText.caseInsensitiveCompare(text) != .orderedSame
        case .textContains(let t): return !t.isEmpty && value.plainText.range(of: t, options: .caseInsensitive) != nil
        case .beginsWith(let t): return value.plainText.lowercased().hasPrefix(t.lowercased())
        case .endsWith(let t): return value.plainText.lowercased().hasSuffix(t.lowercased())
        case .blanks: return value.isEmpty || value == .string("")
        case .noBlanks: return !(value.isEmpty || value == .string(""))
        case .duplicates:
            guard !value.isEmpty, let stats else { return false }
            return (stats.textCounts[value.plainText.lowercased()] ?? 0) > 1
        case .uniques:
            guard !value.isEmpty, let stats else { return false }
            return (stats.textCounts[value.plainText.lowercased()] ?? 0) == 1
        case .top(let count, let percent):
            guard let n = number, let t = stats?.threshold(top: true, count: count, percent: percent) else { return false }
            return n >= t
        case .bottom(let count, let percent):
            guard let n = number, let t = stats?.threshold(top: false, count: count, percent: percent) else { return false }
            return n <= t
        case .aboveAverage:
            guard let n = number, let stats else { return false }
            return n > stats.average
        case .belowAverage:
            guard let n = number, let stats else { return false }
            return n < stats.average
        case .formula, .colorScale, .dataBar, .iconSet:
            return false
        }
    }
}

/// Evaluates a sheet's conditional formats, caching range statistics per recalculation.
final class ConditionalFormatter {
    private var statsCache: [UUID: ConditionalStats] = [:]
    private var cacheKey: (Int, Int) = (-1, -1)

    func look(at address: CellAddress, sheetIndex: Int, controller: WorkbookController) -> ConditionalLook? {
        let sheet = controller.workbook.sheets[sheetIndex]
        guard !sheet.conditionalFormats.isEmpty else { return nil }
        if cacheKey != (controller.revision, sheetIndex) {
            statsCache.removeAll()
            cacheKey = (controller.revision, sheetIndex)
        }
        var look = ConditionalLook()
        var matched = false
        // Earlier rules take priority, so apply from last to first.
        for format in sheet.conditionalFormats.reversed() where format.range.contains(address) {
            let value = controller.value(sheet: sheetIndex, at: address)
            let stats = self.stats(for: format, sheetIndex: sheetIndex, controller: controller)
            switch format.rule {
            case .colorScale(let colors):
                guard let n = value.number, colors.count >= 2, stats.maximum > stats.minimum else {
                    if value.number != nil, let first = colors.first { look.fill = colors.count == 3 ? colors[1] : first; matched = true }
                    continue
                }
                let t = (n - stats.minimum) / (stats.maximum - stats.minimum)
                if colors.count == 2 {
                    look.fill = colors[0].mixed(with: colors[1], t)
                } else {
                    look.fill = t < 0.5 ? colors[0].mixed(with: colors[1], t * 2) : colors[1].mixed(with: colors[2], (t - 0.5) * 2)
                }
                matched = true
            case .dataBar(let color):
                guard let n = value.number else { continue }
                let low = min(stats.minimum, 0), high = max(stats.maximum, 0)
                let fraction = high > low ? (n - low) / (high - low) : 1
                look.dataBar = (max(0.02, min(1, fraction)), color)
                matched = true
            case .iconSet(let set):
                guard let n = value.number else { continue }
                let span = stats.maximum - stats.minimum
                let t = span > 0 ? (n - stats.minimum) / span : 1
                look.icon = (set, t >= 0.67 ? 2 : (t >= 0.33 ? 1 : 0))
                matched = true
            case .formula(let formula):
                // Relative references are written for the range's top-left cell.
                let shifted = FormulaRewriter.shift(formula, rows: address.row - format.range.minRow, columns: address.column - format.range.minColumn)
                let result = controller.calculator.evaluate(formula: shifted, sheet: sheetIndex, at: address)
                if (try? result.asBool()) == true { apply(format.format, to: &look); matched = true }
            default:
                if ConditionalEvaluator.matches(format.rule, value: value, stats: stats) {
                    apply(format.format, to: &look)
                    matched = true
                }
            }
        }
        return matched ? look : nil
    }

    private func apply(_ format: HighlightFormat, to look: inout ConditionalLook) {
        if let fill = format.fill { look.fill = fill }
        if let text = format.text { look.text = text }
        if format.bold { look.bold = true }
        if format.italic { look.italic = true }
        if let border = format.border { look.border = border }
    }

    private func stats(for format: ConditionalFormat, sheetIndex: Int, controller: WorkbookController) -> ConditionalStats {
        if let cached = statsCache[format.id] { return cached }
        var values: [CellValue] = []
        let sheet = controller.workbook.sheets[sheetIndex]
        var range = format.range
        if range.isWholeColumns || range.isWholeRows {
            let extent = sheet.contentExtent
            range = CellRange(range.start, CellAddress(row: min(range.maxRow, extent.row), column: min(range.maxColumn, extent.column)))
        }
        if range.cellCount <= 1_000_000 {
            for address in range.addresses { values.append(controller.value(sheet: sheetIndex, at: address)) }
        }
        let stats = ConditionalStats(values: values)
        statsCache[format.id] = stats
        return stats
    }
}
