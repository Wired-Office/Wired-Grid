import Foundation

/// Reads `.xlsx` workbooks written by Excel, Numbers, Google Sheets and others:
/// values, formulas (including shared formulas), styles, column widths, row
/// heights, merges, frozen panes, filters, conditional formats and names.
enum XLSXReader {
    static func read(_ data: Data) throws -> Workbook {
        let entries: [String: Data]
        do {
            entries = try ZipArchive.read(data)
        } catch {
            throw GridError.corruptDocument("The file isn't a valid Excel workbook.")
        }
        func document(_ path: String) -> XMLDocument? {
            guard let data = entries[path] ?? entries[path.hasPrefix("/") ? String(path.dropFirst()) : "/" + path] else { return nil }
            return try? XMLDocument(data: data, options: [.nodePreserveWhitespace])
        }
        guard let workbookXML = document("xl/workbook.xml") else {
            throw GridError.corruptDocument("The workbook part is missing.")
        }

        // Relationships: rId → target path.
        var targets: [String: String] = [:]
        if let rels = document("xl/_rels/workbook.xml.rels") {
            for rel in rels.rootElement()?.children(named: "Relationship") ?? [] {
                guard let id = rel.attribute("Id"), var target = rel.attribute("Target") else { continue }
                if target.hasPrefix("/") { target.removeFirst() } else { target = "xl/" + target }
                targets[id] = target
            }
        }

        let sharedStrings = readSharedStrings(document("xl/sharedStrings.xml"))
        let theme = readTheme(document("xl/theme/theme1.xml"))
        let styles = StyleReader(document("xl/styles.xml"), theme: theme)

        var workbook = Workbook(sheets: [])
        let root = workbookXML.rootElement()
        let sheetElements = root?.child(named: "sheets")?.children(named: "sheet") ?? []
        for element in sheetElements {
            let name = element.attribute("name") ?? "Sheet\(workbook.sheets.count + 1)"
            let rid = element.attribute("r:id") ?? element.attributes?.first(where: { $0.name?.hasSuffix(":id") == true })?.stringValue ?? ""
            let path = targets[rid] ?? "xl/worksheets/sheet\(workbook.sheets.count + 1).xml"
            var sheet = Sheet(name: workbook.uniqueSheetName(name))
            if let xml = document(path) {
                readWorksheet(xml, into: &sheet, strings: sharedStrings, styles: styles, theme: theme)
            }
            workbook.sheets.append(sheet)
        }
        if workbook.sheets.isEmpty { workbook.sheets = [Sheet(name: "Sheet1")] }
        if let active = root?.child(named: "bookViews")?.child(named: "workbookView")?.attribute("activeTab").flatMap(Int.init) {
            workbook.activeSheetIndex = min(max(active, 0), workbook.sheets.count - 1)
        }

        for element in root?.child(named: "definedNames")?.children(named: "definedName") ?? [] {
            guard let name = element.attribute("name"), let body = element.stringValue else { continue }
            if name.hasPrefix("_xlnm.") {
                if name == "_xlnm.Print_Area", let local = element.attribute("localSheetId").flatMap(Int.init), workbook.sheets.indices.contains(local),
                   let bang = body.lastIndex(of: "!"), let range = CellRange(a1: String(body[body.index(after: bang)...])) {
                    workbook.sheets[local].pageSetup.printArea = range
                }
                continue
            }
            guard WorkbookController.isValidName(name), element.attribute("localSheetId") == nil else { continue }
            workbook.names.append(DefinedName(name: name, formula: stripPrefixes(body)))
        }
        if let core = document("docProps/core.xml"), let creator = core.rootElement()?.children?.first(where: { $0.localName == "creator" })?.stringValue {
            workbook.author = creator
        }
        return workbook
    }

    static func stripPrefixes(_ formula: String) -> String {
        formula.replacingOccurrences(of: "_xlfn._xlws.", with: "").replacingOccurrences(of: "_xlfn.", with: "").replacingOccurrences(of: "_xlws.", with: "")
    }

    // MARK: - Shared strings

    private static func readSharedStrings(_ document: XMLDocument?) -> [String] {
        guard let root = document?.rootElement() else { return [] }
        return root.children(named: "si").map(richText)
    }

    /// The text of an `<si>` or `<is>` element (plain or rich runs; phonetic runs skipped).
    private static func richText(_ element: XMLElement) -> String {
        if let t = element.child(named: "t") { return t.stringValue ?? "" }
        return element.children(named: "r").map { $0.child(named: "t")?.stringValue ?? "" }.joined()
    }

    // MARK: - Theme

    private static func readTheme(_ document: XMLDocument?) -> [RGBColor] {
        // Default Office palette in theme index order: lt1, dk1, lt2, dk2, accent1…6.
        var palette = [0xFFFFFF, 0x000000, 0xE7E6E6, 0x44546A, 0x4472C4, 0xED7D31, 0xA5A5A5, 0xFFC000, 0x5B9BD5, 0x70AD47].map(RGBColor.init)
        guard let scheme = document?.rootElement()?.child(named: "themeElements")?.child(named: "clrScheme") else { return palette }
        let order = ["lt1", "dk1", "lt2", "dk2", "accent1", "accent2", "accent3", "accent4", "accent5", "accent6"]
        for (i, name) in order.enumerated() {
            guard let element = scheme.child(named: name) else { continue }
            if let value = element.child(named: "srgbClr")?.attribute("val"), let color = RGBColor(hex: value) {
                palette[i] = color
            } else if let value = element.child(named: "sysClr")?.attribute("lastClr"), let color = RGBColor(hex: value) {
                palette[i] = color
            }
        }
        return palette
    }

    // MARK: - Worksheets

    private static func readWorksheet(_ document: XMLDocument, into sheet: inout Sheet, strings: [String], styles: StyleReader, theme: [RGBColor]) {
        guard let root = document.rootElement() else { return }

        if let tab = root.child(named: "sheetPr")?.child(named: "tabColor") {
            sheet.tabColor = StyleReader.color(tab, theme: theme)
        }
        if let view = root.child(named: "sheetViews")?.child(named: "sheetView") {
            if view.attribute("showGridLines") == "0" { sheet.showGridlines = false }
            if view.attribute("showRowColHeaders") == "0" { sheet.showHeadings = false }
            if let zoom = view.attribute("zoomScale").flatMap(Double.init), zoom > 0 { sheet.zoom = min(max(zoom / 100, 0.1), 4) }
            if let pane = view.child(named: "pane"), pane.attribute("state") == "frozen" || pane.attribute("state") == "frozenSplit" {
                sheet.frozenColumns = Int(Double(pane.attribute("xSplit") ?? "0") ?? 0)
                sheet.frozenRows = Int(Double(pane.attribute("ySplit") ?? "0") ?? 0)
            }
        }
        let defaultRowHeight = root.child(named: "sheetFormatPr")?.attribute("defaultRowHeight").flatMap(Double.init) ?? 15

        for col in root.child(named: "cols")?.children(named: "col") ?? [] {
            guard let min = col.attribute("min").flatMap(Int.init), let max = col.attribute("max").flatMap(Int.init), min >= 1, max >= min else { continue }
            let upper = Swift.min(max, min + 300) // ignore absurd whole-sheet ranges beyond what matters
            for column in (min - 1)...(upper - 1) {
                if let width = col.attribute("width").flatMap(Double.init), col.attribute("customWidth") == "1" || abs(width - 8.43) > 0.3 {
                    let points = ExcelUnits.points(fromColumnCharacters: width)
                    if abs(points - Sheet.defaultColumnWidth) > 0.5 { sheet.columnWidths[column] = points }
                }
                if col.attribute("hidden") == "1" { sheet.hiddenColumns.insert(column) }
                if let s = col.attribute("style").flatMap(Int.init), let style = styles.style(s), !style.isPlain, max - min < 300 {
                    sheet.columnStyles[column] = style
                }
            }
        }

        var sharedFormulas: [String: (formula: String, origin: CellAddress)] = [:]
        var nextRow = 0
        for rowElement in root.child(named: "sheetData")?.children(named: "row") ?? [] {
            let row = (rowElement.attribute("r").flatMap(Int.init) ?? (nextRow + 1)) - 1
            nextRow = row + 1
            guard row >= 0, row < SheetLimits.rows else { continue }
            if let height = rowElement.attribute("ht").flatMap(Double.init), rowElement.attribute("customHeight") == "1" || abs(height - defaultRowHeight) > 0.3 {
                let points = ExcelUnits.points(fromExcelRowHeight: height)
                if abs(points - Sheet.defaultRowHeight) > 0.5 { sheet.rowHeights[row] = points }
            }
            if rowElement.attribute("hidden") == "1" { sheet.hiddenRows.insert(row) }
            if rowElement.attribute("customFormat") == "1", let s = rowElement.attribute("s").flatMap(Int.init), let style = styles.style(s), !style.isPlain {
                sheet.rowStyles[row] = style
            }
            var nextColumn = 0
            for c in rowElement.children(named: "c") {
                let address = c.attribute("r").flatMap { CellAddress(a1: $0) } ?? CellAddress(row: row, column: nextColumn)
                nextColumn = address.column + 1
                var cell = Cell()
                if let s = c.attribute("s").flatMap(Int.init), let style = styles.style(s), !style.isPlain {
                    cell.style = style
                }
                let type = c.attribute("t") ?? "n"
                let rawValue = c.child(named: "v")?.stringValue
                switch type {
                case "s":
                    if let index = rawValue.flatMap(Int.init), strings.indices.contains(index) { cell.value = .string(strings[index]) }
                case "inlineStr":
                    if let inline = c.child(named: "is") { cell.value = .string(richText(inline)) }
                case "str":
                    cell.value = .string(rawValue ?? "")
                case "b":
                    cell.value = .bool(rawValue == "1" || rawValue?.lowercased() == "true")
                case "e":
                    cell.value = .error(FormulaError(rawValue: rawValue ?? "") ?? .value)
                case "d":
                    if let raw = rawValue, let date = ISO8601DateFormatter().date(from: raw) { cell.value = .number(DateSerial.from(date, timeZone: TimeZone(secondsFromGMT: 0)!)) }
                default:
                    if let raw = rawValue, let n = Double(raw) { cell.value = .number(n) }
                }
                if let f = c.child(named: "f") {
                    let text = f.stringValue ?? ""
                    if f.attribute("t") == "shared", let si = f.attribute("si") {
                        if !text.isEmpty {
                            sharedFormulas[si] = (text, address)
                            cell.formula = stripPrefixes(text)
                        } else if let master = sharedFormulas[si] {
                            cell.formula = stripPrefixes(FormulaRewriter.shift(master.formula, rows: address.row - master.origin.row, columns: address.column - master.origin.column))
                        }
                    } else if !text.isEmpty, f.attribute("t") != "dataTable" {
                        cell.formula = stripPrefixes(text).replacingOccurrences(of: "_xlpm.", with: "")
                    }
                    if let formula = cell.formula, formula.hasPrefix("@") { cell.formula = String(formula.dropFirst()) }
                }
                if address.isValid, !cell.isVacant { sheet[address] = cell }
            }
        }

        for merge in root.child(named: "mergeCells")?.children(named: "mergeCell") ?? [] {
            if let ref = merge.attribute("ref"), let range = CellRange(a1: ref), !range.isSingleCell { sheet.merges.append(range) }
        }
        if let filter = root.child(named: "autoFilter"), let ref = filter.attribute("ref"), let range = CellRange(a1: ref) {
            var autoFilter = AutoFilter(range: range)
            for column in filter.children(named: "filterColumn") {
                guard let id = column.attribute("colId").flatMap(Int.init), let filters = column.child(named: "filters") else { continue }
                var allowed = Set(filters.children(named: "filter").compactMap { $0.attribute("val") })
                if filters.attribute("blank") == "1" { allowed.insert("") }
                autoFilter.criteria[range.minColumn + id] = .values(allowed)
            }
            // Rows Excel hid for the filter are the filtered rows.
            if !autoFilter.criteria.isEmpty, let dataRows = autoFilter.dataRows {
                autoFilter.hiddenRows = sheet.hiddenRows.filter { dataRows.contains($0) }
                sheet.hiddenRows.subtract(autoFilter.hiddenRows)
            }
            sheet.filter = autoFilter
        }
        for block in root.children(named: "conditionalFormatting") {
            guard let sqref = block.attribute("sqref") else { continue }
            let ranges = sqref.split(separator: " ").compactMap { CellRange(a1: String($0)) }
            for rule in block.children(named: "cfRule") {
                guard let parsed = conditionalRule(rule, styles: styles, theme: theme) else { continue }
                for range in ranges {
                    sheet.conditionalFormats.append(ConditionalFormat(range: range, rule: parsed.0, format: parsed.1))
                }
            }
        }
        if let options = root.child(named: "printOptions") {
            sheet.pageSetup.printGridlines = options.attribute("gridLines") == "1"
            sheet.pageSetup.printHeadings = options.attribute("headings") == "1"
            sheet.pageSetup.centerHorizontally = options.attribute("horizontalCentered") == "1"
        }
        if let setup = root.child(named: "pageSetup") {
            if setup.attribute("orientation") == "landscape" { sheet.pageSetup.orientation = .landscape }
            if setup.attribute("fitToHeight") == "0" && setup.attribute("fitToWidth") == "1" { sheet.pageSetup.scaling = .fitWidth }
        }
    }

    private static func conditionalRule(_ rule: XMLElement, styles: StyleReader, theme: [RGBColor]) -> (ConditionalFormat.Rule, HighlightFormat)? {
        let format = rule.attribute("dxfId").flatMap(Int.init).flatMap { styles.differential($0) } ?? .lightRed
        let formulas = rule.children(named: "formula").compactMap(\.stringValue)
        func number(_ i: Int) -> Double? { formulas.indices.contains(i) ? Double(formulas[i]) : nil }
        func text(_ i: Int) -> String? {
            guard formulas.indices.contains(i) else { return nil }
            var t = formulas[i]
            if t.hasPrefix("\"") && t.hasSuffix("\"") && t.count >= 2 { t = String(t.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"") }
            return t
        }
        switch rule.attribute("type") {
        case "cellIs":
            switch rule.attribute("operator") {
            case "greaterThan": return number(0).map { (.greaterThan($0), format) }
            case "greaterThanOrEqual": return number(0).map { (.greaterThan($0 - 1e-9), format) }
            case "lessThan": return number(0).map { (.lessThan($0), format) }
            case "lessThanOrEqual": return number(0).map { (.lessThan($0 + 1e-9), format) }
            case "between": if let a = number(0), let b = number(1) { return (.between(a, b), format) }
            case "equal": return text(0).map { (.equalTo($0), format) }
            case "notEqual": return text(0).map { (.notEqualTo($0), format) }
            default: return nil
            }
            return nil
        case "containsText": return rule.attribute("text").map { (.textContains($0), format) }
        case "beginsWith": return rule.attribute("text").map { (.beginsWith($0), format) }
        case "endsWith": return rule.attribute("text").map { (.endsWith($0), format) }
        case "containsBlanks": return (.blanks, format)
        case "notContainsBlanks": return (.noBlanks, format)
        case "duplicateValues": return (.duplicates, format)
        case "uniqueValues": return (.uniques, format)
        case "top10":
            let rank = rule.attribute("rank").flatMap(Int.init) ?? 10
            let percent = rule.attribute("percent") == "1"
            return (rule.attribute("bottom") == "1" ? .bottom(rank, percent: percent) : .top(rank, percent: percent), format)
        case "aboveAverage":
            return (rule.attribute("aboveAverage") == "0" ? .belowAverage : .aboveAverage, format)
        case "expression":
            return formulas.first.map { (.formula(stripPrefixes($0)), format) }
        case "colorScale":
            let colors = rule.child(named: "colorScale")?.children(named: "color").compactMap { StyleReader.color($0, theme: theme) } ?? []
            return colors.count >= 2 ? (.colorScale(colors), format) : nil
        case "dataBar":
            let color = rule.child(named: "dataBar")?.child(named: "color").flatMap { StyleReader.color($0, theme: theme) } ?? RGBColor(0x638EC6)
            return (.dataBar(color), format)
        case "iconSet":
            let name = rule.child(named: "iconSet")?.attribute("iconSet") ?? "3TrafficLights1"
            let set: ConditionalFormat.IconSet = name.contains("Arrow") ? .arrows : name.contains("Flag") ? .flags : name.contains("Star") ? .stars : .trafficLights
            return (.iconSet(set), format)
        default:
            return nil
        }
    }
}

// MARK: - Styles

private struct StyleReader {
    private var styles: [CellStyle] = []
    private var dxfs: [HighlightFormat] = []

    static let builtinFormats: [Int: String] = [
        0: "General", 1: "0", 2: "0.00", 3: "#,##0", 4: "#,##0.00", 5: "$#,##0_);($#,##0)", 6: "$#,##0_);[Red]($#,##0)",
        7: "$#,##0.00_);($#,##0.00)", 8: "$#,##0.00_);[Red]($#,##0.00)", 9: "0%", 10: "0.00%", 11: "0.00E+00", 12: "# ?/?",
        13: "# ??/??", 14: "m/d/yyyy", 15: "d-mmm-yy", 16: "d-mmm", 17: "mmm-yy", 18: "h:mm AM/PM", 19: "h:mm:ss AM/PM",
        20: "h:mm", 21: "h:mm:ss", 22: "m/d/yyyy h:mm", 37: "#,##0 ;(#,##0)", 38: "#,##0 ;[Red](#,##0)", 39: "#,##0.00;(#,##0.00)",
        40: "#,##0.00;[Red](#,##0.00)", 44: NumberFormat.accounting, 45: "mm:ss", 46: "[h]:mm:ss", 47: "mmss.0", 48: "##0.0E+0", 49: "@",
    ]

    init(_ document: XMLDocument?, theme: [RGBColor]) {
        guard let root = document?.rootElement() else { return }
        var formats = Self.builtinFormats
        for numFmt in root.child(named: "numFmts")?.children(named: "numFmt") ?? [] {
            if let id = numFmt.attribute("numFmtId").flatMap(Int.init), let code = numFmt.attribute("formatCode") {
                formats[id] = Self.cleanFormat(code)
            }
        }
        struct Font { var name: String?; var size: Double?; var bold = false, italic = false, underline = false, doubleUnderline = false, strike = false; var color: RGBColor? }
        let fonts: [Font] = (root.child(named: "fonts")?.children(named: "font") ?? []).map { f in
            var font = Font()
            font.name = f.child(named: "name")?.attribute("val")
            font.size = f.child(named: "sz")?.attribute("val").flatMap(Double.init)
            font.bold = f.child(named: "b").map { $0.attribute("val") != "0" } ?? false
            font.italic = f.child(named: "i").map { $0.attribute("val") != "0" } ?? false
            font.strike = f.child(named: "strike").map { $0.attribute("val") != "0" } ?? false
            if let u = f.child(named: "u") {
                let val = u.attribute("val") ?? "single"
                font.underline = val == "single" || val == "singleAccounting"
                font.doubleUnderline = val == "double" || val == "doubleAccounting"
            }
            if let c = f.child(named: "color") {
                let color = Self.color(c, theme: theme)
                // Theme text color 1 is the default "automatic" black.
                if !(c.attribute("theme") == "1" && c.attribute("tint") == nil) && c.attribute("auto") != "1" && color != .black { font.color = color }
            }
            return font
        }
        let fills: [RGBColor?] = (root.child(named: "fills")?.children(named: "fill") ?? []).map { f in
            guard let pattern = f.child(named: "patternFill"), let type = pattern.attribute("patternType"), type != "none", type != "gray125" else { return nil }
            if let fg = pattern.child(named: "fgColor"), let color = Self.color(fg, theme: theme) { return color }
            return pattern.child(named: "bgColor").flatMap { Self.color($0, theme: theme) }
        }
        let borders: [CellBorders] = (root.child(named: "borders")?.children(named: "border") ?? []).map { b in
            func line(_ name: String) -> BorderLine? {
                guard let edge = b.child(named: name), let style = edge.attribute("style"), style != "none" else { return nil }
                let lineStyle: BorderLineStyle
                switch style {
                case "medium", "mediumDashed", "mediumDashDot", "mediumDashDotDot", "slantDashDot": lineStyle = .medium
                case "thick": lineStyle = .thick
                case "dashed", "dashDot", "dashDotDot": lineStyle = .dashed
                case "dotted": lineStyle = .dotted
                case "double": lineStyle = .double
                case "hair": lineStyle = .hair
                default: lineStyle = .thin
                }
                return BorderLine(style: lineStyle, color: edge.child(named: "color").flatMap { Self.color($0, theme: theme) } ?? .black)
            }
            return CellBorders(top: line("top"), left: line("left") ?? line("start"), bottom: line("bottom"), right: line("right") ?? line("end"))
        }
        let defaultFont = fonts.first
        // Excel's default is 11 pt; Wired Grid's is 12 pt. Keep sizes relative to the default.
        let sizeOffset = CellStyle.defaultFontSize - (defaultFont?.size ?? 11)
        for xf in root.child(named: "cellXfs")?.children(named: "xf") ?? [] {
            var style = CellStyle()
            if let id = xf.attribute("numFmtId").flatMap(Int.init) { style.numberFormat = formats[id] ?? "General" }
            if let id = xf.attribute("fontId").flatMap(Int.init), fonts.indices.contains(id) {
                let font = fonts[id]
                style.bold = font.bold
                style.italic = font.italic
                style.underline = font.underline
                style.doubleUnderline = font.doubleUnderline
                style.strikethrough = font.strike
                style.textColor = font.color
                // Only record fonts that differ from the workbook default.
                if font.name != defaultFont?.name { style.fontName = font.name }
                if font.size != defaultFont?.size, let size = font.size { style.fontSize = size + sizeOffset }
            }
            if let id = xf.attribute("fillId").flatMap(Int.init), fills.indices.contains(id) { style.fillColor = fills[id] }
            if let id = xf.attribute("borderId").flatMap(Int.init), borders.indices.contains(id) { style.borders = borders[id] }
            if let alignment = xf.child(named: "alignment") {
                switch alignment.attribute("horizontal") {
                case "left": style.horizontal = .left
                case "center": style.horizontal = .center
                case "right": style.horizontal = .right
                case "fill": style.horizontal = .fill
                case "justify", "distributed": style.horizontal = .justify
                case "centerContinuous": style.horizontal = .centerAcross
                default: break
                }
                switch alignment.attribute("vertical") {
                case "top": style.vertical = .top
                case "center", "justify", "distributed": style.vertical = .middle
                default: break
                }
                style.wrap = alignment.attribute("wrapText") == "1" || alignment.attribute("wrapText") == "true"
                style.shrinkToFit = alignment.attribute("shrinkToFit") == "1"
                style.indent = alignment.attribute("indent").flatMap(Int.init) ?? 0
                if let rotation = alignment.attribute("textRotation").flatMap(Int.init), rotation != 0 {
                    style.rotation = rotation <= 90 ? rotation : 90 - rotation
                }
            }
            styles.append(style)
        }
        for dxf in root.child(named: "dxfs")?.children(named: "dxf") ?? [] {
            var format = HighlightFormat()
            if let font = dxf.child(named: "font") {
                format.bold = font.child(named: "b") != nil
                format.italic = font.child(named: "i") != nil
                format.text = font.child(named: "color").flatMap { Self.color($0, theme: theme) }
            }
            if let pattern = dxf.child(named: "fill")?.child(named: "patternFill") {
                format.fill = pattern.child(named: "bgColor").flatMap { Self.color($0, theme: theme) } ?? pattern.child(named: "fgColor").flatMap { Self.color($0, theme: theme) }
            }
            if let edge = dxf.child(named: "border")?.child(named: "left"), edge.attribute("style") != nil {
                format.border = edge.child(named: "color").flatMap { Self.color($0, theme: theme) } ?? .black
            }
            dxfs.append(format)
        }
    }

    func style(_ index: Int) -> CellStyle? {
        styles.indices.contains(index) ? styles[index] : nil
    }

    func differential(_ index: Int) -> HighlightFormat? {
        dxfs.indices.contains(index) ? dxfs[index] : nil
    }

    /// Drops locale tags Wired Grid doesn't use (e.g. `[$-409]`).
    static func cleanFormat(_ code: String) -> String {
        var result = code
        while let range = result.range(of: #"\[\$-[0-9A-Fa-f]+\]"#, options: .regularExpression) {
            result.removeSubrange(range)
        }
        return result.isEmpty ? "General" : result
    }

    static let indexedColors: [UInt32] = [
        0x000000, 0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0xFF00FF, 0x00FFFF,
        0x000000, 0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0xFF00FF, 0x00FFFF,
        0x800000, 0x008000, 0x000080, 0x808000, 0x800080, 0x008080, 0xC0C0C0, 0x808080,
        0x9999FF, 0x993366, 0xFFFFCC, 0xCCFFFF, 0x660066, 0xFF8080, 0x0066CC, 0xCCCCFF,
        0x000080, 0xFF00FF, 0xFFFF00, 0x00FFFF, 0x800080, 0x800000, 0x008080, 0x0000FF,
        0x00CCFF, 0xCCFFFF, 0xCCFFCC, 0xFFFF99, 0x99CCFF, 0xFF99CC, 0xCC99FF, 0xFFCC99,
        0x3366FF, 0x33CCCC, 0x99CC00, 0xFFCC00, 0xFF9900, 0xFF6600, 0x666699, 0x969696,
        0x003366, 0x339966, 0x003300, 0x333300, 0x993300, 0x993366, 0x333399, 0x333333,
    ]

    static func color(_ element: XMLElement, theme: [RGBColor]) -> RGBColor? {
        var color: RGBColor?
        if let rgb = element.attribute("rgb"), let parsed = RGBColor(hex: rgb) {
            color = parsed
        } else if let t = element.attribute("theme").flatMap(Int.init), theme.indices.contains(t) {
            color = theme[t]
        } else if let i = element.attribute("indexed").flatMap(Int.init) {
            if i < indexedColors.count { color = RGBColor(indexedColors[i]) } else { return nil }
        }
        guard var result = color else { return nil }
        if let tint = element.attribute("tint").flatMap(Double.init), tint != 0 {
            result = tint > 0 ? result.mixed(with: .white, tint) : result.mixed(with: .black, -tint)
        }
        return result
    }
}

// MARK: - XML helpers

extension XMLElement {
    func child(named name: String) -> XMLElement? {
        children?.first { ($0 as? XMLElement)?.localName == name } as? XMLElement
    }

    func children(named name: String) -> [XMLElement] {
        (children ?? []).compactMap { node in
            guard let element = node as? XMLElement, element.localName == name else { return nil }
            return element
        }
    }

    func attribute(_ name: String) -> String? {
        if let direct = attribute(forName: name)?.stringValue { return direct }
        // Match by local name when the attribute carries a different prefix.
        let local = name.split(separator: ":").last.map(String.init) ?? name
        return attributes?.first { ($0.localName ?? $0.name) == local }?.stringValue
    }
}
