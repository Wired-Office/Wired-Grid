import AppKit
import SwiftUI

/// Number formats offered in the Home ▸ Number menu.
enum NumberFormatPreset: String, CaseIterable, Identifiable {
    case general, number, currency, accounting, shortDate, longDate, time, percentage, fraction, scientific, text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .number: "Number"
        case .currency: "Currency"
        case .accounting: "Accounting"
        case .shortDate: "Short Date"
        case .longDate: "Long Date"
        case .time: "Time"
        case .percentage: "Percentage"
        case .fraction: "Fraction"
        case .scientific: "Scientific"
        case .text: "Text"
        }
    }

    var code: String {
        switch self {
        case .general: NumberFormat.generalCode
        case .number: NumberFormat.number
        case .currency: NumberFormat.currency
        case .accounting: NumberFormat.accounting
        case .shortDate: NumberFormat.shortDate
        case .longDate: NumberFormat.longDate
        case .time: NumberFormat.time
        case .percentage: NumberFormat.percent
        case .fraction: NumberFormat.fraction
        case .scientific: NumberFormat.scientific
        case .text: NumberFormat.text
        }
    }

    var symbol: String {
        switch self {
        case .general: "textformat.123"
        case .number: "number"
        case .currency: "dollarsign"
        case .accounting: "dollarsign.square"
        case .shortDate: "calendar"
        case .longDate: "calendar.badge.clock"
        case .time: "clock"
        case .percentage: "percent"
        case .fraction: "divide"
        case .scientific: "function"
        case .text: "textformat"
        }
    }

    /// The preset a format code belongs to, for the popup's label.
    static func matching(_ code: String) -> NumberFormatPreset? {
        if let exact = allCases.first(where: { $0.code == code }) { return exact }
        if code == "General" { return .general }
        if NumberFormat.isTime(code) { return .time }
        if NumberFormat.isDate(code) { return code.contains("dddd") || code.contains("mmmm") ? .longDate : .shortDate }
        if NumberFormat.isPercent(code) { return .percentage }
        if code.contains("E+") || code.contains("E-") { return .scientific }
        if code.contains("?/") { return .fraction }
        if code.contains("* ") { return .accounting }
        if code.contains("$") || code.contains("€") || code.contains("£") || code.contains("¥") { return .currency }
        if code == "@" { return .text }
        return code.contains("0") || code.contains("#") ? .number : nil
    }
}

struct HomeTab: View {
    @ObservedObject var controller: WorkbookController

    private var style: CellStyle { controller.activeStyle }

    var body: some View {
        HStack(spacing: 0) {
            clipboard
            font
            alignment
            number
            styles
            cells
            editing
        }
    }

    // MARK: Clipboard

    private var clipboard: some View {
        CaptionedGroup(title: "Clipboard") {
            RibbonLargeButton(title: "Paste", symbol: "doc.on.clipboard", help: "Paste (⌘V)", menu: { pasteMenu() }) {
                controller.paste()
            }
            RibbonColumn {
                RibbonCompactButton(title: "Cut", symbol: "scissors", help: "Cut (⌘X)") { controller.copySelection(cut: true) }
                RibbonCompactButton(title: "Copy", symbol: "doc.on.doc", help: "Copy (⌘C)") { controller.copySelection() }
                RibbonCompactButton(title: "Format", symbol: "paintbrush.pointed", help: "Format Painter: click once to paint one range, double-click to keep painting",
                                    isOn: controller.formatPainter != nil) {
                    if controller.formatPainter != nil { controller.formatPainter = nil } else { controller.captureFormatPainter(sticky: NSApp.currentEvent?.clickCount == 2) }
                }
            }
        }
    }

    private func pasteMenu() -> NSMenu {
        let menu = NSMenu()
        for mode in PasteMode.allCases {
            menu.add(mode.title, symbol: mode.symbol, enabled: controller.canPaste) { controller.paste(mode) }
        }
        return menu
    }

    // MARK: Font

    private var font: some View {
        CaptionedGroup(title: "Font") {
            RibbonRows {
                FontFamilyPicker(family: style.effectiveFontName) { controller.setFontName($0) }
                    .frame(width: 150)
                FontSizeField(size: CGFloat(style.effectiveFontSize)) { controller.setFontSize(Double($0)) }
                    .frame(width: 56)
                RibbonIconButton(symbol: "textformat.size.larger", help: "Increase Font Size") { controller.growFont(true) }
                RibbonIconButton(symbol: "textformat.size.smaller", help: "Decrease Font Size") { controller.growFont(false) }
            } bottom: {
                RibbonIconButton(symbol: "bold", help: "Bold (⌘B)", isOn: style.bold) { controller.toggleBold() }
                RibbonIconButton(symbol: "italic", help: "Italic (⌘I)", isOn: style.italic) { controller.toggleItalic() }
                RibbonIconButton(symbol: "underline", help: "Underline (⌘U)", isOn: style.underline || style.doubleUnderline) { controller.toggleUnderline() }
                RibbonIconButton(symbol: "strikethrough", help: "Strikethrough", isOn: style.strikethrough) { controller.toggleStrikethrough() }
                RibbonMenuButton(symbol: "square.dashed", help: "Borders") { bordersMenu() }
                ColorSplitButton(symbol: "paintbrush.fill", help: "Fill Color", color: style.fillColor?.nsColor ?? ColorPalettes.defaultHighlightColor, kind: .highlight) { picked in
                    controller.setFillColor(picked.map(RGBColor.init))
                } onMore: {
                    ColorPanelRelay.shared.begin { controller.setFillColor(RGBColor($0)) }
                }
                ColorSplitButton(symbol: "textformat", help: "Font Color", color: style.textColor?.nsColor ?? ColorPalettes.defaultTextColor, kind: .text) { picked in
                    controller.setTextColor(picked.map(RGBColor.init))
                } onMore: {
                    ColorPanelRelay.shared.begin { controller.setTextColor(RGBColor($0)) }
                }
            }
        }
    }

    private func bordersMenu() -> NSMenu {
        let menu = NSMenu()
        for preset in BorderPreset.allCases {
            menu.add(preset.title, symbol: preset.symbol) { controller.applyBorders(preset) }
            if preset == .right || preset == .thickOutside { menu.addItem(.separator()) }
        }
        menu.addItem(.separator())
        let styles = NSMenu(title: "Line Style")
        for line in BorderLineStyle.allCases {
            styles.add(line.rawValue.capitalized) { controller.applyBorders(.all, line: BorderLine(style: line)) }
        }
        menu.addSubmenu(styles, title: "All Borders With Line Style")
        menu.add("More Borders…", symbol: "tablecells") { controller.presenter?.presentFormatCells(tab: .border) }
        return menu
    }

    // MARK: Alignment

    private var alignment: some View {
        CaptionedGroup(title: "Alignment") {
            RibbonRows {
                RibbonIconButton(symbol: "arrow.up.to.line", help: "Top Align", isOn: style.vertical == .top) { controller.setVerticalAlignment(.top) }
                RibbonIconButton(symbol: "arrow.up.and.down.text.horizontal", help: "Middle Align", isOn: style.vertical == .middle) { controller.setVerticalAlignment(.middle) }
                RibbonIconButton(symbol: "arrow.down.to.line", help: "Bottom Align", isOn: style.vertical == .bottom) { controller.setVerticalAlignment(.bottom) }
                RibbonMenuButton(symbol: "textformat.abc.dottedunderline", help: "Orientation") { orientationMenu() }
                RibbonCompactButton(title: "Wrap Text", symbol: "text.word.spacing", isOn: style.wrap) { controller.toggleWrap() }
            } bottom: {
                RibbonIconButton(symbol: "text.alignleft", help: "Align Left", isOn: style.horizontal == .left) { controller.setHorizontalAlignment(.left) }
                RibbonIconButton(symbol: "text.aligncenter", help: "Center", isOn: style.horizontal == .center) { controller.setHorizontalAlignment(.center) }
                RibbonIconButton(symbol: "text.alignright", help: "Align Right", isOn: style.horizontal == .right) { controller.setHorizontalAlignment(.right) }
                RibbonIconButton(symbol: "decrease.indent", help: "Decrease Indent") { controller.changeIndent(-1) }
                RibbonIconButton(symbol: "increase.indent", help: "Increase Indent") { controller.changeIndent(1) }
                RibbonSplitButton(symbol: "rectangle.compress.vertical", help: "Merge & Center", isOn: controller.selectionIsMerged) {
                    controller.merge(.mergeAndCenter)
                } menu: {
                    let menu = NSMenu()
                    menu.add("Merge & Center") { controller.merge(.mergeAndCenter) }
                    menu.add("Merge Across") { controller.merge(.mergeAcross) }
                    menu.add("Merge Cells") { controller.merge(.merge) }
                    menu.add("Unmerge Cells") { controller.merge(.unmerge) }
                    return menu
                }
            }
        }
    }

    private func orientationMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, degrees) in [("Horizontal", 0), ("Angle Counterclockwise", 45), ("Angle Clockwise", -45), ("Rotate Text Up", 90), ("Rotate Text Down", -90)] {
            menu.add(title, checked: style.rotation == degrees) { controller.setRotation(degrees) }
        }
        menu.addItem(.separator())
        menu.add("Format Cell Alignment…") { controller.presenter?.presentFormatCells(tab: .alignment) }
        return menu
    }

    // MARK: Number

    private var number: some View {
        CaptionedGroup(title: "Number") {
            RibbonRows {
                RibbonMenuButton(symbol: NumberFormatPreset.matching(style.numberFormat)?.symbol ?? "number",
                                 help: "Number Format", label: (NumberFormatPreset.matching(style.numberFormat)?.title ?? "Custom").padding(toLength: 11)) {
                    numberMenu()
                }
                .frame(width: 136, alignment: .leading)
            } bottom: {
                RibbonMenuButton(symbol: "dollarsign", help: "Accounting Number Format") { currencyMenu() }
                RibbonIconButton(symbol: "percent", help: "Percent Style") { controller.setNumberFormat("0%") }
                RibbonIconButton(symbol: "comma", help: "Comma Style", text: ",") { controller.setNumberFormat("#,##0.00") }
                RibbonIconButton(symbol: "plus", help: "Increase Decimal", text: ".0→") { controller.adjustDecimals(1) }
                RibbonIconButton(symbol: "minus", help: "Decrease Decimal", text: "←.0") { controller.adjustDecimals(-1) }
            }
        }
    }

    private func numberMenu() -> NSMenu {
        let menu = NSMenu()
        let sample = controller.value(at: controller.selection.active)
        for preset in NumberFormatPreset.allCases {
            let preview = sample.number.map { NumberFormat.formatNumber($0, preset.code).text } ?? ""
            let item = menu.add(preset.title, symbol: preset.symbol, checked: NumberFormatPreset.matching(style.numberFormat) == preset) {
                controller.setNumberFormat(preset.code)
            }
            if !preview.isEmpty { item.toolTip = preview; item.title = preset.title + "    " + preview }
        }
        menu.addItem(.separator())
        menu.add("More Number Formats…", symbol: "ellipsis.circle") { controller.presenter?.presentFormatCells(tab: .number) }
        return menu
    }

    private func currencyMenu() -> NSMenu {
        let menu = NSMenu()
        menu.add("$ English (United States)") { controller.setNumberFormat(NumberFormat.accounting) }
        menu.add("£ English (United Kingdom)") { controller.setNumberFormat("_(£* #,##0.00_);_(£* (#,##0.00);_(£* \"-\"??_);_(@_)") }
        menu.add("€ Euro") { controller.setNumberFormat("_(* #,##0.00 €_);_(* (#,##0.00) €;_(* \"-\"?? €_);_(@_)") }
        menu.add("¥ Japanese") { controller.setNumberFormat("_(¥* #,##0_);_(¥* (#,##0);_(¥* \"-\"_);_(@_)") }
        menu.add("CHF Swiss Franc") { controller.setNumberFormat("_(\"CHF\"* #,##0.00_);_(\"CHF\"* (#,##0.00);_(\"CHF\"* \"-\"??_);_(@_)") }
        menu.addItem(.separator())
        menu.add("More Accounting Formats…") { controller.presenter?.presentFormatCells(tab: .number) }
        return menu
    }

    // MARK: Styles

    private var styles: some View {
        CaptionedGroup(title: "Styles") {
            RibbonLargeButton(title: "Conditional Formatting", symbol: "chart.bar.doc.horizontal", menu: { ConditionalFormattingMenu.make(controller) })
            RibbonLargeButton(title: "Format as Table", symbol: "tablecells.badge.ellipsis", menu: { tableMenu() })
            RibbonLargeButton(title: "Cell Styles", symbol: "paintpalette", menu: { cellStylesMenu() })
        }
    }

    private func tableMenu() -> NSMenu {
        let menu = NSMenu()
        for style in TableStyle.allCases {
            let item = menu.add(style.title) { controller.formatAsTable(style) }
            item.image = NSImage(size: NSSize(width: 28, height: 18), flipped: true) { rect in
                style.header.nsColor.setFill()
                CGRect(x: 0, y: 0, width: rect.width, height: 5).fill()
                for i in 0..<3 {
                    (i % 2 == 0 ? style.band.nsColor : NSColor.white).setFill()
                    CGRect(x: 0, y: 5 + CGFloat(i) * 4.3, width: rect.width, height: 4.3).fill()
                }
                NSColor.separatorColor.setStroke()
                NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
                return true
            }
        }
        if controller.sheet.tables.contains(where: { $0.range.contains(controller.selection.active) }) {
            menu.addItem(.separator())
            let address = controller.selection.active
            if let table = controller.sheet.tables.first(where: { $0.range.contains(address) }) {
                menu.add("Banded Rows", checked: table.bandedRows) { var t = table; t.bandedRows.toggle(); controller.updateTable(t) }
                menu.add("Header Row", checked: table.showHeader) { var t = table; t.showHeader.toggle(); controller.updateTable(t) }
                menu.add("Total Row", checked: table.showTotals) { var t = table; t.showTotals.toggle(); controller.updateTable(t) }
            }
            menu.add("Convert to Range") { controller.removeTable(containing: address) }
        }
        return menu
    }

    private func cellStylesMenu() -> NSMenu {
        let menu = NSMenu()
        for named in NamedCellStyle.allCases {
            var sample = CellStyle()
            named.apply(to: &sample)
            let item = menu.add(named.title) { controller.applyNamedStyle(named) }
            let title = NSMutableAttributedString(string: named.title, attributes: [
                .font: sample.font(zoom: min(1, 13 / sample.effectiveFontSize)),
                .foregroundColor: sample.textColor?.nsColor ?? NSColor.labelColor,
            ])
            if let fill = sample.fillColor { title.addAttribute(.backgroundColor, value: fill.nsColor, range: NSRange(location: 0, length: title.length)) }
            item.attributedTitle = title
            if named == .normal || named == .neutral || named == .heading3 || named == .calculation { menu.addItem(.separator()) }
        }
        return menu
    }

    // MARK: Cells

    private var cells: some View {
        CaptionedGroup(title: "Cells") {
            RibbonLargeButton(title: "Insert", symbol: "plus.rectangle.on.rectangle", menu: {
                let menu = NSMenu()
                menu.add("Insert Cells (Shift Down)", symbol: "arrow.down.square") { controller.insertCells(shiftDown: true) }
                menu.add("Insert Cells (Shift Right)", symbol: "arrow.right.square") { controller.insertCells(shiftDown: false) }
                menu.add("Insert Sheet Rows", symbol: "rectangle.split.1x2") { controller.insertSheetRows() }
                menu.add("Insert Sheet Columns", symbol: "rectangle.split.3x1") { controller.insertSheetColumns() }
                menu.addItem(.separator())
                menu.add("Insert Sheet", symbol: "plus.rectangle") { controller.addSheet() }
                return menu
            }) { controller.insertForSelection() }
            RibbonLargeButton(title: "Delete", symbol: "minus.rectangle", menu: {
                let menu = NSMenu()
                menu.add("Delete Cells (Shift Up)", symbol: "arrow.up.square") { controller.deleteCells(shiftUp: true) }
                menu.add("Delete Cells (Shift Left)", symbol: "arrow.left.square") { controller.deleteCells(shiftUp: false) }
                menu.add("Delete Sheet Rows", symbol: "rectangle.split.1x2") { controller.deleteSheetRows() }
                menu.add("Delete Sheet Columns", symbol: "rectangle.split.3x1") { controller.deleteSheetColumns() }
                menu.addItem(.separator())
                menu.add("Delete Sheet", symbol: "trash", enabled: controller.sheets.count > 1) { controller.deleteSheet(controller.activeSheetIndex) }
                return menu
            }) { controller.deleteForSelection() }
            RibbonLargeButton(title: "Format", symbol: "rectangle.3.group", menu: { formatMenu() })
        }
    }

    private func formatMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addSection("Cell Size")
        menu.add("Row Height…", symbol: "arrow.up.and.down") { presentRowHeight() }
        menu.add("AutoFit Row Height", symbol: "arrow.up.and.down.square") { controller.autoFitRows(controller.selectedRowIndices) }
        menu.add("Column Width…", symbol: "arrow.left.and.right") { presentColumnWidth() }
        menu.add("AutoFit Column Width", symbol: "arrow.left.and.right.square") { controller.autoFitColumns(controller.selectedColumnIndices) }
        menu.addSection("Visibility")
        menu.add("Hide Rows", symbol: "eye.slash") { controller.hideRows() }
        menu.add("Hide Columns", symbol: "eye.slash") { controller.hideColumns() }
        menu.add("Unhide Rows", symbol: "eye") { controller.unhideRows() }
        menu.add("Unhide Columns", symbol: "eye") { controller.unhideColumns() }
        menu.addSection("Organize Sheets")
        menu.add("Rename Sheet…", symbol: "pencil") {
            let index = controller.activeSheetIndex
            controller.presenter?.presentTextPrompt(title: "Rename Sheet", message: "Sheet name:", value: controller.sheet.name) { controller.renameSheet(index, to: $0) }
        }
        menu.add("Duplicate Sheet", symbol: "plus.square.on.square") { controller.duplicateSheet(controller.activeSheetIndex) }
        menu.addItem(.separator())
        menu.add("Format Cells…", symbol: "tablecells") { controller.presenter?.presentFormatCells(tab: .number) }
        return menu
    }

    private func presentRowHeight() {
        let rows = controller.selectedRowIndices
        controller.presenter?.presentNumberPrompt(title: "Row Height", message: "Height in points:", value: controller.sheet.rowHeight(rows.first ?? 0)) {
            controller.setRowHeight($0, rows: rows)
        }
    }

    private func presentColumnWidth() {
        let columns = controller.selectedColumnIndices
        controller.presenter?.presentNumberPrompt(title: "Column Width", message: "Width in points:", value: controller.sheet.columnWidth(columns.first ?? 0)) {
            controller.setColumnWidth($0, columns: columns)
        }
    }

    // MARK: Editing

    private var editing: some View {
        CaptionedGroup(title: "Editing", showsDivider: false) {
            RibbonColumn {
                RibbonSplitButton(symbol: "sum", help: "AutoSum") { controller.autoSum() } menu: { AutoSumMenu.make(controller) }
                RibbonMenuButton(symbol: "arrow.down.to.line.compact", help: "Fill", label: "Fill") {
                    let menu = NSMenu()
                    menu.add("Down (⌘D)", symbol: "arrow.down") { controller.fill(down: true) }
                    menu.add("Right (⌘R)", symbol: "arrow.right") { controller.fill(down: false) }
                    menu.add("Series…", symbol: "list.number") {
                        controller.presenter?.presentNumberPrompt(title: "Series", message: "Step value:", value: 1) { step in
                            controller.fillSeries(step: step, vertical: controller.selection.primary.rowCount >= controller.selection.primary.columnCount)
                        }
                    }
                    return menu
                }
                RibbonMenuButton(symbol: "eraser", help: "Clear", label: "Clear") {
                    let menu = NSMenu()
                    menu.add("Clear All", symbol: "eraser.fill") { controller.clearAll() }
                    menu.add("Clear Formats", symbol: "paintbrush") { controller.clearFormats() }
                    menu.add("Clear Contents", symbol: "eraser") { controller.clearContents() }
                    menu.add("Clear Notes", symbol: "note.text") { controller.clearNotes() }
                    menu.add("Clear Hyperlinks", symbol: "link") { controller.clearHyperlinks() }
                    return menu
                }
            }
            RibbonLargeButton(title: "Sort & Filter", symbol: "line.3.horizontal.decrease.circle", menu: { SortFilterMenu.make(controller) })
            RibbonLargeButton(title: "Find & Select", symbol: "magnifyingglass", menu: { findMenu() })
        }
    }

    private func findMenu() -> NSMenu {
        let menu = NSMenu()
        menu.add("Find…", symbol: "magnifyingglass") { controller.presenter?.presentFindReplace(replace: false) }
        menu.add("Replace…", symbol: "arrow.2.squarepath") { controller.presenter?.presentFindReplace(replace: true) }
        menu.add("Go To…", symbol: "arrow.right.circle") { controller.presenter?.presentGoTo() }
        menu.addItem(.separator())
        menu.add("Formulas", symbol: "function") { controller.selectSpecial(.formulas) }
        menu.add("Constants", symbol: "textformat.123") { controller.selectSpecial(.constants) }
        menu.add("Blanks", symbol: "square.dashed") { controller.selectSpecial(.blanks) }
        menu.add("Notes", symbol: "note.text") { controller.selectSpecial(.notes) }
        menu.add("Errors", symbol: "exclamationmark.triangle") { controller.selectSpecial(.errors) }
        menu.add("Conditional Formatting", symbol: "chart.bar.doc.horizontal") { controller.selectSpecial(.conditionalFormats) }
        return menu
    }
}

// MARK: - Shared menus

enum AutoSumMenu {
    static func make(_ controller: WorkbookController) -> NSMenu {
        let menu = NSMenu()
        for (title, function) in [("Sum", "SUM"), ("Average", "AVERAGE"), ("Count Numbers", "COUNT"), ("Max", "MAX"), ("Min", "MIN")] {
            menu.add(title) { controller.autoSum(function) }
        }
        menu.addItem(.separator())
        menu.add("More Functions…") { controller.presenter?.presentInsertFunction(category: nil) }
        return menu
    }
}

enum SortFilterMenu {
    static func make(_ controller: WorkbookController) -> NSMenu {
        let menu = NSMenu()
        menu.add("Sort A to Z", symbol: "arrow.up") { controller.quickSort(ascending: true) }
        menu.add("Sort Z to A", symbol: "arrow.down") { controller.quickSort(ascending: false) }
        menu.add("Custom Sort…", symbol: "arrow.up.arrow.down") { controller.presenter?.presentSort() }
        menu.addItem(.separator())
        menu.add("Filter", symbol: "line.3.horizontal.decrease.circle", checked: controller.sheet.filter != nil) { controller.toggleFilter() }
        menu.add("Clear", symbol: "xmark.circle", enabled: !(controller.sheet.filter?.criteria.isEmpty ?? true)) { controller.clearFilters() }
        menu.add("Reapply", symbol: "arrow.clockwise", enabled: controller.sheet.filter != nil) { controller.reapplyFilter() }
        return menu
    }
}

enum ConditionalFormattingMenu {
    static func make(_ c: WorkbookController) -> NSMenu {
        let menu = NSMenu()
        let highlight = NSMenu(title: "Highlight Cells Rules")
        highlight.add("Greater Than…") { c.presenter?.presentConditionalFormat(.greaterThan(0)) }
        highlight.add("Less Than…") { c.presenter?.presentConditionalFormat(.lessThan(0)) }
        highlight.add("Between…") { c.presenter?.presentConditionalFormat(.between(0, 100)) }
        highlight.add("Equal To…") { c.presenter?.presentConditionalFormat(.equalTo("")) }
        highlight.add("Text That Contains…") { c.presenter?.presentConditionalFormat(.textContains("")) }
        highlight.add("Duplicate Values") { c.addConditionalFormat(.duplicates) }
        highlight.add("Unique Values") { c.addConditionalFormat(.uniques, format: .green) }
        highlight.add("Blank Cells") { c.addConditionalFormat(.blanks, format: .yellow) }
        menu.addSubmenu(highlight)
        let top = NSMenu(title: "Top/Bottom Rules")
        top.add("Top 10 Items") { c.addConditionalFormat(.top(10, percent: false), format: .green) }
        top.add("Top 10%") { c.addConditionalFormat(.top(10, percent: true), format: .green) }
        top.add("Bottom 10 Items") { c.addConditionalFormat(.bottom(10, percent: false)) }
        top.add("Bottom 10%") { c.addConditionalFormat(.bottom(10, percent: true)) }
        top.add("Above Average") { c.addConditionalFormat(.aboveAverage, format: .green) }
        top.add("Below Average") { c.addConditionalFormat(.belowAverage) }
        menu.addSubmenu(top)
        menu.addItem(.separator())
        let bars = NSMenu(title: "Data Bars")
        for (name, hex) in [("Blue", 0x638EC6), ("Green", 0x63BE7B), ("Red", 0xF8696B), ("Orange", 0xFFB628), ("Light Blue", 0x008AEF), ("Purple", 0xD6007B)] as [(String, UInt32)] {
            let item = bars.add(name) { c.addConditionalFormat(.dataBar(RGBColor(hex))) }
            item.image = swatch([RGBColor(hex)])
        }
        menu.addSubmenu(bars)
        let scales = NSMenu(title: "Color Scales")
        let scaleOptions: [(String, [RGBColor])] = [
            ("Green – Yellow – Red", [RGBColor(0xF8696B), RGBColor(0xFFEB84), RGBColor(0x63BE7B)]),
            ("Red – Yellow – Green", [RGBColor(0x63BE7B), RGBColor(0xFFEB84), RGBColor(0xF8696B)]),
            ("Green – White – Red", [RGBColor(0xF8696B), RGBColor(0xFFFFFF), RGBColor(0x63BE7B)]),
            ("Blue – White – Red", [RGBColor(0xF8696B), RGBColor(0xFFFFFF), RGBColor(0x5A8AC6)]),
            ("White – Green", [RGBColor(0xFFFFFF), RGBColor(0x63BE7B)]),
            ("White – Red", [RGBColor(0xFFFFFF), RGBColor(0xF8696B)]),
        ]
        for (name, colors) in scaleOptions {
            let item = scales.add(name) { c.addConditionalFormat(.colorScale(colors)) }
            item.image = swatch(colors)
        }
        menu.addSubmenu(scales)
        let icons = NSMenu(title: "Icon Sets")
        for set in ConditionalFormat.IconSet.allCases {
            let item = icons.add(set.title) { c.addConditionalFormat(.iconSet(set)) }
            item.image = NSImage(size: NSSize(width: 44, height: 14), flipped: true) { _ in
                for level in 0..<3 {
                    CellRenderer.drawIcon(set, level: 2 - level, in: CGRect(x: CGFloat(level) * 15, y: 0, width: 14, height: 14))
                }
                return true
            }
        }
        menu.addSubmenu(icons)
        menu.addItem(.separator())
        menu.add("New Rule…", symbol: "plus") { c.presenter?.presentConditionalFormat(nil) }
        let clear = NSMenu(title: "Clear Rules")
        clear.add("Clear Rules from Selected Cells") { c.clearConditionalFormats(selectionOnly: true) }
        clear.add("Clear Rules from Entire Sheet") { c.clearConditionalFormats(selectionOnly: false) }
        menu.addSubmenu(clear)
        menu.add("Manage Rules…", symbol: "list.bullet.rectangle") { c.presenter?.presentManageRules() }
        return menu
    }

    static func swatch(_ colors: [RGBColor]) -> NSImage {
        NSImage(size: NSSize(width: 36, height: 12), flipped: false) { rect in
            if colors.count == 1 {
                NSGradient(starting: colors[0].nsColor, ending: colors[0].nsColor.withAlphaComponent(0.2))?.draw(in: rect, angle: 0)
            } else {
                NSGradient(colors: colors.map(\.nsColor))?.draw(in: rect, angle: 0)
            }
            NSColor.separatorColor.setStroke()
            NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            return true
        }
    }
}

/// Sends the shared color panel's picks to a closure (fill or text color).
final class ColorPanelRelay: NSObject {
    static let shared = ColorPanelRelay()
    private var handler: ((NSColor) -> Void)?

    func begin(_ handler: @escaping (NSColor) -> Void) {
        self.handler = handler
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.isContinuous = false
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ panel: NSColorPanel) {
        handler?(panel.color)
    }
}

extension String {
    func padding(toLength length: Int) -> String {
        count >= length ? self : self + String(repeating: " ", count: length - count)
    }
}
