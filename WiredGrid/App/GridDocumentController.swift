import AppKit

/// Adds template-based workbook creation to the standard document controller.
final class GridDocumentController: NSDocumentController {
    override var defaultType: String? { DocumentFormat.grid.typeIdentifier }

    func newDocument(from template: WorkbookTemplate) {
        do {
            guard let document = try makeUntitledDocument(ofType: DocumentFormat.grid.typeIdentifier) as? GridDocument else { return }
            if template.id != TemplateLibrary.blank.id {
                document.controller.load(template.build())
            }
            addDocument(document)
            document.makeWindowControllers()
            document.showWindows()
        } catch {
            presentError(error)
        }
    }
}

/// Populates File ▸ Open Recent from the document controller's recent list.
final class RecentDocumentsMenuController: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs
        if urls.isEmpty {
            let empty = NSMenuItem(title: "No Recent Workbooks", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for url in urls {
            let item = NSMenuItem(title: FileManager.default.displayName(atPath: url.path), action: #selector(openRecentDocument(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: ""))
    }

    @objc private func openRecentDocument(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
        }
    }
}
