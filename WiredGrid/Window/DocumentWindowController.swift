import AppKit

final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let contentController: WorkbookViewController
    private var sizeLock: [NSLayoutConstraint] = []

    private static let undoItem = NSToolbarItem.Identifier("wg.undo")
    private static let redoItem = NSToolbarItem.Identifier("wg.redo")
    private static let saveItem = NSToolbarItem.Identifier("wg.save")
    private static let printItem = NSToolbarItem.Identifier("wg.print")
    private static let sumItem = NSToolbarItem.Identifier("wg.sum")
    private static let chartItem = NSToolbarItem.Identifier("wg.chart")
    private static let filterItem = NSToolbarItem.Identifier("wg.filter")
    private static let findItem = NSToolbarItem.Identifier("wg.find")
    private static let shareItem = NSToolbarItem.Identifier("wg.share")

    init(document: GridDocument) {
        contentController = WorkbookViewController(controller: document.controller)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = contentController
        window.setContentSize(NSSize(width: 1240, height: 820))
        window.contentMinSize = NSSize(width: 760, height: 480)
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.tabbingIdentifier = "com.wiredgrid.document-window"
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isRestorable = true
        window.backgroundColor = Theme.barBackground
        super.init(window: window)
        window.delegate = self
        let toolbar = NSToolbar(identifier: "WiredGridToolbar1")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        shouldCascadeWindows = true
        window.center()
        lockContentSize(window.contentLayoutRect.size)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Initial size

    /// AppKit's first constraint pass shrinks a new window to its fitting size; hold
    /// the intended size until that pass has run.
    private func lockContentSize(_ size: NSSize) {
        NSLayoutConstraint.deactivate(sizeLock)
        guard let content = window?.contentView else { return }
        sizeLock = [
            content.widthAnchor.constraint(equalToConstant: size.width),
            content.heightAnchor.constraint(equalToConstant: size.height),
        ]
        NSLayoutConstraint.activate(sizeLock)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.releaseSizeLock() }
    }

    private func releaseSizeLock() {
        guard !sizeLock.isEmpty else { return }
        NSLayoutConstraint.deactivate(sizeLock)
        sizeLock = []
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        DispatchQueue.main.async { DispatchQueue.main.async { [weak self] in self?.releaseSizeLock() } }
    }

    func windowWillEnterFullScreen(_ notification: Notification) { releaseSizeLock() }

    func window(_ window: NSWindow, didDecodeRestorableState state: NSCoder) {
        if !sizeLock.isEmpty && !window.styleMask.contains(.fullScreen) {
            lockContentSize(window.contentLayoutRect.size)
        }
    }

    override var document: AnyObject? {
        didSet { updateSubtitle() }
    }

    func updateSubtitle() {
        guard let window, let document = document as? GridDocument else { return }
        var parts: [String] = []
        if let format = document.format, !format.isNative { parts.append(format.shortName) }
        if document.fileURL == nil { parts.append("Not saved") }
        window.subtitle = parts.joined(separator: " · ")
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        (document as? NSDocument)?.undoManager
    }

    func windowDidBecomeKey(_ notification: Notification) {
        contentController.controller.validateMarquee()
    }

    // MARK: - Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.saveItem, Self.undoItem, Self.redoItem, .flexibleSpace, Self.sumItem, Self.chartItem, Self.filterItem, .space, Self.findItem, Self.shareItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [Self.printItem, .space, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func button(_ label: String, _ symbol: String, _ action: Selector, _ tip: String) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = label
            item.paletteLabel = label
            item.toolTip = tip
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.action = action
            item.isBordered = true
            return item
        }
        switch identifier {
        case Self.saveItem: return button("Save", "square.and.arrow.down", #selector(NSDocument.save(_:)), "Save (⌘S)")
        case Self.undoItem: return button("Undo", "arrow.uturn.backward", Selector(("undo:")), "Undo (⌘Z)")
        case Self.redoItem: return button("Redo", "arrow.uturn.forward", Selector(("redo:")), "Redo (⇧⌘Z)")
        case Self.printItem: return button("Print", "printer", #selector(NSDocument.printDocument(_:)), "Print (⌘P)")
        case Self.sumItem: return button("AutoSum", "sum", #selector(WorkbookViewController.autoSum(_:)), "AutoSum (⇧⌘T)")
        case Self.filterItem: return button("Filter", "line.3.horizontal.decrease.circle", #selector(WorkbookViewController.toggleFilter(_:)), "Filter (⇧⌘F)")
        case Self.findItem: return button("Find", "magnifyingglass", #selector(WorkbookViewController.findCells(_:)), "Find & Replace (⌘F)")
        case Self.chartItem:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.label = "Chart"
            item.paletteLabel = "Chart"
            item.toolTip = "Insert a chart of the selected data"
            item.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "Chart")
            let menu = NSMenu()
            for kind in ChartKind.allCases {
                let entry = NSMenuItem(title: kind.title, action: #selector(WorkbookViewController.insertChart(_:)), keyEquivalent: "")
                entry.representedObject = kind.rawValue
                entry.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)
                menu.addItem(entry)
            }
            item.menu = menu
            item.showsIndicator = true
            return item
        case Self.shareItem:
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: identifier)
            item.label = "Share"
            item.delegate = self
            return item
        default:
            return nil
        }
    }
}

extension DocumentWindowController: NSSharingServicePickerToolbarItemDelegate {
    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        guard let document = document as? GridDocument else { return [] }
        if let url = document.fileURL { return [url] }
        return []
    }
}
