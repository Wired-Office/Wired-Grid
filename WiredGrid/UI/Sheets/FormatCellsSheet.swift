import SwiftUI

enum FormatCellsTab: String, CaseIterable, Identifiable {
    case number, alignment, font, border, fill
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Format ▸ Cells: number formats with a live sample, alignment, font, borders and fill.
struct FormatCellsSheet: View {
    let controller: WorkbookController
    let initialTab: FormatCellsTab
    let dismiss: () -> Void

    @State private var tab: FormatCellsTab = .number
    @State private var style = CellStyle()
    @State private var original = CellStyle()
    @State private var category: NumberFormatPreset? = .general
    @State private var decimals = 2
    @State private var thousands = true
    @State private var negativeStyle = 0
    @State private var symbol = "$"
    @State private var customCode = "General"
    @State private var useCustom = false
    @State private var borderLine = BorderLineStyle.thin
    @State private var borderColor = Color.black
    @State private var pendingBorder: BorderPreset?

    private var sample: CellValue { controller.value(at: controller.selection.active) }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(FormatCellsTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 16)

            Group {
                switch tab {
                case .number: numberTab
                case .alignment: alignmentTab
                case .font: fontTab
                case .border: borderTab
                case .fill: fillTab
                }
            }
            .frame(width: 520, height: 330, alignment: .topLeading)
            .padding(16)

            Divider()
            HStack {
                preview
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button("OK") { apply() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .onAppear(perform: load)
    }

    // MARK: - Preview

    private var preview: some View {
        let formatted = NumberFormat.format(sample.isEmpty ? .number(1234.5678) : sample, style.numberFormat)
        return HStack(spacing: 8) {
            Text("Sample").font(.caption).foregroundStyle(.secondary)
            Text(formatted.text.isEmpty ? " " : formatted.text)
                .font(Font(style.font(zoom: 1)))
                .underline(style.underline)
                .strikethrough(style.strikethrough)
                .foregroundStyle(Color(nsColor: formatted.color?.nsColor ?? style.textColor?.nsColor ?? .labelColor))
                .padding(.horizontal, 10)
                .frame(minWidth: 160, minHeight: 26, alignment: style.horizontal == .center ? .center : (style.horizontal == .right || (style.horizontal == .general && sample.number != nil) ? .trailing : .leading))
                .background(Color(nsColor: style.fillColor?.nsColor ?? .textBackgroundColor))
                .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.2)))
                .lineLimit(1)
        }
    }

    // MARK: - Number

    private var numberTab: some View {
        HStack(alignment: .top, spacing: 16) {
            List(selection: Binding(get: { useCustom ? nil : category }, set: { category = $0; useCustom = false; rebuildCode() })) {
                ForEach(NumberFormatPreset.allCases) { preset in
                    Label(preset.title, systemImage: preset.symbol).tag(Optional(preset))
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false))
            .frame(width: 170)

            VStack(alignment: .leading, spacing: 12) {
                switch category {
                case .number?:
                    Stepper("Decimal places: \(decimals)", value: $decimals, in: 0...10).onChange(of: decimals) { _, _ in rebuildCode() }
                    Toggle("Use 1000 separator (,)", isOn: $thousands).onChange(of: thousands) { _, _ in rebuildCode() }
                    negativePicker
                case .currency?, .accounting?:
                    Stepper("Decimal places: \(decimals)", value: $decimals, in: 0...10).onChange(of: decimals) { _, _ in rebuildCode() }
                    Picker("Symbol", selection: $symbol) {
                        ForEach(["$", "€", "£", "¥", "CHF", "kr", "₹", "None"], id: \.self) { Text($0).tag($0) }
                    }
                    .frame(width: 200)
                    .onChange(of: symbol) { _, _ in rebuildCode() }
                    if category == .currency { negativePicker }
                case .percentage?, .scientific?:
                    Stepper("Decimal places: \(decimals)", value: $decimals, in: 0...10).onChange(of: decimals) { _, _ in rebuildCode() }
                case .shortDate?, .longDate?, .time?:
                    Picker("Type", selection: $customCode) {
                        ForEach(typeCodes, id: \.self) { code in
                            Text(NumberFormat.formatNumber(sample.number ?? 46100.5625, code).text).tag(code)
                        }
                    }
                    .onChange(of: customCode) { _, code in style.numberFormat = code }
                case .fraction?:
                    Picker("Type", selection: $customCode) {
                        ForEach(["# ?/?", "# ??/??", "# ???/???", "# ?/2", "# ?/4", "# ?/8", "# ??/16", "# ?/10", "# ??/100"], id: \.self) { Text($0).tag($0) }
                    }
                    .onChange(of: customCode) { _, code in style.numberFormat = code }
                case .text?:
                    Text("Text format treats the cell's contents as text, even numbers, and displays them exactly as entered.")
                        .foregroundStyle(.secondary)
                case .general?:
                    Text("General cells have no specific number format.")
                        .foregroundStyle(.secondary)
                case nil:
                    EmptyView()
                }
                Divider()
                Toggle("Custom format code", isOn: $useCustom)
                TextField("Format code", text: Binding(get: { style.numberFormat }, set: { style.numberFormat = $0; customCode = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(!useCustom)
                Text("Codes like  #,##0.00  ·  0%  ·  $#,##0;[Red]-$#,##0  ·  yyyy-mm-dd  ·  h:mm AM/PM")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var typeCodes: [String] {
        switch category {
        case .shortDate?: ["m/d/yyyy", "m/d/yy", "mm/dd/yyyy", "d-mmm", "d-mmm-yy", "mmm-yy", "yyyy-mm-dd", "d.m.yyyy", "dd/mm/yyyy"]
        case .longDate?: ["dddd, mmmm d, yyyy", "mmmm d, yyyy", "d mmmm yyyy", "ddd, mmm d", "mmmm yyyy"]
        default: ["h:mm AM/PM", "h:mm:ss AM/PM", "h:mm", "h:mm:ss", "[h]:mm:ss", "m/d/yyyy h:mm", "mm:ss.0"]
        }
    }

    private var negativePicker: some View {
        Picker("Negative numbers", selection: $negativeStyle) {
            Text("-1,234.10").tag(0)
            Text("-1,234.10").foregroundStyle(.red).tag(1)
            Text("(1,234.10)").tag(2)
            Text("(1,234.10)").foregroundStyle(.red).tag(3)
        }
        .frame(width: 260)
        .onChange(of: negativeStyle) { _, _ in rebuildCode() }
    }

    private func rebuildCode() {
        guard !useCustom, let category else { return }
        let fraction = decimals > 0 ? "." + String(repeating: "0", count: decimals) : ""
        func withNegative(_ base: String) -> String {
            switch negativeStyle {
            case 1: return base + ";[Red]-" + base
            case 2: return base + "_);(" + base + ")"
            case 3: return base + "_);[Red](" + base + ")"
            default: return base
            }
        }
        let sym = symbol == "None" ? "" : (symbol.count > 1 ? "\"\(symbol)\" " : symbol)
        switch category {
        case .number: style.numberFormat = withNegative((thousands ? "#,##0" : "0") + fraction)
        case .currency: style.numberFormat = withNegative(sym + "#,##0" + fraction)
        case .accounting:
            let body = "#,##0" + fraction
            style.numberFormat = "_(\(sym)* \(body)_);_(\(sym)* (\(body));_(\(sym)* \"-\"\(decimals > 0 ? "??" : "")_);_(@_)"
        case .percentage: style.numberFormat = "0" + fraction + "%"
        case .scientific: style.numberFormat = "0" + fraction + "E+00"
        case .shortDate, .longDate, .time, .fraction:
            style.numberFormat = typeCodes.contains(customCode) || category == .fraction && customCode.contains("/") ? customCode : category.code
            customCode = style.numberFormat
        case .general, .text: style.numberFormat = category.code
        }
        customCode = style.numberFormat
    }

    // MARK: - Alignment

    private var alignmentTab: some View {
        Form {
            Picker("Horizontal", selection: $style.horizontal) {
                Text("General").tag(HorizontalAlignment.general)
                Text("Left").tag(HorizontalAlignment.left)
                Text("Center").tag(HorizontalAlignment.center)
                Text("Right").tag(HorizontalAlignment.right)
                Text("Fill").tag(HorizontalAlignment.fill)
                Text("Justify").tag(HorizontalAlignment.justify)
            }
            Picker("Vertical", selection: $style.vertical) {
                Text("Top").tag(VerticalAlignment.top)
                Text("Center").tag(VerticalAlignment.middle)
                Text("Bottom").tag(VerticalAlignment.bottom)
            }
            Stepper("Indent: \(style.indent)", value: $style.indent, in: 0...15)
            Toggle("Wrap text", isOn: $style.wrap)
            Toggle("Shrink to fit", isOn: $style.shrinkToFit)
            Picker("Orientation", selection: $style.rotation) {
                Text("Horizontal").tag(0)
                Text("45° up").tag(45)
                Text("45° down").tag(-45)
                Text("90° up").tag(90)
                Text("90° down").tag(-90)
            }
            Toggle("Merge cells", isOn: Binding(get: { controller.selectionIsMerged }, set: { on in controller.merge(on ? .merge : .unmerge) }))
        }
        .formStyle(.grouped)
    }

    // MARK: - Font

    private var fontTab: some View {
        Form {
            HStack {
                Text("Font")
                Spacer()
                FontFamilyPicker(family: style.effectiveFontName) { style.fontName = $0 }.frame(width: 220)
            }
            HStack {
                Text("Size")
                Spacer()
                FontSizeField(size: CGFloat(style.effectiveFontSize)) { style.fontSize = Double($0) }.frame(width: 70)
            }
            Toggle("Bold", isOn: $style.bold)
            Toggle("Italic", isOn: $style.italic)
            Toggle("Underline", isOn: $style.underline)
            Toggle("Double underline", isOn: $style.doubleUnderline)
            Toggle("Strikethrough", isOn: $style.strikethrough)
            HStack {
                Text("Color")
                Spacer()
                ColorPicker("", selection: Binding(get: { Color(nsColor: style.textColor?.nsColor ?? .black) }, set: { style.textColor = RGBColor(NSColor($0)) }))
                    .labelsHidden()
                Button("Automatic") { style.textColor = nil }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Border

    private var borderTab: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Line").font(.headline)
                Picker("Style", selection: $borderLine) {
                    ForEach(BorderLineStyle.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .frame(width: 180)
                ColorPicker("Color", selection: $borderColor)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Presets").font(.headline)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(150), alignment: .leading), count: 2), spacing: 8) {
                    ForEach([BorderPreset.none, .outside, .all, .insideHorizontal, .insideVertical, .top, .bottom, .left, .right, .thickOutside, .doubleBottom, .topAndBottom], id: \.self) { preset in
                        Button {
                            pendingBorder = preset
                        } label: {
                            Label(preset.title, systemImage: preset.symbol)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .tint(pendingBorder == preset ? Theme.accentColor : nil)
                    }
                }
                Text("The chosen preset is applied to the selection when you click OK.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Fill

    private var fillTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Background color").font(.headline)
            VStack(spacing: 4) {
                ForEach(ColorPalettes.textGrid.indices, id: \.self) { row in
                    HStack(spacing: 4) {
                        ForEach(ColorPalettes.textGrid[row].indices, id: \.self) { column in
                            let color = ColorPalettes.textGrid[row][column]
                            Button {
                                style.fillColor = RGBColor(color)
                            } label: {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color(nsColor: color))
                                    .frame(width: 26, height: 22)
                                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(style.fillColor == RGBColor(color) ? Theme.accentColor : Color.primary.opacity(0.15), lineWidth: style.fillColor == RGBColor(color) ? 2 : 0.5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            HStack {
                ColorPicker("More colors", selection: Binding(get: { Color(nsColor: style.fillColor?.nsColor ?? .white) }, set: { style.fillColor = RGBColor(NSColor($0)) }))
                Button("No Color") { style.fillColor = nil }
            }
        }
    }

    // MARK: - Load / apply

    private func load() {
        tab = initialTab
        style = controller.activeStyle
        original = style
        customCode = style.numberFormat
        category = NumberFormatPreset.matching(style.numberFormat)
        decimals = NumberFormat.decimals(style.numberFormat)
        if category == nil { useCustom = true }
        if decimals == 0, category == .number || category == .currency { decimals = style.numberFormat.contains(".") ? decimals : 0 }
    }

    private func apply() {
        let new = style
        let old = original
        // Only properties that changed are applied, so mixed selections keep their other formatting.
        controller.applyStyle("Format Cells", geometry: true) { s in
            if new.numberFormat != old.numberFormat { s.numberFormat = new.numberFormat }
            if new.fontName != old.fontName { s.fontName = new.fontName }
            if new.fontSize != old.fontSize { s.fontSize = new.fontSize }
            if new.bold != old.bold { s.bold = new.bold }
            if new.italic != old.italic { s.italic = new.italic }
            if new.underline != old.underline { s.underline = new.underline }
            if new.doubleUnderline != old.doubleUnderline { s.doubleUnderline = new.doubleUnderline }
            if new.strikethrough != old.strikethrough { s.strikethrough = new.strikethrough }
            if new.textColor != old.textColor { s.textColor = new.textColor }
            if new.fillColor != old.fillColor { s.fillColor = new.fillColor }
            if new.horizontal != old.horizontal { s.horizontal = new.horizontal }
            if new.vertical != old.vertical { s.vertical = new.vertical }
            if new.indent != old.indent { s.indent = new.indent }
            if new.wrap != old.wrap { s.wrap = new.wrap }
            if new.shrinkToFit != old.shrinkToFit { s.shrinkToFit = new.shrinkToFit }
            if new.rotation != old.rotation { s.rotation = new.rotation }
        }
        if let pendingBorder {
            controller.applyBorders(pendingBorder, line: BorderLine(style: borderLine, color: RGBColor(NSColor(borderColor))))
        }
        dismiss()
    }
}
