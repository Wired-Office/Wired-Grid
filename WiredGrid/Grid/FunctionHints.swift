import AppKit

/// What the formula under the caret calls for: a list of function names or an argument hint.
enum FormulaContext {
    case suggestions(prefix: String, range: NSRange, items: [FunctionSpec])
    case signature(FunctionSpec, argument: Int)
    case none

    /// Analyzes formula text up to the caret.
    static func analyze(_ text: String, caret: Int) -> FormulaContext {
        guard text.hasPrefix("=") else { return .none }
        let units = Array(text.utf16)
        let end = min(caret, units.count)

        // An identifier being typed right before the caret.
        var start = end
        while start > 1, let scalar = UnicodeScalar(units[start - 1]),
              CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) || scalar == "." || scalar == "_" {
            start -= 1
        }
        if start < end {
            let prefix = String(decoding: units[start..<end], as: UTF16.self)
            let before = start > 0 ? UnicodeScalar(units[start - 1]).map(Character.init) : nil
            let afterIsParen = end < units.count && units[end] == 40
            if let first = prefix.first, first.isLetter, !afterIsParen,
               before.map({ "=(,;+-*/^&<> :".contains($0) }) ?? false, !insideString(units, upTo: start) {
                let items = FunctionLibrary.shared.completions(for: prefix).prefix(12)
                if !items.isEmpty, !(items.count == 1 && items.first!.name == prefix.uppercased() && false) {
                    return .suggestions(prefix: prefix, range: NSRange(location: start, length: end - start), items: Array(items))
                }
            }
        }

        // The innermost function call around the caret.
        var stack: [(String?, Int)] = []
        var i = 1
        var inString = false
        while i < end {
            let u = units[i]
            if u == 34 { inString.toggle() }
            if !inString {
                if u == 40 {
                    var j = i
                    while j > 1, let scalar = UnicodeScalar(units[j - 1]), CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) || scalar == "." || scalar == "_" { j -= 1 }
                    let name = j < i ? String(decoding: units[j..<i], as: UTF16.self).uppercased() : nil
                    stack.append((name, 0))
                } else if u == 41 {
                    if !stack.isEmpty { stack.removeLast() }
                } else if u == 44 || u == 59 {
                    if !stack.isEmpty { stack[stack.count - 1].1 += 1 }
                }
            }
            i += 1
        }
        if let (name, argument) = stack.last(where: { $0.0 != nil }), let name, let spec = FunctionLibrary.shared.function(named: name) {
            return .signature(spec, argument: argument)
        }
        return .none
    }

    private static func insideString(_ units: [UInt16], upTo index: Int) -> Bool {
        units[..<index].filter { $0 == 34 }.count % 2 == 1
    }
}

/// A small floating panel under the cell editor showing function suggestions or argument help.
final class FunctionHintController {
    private let panel: NSPanel
    private let content = HintContentView()
    private(set) var items: [FunctionSpec] = []
    private(set) var selectedIndex = 0
    private(set) var replaceRange = NSRange(location: 0, length: 0)
    var onAccept: ((FunctionSpec, NSRange) -> Void)?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 40), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = true
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8
        effect.layer?.masksToBounds = true
        panel.contentView = effect
        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        content.onClick = { [weak self] index in
            guard let self, self.items.indices.contains(index) else { return }
            self.onAccept?(self.items[index], self.replaceRange)
        }
    }

    var isShowingList: Bool { panel.isVisible && !items.isEmpty }

    func update(_ context: FormulaContext, below anchor: NSRect, in window: NSWindow?) {
        guard AppSettings.shared.functionHints, let window else { hide(); return }
        switch context {
        case .none:
            hide()
            return
        case .suggestions(_, let range, let list):
            if items.map(\.name) != list.map(\.name) { selectedIndex = 0 }
            items = list
            replaceRange = range
            content.mode = .list(list, selected: selectedIndex)
        case .signature(let spec, let argument):
            items = []
            content.mode = .signature(spec, argument: argument)
        }
        let size = content.fittingSize
        let screenAnchor = window.convertToScreen(anchor)
        var origin = CGPoint(x: screenAnchor.minX, y: screenAnchor.minY - size.height - 4)
        if let screen = window.screen, origin.y < screen.visibleFrame.minY { origin.y = screenAnchor.maxY + 4 }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + items.count) % items.count
        content.mode = .list(items, selected: selectedIndex)
    }

    var selectedItem: FunctionSpec? { items.indices.contains(selectedIndex) ? items[selectedIndex] : nil }

    func hide() {
        items = []
        if let parent = panel.parent { parent.removeChildWindow(panel) }
        panel.orderOut(nil)
    }
}

private final class HintContentView: NSView {
    enum Mode {
        case list([FunctionSpec], selected: Int)
        case signature(FunctionSpec, argument: Int)
        case empty
    }

    var mode: Mode = .empty { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var onClick: ((Int) -> Void)?
    private let rowHeight: CGFloat = 22

    override var isFlipped: Bool { true }

    override var fittingSize: NSSize { intrinsicContentSize }

    override var intrinsicContentSize: NSSize {
        switch mode {
        case .list(let items, _):
            let width = max(260, items.map { ($0.name as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)]).width }.max() ?? 0 + 40)
            return NSSize(width: min(width + 20, 420), height: CGFloat(items.count) * rowHeight + 36 + 8)
        case .signature(let spec, _):
            let signature = signatureString(spec, argument: -1)
            let width = min(max(signature.size().width + 24, 200), 520)
            let summary = NSAttributedString(string: spec.summary, attributes: [.font: NSFont.systemFont(ofSize: 11)])
            let height = summary.boundingRect(with: NSSize(width: width - 24, height: 200), options: [.usesLineFragmentOrigin]).height
            return NSSize(width: width, height: 30 + ceil(height) + 8)
        case .empty:
            return NSSize(width: 10, height: 10)
        }
    }

    private func signatureString(_ spec: FunctionSpec, argument: Int) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.labelColor]
        let bold: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold), .foregroundColor: Theme.accent]
        result.append(NSAttributedString(string: spec.name + "(", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor]))
        let parameters = spec.parameters
        for (i, parameter) in parameters.enumerated() {
            if i > 0 { result.append(NSAttributedString(string: ", ", attributes: base)) }
            // Repeating parameters ("…") highlight for every later argument.
            let isCurrent = i == argument || (i == parameters.count - 1 && parameter.contains("…") && argument >= i) || (parameter.contains("…") && argument > i && i == parameters.count - 1)
            result.append(NSAttributedString(string: parameter, attributes: isCurrent ? bold : base))
        }
        result.append(NSAttributedString(string: ")", attributes: base))
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        switch mode {
        case .list(let items, let selected):
            let header: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]
            ("FUNCTIONS  ·  Tab to insert" as NSString).draw(at: CGPoint(x: 12, y: 6), withAttributes: header)
            for (i, item) in items.enumerated() {
                let rect = CGRect(x: 4, y: 24 + CGFloat(i) * rowHeight, width: bounds.width - 8, height: rowHeight)
                if i == selected {
                    Theme.accent.withAlphaComponent(0.85).setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
                }
                let nameAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: i == selected ? NSColor.white : NSColor.labelColor]
                (item.name as NSString).draw(at: CGPoint(x: rect.minX + 8, y: rect.minY + 3), withAttributes: nameAttrs)
                let nameWidth = (item.name as NSString).size(withAttributes: nameAttrs).width
                let summaryAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: i == selected ? NSColor.white.withAlphaComponent(0.85) : NSColor.secondaryLabelColor]
                let summaryRect = CGRect(x: rect.minX + 16 + nameWidth, y: rect.minY + 4, width: rect.width - nameWidth - 24, height: rowHeight - 4)
                (item.summary as NSString).draw(with: summaryRect, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], attributes: summaryAttrs)
            }
            if let selectedItem = items.indices.contains(selected) ? items[selected] : nil {
                let footer: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
                (selectedItem.syntax as NSString).draw(with: CGRect(x: 12, y: bounds.height - 18, width: bounds.width - 24, height: 16), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], attributes: footer)
            }
        case .signature(let spec, let argument):
            signatureString(spec, argument: argument).draw(at: CGPoint(x: 12, y: 7))
            let summary = NSAttributedString(string: spec.summary, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            summary.draw(with: CGRect(x: 12, y: 27, width: bounds.width - 24, height: bounds.height - 30), options: [.usesLineFragmentOrigin])
        case .empty:
            break
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if case .list = mode {
            onClick?(Int((point.y - 24) / rowHeight))
        }
    }
}
