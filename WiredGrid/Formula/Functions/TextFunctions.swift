import Foundation

extension FunctionLibrary {
    func registerText() {
        let v = FunctionLibrary.variadic

        let joinAll: (FunctionCall, Range<Int>) throws -> [String] = { c, indices in
            var parts: [String] = []
            for i in indices where !c.isMissing(i) {
                for value in try c.flat(i) {
                    if case .error(let e) = value { throw e }
                    parts.append(try value.asText())
                }
            }
            return parts
        }
        register("CONCATENATE", .text, "CONCATENATE(text1, [text2], …)", "Joins several text strings into one.", args: 1...v) { c in
            var result = ""
            for i in 0..<c.count { result += try c.text(i, default: "") }
            return .string(result)
        }
        register("CONCAT", .text, "CONCAT(text1, [text2], …)", "Joins text from multiple ranges and strings.", args: 1...v) { c in
            .string(try joinAll(c, 0..<c.count).joined())
        }
        register("TEXTJOIN", .text, "TEXTJOIN(delimiter, ignore_empty, text1, …)", "Joins text with a delimiter between each value.", args: 3...v) { c in
            let delimiter = try c.text(0)
            let ignoreEmpty = try c.bool(1)
            var parts = try joinAll(c, 2..<c.count)
            if ignoreEmpty { parts = parts.filter { !$0.isEmpty } }
            return .string(parts.joined(separator: delimiter))
        }
        register("LEFT", .text, "LEFT(text, [num_chars])", "Returns the leftmost characters of a text value.", args: 1...2) { c in
            let n = try c.int(1, default: 1)
            guard n >= 0 else { throw FormulaError.value }
            return try c.liftText { .string(String($0.prefix(n))) }
        }
        register("RIGHT", .text, "RIGHT(text, [num_chars])", "Returns the rightmost characters of a text value.", args: 1...2) { c in
            let n = try c.int(1, default: 1)
            guard n >= 0 else { throw FormulaError.value }
            return try c.liftText { .string(String($0.suffix(n))) }
        }
        register("MID", .text, "MID(text, start_num, num_chars)", "Returns characters from the middle of a text string.", args: 3...3) { c in
            let start = try c.int(1), length = try c.int(2)
            guard start >= 1, length >= 0 else { throw FormulaError.value }
            return try c.liftText { s in
                let chars = Array(s)
                guard start - 1 < chars.count else { return .string("") }
                return .string(String(chars[(start - 1)..<min(chars.count, start - 1 + length)]))
            }
        }
        register("LEN", .text, "LEN(text)", "Returns the number of characters in a text string.", args: 1...1) { c in
            try c.liftText { .number(Double($0.count)) }
        }
        register("LOWER", .text, "LOWER(text)", "Converts text to lowercase.", args: 1...1) { c in
            try c.liftText { .string($0.lowercased()) }
        }
        register("UPPER", .text, "UPPER(text)", "Converts text to uppercase.", args: 1...1) { c in
            try c.liftText { .string($0.uppercased()) }
        }
        register("PROPER", .text, "PROPER(text)", "Capitalizes the first letter of each word.", args: 1...1) { c in
            try c.liftText { s in
                var result = ""
                var previousIsLetter = false
                for ch in s {
                    result += previousIsLetter ? ch.lowercased() : ch.uppercased()
                    previousIsLetter = ch.isLetter
                }
                return .string(result)
            }
        }
        register("TRIM", .text, "TRIM(text)", "Removes extra spaces from text.", args: 1...1) { c in
            try c.liftText { .string($0.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")) }
        }
        register("CLEAN", .text, "CLEAN(text)", "Removes nonprintable characters from text.", args: 1...1) { c in
            try c.liftText { .string(String($0.unicodeScalars.filter { $0.value >= 32 }.map(Character.init))) }
        }
        register("SUBSTITUTE", .text, "SUBSTITUTE(text, old_text, new_text, [instance_num])", "Substitutes new text for old text.", args: 3...4) { c in
            let old = try c.text(1), new = try c.text(2)
            let instance = c.isMissing(3) ? nil : try c.int(3)
            if let instance, instance < 1 { throw FormulaError.value }
            return try c.liftText { s in
                guard !old.isEmpty else { return .string(s) }
                guard let instance else { return .string(s.replacingOccurrences(of: old, with: new)) }
                var count = 0
                var searchStart = s.startIndex
                while let found = s.range(of: old, range: searchStart..<s.endIndex) {
                    count += 1
                    if count == instance { return .string(s.replacingCharacters(in: found, with: new)) }
                    searchStart = found.upperBound
                }
                return .string(s)
            }
        }
        register("REPLACE", .text, "REPLACE(old_text, start_num, num_chars, new_text)", "Replaces characters within text.", args: 4...4) { c in
            var chars = Array(try c.text(0))
            let start = try c.int(1), length = try c.int(2)
            let new = try c.text(3)
            guard start >= 1, length >= 0 else { throw FormulaError.value }
            let from = min(start - 1, chars.count), to = min(from + length, chars.count)
            chars.replaceSubrange(from..<to, with: Array(new))
            return .string(String(chars))
        }
        let finder: (Bool) -> (FunctionCall) throws -> FValue = { caseInsensitive in
            { c in
                let needle = try c.text(0)
                let start = try c.int(2, default: 1)
                return try c.liftText(1) { haystack in
                    let chars = Array(haystack)
                    guard start >= 1, start <= chars.count + 1 else { throw FormulaError.value }
                    let tail = String(chars[(start - 1)...])
                    if needle.isEmpty { return .number(Double(start)) }
                    let found: Range<String.Index>?
                    if caseInsensitive {
                        if needle.contains(where: { $0 == "*" || $0 == "?" }), let regex = Criterion.wildcard(needle) {
                            let pattern = String(regex.pattern.dropFirst().dropLast())
                            found = tail.range(of: pattern, options: [.regularExpression, .caseInsensitive])
                        } else {
                            found = tail.range(of: needle, options: .caseInsensitive)
                        }
                    } else {
                        found = tail.range(of: needle)
                    }
                    guard let found else { throw FormulaError.value }
                    return .number(Double(tail.distance(from: tail.startIndex, to: found.lowerBound) + start))
                }
            }
        }
        register("FIND", .text, "FIND(find_text, within_text, [start_num])", "Finds one text value within another (case-sensitive).", args: 2...3, finder(false))
        register("SEARCH", .text, "SEARCH(find_text, within_text, [start_num])", "Finds one text value within another (not case-sensitive, wildcards allowed).", args: 2...3, finder(true))
        register("REPT", .text, "REPT(text, number_times)", "Repeats text a given number of times.", args: 2...2) { c in
            let n = try c.int(1)
            guard n >= 0, n < 32768 else { throw FormulaError.value }
            return try c.liftText { .string(String(repeating: $0, count: n)) }
        }
        register("TEXT", .text, "TEXT(value, format_text)", "Formats a number and converts it to text.", args: 2...2) { c in
            let code = try c.text(1)
            return try c.lift(0) { value in
                if case .error = value { return value }
                var v = value
                if case .string(let s) = value, let n = ValueParser.number(from: s) { v = .number(n) }
                return .string(NumberFormat.format(v, code).text)
            }
        }
        register("VALUE", .text, "VALUE(text)", "Converts a text argument to a number.", args: 1...1) { c in
            try c.lift(0) { value in
                switch value {
                case .number, .error: return value
                case .empty: return .number(0)
                case .bool: throw FormulaError.value
                case .string(let s):
                    guard let n = ValueParser.number(from: s.trimmingCharacters(in: .whitespaces)) else { throw FormulaError.value }
                    return .number(n)
                }
            }
        }
        register("NUMBERVALUE", .text, "NUMBERVALUE(text, [decimal_separator], [group_separator])", "Converts text to a number in a locale-independent way.", args: 1...3) { c in
            var s = try c.text(0).trimmingCharacters(in: .whitespaces)
            let decimal = try c.text(1, default: ".")
            let group = try c.text(2, default: ",")
            s = s.replacingOccurrences(of: group, with: "").replacingOccurrences(of: decimal, with: ".")
            var percent = 0
            while s.hasSuffix("%") { percent += 1; s.removeLast() }
            guard let n = Double(s) else { throw FormulaError.value }
            return numberResult(n / pow(100, Double(percent)))
        }
        register("EXACT", .text, "EXACT(text1, text2)", "Checks whether two text values are identical.", args: 2...2) { c in
            .bool(try c.text(0) == (try c.text(1)))
        }
        register("CHAR", .text, "CHAR(number)", "Returns the character specified by a code number.", args: 1...1) { c in
            let n = try c.int(0)
            guard (1...255).contains(n), let scalar = UnicodeScalar(n) else { throw FormulaError.value }
            return .string(String(Character(scalar)))
        }
        register("UNICHAR", .text, "UNICHAR(number)", "Returns the Unicode character for a number.", args: 1...1) { c in
            let n = try c.int(0)
            guard n > 0, let scalar = UnicodeScalar(n) else { throw FormulaError.value }
            return .string(String(Character(scalar)))
        }
        register("CODE", .text, "CODE(text)", "Returns a numeric code for the first character.", args: 1...1) { c in
            guard let scalar = try c.text(0).unicodeScalars.first else { throw FormulaError.value }
            return .number(Double(scalar.value))
        }
        register("UNICODE", .text, "UNICODE(text)", "Returns the Unicode code point of the first character.", args: 1...1) { c in
            guard let scalar = try c.text(0).unicodeScalars.first else { throw FormulaError.value }
            return .number(Double(scalar.value))
        }
        register("DOLLAR", .text, "DOLLAR(number, [decimals])", "Converts a number to text in currency format.", args: 1...2) { c in
            let decimals = try c.int(1, default: 2)
            let code = "$#,##0" + (decimals > 0 ? "." + String(repeating: "0", count: decimals) : "")
            return .string(NumberFormat.format(.number(excelRound(try c.number(0), decimals)), code + ";($" + code.dropFirst() + ")").text)
        }
        register("FIXED", .text, "FIXED(number, [decimals], [no_commas])", "Formats a number as text with a fixed number of decimals.", args: 1...3) { c in
            let decimals = try c.int(1, default: 2)
            let noCommas = try c.bool(2, default: false)
            let code = (noCommas ? "0" : "#,##0") + (decimals > 0 ? "." + String(repeating: "0", count: decimals) : "")
            return .string(NumberFormat.format(.number(excelRound(try c.number(0), decimals)), code).text)
        }
        register("T", .text, "T(value)", "Returns the text if the value is text, otherwise empty text.", args: 1...1) { c in
            if case .string(let s) = try c.scalar(0) { return .string(s) }
            return .string("")
        }
        register("TEXTBEFORE", .text, "TEXTBEFORE(text, delimiter, [instance_num])", "Returns text that occurs before a delimiter.", args: 2...3) { c in
            let text = try c.text(0), delimiter = try c.text(1), instance = try c.int(2, default: 1)
            let parts = text.components(separatedBy: delimiter)
            guard instance != 0, abs(instance) < parts.count else { throw FormulaError.na }
            let count = instance > 0 ? instance : parts.count + instance
            return .string(parts.prefix(count).joined(separator: delimiter))
        }
        register("TEXTAFTER", .text, "TEXTAFTER(text, delimiter, [instance_num])", "Returns text that occurs after a delimiter.", args: 2...3) { c in
            let text = try c.text(0), delimiter = try c.text(1), instance = try c.int(2, default: 1)
            let parts = text.components(separatedBy: delimiter)
            guard instance != 0, abs(instance) < parts.count else { throw FormulaError.na }
            let count = instance > 0 ? instance : parts.count + instance
            return .string(parts.dropFirst(count).joined(separator: delimiter))
        }
        register("TEXTSPLIT", .text, "TEXTSPLIT(text, col_delimiter, [row_delimiter])", "Splits text into rows or columns using delimiters.", args: 2...3) { c in
            let text = try c.text(0), columnDelimiter = try c.text(1)
            let rowDelimiter = c.isMissing(2) ? nil : try c.text(2)
            let rows = rowDelimiter.map { text.components(separatedBy: $0) } ?? [text]
            let grid = rows.map { row in (columnDelimiter.isEmpty ? [row] : row.components(separatedBy: columnDelimiter)).map { CellValue.string($0) } }
            var m = Matrix(grid)
            for i in m.values.indices where m.values[i].isEmpty { m.values[i] = .error(.na) }
            return .matrix(m)
        }
        register("HYPERLINK", .text, "HYPERLINK(link_location, [friendly_name])", "Creates a link to a web page or file.", args: 1...2) { c in
            c.isMissing(1) ? .string(try c.text(0)) : try c.value(1)
        }
    }
}
