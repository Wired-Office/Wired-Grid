import Foundation

/// Office Open XML measurement conversions between Wired Grid points and Excel units.
enum ExcelUnits {
    /// Excel's default column (8.43 characters) is Wired Grid's 80 pt column.
    static func columnCharacters(fromPoints points: Double) -> Double { (points / Sheet.defaultColumnWidth * 8.43 * 100).rounded() / 100 }
    static func points(fromColumnCharacters characters: Double) -> Double { characters / 8.43 * Sheet.defaultColumnWidth }
    /// Excel's default 15 pt row is Wired Grid's 21 pt row.
    static func excelRowHeight(fromPoints points: Double) -> Double { (points * 15 / Sheet.defaultRowHeight * 4).rounded() / 4 }
    static func points(fromExcelRowHeight height: Double) -> Double { height * Sheet.defaultRowHeight / 15 }
}

/// Writes `.xlsx` workbooks: values, formulas (with cached results), styles,
/// column widths, row heights, merges, frozen panes, filters, conditional
/// formatting, notes-free defined names and page setup.
enum XLSXWriter {
    static func write(_ workbook: Workbook) -> Data {
        let calculator = Calculator(workbook: workbook)
        calculator.recalculate()
        var strings = SharedStrings()
        var styles = StyleTable()

        var sheetXML: [String] = []
        for (index, sheet) in workbook.sheets.enumerated() {
            sheetXML.append(worksheet(sheet, index: index, active: index == workbook.activeSheetIndex, calculator: calculator, strings: &strings, styles: &styles))
        }

        var entries: [(path: String, data: Data)] = []
        func add(_ path: String, _ xml: String) { entries.append((path, Data(xml.utf8))) }

        add("[Content_Types].xml", contentTypes(sheetCount: workbook.sheets.count))
        add("_rels/.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>
        """)
        add("docProps/app.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>Wired Grid</Application></Properties>
        """)
        let now = ISO8601DateFormatter().string(from: Date())
        add("docProps/core.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:creator>\(escape(workbook.author))</dc:creator><dcterms:created xsi:type="dcterms:W3CDTF">\(ISO8601DateFormatter().string(from: workbook.created))</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">\(now)</dcterms:modified></cp:coreProperties>
        """)
        add("xl/workbook.xml", workbookXML(workbook))
        var rels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        for i in workbook.sheets.indices {
            rels += "<Relationship Id=\"rId\(i + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(i + 1).xml\"/>"
        }
        let n = workbook.sheets.count
        rels += "<Relationship Id=\"rId\(n + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
        rels += "<Relationship Id=\"rId\(n + 2)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings\" Target=\"sharedStrings.xml\"/>"
        rels += "</Relationships>"
        add("xl/_rels/workbook.xml.rels", rels)
        add("xl/styles.xml", styles.xml())
        add("xl/sharedStrings.xml", strings.xml())
        for (i, xml) in sheetXML.enumerated() { add("xl/worksheets/sheet\(i + 1).xml", xml) }
        return ZipArchive.write(entries)
    }

    // MARK: - Parts

    private static func contentTypes(sheetCount: Int) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
        """
        for i in 0..<sheetCount {
            xml += "<Override PartName=\"/xl/worksheets/sheet\(i + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        return xml + "</Types>"
    }

    private static func workbookXML(_ workbook: Workbook) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><bookViews><workbookView activeTab="\(workbook.activeSheetIndex)"/></bookViews><sheets>
        """
        for (i, sheet) in workbook.sheets.enumerated() {
            xml += "<sheet name=\"\(escape(sheet.name))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
        }
        xml += "</sheets>"
        var names = workbook.names.map { "<definedName name=\"\(escape($0.name))\">\(escape(excelFormula($0.formula)))</definedName>" }
        for (i, sheet) in workbook.sheets.enumerated() {
            if let filter = sheet.filter {
                names.append("<definedName name=\"_xlnm._FilterDatabase\" localSheetId=\"\(i)\" hidden=\"1\">\(escape(quotedSheetName(sheet.name)))!\(absolute(filter.range))</definedName>")
            }
            if let area = sheet.pageSetup.printArea {
                names.append("<definedName name=\"_xlnm.Print_Area\" localSheetId=\"\(i)\">\(escape(quotedSheetName(sheet.name)))!\(absolute(area))</definedName>")
            }
        }
        if !names.isEmpty { xml += "<definedNames>" + names.joined() + "</definedNames>" }
        xml += "<calcPr calcId=\"191029\" fullCalcOnLoad=\"1\"/></workbook>"
        return xml
    }

    private static func absolute(_ range: CellRange) -> String {
        func abs(_ a: CellAddress) -> String { "$" + CellAddress.columnName(a.column) + "$" + String(a.row + 1) }
        return range.isSingleCell ? abs(range.start) : abs(range.start) + ":" + abs(range.end)
    }

    /// Functions newer than Excel 2010 need the `_xlfn.` prefix in files.
    private static let futureFunctions: Set<String> = [
        "XLOOKUP", "XMATCH", "FILTER", "SORT", "SORTBY", "UNIQUE", "SEQUENCE", "RANDARRAY", "LET", "TEXTJOIN", "CONCAT",
        "IFS", "SWITCH", "MAXIFS", "MINIFS", "IFNA", "XOR", "DAYS", "ISOWEEKNUM", "STDEV.S", "STDEV.P", "VAR.S", "VAR.P",
        "MODE.SNGL", "PERCENTILE.INC", "PERCENTILE.EXC", "QUARTILE.INC", "QUARTILE.EXC", "RANK.EQ", "RANK.AVG",
        "NORM.DIST", "NORM.S.DIST", "NORM.INV", "NORM.S.INV", "CEILING.MATH", "FLOOR.MATH", "TEXTBEFORE", "TEXTAFTER",
        "TEXTSPLIT", "VSTACK", "HSTACK", "TAKE", "DROP", "CHOOSECOLS", "CHOOSEROWS", "TOCOL", "TOROW", "FORECAST.LINEAR",
        "COVARIANCE.P", "COVARIANCE.S", "BINOM.DIST", "POISSON.DIST", "EXPON.DIST", "CONFIDENCE.NORM", "UNICHAR", "UNICODE",
        "NUMBERVALUE", "SHEET", "SHEETS", "FORMULATEXT", "ISFORMULA", "COMBINA", "ARABIC", "BASE", "DECIMAL", "COT", "CSC",
        "SEC", "AGGREGATE", "PERCENTRANK.INC", "RRI", "PDURATION",
    ]

    static func excelFormula(_ formula: String) -> String {
        guard let tokens = try? FormulaLexer.tokenize(formula) else { return formula }
        var result = ""
        for token in tokens {
            if case .function(let name) = token.kind, futureFunctions.contains(name) {
                result += "_xlfn." + token.text
            } else {
                result += token.text
            }
        }
        return result
    }

    // MARK: - Worksheets

    private static func worksheet(_ sheet: Sheet, index: Int, active: Bool, calculator: Calculator, strings: inout SharedStrings, styles: inout StyleTable) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        """
        if let tab = sheet.tabColor { xml += "<sheetPr><tabColor rgb=\"\(tab.argb)\"/></sheetPr>" }
        xml += "<dimension ref=\"\(sheet.usedRange.map { CellRange(.origin, $0.end).a1 } ?? "A1")\"/>"

        var view = "<sheetView workbookViewId=\"0\""
        if active { view += " tabSelected=\"1\"" }
        if !sheet.showGridlines { view += " showGridLines=\"0\"" }
        if !sheet.showHeadings { view += " showRowColHeaders=\"0\"" }
        if sheet.zoom != 1 { view += " zoomScale=\"\(Int((sheet.zoom * 100).rounded()))\"" }
        view += ">"
        if sheet.frozenRows > 0 || sheet.frozenColumns > 0 {
            let topLeft = CellAddress(row: sheet.frozenRows, column: sheet.frozenColumns).a1
            let pane = sheet.frozenRows > 0 && sheet.frozenColumns > 0 ? "bottomRight" : (sheet.frozenRows > 0 ? "bottomLeft" : "topRight")
            view += "<pane"
            if sheet.frozenColumns > 0 { view += " xSplit=\"\(sheet.frozenColumns)\"" }
            if sheet.frozenRows > 0 { view += " ySplit=\"\(sheet.frozenRows)\"" }
            view += " topLeftCell=\"\(topLeft)\" activePane=\"\(pane)\" state=\"frozen\"/>"
        }
        view += "</sheetView>"
        xml += "<sheetViews>\(view)</sheetViews>"
        xml += "<sheetFormatPr defaultRowHeight=\"15\"/>"

        // Columns: runs of identical width/style/hidden settings.
        let customColumns = Set(sheet.columnWidths.keys).union(sheet.hiddenColumns).union(sheet.columnStyles.keys).sorted()
        if !customColumns.isEmpty {
            xml += "<cols>"
            for column in customColumns {
                let width = ExcelUnits.columnCharacters(fromPoints: sheet.columnWidths[column] ?? Sheet.defaultColumnWidth)
                var col = "<col min=\"\(column + 1)\" max=\"\(column + 1)\" width=\"\(width)\" customWidth=\"1\""
                if sheet.hiddenColumns.contains(column) { col += " hidden=\"1\"" }
                if let style = sheet.columnStyles[column] { col += " style=\"\(styles.index(for: style))\"" }
                xml += col + "/>"
            }
            xml += "</cols>"
        }

        // Cells, row by row.
        var rows: [Int: [(Int, Cell)]] = [:]
        for (address, cell) in sheet.cells { rows[address.row, default: []].append((address.column, cell)) }
        let rowIndices = Set(rows.keys).union(sheet.rowHeights.keys).union(sheet.hiddenRows).union(sheet.rowStyles.keys)
            .union(sheet.filter?.hiddenRows ?? []).sorted()
        xml += "<sheetData>"
        for row in rowIndices {
            var rowXML = "<row r=\"\(row + 1)\""
            if let height = sheet.rowHeights[row] { rowXML += " ht=\"\(ExcelUnits.excelRowHeight(fromPoints: height))\" customHeight=\"1\"" }
            if sheet.isRowHidden(row) { rowXML += " hidden=\"1\"" }
            if let style = sheet.rowStyles[row] { rowXML += " s=\"\(styles.index(for: style))\" customFormat=\"1\"" }
            rowXML += ">"
            for (column, cell) in (rows[row] ?? []).sorted(by: { $0.0 < $1.0 }) {
                let address = CellAddress(row: row, column: column)
                let style = sheet.style(at: address)
                let styleIndex = style.isPlain ? 0 : styles.index(for: style)
                var c = "<c r=\"\(address.a1)\""
                if styleIndex != 0 { c += " s=\"\(styleIndex)\"" }
                if let formula = cell.formula {
                    let value = calculator.value(sheet: index, at: address)
                    switch value {
                    case .string(let s): c += " t=\"str\"><f>\(escape(excelFormula(formula)))</f><v>\(escape(s))</v></c>"
                    case .bool(let b): c += " t=\"b\"><f>\(escape(excelFormula(formula)))</f><v>\(b ? 1 : 0)</v></c>"
                    case .error(let e): c += " t=\"e\"><f>\(escape(excelFormula(formula)))</f><v>\(escape(e == .circular ? "#REF!" : e.rawValue))</v></c>"
                    case .number(let n): c += "><f>\(escape(excelFormula(formula)))</f><v>\(number(n))</v></c>"
                    case .empty: c += "><f>\(escape(excelFormula(formula)))</f></c>"
                    }
                } else {
                    switch cell.value {
                    case .empty: c += "/>"
                    case .number(let n): c += "><v>\(number(n))</v></c>"
                    case .string(let s): c += " t=\"s\"><v>\(strings.index(for: s))</v></c>"
                    case .bool(let b): c += " t=\"b\"><v>\(b ? 1 : 0)</v></c>"
                    case .error(let e): c += " t=\"e\"><v>\(escape(e.rawValue))</v></c>"
                    }
                }
                rowXML += c
            }
            xml += rowXML + "</row>"
        }
        xml += "</sheetData>"

        if let filter = sheet.filter {
            xml += "<autoFilter ref=\"\(filter.range.a1)\">"
            for (column, criterion) in filter.criteria.sorted(by: { $0.key < $1.key }) {
                guard case .values(let allowed) = criterion else { continue }
                xml += "<filterColumn colId=\"\(column - filter.range.minColumn)\"><filters\(allowed.contains("") ? " blank=\"1\"" : "")>"
                for value in allowed.sorted() where !value.isEmpty { xml += "<filter val=\"\(escape(value))\"/>" }
                xml += "</filters></filterColumn>"
            }
            xml += "</autoFilter>"
        }
        if !sheet.merges.isEmpty {
            xml += "<mergeCells count=\"\(sheet.merges.count)\">" + sheet.merges.map { "<mergeCell ref=\"\($0.a1)\"/>" }.joined() + "</mergeCells>"
        }
        var priority = 1
        for cf in sheet.conditionalFormats {
            if let rule = conditionalRule(cf, priority: priority, styles: &styles) {
                xml += "<conditionalFormatting sqref=\"\(cf.range.a1)\">\(rule)</conditionalFormatting>"
                priority += 1
            }
        }
        let setup = sheet.pageSetup
        if setup.printGridlines || setup.printHeadings || setup.centerHorizontally {
            xml += "<printOptions" + (setup.printGridlines ? " gridLines=\"1\"" : "") + (setup.printHeadings ? " headings=\"1\"" : "") + (setup.centerHorizontally ? " horizontalCentered=\"1\"" : "") + "/>"
        }
        let margin = setup.margin / 72
        xml += "<pageMargins left=\"\(margin)\" right=\"\(margin)\" top=\"\(margin)\" bottom=\"\(margin)\" header=\"0.3\" footer=\"0.3\"/>"
        var page = "<pageSetup orientation=\"\(setup.orientation == .landscape ? "landscape" : "portrait")\""
        if setup.scaling == .fitWidth { page += " fitToWidth=\"1\" fitToHeight=\"0\"" }
        if setup.scaling == .fitPage { page += " fitToWidth=\"1\" fitToHeight=\"1\"" }
        xml += page + "/>"
        xml += "</worksheet>"
        return xml
    }

    private static func conditionalRule(_ cf: ConditionalFormat, priority: Int, styles: inout StyleTable) -> String? {
        func dxf() -> Int { styles.differential(for: cf.format) }
        func cellIs(_ op: String, _ formulas: [String]) -> String {
            "<cfRule type=\"cellIs\" dxfId=\"\(dxf())\" priority=\"\(priority)\" operator=\"\(op)\">" + formulas.map { "<formula>\(escape($0))</formula>" }.joined() + "</cfRule>"
        }
        func quoted(_ text: String) -> String {
            ValueParser.number(from: text) != nil ? text : "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let first = cf.range.start.a1
        switch cf.rule {
        case .greaterThan(let v): return cellIs("greaterThan", [number(v)])
        case .lessThan(let v): return cellIs("lessThan", [number(v)])
        case .between(let a, let b): return cellIs("between", [number(a), number(b)])
        case .equalTo(let t): return cellIs("equal", [quoted(t)])
        case .notEqualTo(let t): return cellIs("notEqual", [quoted(t)])
        case .textContains(let t):
            return "<cfRule type=\"containsText\" dxfId=\"\(dxf())\" priority=\"\(priority)\" operator=\"containsText\" text=\"\(escape(t))\"><formula>NOT(ISERROR(SEARCH(\(escape(quoted(t))),\(first))))</formula></cfRule>"
        case .beginsWith(let t):
            return "<cfRule type=\"beginsWith\" dxfId=\"\(dxf())\" priority=\"\(priority)\" operator=\"beginsWith\" text=\"\(escape(t))\"><formula>LEFT(\(first),\(t.count))=\(escape(quoted(t)))</formula></cfRule>"
        case .endsWith(let t):
            return "<cfRule type=\"endsWith\" dxfId=\"\(dxf())\" priority=\"\(priority)\" operator=\"endsWith\" text=\"\(escape(t))\"><formula>RIGHT(\(first),\(t.count))=\(escape(quoted(t)))</formula></cfRule>"
        case .blanks:
            return "<cfRule type=\"containsBlanks\" dxfId=\"\(dxf())\" priority=\"\(priority)\"><formula>LEN(TRIM(\(first)))=0</formula></cfRule>"
        case .noBlanks:
            return "<cfRule type=\"notContainsBlanks\" dxfId=\"\(dxf())\" priority=\"\(priority)\"><formula>LEN(TRIM(\(first)))&gt;0</formula></cfRule>"
        case .duplicates: return "<cfRule type=\"duplicateValues\" dxfId=\"\(dxf())\" priority=\"\(priority)\"/>"
        case .uniques: return "<cfRule type=\"uniqueValues\" dxfId=\"\(dxf())\" priority=\"\(priority)\"/>"
        case .top(let n, let p): return "<cfRule type=\"top10\" dxfId=\"\(dxf())\" priority=\"\(priority)\" rank=\"\(n)\"\(p ? " percent=\"1\"" : "")/>"
        case .bottom(let n, let p): return "<cfRule type=\"top10\" dxfId=\"\(dxf())\" priority=\"\(priority)\" rank=\"\(n)\" bottom=\"1\"\(p ? " percent=\"1\"" : "")/>"
        case .aboveAverage: return "<cfRule type=\"aboveAverage\" dxfId=\"\(dxf())\" priority=\"\(priority)\"/>"
        case .belowAverage: return "<cfRule type=\"aboveAverage\" dxfId=\"\(dxf())\" priority=\"\(priority)\" aboveAverage=\"0\"/>"
        case .formula(let f): return "<cfRule type=\"expression\" dxfId=\"\(dxf())\" priority=\"\(priority)\"><formula>\(escape(excelFormula(f)))</formula></cfRule>"
        case .colorScale(let colors):
            guard colors.count >= 2 else { return nil }
            let values = colors.count == 3 ? "<cfvo type=\"min\"/><cfvo type=\"percentile\" val=\"50\"/><cfvo type=\"max\"/>" : "<cfvo type=\"min\"/><cfvo type=\"max\"/>"
            return "<cfRule type=\"colorScale\" priority=\"\(priority)\"><colorScale>\(values)" + colors.map { "<color rgb=\"\($0.argb)\"/>" }.joined() + "</colorScale></cfRule>"
        case .dataBar(let color):
            return "<cfRule type=\"dataBar\" priority=\"\(priority)\"><dataBar><cfvo type=\"min\"/><cfvo type=\"max\"/><color rgb=\"\(color.argb)\"/></dataBar></cfRule>"
        case .iconSet(let set):
            let name: String
            switch set {
            case .arrows: name = "3Arrows"
            case .trafficLights: name = "3TrafficLights1"
            case .flags: name = "3Flags"
            case .stars: name = "3Stars"
            }
            return "<cfRule type=\"iconSet\" priority=\"\(priority)\"><iconSet iconSet=\"\(name)\"><cfvo type=\"percent\" val=\"0\"/><cfvo type=\"percent\" val=\"33\"/><cfvo type=\"percent\" val=\"67\"/></iconSet></cfRule>"
        }
    }

    static func number(_ n: Double) -> String {
        if n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
        return String(n)
    }

    static func escape(_ s: String) -> String {
        var result = ""
        result.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default:
                // Control characters aren't allowed in XML 1.0.
                if scalar.value < 32 && scalar != "\n" && scalar != "\t" && scalar != "\r" { continue }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

// MARK: - Shared strings

private struct SharedStrings {
    private var indices: [String: Int] = [:]
    private var strings: [String] = []
    private var total = 0

    mutating func index(for string: String) -> Int {
        total += 1
        if let existing = indices[string] { return existing }
        indices[string] = strings.count
        strings.append(string)
        return strings.count - 1
    }

    func xml() -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" count=\"\(total)\" uniqueCount=\"\(strings.count)\">"
        for s in strings {
            let preserve = s.first == " " || s.last == " " || s.contains("\n")
            xml += "<si><t\(preserve ? " xml:space=\"preserve\"" : "")>\(XLSXWriter.escape(s))</t></si>"
        }
        return xml + "</sst>"
    }
}

// MARK: - Styles

private struct StyleTable {
    private var xfs: [CellStyle] = [.plain]
    private var xfIndex: [CellStyle: Int] = [.plain: 0]
    private var dxfs: [HighlightFormat] = []

    static let builtinFormats: [String: Int] = [
        "General": 0, "0": 1, "0.00": 2, "#,##0": 3, "#,##0.00": 4, "0%": 9, "0.00%": 10, "0.00E+00": 11,
        "# ?/?": 12, "# ??/??": 13, "m/d/yyyy": 14, "d-mmm-yy": 15, "d-mmm": 16, "mmm-yy": 17, "h:mm AM/PM": 18,
        "h:mm:ss AM/PM": 19, "h:mm": 20, "h:mm:ss": 21, "m/d/yyyy h:mm": 22, "@": 49,
    ]

    mutating func index(for style: CellStyle) -> Int {
        if let existing = xfIndex[style] { return existing }
        xfIndex[style] = xfs.count
        xfs.append(style)
        return xfs.count - 1
    }

    mutating func differential(for format: HighlightFormat) -> Int {
        if let existing = dxfs.firstIndex(of: format) { return existing }
        dxfs.append(format)
        return dxfs.count - 1
    }

    func xml() -> String {
        // Number formats.
        var customFormats: [String: Int] = [:]
        var nextFormatID = 164
        for style in xfs where Self.builtinFormats[style.numberFormat] == nil && customFormats[style.numberFormat] == nil {
            customFormats[style.numberFormat] = nextFormatID
            nextFormatID += 1
        }
        func formatID(_ code: String) -> Int { Self.builtinFormats[code] ?? customFormats[code] ?? 0 }

        // Fonts, fills and borders, deduplicated.
        struct FontKey: Hashable { var name: String; var size: Double; var bold, italic, underline, doubleUnderline, strike: Bool; var color: RGBColor? }
        var fonts: [FontKey] = []
        var fontIndex: [FontKey: Int] = [:]
        var fills: [RGBColor?] = [nil, nil]
        var fillIndex: [RGBColor: Int] = [:]
        var borders: [CellBorders] = [CellBorders()]
        var borderIndex: [CellBorders: Int] = [CellBorders(): 0]
        func font(_ s: CellStyle) -> Int {
            let key = FontKey(name: s.effectiveFontName, size: s.effectiveFontSize, bold: s.bold, italic: s.italic, underline: s.underline, doubleUnderline: s.doubleUnderline, strike: s.strikethrough, color: s.textColor)
            if let i = fontIndex[key] { return i }
            fontIndex[key] = fonts.count
            fonts.append(key)
            return fonts.count - 1
        }
        func fill(_ s: CellStyle) -> Int {
            guard let color = s.fillColor else { return 0 }
            if let i = fillIndex[color] { return i }
            fillIndex[color] = fills.count
            fills.append(color)
            return fills.count - 1
        }
        func border(_ s: CellStyle) -> Int {
            if let i = borderIndex[s.borders] { return i }
            borderIndex[s.borders] = borders.count
            borders.append(s.borders)
            return borders.count - 1
        }
        var xfRecords: [String] = []
        for style in xfs {
            let f = font(style), fl = fill(style), b = border(style), n = formatID(style.numberFormat)
            var record = "<xf numFmtId=\"\(n)\" fontId=\"\(f)\" fillId=\"\(fl)\" borderId=\"\(b)\" xfId=\"0\""
            if n != 0 { record += " applyNumberFormat=\"1\"" }
            if f != 0 { record += " applyFont=\"1\"" }
            if fl != 0 { record += " applyFill=\"1\"" }
            if b != 0 { record += " applyBorder=\"1\"" }
            var alignment = ""
            if style.horizontal != .general {
                let h: String
                switch style.horizontal {
                case .general: h = "general"
                case .left: h = "left"
                case .center: h = "center"
                case .right: h = "right"
                case .fill: h = "fill"
                case .justify: h = "justify"
                case .centerAcross: h = "centerContinuous"
                }
                alignment += " horizontal=\"\(h)\""
            }
            if style.vertical != .bottom { alignment += " vertical=\"\(style.vertical == .top ? "top" : "center")\"" }
            if style.wrap { alignment += " wrapText=\"1\"" }
            if style.shrinkToFit { alignment += " shrinkToFit=\"1\"" }
            if style.indent > 0 { alignment += " indent=\"\(style.indent)\"" }
            if style.rotation != 0 { alignment += " textRotation=\"\(style.rotation > 0 ? style.rotation : 90 - style.rotation)\"" }
            if alignment.isEmpty {
                record += "/>"
            } else {
                record += " applyAlignment=\"1\"><alignment\(alignment)/></xf>"
            }
            xfRecords.append(record)
        }

        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
        if !customFormats.isEmpty {
            xml += "<numFmts count=\"\(customFormats.count)\">"
            for (code, id) in customFormats.sorted(by: { $0.value < $1.value }) {
                xml += "<numFmt numFmtId=\"\(id)\" formatCode=\"\(XLSXWriter.escape(code))\"/>"
            }
            xml += "</numFmts>"
        }
        xml += "<fonts count=\"\(fonts.count)\">"
        for f in fonts {
            xml += "<font>"
            if f.bold { xml += "<b/>" }
            if f.italic { xml += "<i/>" }
            if f.strike { xml += "<strike/>" }
            if f.underline { xml += "<u/>" }
            if f.doubleUnderline { xml += "<u val=\"double\"/>" }
            xml += "<sz val=\"\(XLSXWriter.number(f.size))\"/>"
            xml += f.color.map { "<color rgb=\"\($0.argb)\"/>" } ?? "<color theme=\"1\"/>"
            xml += "<name val=\"\(XLSXWriter.escape(f.name))\"/><family val=\"2\"/></font>"
        }
        xml += "</fonts>"
        xml += "<fills count=\"\(fills.count)\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill>"
        for color in fills.dropFirst(2) {
            xml += "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"\(color!.argb)\"/><bgColor indexed=\"64\"/></patternFill></fill>"
        }
        xml += "</fills>"
        xml += "<borders count=\"\(borders.count)\">"
        for b in borders {
            func edge(_ name: String, _ line: BorderLine?) -> String {
                guard let line else { return "<\(name)/>" }
                let style: String
                switch line.style {
                case .thin: style = "thin"
                case .medium: style = "medium"
                case .thick: style = "thick"
                case .dashed: style = "dashed"
                case .dotted: style = "dotted"
                case .double: style = "double"
                case .hair: style = "hair"
                }
                return "<\(name) style=\"\(style)\"><color rgb=\"\(line.color.argb)\"/></\(name)>"
            }
            xml += "<border>" + edge("left", b.left) + edge("right", b.right) + edge("top", b.top) + edge("bottom", b.bottom) + "<diagonal/></border>"
        }
        xml += "</borders>"
        xml += "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
        xml += "<cellXfs count=\"\(xfRecords.count)\">" + xfRecords.joined() + "</cellXfs>"
        xml += "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>"
        xml += "<dxfs count=\"\(dxfs.count)\">"
        for d in dxfs {
            xml += "<dxf>"
            if d.bold || d.italic || d.text != nil {
                xml += "<font>" + (d.bold ? "<b/>" : "") + (d.italic ? "<i/>" : "") + (d.text.map { "<color rgb=\"\($0.argb)\"/>" } ?? "") + "</font>"
            }
            if let fill = d.fill { xml += "<fill><patternFill><bgColor rgb=\"\(fill.argb)\"/></patternFill></fill>" }
            if let border = d.border {
                let e = { (n: String) in "<\(n) style=\"thin\"><color rgb=\"\(border.argb)\"/></\(n)>" }
                xml += "<border>" + e("left") + e("right") + e("top") + e("bottom") + "</border>"
            }
            xml += "</dxf>"
        }
        xml += "</dxfs><tableStyles count=\"0\"/></styleSheet>"
        return xml
    }
}
