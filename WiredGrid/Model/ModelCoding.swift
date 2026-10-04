import Foundation

// Sparse dictionaries keyed by addresses are stored as compact arrays, and every
// field decodes tolerantly so files move safely between app versions.

private struct StoredCell: Codable {
    var r: Int
    var c: Int
    var v: CellValue?
    var f: String?
    var s: Int?
    var l: String?
}

private struct StoredNote: Codable {
    var r: Int
    var c: Int
    var text: String
}

extension Sheet: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, cells, styles, columnWidths, rowHeights, hiddenColumns, hiddenRows, columnStyles, rowStyles
        case merges, frozenRows, frozenColumns, notes, conditionalFormats, charts, filter, tables
        case tabColor, showGridlines, showHeadings, zoom, pageSetup
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decodeIfPresent(String.self, forKey: .name) ?? "Sheet")
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let styles = try c.decodeIfPresent([CellStyle].self, forKey: .styles) ?? []
        for stored in try c.decodeIfPresent([StoredCell].self, forKey: .cells) ?? [] {
            let style = stored.s.flatMap { styles.indices.contains($0) ? styles[$0] : nil }
            let cell = Cell(value: stored.v ?? .empty, formula: stored.f, style: style, link: stored.l)
            let address = CellAddress(row: stored.r, column: stored.c)
            if address.isValid { self[address] = cell }
        }
        columnWidths = Self.intKeyed(try c.decodeIfPresent([String: Double].self, forKey: .columnWidths))
        rowHeights = Self.intKeyed(try c.decodeIfPresent([String: Double].self, forKey: .rowHeights))
        hiddenColumns = try c.decodeIfPresent(Set<Int>.self, forKey: .hiddenColumns) ?? []
        hiddenRows = try c.decodeIfPresent(Set<Int>.self, forKey: .hiddenRows) ?? []
        columnStyles = Self.intKeyed(try c.decodeIfPresent([String: CellStyle].self, forKey: .columnStyles))
        rowStyles = Self.intKeyed(try c.decodeIfPresent([String: CellStyle].self, forKey: .rowStyles))
        merges = try c.decodeIfPresent([CellRange].self, forKey: .merges) ?? []
        frozenRows = try c.decodeIfPresent(Int.self, forKey: .frozenRows) ?? 0
        frozenColumns = try c.decodeIfPresent(Int.self, forKey: .frozenColumns) ?? 0
        for note in try c.decodeIfPresent([StoredNote].self, forKey: .notes) ?? [] {
            notes[CellAddress(row: note.r, column: note.c)] = note.text
        }
        conditionalFormats = (try? c.decodeIfPresent([ConditionalFormat].self, forKey: .conditionalFormats)) ?? []
        charts = (try? c.decodeIfPresent([ChartObject].self, forKey: .charts)) ?? []
        filter = try? c.decodeIfPresent(AutoFilter.self, forKey: .filter)
        tables = (try? c.decodeIfPresent([TableObject].self, forKey: .tables)) ?? []
        tabColor = try c.decodeIfPresent(RGBColor.self, forKey: .tabColor)
        showGridlines = try c.decodeIfPresent(Bool.self, forKey: .showGridlines) ?? true
        showHeadings = try c.decodeIfPresent(Bool.self, forKey: .showHeadings) ?? true
        zoom = try c.decodeIfPresent(Double.self, forKey: .zoom) ?? 1
        pageSetup = (try? c.decodeIfPresent(PageSetup.self, forKey: .pageSetup)) ?? PageSetup()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)

        // Styles are pooled: each distinct style is written once.
        var styles: [CellStyle] = []
        var styleIndex: [CellStyle: Int] = [:]
        var stored: [StoredCell] = []
        stored.reserveCapacity(cells.count)
        for (address, cell) in cells.sorted(by: { $0.key < $1.key }) {
            var index: Int?
            if let style = cell.style {
                if let existing = styleIndex[style] {
                    index = existing
                } else {
                    index = styles.count
                    styleIndex[style] = styles.count
                    styles.append(style)
                }
            }
            stored.append(StoredCell(r: address.row, c: address.column, v: cell.value.isEmpty ? nil : cell.value, f: cell.formula, s: index, l: cell.link))
        }
        try c.encode(stored, forKey: .cells)
        if !styles.isEmpty { try c.encode(styles, forKey: .styles) }
        if !columnWidths.isEmpty { try c.encode(Self.stringKeyed(columnWidths), forKey: .columnWidths) }
        if !rowHeights.isEmpty { try c.encode(Self.stringKeyed(rowHeights), forKey: .rowHeights) }
        if !hiddenColumns.isEmpty { try c.encode(hiddenColumns.sorted(), forKey: .hiddenColumns) }
        if !hiddenRows.isEmpty { try c.encode(hiddenRows.sorted(), forKey: .hiddenRows) }
        if !columnStyles.isEmpty { try c.encode(Self.stringKeyed(columnStyles), forKey: .columnStyles) }
        if !rowStyles.isEmpty { try c.encode(Self.stringKeyed(rowStyles), forKey: .rowStyles) }
        if !merges.isEmpty { try c.encode(merges, forKey: .merges) }
        if frozenRows > 0 { try c.encode(frozenRows, forKey: .frozenRows) }
        if frozenColumns > 0 { try c.encode(frozenColumns, forKey: .frozenColumns) }
        if !notes.isEmpty {
            try c.encode(notes.sorted { $0.key < $1.key }.map { StoredNote(r: $0.key.row, c: $0.key.column, text: $0.value) }, forKey: .notes)
        }
        if !conditionalFormats.isEmpty { try c.encode(conditionalFormats, forKey: .conditionalFormats) }
        if !charts.isEmpty { try c.encode(charts, forKey: .charts) }
        try c.encodeIfPresent(filter, forKey: .filter)
        if !tables.isEmpty { try c.encode(tables, forKey: .tables) }
        try c.encodeIfPresent(tabColor, forKey: .tabColor)
        if !showGridlines { try c.encode(showGridlines, forKey: .showGridlines) }
        if !showHeadings { try c.encode(showHeadings, forKey: .showHeadings) }
        if zoom != 1 { try c.encode(zoom, forKey: .zoom) }
        if pageSetup != PageSetup() { try c.encode(pageSetup, forKey: .pageSetup) }
    }

    private static func intKeyed<T>(_ dictionary: [String: T]?) -> [Int: T] {
        var result: [Int: T] = [:]
        for (key, value) in dictionary ?? [:] {
            if let index = Int(key) { result[index] = value }
        }
        return result
    }

    private static func stringKeyed<T>(_ dictionary: [Int: T]) -> [String: T] {
        Dictionary(uniqueKeysWithValues: dictionary.map { (String($0.key), $0.value) })
    }
}

extension Workbook: Codable {
    private enum CodingKeys: String, CodingKey {
        case formatVersion, sheets, activeSheetIndex, names, author, created
    }

    static let formatVersion = 1

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var sheets = try c.decodeIfPresent([Sheet].self, forKey: .sheets) ?? []
        if sheets.isEmpty { sheets = [Sheet(name: "Sheet1")] }
        self.init(sheets: sheets)
        activeSheetIndex = min(max(try c.decodeIfPresent(Int.self, forKey: .activeSheetIndex) ?? 0, 0), sheets.count - 1)
        names = (try? c.decodeIfPresent([DefinedName].self, forKey: .names)) ?? []
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.formatVersion, forKey: .formatVersion)
        try c.encode(sheets, forKey: .sheets)
        try c.encode(activeSheetIndex, forKey: .activeSheetIndex)
        if !names.isEmpty { try c.encode(names, forKey: .names) }
        if !author.isEmpty { try c.encode(author, forKey: .author) }
        try c.encode(created, forKey: .created)
    }
}
