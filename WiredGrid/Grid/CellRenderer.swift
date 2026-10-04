import AppKit

/// Everything needed to draw one cell's contents.
struct CellAppearance {
    var text: String
    var font: NSFont
    var color: NSColor
    var fill: NSColor?
    var horizontal: HorizontalAlignment
    var vertical: VerticalAlignment
    var wrap: Bool
    var underline: Bool
    var doubleUnderline: Bool
    var strikethrough: Bool
    var indent: CGFloat
    var rotation: Int
    var isNumber: Bool
    var isGeneral: Bool
    var fillSplit: (left: String, right: String)?
    var fillCharacter: Character
    var dataBar: (Double, RGBColor)?
    var icon: (ConditionalFormat.IconSet, Int)?
    var cfBorder: RGBColor?
}

/// Draws cell text with Excel's alignment, overflow, wrapping and "###" rules.
enum CellRenderer {
    static let padding: CGFloat = 3

    static func attributes(_ a: CellAppearance, alignment: NSTextAlignment = .left, wrap: Bool = false) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [.font: a.font, .foregroundColor: a.color]
        if a.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if a.doubleUnderline { attrs[.underlineStyle] = NSUnderlineStyle.double.rawValue }
        if a.strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if wrap {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            paragraph.lineBreakMode = .byWordWrapping
            attrs[.paragraphStyle] = paragraph
        }
        return attrs
    }

    static func effectiveAlignment(_ a: CellAppearance, value: CellValue) -> HorizontalAlignment {
        guard a.horizontal == .general else { return a.horizontal }
        switch value {
        case .number: return a.rotation == 0 ? .right : .left
        case .bool, .error: return .center
        default: return .left
        }
    }

    /// The horizontal space text needs beyond the cell, for overflow into empty neighbours.
    static func textWidth(_ a: CellAppearance) -> CGFloat {
        ceil((a.text as NSString).size(withAttributes: attributes(a)).width)
    }

    /// Draws the text of a cell in `rect`. `clip` is the area text may occupy (wider when overflowing).
    static func draw(_ a: CellAppearance, value: CellValue, in rect: CGRect, clip: CGRect, zoom: CGFloat) {
        guard !a.text.isEmpty || a.icon != nil else { return }
        let pad = padding * zoom
        var inner = rect.insetBy(dx: pad, dy: 0)
        let alignment = effectiveAlignment(a, value: value)

        if let icon = a.icon {
            let size = min(rect.height - 4 * zoom, 14 * zoom)
            let iconRect = CGRect(x: rect.minX + pad, y: rect.midY - size / 2, width: size, height: size)
            drawIcon(icon.0, level: icon.1, in: iconRect)
            inner.origin.x += size + 3 * zoom
            inner.size.width -= size + 3 * zoom
        }
        if a.indent > 0 {
            if alignment == .right { inner.size.width -= a.indent } else { inner.origin.x += a.indent; inner.size.width -= a.indent }
        }
        guard inner.width > 1 else { return }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: clip.intersection(rect.union(clip))).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }

        if a.rotation != 0 {
            drawRotated(a, value: value, in: rect, zoom: zoom)
            return
        }

        if a.wrap && !a.isNumber {
            let paragraphAlignment: NSTextAlignment = alignment == .center ? .center : (alignment == .right ? .right : (alignment == .justify ? .justified : .left))
            let attrs = attributes(a, alignment: paragraphAlignment, wrap: true)
            let string = a.text as NSString
            let bounds = string.boundingRect(with: CGSize(width: inner.width, height: 100_000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs)
            var textRect = inner
            let height = min(ceil(bounds.height), rect.height)
            switch a.vertical {
            case .top: textRect.origin.y = rect.minY + 2 * zoom
            case .middle: textRect.origin.y = rect.midY - height / 2
            case .bottom: textRect.origin.y = rect.maxY - height - 2 * zoom
            }
            textRect.origin.y = max(textRect.origin.y, rect.minY)
            textRect.size.height = rect.maxY - textRect.minY
            string.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs)
            return
        }

        let attrs = attributes(a)
        var text = a.text
        // Multi-line text without wrap shows only the first line, like Excel.
        if let newline = text.firstIndex(where: { $0 == "\n" || $0 == "\r" }) { text = String(text[..<newline]) }
        var size = (text as NSString).size(withAttributes: attrs)

        // Numbers that don't fit become ### (or fewer General digits).
        if a.isNumber, size.width > inner.width + 0.5 {
            if case .number(let n) = value, a.fillSplit == nil {
                var shortened: String?
                if a.isGeneral {
                    var length = text.count - 1
                    while length >= 1 {
                        let candidate = NumberFormat.general(n, maxLength: length)
                        if (candidate as NSString).size(withAttributes: attrs).width <= inner.width {
                            shortened = candidate
                            break
                        }
                        length -= 1
                    }
                }
                if let shortened {
                    text = shortened
                } else {
                    let hashWidth = ("#" as NSString).size(withAttributes: attrs).width
                    text = String(repeating: "#", count: max(1, Int(inner.width / max(hashWidth, 1))))
                }
                size = (text as NSString).size(withAttributes: attrs)
            }
        }

        let lineHeight = a.font.ascender - a.font.descender
        var y: CGFloat
        switch a.vertical {
        case .top: y = rect.minY + 2 * zoom
        case .middle: y = rect.midY - lineHeight / 2
        case .bottom: y = rect.maxY - lineHeight - 3 * zoom
        }
        y = max(y, rect.minY + 0.5)

        // Accounting-style formats pin the currency symbol left and the number right.
        if let split = a.fillSplit, a.isNumber {
            (split.left as NSString).draw(at: CGPoint(x: inner.minX, y: y), withAttributes: attrs)
            let rightWidth = (split.right as NSString).size(withAttributes: attrs).width
            (split.right as NSString).draw(at: CGPoint(x: inner.maxX - rightWidth, y: y), withAttributes: attrs)
            return
        }

        var x: CGFloat
        switch alignment {
        case .right: x = inner.maxX - size.width
        case .center, .centerAcross: x = inner.midX - size.width / 2
        case .fill:
            // Repeat the text to fill the cell.
            let unit = max(size.width, 1)
            let count = max(1, Int(inner.width / unit))
            text = String(repeating: text, count: count)
            x = inner.minX
        default: x = inner.minX
        }
        (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
    }

    private static func drawRotated(_ a: CellAppearance, value: CellValue, in rect: CGRect, zoom: CGFloat) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let attrs = attributes(a)
        let size = (a.text as NSString).size(withAttributes: attrs)
        let angle = -CGFloat(a.rotation) * .pi / 180
        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: angle)
        (a.text as NSString).draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2), withAttributes: attrs)
        context.restoreGState()
    }

    // MARK: - Icons

    static func drawIcon(_ set: ConditionalFormat.IconSet, level: Int, in rect: CGRect) {
        let colors = [NSColor(srgbRed: 0.85, green: 0.22, blue: 0.2, alpha: 1), NSColor(srgbRed: 0.95, green: 0.72, blue: 0.1, alpha: 1), NSColor(srgbRed: 0.2, green: 0.65, blue: 0.3, alpha: 1)]
        let color = colors[max(0, min(2, level))]
        switch set {
        case .trafficLights:
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            NSColor.black.withAlphaComponent(0.2).setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).stroke()
        case .arrows:
            let path = NSBezierPath()
            let r = rect.insetBy(dx: 1.5, dy: 1.5)
            switch level {
            case 2:
                path.move(to: CGPoint(x: r.midX, y: r.minY)); path.line(to: CGPoint(x: r.maxX, y: r.midY)); path.line(to: CGPoint(x: r.midX + r.width * 0.18, y: r.midY))
                path.line(to: CGPoint(x: r.midX + r.width * 0.18, y: r.maxY)); path.line(to: CGPoint(x: r.midX - r.width * 0.18, y: r.maxY))
                path.line(to: CGPoint(x: r.midX - r.width * 0.18, y: r.midY)); path.line(to: CGPoint(x: r.minX, y: r.midY))
            case 0:
                path.move(to: CGPoint(x: r.midX, y: r.maxY)); path.line(to: CGPoint(x: r.maxX, y: r.midY)); path.line(to: CGPoint(x: r.midX + r.width * 0.18, y: r.midY))
                path.line(to: CGPoint(x: r.midX + r.width * 0.18, y: r.minY)); path.line(to: CGPoint(x: r.midX - r.width * 0.18, y: r.minY))
                path.line(to: CGPoint(x: r.midX - r.width * 0.18, y: r.midY)); path.line(to: CGPoint(x: r.minX, y: r.midY))
            default:
                path.move(to: CGPoint(x: r.maxX, y: r.midY)); path.line(to: CGPoint(x: r.midX, y: r.minY)); path.line(to: CGPoint(x: r.midX, y: r.midY - r.height * 0.18))
                path.line(to: CGPoint(x: r.minX, y: r.midY - r.height * 0.18)); path.line(to: CGPoint(x: r.minX, y: r.midY + r.height * 0.18))
                path.line(to: CGPoint(x: r.midX, y: r.midY + r.height * 0.18)); path.line(to: CGPoint(x: r.midX, y: r.maxY))
            }
            path.close()
            color.setFill()
            path.fill()
        case .flags:
            let r = rect.insetBy(dx: 2, dy: 1.5)
            NSColor.darkGray.setFill()
            NSBezierPath(rect: CGRect(x: r.minX, y: r.minY, width: 1.2, height: r.height)).fill()
            let flag = NSBezierPath()
            flag.move(to: CGPoint(x: r.minX + 1.2, y: r.minY))
            flag.line(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.28))
            flag.line(to: CGPoint(x: r.minX + 1.2, y: r.minY + r.height * 0.56))
            flag.close()
            color.setFill()
            flag.fill()
        case .stars:
            let r = rect.insetBy(dx: 1, dy: 1)
            let star = NSBezierPath()
            for i in 0..<10 {
                let angle = CGFloat(i) * .pi / 5 - .pi / 2
                let radius = i % 2 == 0 ? r.width / 2 : r.width / 4.5
                let point = CGPoint(x: r.midX + cos(angle) * radius, y: r.midY + sin(angle) * radius)
                if i == 0 { star.move(to: point) } else { star.line(to: point) }
            }
            star.close()
            let gold = NSColor(srgbRed: 0.98, green: 0.75, blue: 0.1, alpha: 1)
            if level == 2 {
                gold.setFill(); star.fill()
            } else if level == 1 {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: CGRect(x: r.minX, y: r.minY, width: r.width / 2, height: r.height)).addClip()
                gold.setFill(); star.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            gold.setStroke()
            star.lineWidth = 0.8
            star.stroke()
        }
    }
}
