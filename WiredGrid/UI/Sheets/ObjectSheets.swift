import SwiftUI

// MARK: - Chart editor

struct ChartEditorSheet: View {
    let controller: WorkbookController
    let chart: ChartObject
    let dismiss: () -> Void
    @State private var edited: ChartObject
    @State private var rangeText = ""

    init(controller: WorkbookController, chart: ChartObject, dismiss: @escaping () -> Void) {
        self.controller = controller
        self.chart = chart
        self.dismiss = dismiss
        _edited = State(initialValue: chart)
        _rangeText = State(initialValue: chart.dataRange.a1)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Form {
                Section("Chart") {
                    Picker("Type", selection: $edited.kind) {
                        ForEach(ChartKind.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    TextField("Title", text: $edited.title)
                    TextField("Data range", text: $rangeText)
                        .onSubmit { if let r = CellRange(a1: rangeText) { edited.dataRange = r } }
                    Picker("Series in", selection: $edited.seriesInColumns) {
                        Text("Columns").tag(true)
                        Text("Rows").tag(false)
                    }
                    .pickerStyle(.segmented)
                }
                Section("Style") {
                    Picker("Colors", selection: $edited.palette) {
                        ForEach(ChartPalette.allCases) { palette in
                            HStack(spacing: 2) {
                                ForEach(palette.colors.prefix(5).indices, id: \.self) { i in
                                    RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: palette.colors[i].nsColor)).frame(width: 10, height: 10)
                                }
                                Text(palette.title)
                            }
                            .tag(palette)
                        }
                    }
                    Toggle("Legend", isOn: $edited.showLegend)
                    Toggle("Data labels", isOn: $edited.showDataLabels)
                    Toggle("Gridlines", isOn: $edited.showGridlines)
                    if !edited.kind.isRadial {
                        TextField("Horizontal axis title", text: $edited.xAxisTitle)
                        TextField("Vertical axis title", text: $edited.yAxisTitle)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 330)

            VStack {
                ChartPreview(controller: controller, chart: edited)
                    .frame(width: 400, height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
                Spacer()
                HStack {
                    Button("Delete Chart", role: .destructive) {
                        controller.deleteChart(chart.id)
                        dismiss()
                    }
                    Spacer()
                    Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                    Button("Done") {
                        if let r = CellRange(a1: rangeText) { edited.dataRange = r }
                        controller.updateChart(edited)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(height: 440)
    }
}

private struct ChartPreview: NSViewRepresentable {
    let controller: WorkbookController
    let chart: ChartObject

    func makeNSView(context: Context) -> PreviewView { PreviewView() }

    func updateNSView(_ view: PreviewView, context: Context) {
        view.controller = controller
        view.chart = chart
        view.needsDisplay = true
    }

    final class PreviewView: NSView {
        var controller: WorkbookController?
        var chart: ChartObject?
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            guard let controller, let chart else { return }
            let data = ChartData.read(chart, sheetIndex: controller.activeSheetIndex, controller: controller)
            ChartRenderer.draw(chart, data: data, in: bounds, dark: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        }
    }
}

// MARK: - Conditional formatting

struct ConditionalFormatSheet: View {
    let controller: WorkbookController
    let initialRule: ConditionalFormat.Rule?
    let dismiss: () -> Void

    enum Kind: String, CaseIterable, Identifiable {
        case greater = "Greater than", less = "Less than", between = "Between", equal = "Equal to", notEqual = "Not equal to"
        case contains = "Text contains", begins = "Begins with", ends = "Ends with", duplicates = "Duplicate values", uniques = "Unique values"
        case top = "Top N", bottom = "Bottom N", above = "Above average", below = "Below average", blanks = "Blank cells", formula = "Formula is"
        case scale = "Color scale", bar = "Data bar", icons = "Icon set"
        var id: String { rawValue }
    }

    @State private var kind: Kind = .greater
    @State private var value1 = ""
    @State private var value2 = ""
    @State private var count = 10
    @State private var percent = false
    @State private var formatIndex = 0
    @State private var rangeText = ""
    @State private var barColor = Color(nsColor: RGBColor(0x638EC6).nsColor)
    @State private var scaleIndex = 0
    @State private var iconSet = ConditionalFormat.IconSet.trafficLights

    private let scales: [(String, [RGBColor])] = [
        ("Green – Yellow – Red", [RGBColor(0xF8696B), RGBColor(0xFFEB84), RGBColor(0x63BE7B)]),
        ("Red – Yellow – Green", [RGBColor(0x63BE7B), RGBColor(0xFFEB84), RGBColor(0xF8696B)]),
        ("White – Green", [RGBColor(0xFFFFFF), RGBColor(0x63BE7B)]),
        ("White – Red", [RGBColor(0xFFFFFF), RGBColor(0xF8696B)]),
        ("Blue – White – Red", [RGBColor(0xF8696B), RGBColor(0xFFFFFF), RGBColor(0x5A8AC6)]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Applies to", text: $rangeText)
                Picker("Format cells if", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                switch kind {
                case .greater, .less, .equal, .notEqual, .contains, .begins, .ends:
                    TextField("Value", text: $value1)
                case .between:
                    TextField("From", text: $value1)
                    TextField("To", text: $value2)
                case .top, .bottom:
                    Stepper("Count: \(count)", value: $count, in: 1...1000)
                    Toggle("Percent", isOn: $percent)
                case .formula:
                    TextField("Formula (for the first cell)", text: $value1)
                        .font(.system(.body, design: .monospaced))
                    Text("Example: =$C2>100 highlights rows where column C exceeds 100.").font(.caption).foregroundStyle(.secondary)
                case .scale:
                    Picker("Colors", selection: $scaleIndex) {
                        ForEach(scales.indices, id: \.self) { Text(scales[$0].0).tag($0) }
                    }
                case .bar:
                    ColorPicker("Bar color", selection: $barColor)
                case .icons:
                    Picker("Icons", selection: $iconSet) {
                        ForEach(ConditionalFormat.IconSet.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                default:
                    EmptyView()
                }
                if ![.scale, .bar, .icons].contains(kind) {
                    Picker("With", selection: $formatIndex) {
                        ForEach(HighlightFormat.presets.indices, id: \.self) { i in
                            Text(HighlightFormat.presets[i].0).tag(i)
                        }
                    }
                    let format = HighlightFormat.presets[formatIndex].1
                    Text("AaBbCc 123")
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .foregroundStyle(Color(nsColor: format.text?.nsColor ?? .labelColor))
                        .background(Color(nsColor: format.fill?.nsColor ?? .clear))
                        .overlay(Rectangle().strokeBorder(Color(nsColor: format.border?.nsColor ?? .clear)))
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button("OK", action: apply).keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 440)
        .onAppear(perform: load)
    }

    private func load() {
        rangeText = controller.boundedToContent(controller.selection.primary).a1
        switch initialRule {
        case .greaterThan(let v)?: kind = .greater; value1 = v == 0 ? "" : NumberFormat.general(v)
        case .lessThan(let v)?: kind = .less; value1 = v == 0 ? "" : NumberFormat.general(v)
        case .between(let a, let b)?: kind = .between; value1 = NumberFormat.general(a); value2 = NumberFormat.general(b)
        case .equalTo(let t)?: kind = .equal; value1 = t
        case .textContains(let t)?: kind = .contains; value1 = t
        default: break
        }
    }

    private func apply() {
        guard let range = CellRange(a1: rangeText.replacingOccurrences(of: "$", with: "")) else { return }
        let format = HighlightFormat.presets[formatIndex].1
        let n1 = Double(value1.trimmingCharacters(in: .whitespaces)) ?? 0
        let n2 = Double(value2.trimmingCharacters(in: .whitespaces)) ?? 0
        let rule: ConditionalFormat.Rule
        switch kind {
        case .greater: rule = .greaterThan(n1)
        case .less: rule = .lessThan(n1)
        case .between: rule = .between(n1, n2)
        case .equal: rule = .equalTo(value1)
        case .notEqual: rule = .notEqualTo(value1)
        case .contains: rule = .textContains(value1)
        case .begins: rule = .beginsWith(value1)
        case .ends: rule = .endsWith(value1)
        case .duplicates: rule = .duplicates
        case .uniques: rule = .uniques
        case .top: rule = .top(count, percent: percent)
        case .bottom: rule = .bottom(count, percent: percent)
        case .above: rule = .aboveAverage
        case .below: rule = .belowAverage
        case .blanks: rule = .blanks
        case .formula:
            var body = value1.trimmingCharacters(in: .whitespaces)
            if body.hasPrefix("=") { body.removeFirst() }
            guard let normalized = try? WorkbookController.normalizeFormula(body) else { return }
            rule = .formula(normalized)
        case .scale: rule = .colorScale(scales[scaleIndex].1)
        case .bar: rule = .dataBar(RGBColor(NSColor(barColor)))
        case .icons: rule = .iconSet(iconSet)
        }
        controller.addConditionalFormat(rule, format: format, range: range)
        dismiss()
    }
}

struct ManageRulesSheet: View {
    @ObservedObject var controller: WorkbookController
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Conditional Formatting Rules — \(controller.sheet.name)").font(.headline)
            if controller.sheet.conditionalFormats.isEmpty {
                Text("This sheet has no rules.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List {
                    ForEach(controller.sheet.conditionalFormats) { cf in
                        HStack {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(nsColor: cf.format.fill?.nsColor ?? .clear))
                                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary.opacity(0.2)))
                                .frame(width: 18, height: 14)
                            VStack(alignment: .leading) {
                                Text(cf.rule.summary)
                                Text("Applies to \(cf.range.a1)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                controller.deleteConditionalFormat(cf.id)
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 220)
            }
            HStack {
                Button("New Rule…") {
                    dismiss()
                    DispatchQueue.main.async { controller.presenter?.presentConditionalFormat(nil) }
                }
                Spacer()
                Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

// MARK: - Names

struct NameManagerSheet: View {
    @ObservedObject var controller: WorkbookController
    let dismiss: () -> Void
    @State private var newName = ""
    @State private var newReference = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Name Manager", systemImage: "tag").font(.headline)
            Text("Names make formulas easier to read: =Price*TaxRate instead of =B4*$F$1.")
                .font(.callout).foregroundStyle(.secondary)
            List {
                ForEach(controller.workbook.names) { name in
                    HStack {
                        Text(name.name).fontWeight(.medium).frame(width: 140, alignment: .leading)
                        Text("=" + name.formula).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                        Spacer()
                        let value = controller.calculator.evaluate(formula: name.formula, sheet: controller.activeSheetIndex, at: .origin)
                        Text(value.plainText).foregroundStyle(.secondary).lineLimit(1).frame(width: 80, alignment: .trailing)
                        Button { controller.deleteName(name.name) } label: { Image(systemName: "trash") }.buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 180)
            HStack {
                TextField("Name", text: $newName).textFieldStyle(.roundedBorder).frame(width: 140)
                TextField("Refers to", text: $newReference).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                Button("Add") {
                    if controller.defineName(newName, formula: newReference) {
                        newName = ""
                        newReference = quotedSheetName(controller.sheet.name) + "!" + controller.absoluteReference(controller.selection.primary)
                    }
                }
                .disabled(newName.isEmpty || newReference.isEmpty)
            }
            HStack {
                Spacer()
                Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            newReference = quotedSheetName(controller.sheet.name) + "!" + controller.absoluteReference(controller.selection.primary)
        }
    }
}
