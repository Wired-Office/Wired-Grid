import AppKit

/// The numbers behind a chart, read from its data range.
struct ChartData {
    struct Series {
        var name: String
        var values: [Double?]
        var xValues: [Double?] = []
    }

    var categories: [String]
    var series: [Series]

    static func read(_ chart: ChartObject, sheetIndex: Int, controller: WorkbookController) -> ChartData {
        let range = chart.dataRange
        let sheet = controller.workbook.sheets[sheetIndex]
        func value(_ r: Int, _ c: Int) -> CellValue { controller.value(sheet: sheetIndex, at: CellAddress(row: r, column: c)) }
        func text(_ r: Int, _ c: Int) -> String {
            let address = CellAddress(row: r, column: c)
            return NumberFormat.format(value(r, c), sheet.style(at: address).numberFormat).text
        }
        // Orient so series run down columns.
        let rows = chart.seriesInColumns ? Array(range.rows) : Array(range.columns)
        let columns = chart.seriesInColumns ? Array(range.columns) : Array(range.rows)
        func v(_ i: Int, _ j: Int) -> CellValue { chart.seriesInColumns ? value(rows[i], columns[j]) : value(columns[j], rows[i]) }
        func t(_ i: Int, _ j: Int) -> String { chart.seriesInColumns ? text(rows[i], columns[j]) : text(columns[j], rows[i]) }
        func isDateColumn(_ j: Int) -> Bool {
            let address = chart.seriesInColumns ? CellAddress(row: rows.last ?? 0, column: columns[j]) : CellAddress(row: columns[j], column: rows.last ?? 0)
            return NumberFormat.isDate(sheet.style(at: address).numberFormat)
        }

        guard !rows.isEmpty, !columns.isEmpty else { return ChartData(categories: [], series: []) }
        // A header row: text over the value columns.
        let firstDataColumn = columns.count > 1 ? 1 : 0
        let hasHeader = rows.count > 1 && (firstDataColumn..<columns.count).contains { v(0, $0).isText }
        let dataStart = hasHeader ? 1 : 0
        // A category column: text (or dates) in the first column.
        let firstColumnIsLabels = columns.count > 1 && (dataStart..<rows.count).contains { v($0, 0).isText } || (columns.count > 1 && isDateColumn(0))
        let scatter = chart.kind == .scatter
        let seriesColumns = (firstColumnIsLabels || (scatter && columns.count > 1)) ? Array(1..<columns.count) : Array(0..<columns.count)

        var categories: [String] = []
        for i in dataStart..<rows.count {
            categories.append(firstColumnIsLabels || scatter && columns.count > 1 ? t(i, 0) : String(i - dataStart + 1))
        }
        var series: [Series] = []
        for (n, j) in seriesColumns.enumerated() {
            let name = hasHeader ? t(0, j) : "Series \(n + 1)"
            let values = (dataStart..<rows.count).map { v($0, j).number }
            var s = Series(name: name.isEmpty ? "Series \(n + 1)" : name, values: values)
            if scatter {
                s.xValues = columns.count > 1 ? (dataStart..<rows.count).map { v($0, 0).number } : (dataStart..<rows.count).map { Double($0 - dataStart + 1) }
            }
            series.append(s)
        }
        return ChartData(categories: categories, series: series)
    }
}

/// Draws charts with Core Graphics.
enum ChartRenderer {
    struct Palette {
        var background: NSColor
        var text: NSColor
        var secondaryText: NSColor
        var grid: NSColor
        var axis: NSColor
    }

    static func palette(dark: Bool) -> Palette {
        dark
            ? Palette(background: NSColor(srgbRed: 0.16, green: 0.17, blue: 0.17, alpha: 1), text: NSColor(white: 0.92, alpha: 1),
                      secondaryText: NSColor(white: 0.65, alpha: 1), grid: NSColor(white: 1, alpha: 0.1), axis: NSColor(white: 1, alpha: 0.3))
            : Palette(background: .white, text: NSColor(white: 0.15, alpha: 1), secondaryText: NSColor(white: 0.42, alpha: 1),
                      grid: NSColor(white: 0, alpha: 0.08), axis: NSColor(white: 0, alpha: 0.28))
    }

    static func draw(_ chart: ChartObject, data: ChartData, in rect: CGRect, dark: Bool, scale: CGFloat = 1) {
        let p = palette(dark: dark)
        p.background.setFill()
        rect.fill()
        let colors = chart.palette.colors.map(\.nsColor)
        var plot = rect.insetBy(dx: 14 * scale, dy: 12 * scale)

        // Title.
        if !chart.title.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15 * scale, weight: .semibold), .foregroundColor: p.text]
            let size = (chart.title as NSString).size(withAttributes: attrs)
            (chart.title as NSString).draw(at: CGPoint(x: rect.midX - size.width / 2, y: plot.minY), withAttributes: attrs)
            plot.origin.y += size.height + 8 * scale
            plot.size.height -= size.height + 8 * scale
        }

        guard !data.series.isEmpty, data.series.contains(where: { $0.values.contains { $0 != nil } }) else {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12 * scale), .foregroundColor: p.secondaryText]
            let message = "No numeric data to chart" as NSString
            let size = message.size(withAttributes: attrs)
            message.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
            return
        }

        // Legend at the bottom.
        let legendItems: [(String, NSColor)] = chart.kind.isRadial
            ? data.categories.enumerated().map { ($0.element, colors[$0.offset % colors.count]) }
            : data.series.enumerated().map { ($0.element.name, colors[$0.offset % colors.count]) }
        if chart.showLegend && (legendItems.count > 1 || chart.kind.isRadial) {
            let height = drawLegend(legendItems, width: plot.width, origin: CGPoint(x: plot.minX, y: plot.maxY), palette: p, scale: scale, measureOnly: true)
            _ = drawLegend(legendItems, width: plot.width, origin: CGPoint(x: plot.minX, y: plot.maxY - height), palette: p, scale: scale, measureOnly: false)
            plot.size.height -= height + 6 * scale
        }

        switch chart.kind {
        case .pie, .doughnut:
            drawPie(chart, data: data, in: plot, colors: colors, palette: p, scale: scale)
        default:
            drawCartesian(chart, data: data, in: plot, colors: colors, palette: p, scale: scale)
        }
    }

    // MARK: - Legend

    private static func drawLegend(_ items: [(String, NSColor)], width: CGFloat, origin: CGPoint, palette p: Palette, scale: CGFloat, measureOnly: Bool) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11 * scale), .foregroundColor: p.secondaryText]
        let lineHeight = 16 * scale
        var lines: [[(String, NSColor, CGFloat)]] = [[]]
        var lineWidth: CGFloat = 0
        for (name, color) in items.prefix(24) {
            let w = min((name as NSString).size(withAttributes: attrs).width, 160 * scale) + 22 * scale
            if lineWidth + w > width && !lines[lines.count - 1].isEmpty {
                lines.append([])
                lineWidth = 0
            }
            lines[lines.count - 1].append((name, color, w))
            lineWidth += w
        }
        let height = CGFloat(lines.count) * lineHeight
        guard !measureOnly else { return height }
        for (i, line) in lines.enumerated() {
            let total = line.reduce(0) { $0 + $1.2 }
            var x = origin.x + (width - total) / 2
            let y = origin.y + CGFloat(i) * lineHeight
            for (name, color, w) in line {
                color.setFill()
                NSBezierPath(roundedRect: CGRect(x: x, y: y + 4 * scale, width: 9 * scale, height: 9 * scale), xRadius: 2 * scale, yRadius: 2 * scale).fill()
                (name as NSString).draw(with: CGRect(x: x + 13 * scale, y: y + 1 * scale, width: w - 18 * scale, height: lineHeight), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], attributes: attrs)
                x += w
            }
        }
        return height
    }

    // MARK: - Axes

    /// "Nice" axis bounds and step (1, 2, 2.5 or 5 × 10ⁿ).
    static func niceScale(min low: Double, max high: Double, ticks: Int = 5) -> (min: Double, max: Double, step: Double) {
        var lo = low, hi = high
        if lo == hi { lo -= lo == 0 ? 1 : abs(lo) * 0.5; hi += hi == 0 ? 1 : abs(hi) * 0.5 }
        let rawStep = (hi - lo) / Double(max(ticks, 1))
        let magnitude = pow(10, floor(log10(rawStep)))
        let residual = rawStep / magnitude
        let nice: Double = residual <= 1 ? 1 : residual <= 2 ? 2 : residual <= 2.5 ? 2.5 : residual <= 5 ? 5 : 10
        let step = nice * magnitude
        return (floor(lo / step) * step, ceil(hi / step) * step, step)
    }

    static func axisLabel(_ value: Double, step: Double) -> String {
        let magnitude = abs(value)
        if magnitude >= 1_000_000_000 { return trim(value / 1_000_000_000) + "B" }
        if magnitude >= 1_000_000 { return trim(value / 1_000_000) + "M" }
        if magnitude >= 10_000 { return trim(value / 1_000) + "K" }
        let decimals = step < 1 ? min(Int(ceil(-log10(step))), 6) : 0
        return NumberFormat.formatNumber(value, decimals > 0 ? "#,##0." + String(repeating: "0", count: decimals) : "#,##0").text
    }

    private static func trim(_ v: Double) -> String {
        let s = String(format: "%.1f", v)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }

    private static func drawCartesian(_ chart: ChartObject, data: ChartData, in area: CGRect, colors: [NSColor], palette p: Palette, scale: CGFloat) {
        let horizontal = chart.kind == .bar
        let stacked = chart.kind == .stackedColumn
        let count = data.categories.count
        guard count > 0 else { return }

        // Value range.
        var low = 0.0, high = 0.0
        if stacked {
            for i in 0..<count {
                let positives = data.series.compactMap { $0.values[safe: i] ?? nil }.filter { $0 > 0 }.reduce(0, +)
                let negatives = data.series.compactMap { $0.values[safe: i] ?? nil }.filter { $0 < 0 }.reduce(0, +)
                high = max(high, positives)
                low = min(low, negatives)
            }
        } else {
            let all = data.series.flatMap { $0.values.compactMap { $0 } }
            low = min(all.min() ?? 0, chart.kind == .line || chart.kind == .scatter ? (all.min() ?? 0) : 0)
            high = max(all.max() ?? 0, chart.kind == .line || chart.kind == .scatter ? (all.max() ?? 0) : 0)
            if chart.kind == .line || chart.kind == .scatter, low > 0, (high - low) < high * 0.5 { /* keep zoomed range */ } else if low > 0 { low = 0 }
        }
        let yScale = niceScale(min: low, max: high)

        // X range for scatter.
        var xScale = (min: 0.0, max: Double(count), step: 1.0)
        if chart.kind == .scatter {
            let xs = data.series.flatMap { $0.xValues.compactMap { $0 } }
            xScale = niceScale(min: xs.min() ?? 0, max: xs.max() ?? 1)
        }

        let labelAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10 * scale), .foregroundColor: p.secondaryText]
        // Measure axis label space.
        var valueLabels: [String] = []
        var tick = yScale.min
        while tick <= yScale.max + yScale.step / 2 {
            valueLabels.append(axisLabel(tick, step: yScale.step))
            tick += yScale.step
        }
        let valueLabelWidth = (valueLabels.map { ($0 as NSString).size(withAttributes: labelAttrs).width }.max() ?? 0) + 6 * scale
        let categoryLabelHeight = 16 * scale
        var plot = area
        if !chart.yAxisTitle.isEmpty { plot.origin.x += 16 * scale; plot.size.width -= 16 * scale }
        if !chart.xAxisTitle.isEmpty { plot.size.height -= 16 * scale }
        if horizontal {
            let categoryWidth = min((data.categories.map { ($0 as NSString).size(withAttributes: labelAttrs).width }.max() ?? 0) + 8 * scale, area.width * 0.35)
            plot = CGRect(x: plot.minX + categoryWidth, y: plot.minY, width: plot.width - categoryWidth - 8 * scale, height: plot.height - categoryLabelHeight)
        } else {
            plot = CGRect(x: plot.minX + valueLabelWidth, y: plot.minY + 4 * scale, width: plot.width - valueLabelWidth - 6 * scale, height: plot.height - categoryLabelHeight - 4 * scale)
        }
        guard plot.width > 20, plot.height > 20 else { return }

        func valuePosition(_ v: Double) -> CGFloat {
            let t = CGFloat((v - yScale.min) / (yScale.max - yScale.min))
            return horizontal ? plot.minX + t * plot.width : plot.maxY - t * plot.height
        }

        // Gridlines and value labels.
        tick = yScale.min
        var index = 0
        while tick <= yScale.max + yScale.step / 2 {
            let pos = valuePosition(tick)
            if chart.showGridlines || abs(tick) < yScale.step / 1000 {
                (abs(tick) < yScale.step / 1000 ? p.axis : p.grid).setFill()
                if horizontal { CGRect(x: pos, y: plot.minY, width: 1, height: plot.height).fill() }
                else { CGRect(x: plot.minX, y: pos, width: plot.width, height: 1).fill() }
            }
            let label = valueLabels[safe: index] ?? axisLabel(tick, step: yScale.step)
            let size = (label as NSString).size(withAttributes: labelAttrs)
            if horizontal {
                (label as NSString).draw(at: CGPoint(x: pos - size.width / 2, y: plot.maxY + 3 * scale), withAttributes: labelAttrs)
            } else {
                (label as NSString).draw(at: CGPoint(x: plot.minX - size.width - 5 * scale, y: pos - size.height / 2), withAttributes: labelAttrs)
            }
            tick += yScale.step
            index += 1
        }

        // Axis titles.
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11 * scale, weight: .medium), .foregroundColor: p.secondaryText]
        if !chart.xAxisTitle.isEmpty {
            let size = (chart.xAxisTitle as NSString).size(withAttributes: titleAttrs)
            (chart.xAxisTitle as NSString).draw(at: CGPoint(x: plot.midX - size.width / 2, y: area.maxY - size.height), withAttributes: titleAttrs)
        }
        if !chart.yAxisTitle.isEmpty, let context = NSGraphicsContext.current?.cgContext {
            let size = (chart.yAxisTitle as NSString).size(withAttributes: titleAttrs)
            context.saveGState()
            context.translateBy(x: area.minX + size.height / 2, y: plot.midY)
            context.rotate(by: -.pi / 2)
            (chart.yAxisTitle as NSString).draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2), withAttributes: titleAttrs)
            context.restoreGState()
        }

        // Category labels (thinned to fit).
        let band = (horizontal ? plot.height : plot.width) / CGFloat(count)
        if chart.kind != .scatter {
            let widest = data.categories.map { ($0 as NSString).size(withAttributes: labelAttrs).width }.max() ?? 0
            let stride = horizontal ? max(1, Int(ceil(14 * scale / max(band, 1)))) : max(1, Int(ceil((widest + 6 * scale) / max(band, 1))))
            for (i, category) in data.categories.enumerated() where i % stride == 0 {
                let size = (category as NSString).size(withAttributes: labelAttrs)
                if horizontal {
                    let y = plot.minY + band * (CGFloat(i) + 0.5)
                    (category as NSString).draw(with: CGRect(x: area.minX, y: y - size.height / 2, width: plot.minX - area.minX - 6 * scale, height: size.height), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], attributes: labelAttrs.merging([.paragraphStyle: rightAligned]) { $1 })
                } else {
                    let x = plot.minX + band * (CGFloat(i) + 0.5)
                    (category as NSString).draw(at: CGPoint(x: x - min(size.width, band * CGFloat(stride)) / 2, y: plot.maxY + 3 * scale), withAttributes: labelAttrs)
                }
            }
        } else {
            var x = xScale.min
            while x <= xScale.max + xScale.step / 2 {
                let px = plot.minX + CGFloat((x - xScale.min) / (xScale.max - xScale.min)) * plot.width
                if chart.showGridlines { p.grid.setFill(); CGRect(x: px, y: plot.minY, width: 1, height: plot.height).fill() }
                let label = axisLabel(x, step: xScale.step)
                let size = (label as NSString).size(withAttributes: labelAttrs)
                (label as NSString).draw(at: CGPoint(x: px - size.width / 2, y: plot.maxY + 3 * scale), withAttributes: labelAttrs)
                x += xScale.step
            }
        }
        p.axis.setFill()
        if horizontal { CGRect(x: valuePosition(max(yScale.min, 0)), y: plot.minY, width: 1, height: plot.height).fill() }
        else { CGRect(x: plot.minX, y: plot.maxY, width: plot.width, height: 1).fill() }

        let dataLabelAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9.5 * scale, weight: .medium), .foregroundColor: p.text]
        let seriesCount = data.series.count
        switch chart.kind {
        case .column, .bar, .stackedColumn:
            let groupWidth = band * 0.72
            let barWidth = stacked ? groupWidth : groupWidth / CGFloat(max(seriesCount, 1))
            for i in 0..<count {
                var positiveBase = 0.0, negativeBase = 0.0
                for (s, series) in data.series.enumerated() {
                    guard let value = series.values[safe: i] ?? nil else { continue }
                    let color = colors[s % colors.count]
                    var from = 0.0, to = value
                    if stacked {
                        if value >= 0 { from = positiveBase; to = positiveBase + value; positiveBase = to }
                        else { from = negativeBase; to = negativeBase + value; negativeBase = to }
                    }
                    let a = valuePosition(from), b = valuePosition(to)
                    let offset = band * CGFloat(i) + (band - groupWidth) / 2 + (stacked ? 0 : barWidth * CGFloat(s))
                    let rect: CGRect = horizontal
                        ? CGRect(x: min(a, b), y: plot.minY + offset, width: abs(b - a), height: barWidth * 0.92)
                        : CGRect(x: plot.minX + offset, y: min(a, b), width: barWidth * 0.92, height: abs(b - a))
                    let radius = min(3 * scale, (horizontal ? rect.height : rect.width) / 4)
                    let path = NSBezierPath(roundedRect: rect, xRadius: stacked ? 0 : radius, yRadius: stacked ? 0 : radius)
                    color.setFill()
                    path.fill()
                    if chart.showDataLabels {
                        let label = axisLabel(value, step: yScale.step / 10) as NSString
                        let size = label.size(withAttributes: dataLabelAttrs)
                        let point = horizontal ? CGPoint(x: rect.maxX + 3, y: rect.midY - size.height / 2) : CGPoint(x: rect.midX - size.width / 2, y: (value >= 0 ? rect.minY - size.height - 1 : rect.maxY + 1))
                        label.draw(at: point, withAttributes: dataLabelAttrs)
                    }
                }
            }
        case .line, .area:
            for (s, series) in data.series.enumerated().reversed() {
                let color = colors[s % colors.count]
                var points: [CGPoint?] = []
                for i in 0..<count {
                    guard let value = series.values[safe: i] ?? nil else { points.append(nil); continue }
                    points.append(CGPoint(x: plot.minX + band * (CGFloat(i) + 0.5), y: valuePosition(value)))
                }
                let valid = points.compactMap { $0 }
                guard !valid.isEmpty else { continue }
                if chart.kind == .area {
                    let fill = NSBezierPath()
                    fill.move(to: CGPoint(x: valid[0].x, y: valuePosition(max(yScale.min, 0))))
                    valid.forEach { fill.line(to: $0) }
                    fill.line(to: CGPoint(x: valid.last!.x, y: valuePosition(max(yScale.min, 0))))
                    fill.close()
                    color.withAlphaComponent(0.35).setFill()
                    fill.fill()
                }
                let line = NSBezierPath()
                line.lineWidth = 2.2 * scale
                line.lineJoinStyle = .round
                line.lineCapStyle = .round
                var started = false
                for point in points {
                    guard let point else { started = false; continue }
                    if started { line.line(to: point) } else { line.move(to: point); started = true }
                }
                color.setStroke()
                line.stroke()
                if chart.kind == .line && count <= 40 {
                    for point in valid {
                        let dot = NSBezierPath(ovalIn: CGRect(x: point.x - 3 * scale, y: point.y - 3 * scale, width: 6 * scale, height: 6 * scale))
                        p.background.setFill(); dot.fill()
                        color.setStroke(); dot.lineWidth = 1.8 * scale; dot.stroke()
                    }
                }
                if chart.showDataLabels {
                    for (i, point) in points.enumerated() {
                        guard let point, let value = series.values[safe: i] ?? nil else { continue }
                        let label = axisLabel(value, step: yScale.step / 10) as NSString
                        let size = label.size(withAttributes: dataLabelAttrs)
                        label.draw(at: CGPoint(x: point.x - size.width / 2, y: point.y - size.height - 4), withAttributes: dataLabelAttrs)
                    }
                }
            }
        case .scatter:
            for (s, series) in data.series.enumerated() {
                let color = colors[s % colors.count]
                for (i, value) in series.values.enumerated() {
                    guard let y = value, let x = series.xValues[safe: i] ?? nil else { continue }
                    let px = plot.minX + CGFloat((x - xScale.min) / (xScale.max - xScale.min)) * plot.width
                    let py = valuePosition(y)
                    let dot = NSBezierPath(ovalIn: CGRect(x: px - 3.5 * scale, y: py - 3.5 * scale, width: 7 * scale, height: 7 * scale))
                    color.withAlphaComponent(0.85).setFill()
                    dot.fill()
                }
            }
        default:
            break
        }
    }

    private static let rightAligned: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    // MARK: - Pie

    private static func drawPie(_ chart: ChartObject, data: ChartData, in area: CGRect, colors: [NSColor], palette p: Palette, scale: CGFloat) {
        guard let series = data.series.first else { return }
        let values = series.values.map { max($0 ?? 0, 0) }
        let total = values.reduce(0, +)
        guard total > 0 else { return }
        let radius = min(area.width, area.height) / 2 - 6 * scale
        let center = CGPoint(x: area.midX, y: area.midY)
        var angle = -CGFloat.pi / 2
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5 * scale, weight: .semibold), .foregroundColor: NSColor.white]
        for (i, value) in values.enumerated() where value > 0 {
            let sweep = CGFloat(value / total) * 2 * .pi
            let path = NSBezierPath()
            path.move(to: center)
            // Flipped view: angles run clockwise.
            path.appendArc(withCenter: center, radius: radius, startAngle: angle * 180 / .pi, endAngle: (angle + sweep) * 180 / .pi, clockwise: false)
            path.close()
            colors[i % colors.count].setFill()
            path.fill()
            p.background.setStroke()
            path.lineWidth = 1.5 * scale
            path.stroke()
            if chart.showDataLabels || sweep > 0.35 {
                let mid = angle + sweep / 2
                let labelRadius = chart.kind == .doughnut ? radius * 0.78 : radius * 0.64
                let label = (chart.showDataLabels ? axisLabel(value, step: 0.1) : NumberFormat.formatNumber(value / total, "0%").text) as NSString
                let size = label.size(withAttributes: labelAttrs)
                label.draw(at: CGPoint(x: center.x + cos(mid) * labelRadius - size.width / 2, y: center.y + sin(mid) * labelRadius - size.height / 2), withAttributes: labelAttrs)
            }
            angle += sweep
        }
        if chart.kind == .doughnut {
            p.background.setFill()
            NSBezierPath(ovalIn: CGRect(x: center.x - radius * 0.55, y: center.y - radius * 0.55, width: radius * 1.1, height: radius * 1.1)).fill()
            let totalAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16 * scale, weight: .bold), .foregroundColor: p.text]
            let text = axisLabel(total, step: 1) as NSString
            let size = text.size(withAttributes: totalAttrs)
            text.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: totalAttrs)
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
