import Foundation
import UniformTypeIdentifiers

enum GridError: LocalizedError {
    case corruptDocument(String)
    case unsupportedFormat(String)

    var errorDescription: String? {
        switch self {
        case .corruptDocument: "The document couldn't be opened."
        case .unsupportedFormat: "The file format isn't supported."
        }
    }

    var failureReason: String? {
        switch self {
        case .corruptDocument(let reason), .unsupportedFormat(let reason): reason
        }
    }
}

/// The file types Wired Grid reads and writes.
enum DocumentFormat: String, CaseIterable {
    case grid, xlsx, csv, tsv

    var typeIdentifier: String {
        switch self {
        case .grid: "com.wiredgrid.grid"
        case .xlsx: "org.openxmlformats.spreadsheetml.sheet"
        case .csv: "public.comma-separated-values-text"
        case .tsv: "public.tab-separated-values-text"
        }
    }

    var fileExtension: String { rawValue }

    var displayName: String {
        switch self {
        case .grid: "Grid Workbook"
        case .xlsx: "Excel Workbook"
        case .csv: "CSV (Comma-Separated)"
        case .tsv: "Tab-Separated Text"
        }
    }

    var shortName: String {
        switch self {
        case .grid: "Grid"
        case .xlsx: "Excel"
        case .csv: "CSV"
        case .tsv: "TSV"
        }
    }

    var isNative: Bool { self == .grid }

    /// Formats that keep only the active sheet's values.
    var isFlat: Bool { self == .csv || self == .tsv }

    static func from(typeName: String) -> DocumentFormat? {
        if let direct = allCases.first(where: { $0.typeIdentifier == typeName }) { return direct }
        guard let type = UTType(typeName) else { return nil }
        return allCases.first { format in
            guard let formatType = UTType(format.typeIdentifier) else { return false }
            return type.conforms(to: formatType)
        } ?? allCases.first { type.preferredFilenameExtension == $0.fileExtension }
    }

    func read(_ data: Data) throws -> Workbook {
        switch self {
        case .grid: return try NativeCodec.read(data)
        case .xlsx: return try XLSXReader.read(data)
        case .csv: return try DelimitedCodec.read(data, separator: ",")
        case .tsv: return try DelimitedCodec.read(data, separator: "\t")
        }
    }

    func write(_ workbook: Workbook, controller: WorkbookController?) throws -> Data {
        switch self {
        case .grid: return try NativeCodec.write(workbook)
        case .xlsx: return XLSXWriter.write(workbook)
        case .csv: return DelimitedCodec.write(workbook, separator: ",")
        case .tsv: return DelimitedCodec.write(workbook, separator: "\t")
        }
    }
}

/// `.grid` files: a ZIP holding a `mimetype` entry and `Workbook.json`.
enum NativeCodec {
    static let mimeType = "application/vnd.wiredgrid.grid"

    static func read(_ data: Data) throws -> Workbook {
        let entries: [String: Data]
        do {
            entries = try ZipArchive.read(data)
        } catch {
            // Plain JSON is accepted too.
            if let workbook = try? JSONDecoder.grid.decode(Workbook.self, from: data) { return workbook }
            throw GridError.corruptDocument("The file is not a valid Wired Grid workbook.")
        }
        if let mime = entries["mimetype"], String(decoding: mime, as: UTF8.self) != mimeType {
            throw GridError.corruptDocument("The file is not a Wired Grid workbook.")
        }
        guard let json = entries["Workbook.json"] else {
            throw GridError.corruptDocument("The workbook data is missing.")
        }
        do {
            return try JSONDecoder.grid.decode(Workbook.self, from: json)
        } catch {
            throw GridError.corruptDocument("The workbook data is damaged.")
        }
    }

    static func write(_ workbook: Workbook) throws -> Data {
        let json = try JSONEncoder.grid.encode(workbook)
        return ZipArchive.write([("mimetype", Data(mimeType.utf8)), ("Workbook.json", json)])
    }
}

extension JSONEncoder {
    static var grid: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }
}

extension JSONDecoder {
    static var grid: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }
}

/// CSV and TSV: one sheet of values.
enum DelimitedCodec {
    static func read(_ data: Data, separator: Character) throws -> Workbook {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) else {
            throw GridError.corruptDocument("The text encoding isn't supported.")
        }
        var content = text
        if content.hasPrefix("\u{FEFF}") { content.removeFirst() }
        let rows = WorkbookController.parseDelimited(content, separator: separator)
        var sheet = Sheet(name: "Sheet1")
        for (r, row) in rows.enumerated() where r < SheetLimits.rows {
            for (c, field) in row.enumerated() where c < SheetLimits.columns && !field.isEmpty {
                let address = CellAddress(row: r, column: c)
                if field.hasPrefix("="), field.count > 1, let formula = try? WorkbookController.normalizeFormula(String(field.dropFirst())) {
                    sheet[address] = Cell(formula: formula)
                    continue
                }
                let parsed = ValueParser.parse(field)
                var cell = Cell(value: parsed.value)
                if let format = parsed.format {
                    var style = CellStyle()
                    style.numberFormat = format
                    cell.style = style
                }
                sheet[address] = cell
            }
        }
        // Widen columns to fit their content, roughly.
        if let used = sheet.usedRange, used.columnCount < 200 {
            for column in used.columns {
                var widest = 0
                for row in used.rows.prefix(500) {
                    let text = sheet.cells[CellAddress(row: row, column: column)]?.value.plainText ?? ""
                    widest = max(widest, text.count)
                }
                let width = Double(min(max(widest, 4), 60)) * 7.5 + 12
                if width > Sheet.defaultColumnWidth { sheet.columnWidths[column] = width }
            }
        }
        return Workbook(sheets: [sheet])
    }

    static func write(_ workbook: Workbook, separator: Character) -> Data {
        let calculator = Calculator(workbook: workbook)
        calculator.recalculate()
        let index = workbook.activeSheetIndex
        let sheet = workbook.sheets[index]
        guard let used = sheet.usedRange else { return Data() }
        var lines: [String] = []
        for row in 0...used.maxRow {
            var fields: [String] = []
            for column in 0...used.maxColumn {
                let address = CellAddress(row: row, column: column)
                let value = calculator.value(sheet: index, at: address)
                var text = NumberFormat.format(value, sheet.style(at: address).numberFormat).text
                if case .number(let n) = value, sheet.style(at: address).numberFormat == NumberFormat.generalCode {
                    text = NumberFormat.general(n, maxLength: 17)
                }
                if text.contains(separator) || text.contains("\"") || text.contains("\n") || text.contains("\r") {
                    text = "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                fields.append(text)
            }
            // Trim trailing empty fields per line? Keep the grid rectangular like Excel.
            lines.append(fields.joined(separator: String(separator)))
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }
}
