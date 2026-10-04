import Foundation

// MARK: - Conditional formatting

/// A rule that restyles cells in a range depending on their values.
struct ConditionalFormat: Codable, Hashable, Identifiable {
    var id = UUID()
    var range: CellRange
    var rule: Rule
    var format = HighlightFormat.lightRed

    enum Rule: Codable, Hashable {
        case greaterThan(Double)
        case lessThan(Double)
        case between(Double, Double)
        case equalTo(String)
        case notEqualTo(String)
        case textContains(String)
        case beginsWith(String)
        case endsWith(String)
        case blanks
        case noBlanks
        case duplicates
        case uniques
        case top(Int, percent: Bool)
        case bottom(Int, percent: Bool)
        case aboveAverage
        case belowAverage
        case formula(String)
        case colorScale([RGBColor])
        case dataBar(RGBColor)
        case iconSet(IconSet)

        var isVisualization: Bool {
            switch self {
            case .colorScale, .dataBar, .iconSet: true
            default: false
            }
        }

        var summary: String {
            let n = { (v: Double) in NumberFormat.general(v) }
            switch self {
            case .greaterThan(let v): return "Cell value > \(n(v))"
            case .lessThan(let v): return "Cell value < \(n(v))"
            case .between(let a, let b): return "Cell value between \(n(a)) and \(n(b))"
            case .equalTo(let v): return "Cell value = \(v)"
            case .notEqualTo(let v): return "Cell value ≠ \(v)"
            case .textContains(let t): return "Text contains “\(t)”"
            case .beginsWith(let t): return "Text begins with “\(t)”"
            case .endsWith(let t): return "Text ends with “\(t)”"
            case .blanks: return "Blank cells"
            case .noBlanks: return "Cells that aren't blank"
            case .duplicates: return "Duplicate values"
            case .uniques: return "Unique values"
            case .top(let k, let p): return "Top \(k)\(p ? "%" : "")"
            case .bottom(let k, let p): return "Bottom \(k)\(p ? "%" : "")"
            case .aboveAverage: return "Above average"
            case .belowAverage: return "Below average"
            case .formula(let f): return "Formula: =\(f)"
            case .colorScale(let colors): return "\(colors.count)-color scale"
            case .dataBar: return "Data bar"
            case .iconSet(let set): return "Icon set: \(set.title)"
            }
        }
    }

    enum IconSet: String, Codable, Hashable, CaseIterable {
        case arrows, trafficLights, flags, stars

        var title: String {
            switch self {
            case .arrows: "3 Arrows"
            case .trafficLights: "3 Traffic Lights"
            case .flags: "3 Flags"
            case .stars: "3 Stars"
            }
        }
    }
}

/// The look applied by a highlight rule.
struct HighlightFormat: Codable, Hashable {
    var fill: RGBColor?
    var text: RGBColor?
    var bold = false
    var italic = false
    var border: RGBColor?

    static let lightRed = HighlightFormat(fill: RGBColor(0xFFC7CE), text: RGBColor(0x9C0006))
    static let yellow = HighlightFormat(fill: RGBColor(0xFFEB9C), text: RGBColor(0x9C5700))
    static let green = HighlightFormat(fill: RGBColor(0xC6EFCE), text: RGBColor(0x006100))
    static let lightRedFill = HighlightFormat(fill: RGBColor(0xFFC7CE))
    static let redText = HighlightFormat(text: RGBColor(0x9C0006))
    static let redBorder = HighlightFormat(border: RGBColor(0xC00000))

    static let presets: [(String, HighlightFormat)] = [
        ("Light Red Fill with Dark Red Text", .lightRed),
        ("Yellow Fill with Dark Yellow Text", .yellow),
        ("Green Fill with Dark Green Text", .green),
        ("Light Red Fill", .lightRedFill),
        ("Red Text", .redText),
        ("Red Border", .redBorder),
    ]
}

// MARK: - AutoFilter

/// Filter buttons on a header row, and the criteria applied to each column.
struct AutoFilter: Codable, Hashable {
    /// Header row plus the data beneath it.
    var range: CellRange
    /// Keyed by absolute column index.
    var criteria: [Int: FilterCriterion] = [:]
    /// Rows hidden by the criteria, captured when the filter was last applied.
    var hiddenRows: Set<Int> = []

    var dataRows: ClosedRange<Int>? {
        range.maxRow > range.minRow ? (range.minRow + 1)...range.maxRow : nil
    }
}

enum FilterCriterion: Codable, Hashable {
    /// Show rows whose displayed text is in the set ("" means blanks).
    case values(Set<String>)
    case condition(ConditionalFormat.Rule)

    var summary: String {
        switch self {
        case .values(let set): "\(set.count) value\(set.count == 1 ? "" : "s")"
        case .condition(let rule): rule.summary
        }
    }
}

// MARK: - Tables

/// A formatted table ("Format as Table") with banded rows and a header.
struct TableObject: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var range: CellRange
    var style: TableStyle = .green
    var showHeader = true
    var bandedRows = true
    var showTotals = false
}

enum TableStyle: String, Codable, CaseIterable, Identifiable {
    case green, blue, orange, gray, purple, teal
    var id: String { rawValue }

    var header: RGBColor {
        switch self {
        case .green: RGBColor(0x1E7B4A)
        case .blue: RGBColor(0x2F5DA8)
        case .orange: RGBColor(0xC8621B)
        case .gray: RGBColor(0x505A64)
        case .purple: RGBColor(0x6B4AA8)
        case .teal: RGBColor(0x137A86)
        }
    }

    var band: RGBColor { header.mixed(with: .white, 0.84) }
    var title: String { rawValue.capitalized }
}

// MARK: - Charts

enum ChartKind: String, Codable, CaseIterable, Identifiable {
    case column, stackedColumn, bar, line, area, pie, doughnut, scatter
    var id: String { rawValue }

    var title: String {
        switch self {
        case .column: "Column"
        case .stackedColumn: "Stacked Column"
        case .bar: "Bar"
        case .line: "Line"
        case .area: "Area"
        case .pie: "Pie"
        case .doughnut: "Doughnut"
        case .scatter: "Scatter"
        }
    }

    var symbol: String {
        switch self {
        case .column: "chart.bar.fill"
        case .stackedColumn: "chart.bar.doc.horizontal"
        case .bar: "chart.bar.xaxis"
        case .line: "chart.xyaxis.line"
        case .area: "chart.line.uptrend.xyaxis"
        case .pie: "chart.pie.fill"
        case .doughnut: "circle.circle"
        case .scatter: "chart.dots.scatter"
        }
    }

    var isRadial: Bool { self == .pie || self == .doughnut }
}

enum ChartPalette: String, Codable, CaseIterable, Identifiable {
    case grid, ocean, sunset, mono, vivid
    var id: String { rawValue }

    var colors: [RGBColor] {
        switch self {
        case .grid: [0x1E8E5A, 0x2F6FDB, 0xF29D38, 0xD9534F, 0x8E5BD6, 0x17A2B8, 0x6C757D, 0xE83E8C].map(RGBColor.init)
        case .ocean: [0x0B4F6C, 0x01BAEF, 0x20BF55, 0x757575, 0x145C9E, 0x7FDBDA, 0x3D5A80, 0x98C1D9].map(RGBColor.init)
        case .sunset: [0xF94144, 0xF3722C, 0xF8961E, 0xF9C74F, 0x90BE6D, 0x43AA8B, 0x577590, 0x277DA1].map(RGBColor.init)
        case .mono: [0x1B4332, 0x2D6A4F, 0x40916C, 0x52B788, 0x74C69D, 0x95D5B2, 0xB7E4C7, 0xD8F3DC].map(RGBColor.init)
        case .vivid: [0x7400B8, 0x5E60CE, 0x4EA8DE, 0x48BFE3, 0x56CFE1, 0x64DFDF, 0x72EFDD, 0x80FFDB].map(RGBColor.init)
        }
    }

    var title: String { rawValue.capitalized }
}

/// A chart floating over the grid, drawn from a data range.
struct ChartObject: Codable, Hashable, Identifiable {
    var id = UUID()
    var kind: ChartKind = .column
    /// The data range on the chart's own sheet.
    var dataRange: CellRange
    var title = ""
    /// Position in sheet content coordinates at 100% zoom (origin at A1's top-left).
    var frame: CGRect
    var seriesInColumns = true
    var showLegend = true
    var showDataLabels = false
    var showGridlines = true
    var palette: ChartPalette = .grid
    var xAxisTitle = ""
    var yAxisTitle = ""
}
