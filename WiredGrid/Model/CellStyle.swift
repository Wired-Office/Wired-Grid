import AppKit

/// An sRGB color stored as "#RRGGBB" (or "#RRGGBBAA").
struct RGBColor: Hashable, Codable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var alpha: UInt8 = 255

    init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ hex: UInt32) {
        self.init(red: UInt8((hex >> 16) & 0xFF), green: UInt8((hex >> 8) & 0xFF), blue: UInt8(hex & 0xFF))
    }

    init?(hex text: String) {
        var digits = text.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard let value = UInt32(digits, radix: 16) else { return nil }
        switch digits.count {
        case 6: self.init(value)
        case 8: // Excel's ARGB
            self.init(red: UInt8((value >> 16) & 0xFF), green: UInt8((value >> 8) & 0xFF), blue: UInt8(value & 0xFF), alpha: 255)
        default: return nil
        }
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        self.init(
            red: UInt8((c.redComponent * 255).rounded().clamped(0, 255)),
            green: UInt8((c.greenComponent * 255).rounded().clamped(0, 255)),
            blue: UInt8((c.blueComponent * 255).rounded().clamped(0, 255)),
            alpha: UInt8((c.alphaComponent * 255).rounded().clamped(0, 255))
        )
    }

    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
    var argb: String { String(format: "FF%02X%02X%02X", red, green, blue) }

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: CGFloat(alpha) / 255)
    }

    var cgColor: CGColor { nsColor.cgColor }

    /// Relative luminance, used to pick legible text over fills.
    var luminance: Double {
        (0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)) / 255
    }

    func mixed(with other: RGBColor, _ t: Double) -> RGBColor {
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((Double(a) + (Double(b) - Double(a)) * t).rounded().clamped(0, 255)) }
        return RGBColor(red: mix(red, other.red), green: mix(green, other.green), blue: mix(blue, other.blue))
    }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        self = RGBColor(hex: text) ?? RGBColor(0)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    static let black = RGBColor(0x000000)
    static let white = RGBColor(0xFFFFFF)
}

extension Comparable {
    func clamped(_ low: Self, _ high: Self) -> Self { min(max(self, low), high) }
}

enum HorizontalAlignment: String, Codable, CaseIterable {
    case general, left, center, right, fill, justify, centerAcross
}

enum VerticalAlignment: String, Codable, CaseIterable {
    case top, middle, bottom
}

enum BorderLineStyle: String, Codable, CaseIterable {
    case thin, medium, thick, dashed, dotted, double, hair

    var width: CGFloat {
        switch self {
        case .hair: 0.5
        case .thin, .dashed, .dotted: 1
        case .medium: 2
        case .thick: 3
        case .double: 3
        }
    }
}

struct BorderLine: Hashable, Codable {
    var style: BorderLineStyle = .thin
    var color: RGBColor = .black
}

struct CellBorders: Hashable, Codable {
    var top: BorderLine?
    var left: BorderLine?
    var bottom: BorderLine?
    var right: BorderLine?

    var isEmpty: Bool { top == nil && left == nil && bottom == nil && right == nil }
}

/// Everything about how a cell looks. Defaults describe an unformatted cell.
struct CellStyle: Hashable {
    var fontName: String?
    var fontSize: Double?
    var bold = false
    var italic = false
    var underline = false
    var doubleUnderline = false
    var strikethrough = false
    var textColor: RGBColor?
    var fillColor: RGBColor?
    var horizontal: HorizontalAlignment = .general
    var vertical: VerticalAlignment = .bottom
    var wrap = false
    var shrinkToFit = false
    var indent = 0
    var rotation = 0
    var numberFormat = "General"
    var borders = CellBorders()
    var locked = true

    static let plain = CellStyle()
    static let defaultFontName = "Helvetica Neue"
    static let defaultFontSize: Double = 12

    var isPlain: Bool { self == .plain }

    var effectiveFontName: String { fontName ?? AppSettings.shared.defaultFontName }
    var effectiveFontSize: Double { fontSize ?? AppSettings.shared.defaultFontSize }

    func font(zoom: CGFloat = 1) -> NSFont {
        let size = CGFloat(effectiveFontSize) * zoom
        var font = NSFont(name: effectiveFontName, size: size) ?? NSFont.systemFont(ofSize: size)
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        if !traits.isEmpty {
            font = NSFontManager.shared.convert(font, toHaveTrait: traits)
            if bold && !NSFontManager.shared.traits(of: font).contains(.boldFontMask) {
                font = NSFont.boldSystemFont(ofSize: size)
            }
        }
        return font
    }
}

extension CellStyle: Codable {
    private enum CodingKeys: String, CodingKey {
        case fontName, fontSize, bold, italic, underline, doubleUnderline, strikethrough, textColor, fillColor
        case horizontal, vertical, wrap, shrinkToFit, indent, rotation, numberFormat, borders, locked
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName)
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize)
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        italic = try c.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        underline = try c.decodeIfPresent(Bool.self, forKey: .underline) ?? false
        doubleUnderline = try c.decodeIfPresent(Bool.self, forKey: .doubleUnderline) ?? false
        strikethrough = try c.decodeIfPresent(Bool.self, forKey: .strikethrough) ?? false
        textColor = try c.decodeIfPresent(RGBColor.self, forKey: .textColor)
        fillColor = try c.decodeIfPresent(RGBColor.self, forKey: .fillColor)
        horizontal = (try? c.decodeIfPresent(HorizontalAlignment.self, forKey: .horizontal)) ?? .general
        vertical = (try? c.decodeIfPresent(VerticalAlignment.self, forKey: .vertical)) ?? .bottom
        wrap = try c.decodeIfPresent(Bool.self, forKey: .wrap) ?? false
        shrinkToFit = try c.decodeIfPresent(Bool.self, forKey: .shrinkToFit) ?? false
        indent = try c.decodeIfPresent(Int.self, forKey: .indent) ?? 0
        rotation = try c.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
        numberFormat = try c.decodeIfPresent(String.self, forKey: .numberFormat) ?? "General"
        borders = (try? c.decodeIfPresent(CellBorders.self, forKey: .borders)) ?? CellBorders()
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let d = CellStyle.plain
        try c.encodeIfPresent(fontName, forKey: .fontName)
        try c.encodeIfPresent(fontSize, forKey: .fontSize)
        if bold != d.bold { try c.encode(bold, forKey: .bold) }
        if italic != d.italic { try c.encode(italic, forKey: .italic) }
        if underline != d.underline { try c.encode(underline, forKey: .underline) }
        if doubleUnderline != d.doubleUnderline { try c.encode(doubleUnderline, forKey: .doubleUnderline) }
        if strikethrough != d.strikethrough { try c.encode(strikethrough, forKey: .strikethrough) }
        try c.encodeIfPresent(textColor, forKey: .textColor)
        try c.encodeIfPresent(fillColor, forKey: .fillColor)
        if horizontal != d.horizontal { try c.encode(horizontal, forKey: .horizontal) }
        if vertical != d.vertical { try c.encode(vertical, forKey: .vertical) }
        if wrap != d.wrap { try c.encode(wrap, forKey: .wrap) }
        if shrinkToFit != d.shrinkToFit { try c.encode(shrinkToFit, forKey: .shrinkToFit) }
        if indent != d.indent { try c.encode(indent, forKey: .indent) }
        if rotation != d.rotation { try c.encode(rotation, forKey: .rotation) }
        if numberFormat != d.numberFormat { try c.encode(numberFormat, forKey: .numberFormat) }
        if !borders.isEmpty { try c.encode(borders, forKey: .borders) }
        if locked != d.locked { try c.encode(locked, forKey: .locked) }
    }
}
