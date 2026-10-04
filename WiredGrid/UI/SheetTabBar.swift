import AppKit

/// Sheet tabs along the bottom: click to switch, double-click to rename, drag to
/// reorder, right-click for more.
final class SheetTabBar: NSView, NSTextFieldDelegate {
    private let controller: WorkbookController
    private var tabRects: [CGRect] = []
    private var scrollOffset: CGFloat = 0
    private var dragIndex: Int?
    private var dropIndex: Int?
    private var renameField: NSTextField?
    private var renameIndex: Int?
    private var hoverIndex: Int?
    private var hoverAdd = false

    static let height: CGFloat = 30
    private let leadingInset: CGFloat = 64
    private let addButtonWidth: CGFloat = 28

    init(controller: WorkbookController) {
        self.controller = controller
        super.init(frame: .zero)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Sheets")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    private let font = NSFont.systemFont(ofSize: 12)
    private let boldFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

    private func layoutTabs() {
        var x = leadingInset - scrollOffset
        tabRects = controller.sheets.enumerated().map { index, sheet in
            let width = max(ceil((sheet.name as NSString).size(withAttributes: [.font: boldFont]).width) + 30, 64)
            defer { x += width + 2 }
            return CGRect(x: x, y: 0, width: width, height: bounds.height - 4)
        }
    }

    private var addButtonRect: CGRect {
        let last = tabRects.last?.maxX ?? leadingInset
        return CGRect(x: min(last + 6, bounds.width - addButtonWidth - 6), y: 4, width: addButtonWidth - 4, height: bounds.height - 10)
    }

    private var navigationRects: (left: CGRect, right: CGRect) {
        (CGRect(x: 8, y: 4, width: 22, height: bounds.height - 10), CGRect(x: 32, y: 4, width: 22, height: bounds.height - 10))
    }

    override func draw(_ dirtyRect: NSRect) {
        layoutTabs()
        Theme.barBackground.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        CGRect(x: 0, y: 0, width: bounds.width, height: 1).fill()

        // Scroll arrows.
        let (left, right) = navigationRects
        drawSymbol("chevron.left", in: left, enabled: scrollOffset > 0)
        drawSymbol("chevron.right", in: right, enabled: (tabRects.last?.maxX ?? 0) > bounds.width - addButtonWidth - 10)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: CGRect(x: leadingInset - 2, y: 0, width: bounds.width - leadingInset - 2, height: bounds.height)).addClip()
        for (index, rect) in tabRects.enumerated() where rect.maxX > leadingInset && rect.minX < bounds.width {
            let sheet = controller.sheets[index]
            let active = index == controller.activeSheetIndex
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 0).offsetBy(dx: 0, dy: -4), xRadius: 6, yRadius: 6)
            if active {
                Theme.cellBackground.setFill()
                path.fill()
                NSColor.separatorColor.setStroke()
                path.lineWidth = 1
                path.stroke()
                Theme.accent.setFill()
                CGRect(x: rect.minX + 8, y: rect.maxY - 3, width: rect.width - 16, height: 2.5).fill()
            } else if hoverIndex == index {
                NSColor.labelColor.withAlphaComponent(0.06).setFill()
                path.fill()
            }
            if let tab = sheet.tabColor {
                tab.nsColor.setFill()
                NSBezierPath(roundedRect: CGRect(x: rect.minX + 6, y: rect.minY + 3, width: rect.width - 12, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
            }
            if index == renameIndex { continue }
            let attrs: [NSAttributedString.Key: Any] = [.font: active ? boldFont : font, .foregroundColor: active ? NSColor.labelColor : NSColor.secondaryLabelColor]
            let size = (sheet.name as NSString).size(withAttributes: attrs)
            (sheet.name as NSString).draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
        }
        if let drop = dropIndex {
            let x = drop < tabRects.count ? tabRects[drop].minX - 2 : (tabRects.last?.maxX ?? leadingInset) + 1
            Theme.accent.setFill()
            CGRect(x: x - 1, y: 3, width: 2.5, height: bounds.height - 8).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        let add = addButtonRect
        if hoverAdd {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: add, xRadius: 5, yRadius: 5).fill()
        }
        drawSymbol("plus", in: add, enabled: true)
    }

    private func drawSymbol(_ name: String, in rect: CGRect, enabled: Bool) {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) else { return }
        let tinted = image.tinted(enabled ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor)
        let size = tinted.size
        tinted.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
    }

    private func tabIndex(at point: CGPoint) -> Int? {
        guard point.x >= leadingInset else { return nil }
        return tabRects.firstIndex { $0.contains(CGPoint(x: point.x, y: min(point.y, $0.midY))) }
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let newHover = tabIndex(at: point)
        let newAdd = addButtonRect.contains(point)
        if newHover != hoverIndex || newAdd != hoverAdd {
            hoverIndex = newHover
            hoverAdd = newAdd
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoverIndex = nil
        hoverAdd = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let (left, right) = navigationRects
        if left.contains(point) { scrollOffset = max(0, scrollOffset - 120); needsDisplay = true; return }
        if right.contains(point) {
            let overflow = (tabRects.last?.maxX ?? 0) + scrollOffset - bounds.width + addButtonWidth + 20
            scrollOffset = min(max(overflow, 0), scrollOffset + 120)
            needsDisplay = true
            return
        }
        if addButtonRect.contains(point) { controller.addSheet(after: controller.sheets.count - 1); needsDisplay = true; return }
        guard let index = tabIndex(at: point) else { return }
        if event.clickCount == 2 { beginRename(index); return }
        commitRename()
        controller.activateSheet(index)
        dragIndex = index
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragIndex != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        var target = tabRects.count
        for (i, rect) in tabRects.enumerated() where point.x < rect.midX { target = i; break }
        dropIndex = target
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let from = dragIndex, let to = dropIndex {
            let destination = to > from ? to - 1 : to
            if destination != from { controller.moveSheet(from: from, to: destination) }
        }
        dragIndex = nil
        dropIndex = nil
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        let overflow = max((tabRects.last?.maxX ?? 0) + scrollOffset - bounds.width + addButtonWidth + 20, 0)
        scrollOffset = min(max(scrollOffset - delta, 0), overflow)
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = tabIndex(at: point) else { return nil }
        let c = controller
        let menu = NSMenu()
        menu.add("Insert Sheet", symbol: "plus.rectangle") { c.addSheet(after: index) }
        menu.add("Delete", symbol: "trash", enabled: c.sheets.count > 1) { c.deleteSheet(index) }
        menu.add("Rename", symbol: "pencil") { [weak self] in self?.beginRename(index) }
        menu.add("Duplicate", symbol: "plus.square.on.square") { c.duplicateSheet(index) }
        menu.addItem(.separator())
        menu.add("Move Left", symbol: "arrow.left", enabled: index > 0) { c.moveSheet(from: index, to: index - 1) }
        menu.add("Move Right", symbol: "arrow.right", enabled: index < c.sheets.count - 1) { c.moveSheet(from: index, to: index + 1) }
        let colors = NSMenu(title: "Tab Color")
        colors.add("No Color") { c.setTabColor(nil, sheet: index) }
        colors.addItem(.separator())
        for (name, hex) in [("Red", 0xD9534F), ("Orange", 0xF29D38), ("Yellow", 0xF2C94C), ("Green", 0x1E8E5A), ("Teal", 0x17A2B8), ("Blue", 0x2F6FDB), ("Purple", 0x8E5BD6), ("Gray", 0x6C757D)] as [(String, UInt32)] {
            let item = colors.add(name) { c.setTabColor(RGBColor(hex), sheet: index) }
            item.image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                RGBColor(hex).nsColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
                return true
            }
        }
        menu.addSubmenu(colors)
        return menu
    }

    // MARK: - Renaming

    func beginRename(_ index: Int) {
        commitRename()
        layoutTabs()
        guard tabRects.indices.contains(index) else { return }
        let rect = tabRects[index].insetBy(dx: 6, dy: 4)
        let field = NSTextField(frame: rect)
        field.stringValue = controller.sheets[index].name
        field.font = boldFont
        field.alignment = .center
        field.focusRingType = .none
        field.delegate = self
        field.bezelStyle = .roundedBezel
        addSubview(field)
        renameField = field
        renameIndex = index
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        needsDisplay = true
    }

    private func commitRename() {
        guard let field = renameField, let index = renameIndex else { return }
        renameField = nil
        renameIndex = nil
        let name = field.stringValue
        field.removeFromSuperview()
        if name != controller.sheets[safe: index]?.name { controller.renameSheet(index, to: name) }
        needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitRename()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            renameField?.removeFromSuperview()
            renameField = nil
            renameIndex = nil
            needsDisplay = true
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        commitRename()
    }

    func refresh() {
        needsDisplay = true
    }
}
