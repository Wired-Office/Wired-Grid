import AppKit
import UniformTypeIdentifiers

/// A workbook document. NSDocument supplies autosave, versions, crash recovery,
/// Open Recent, Duplicate/Rename/Move and Revert.
final class GridDocument: NSDocument {
    let controller: WorkbookController
    /// The format the file was read from (or last saved as).
    private(set) var format: DocumentFormat?

    override init() {
        var workbook = Workbook(sheets: (1...AppSettings.shared.defaultSheetCount).map { Sheet(name: "Sheet\($0)") })
        workbook.author = AppSettings.shared.authorName
        controller = WorkbookController(workbook: workbook)
        super.init()
        controller.document = self
        undoManager?.levelsOfUndo = 100
    }

    override class var autosavesInPlace: Bool { true }
    override class var preservesVersions: Bool { true }

    override class var readableTypes: [String] { DocumentFormat.allCases.map(\.typeIdentifier) }
    override class var writableTypes: [String] { DocumentFormat.allCases.map(\.typeIdentifier) }
    override class func isNativeType(_ type: String) -> Bool { type == DocumentFormat.grid.typeIdentifier }

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController(document: self))
    }

    // MARK: - Reading and writing

    override func read(from data: Data, ofType typeName: String) throws {
        guard let format = DocumentFormat.from(typeName: typeName) else {
            throw GridError.unsupportedFormat("Wired Grid can't open files of type \(typeName).")
        }
        let workbook = try format.read(data)
        self.format = format
        controller.load(workbook)
        undoManager?.removeAllActions()
    }

    override func data(ofType typeName: String) throws -> Data {
        guard let format = DocumentFormat.from(typeName: typeName) else {
            throw GridError.unsupportedFormat("Wired Grid can't save files of type \(typeName).")
        }
        controller.commitEditingIfNeeded()
        let workbook = controller.workbookForSaving()
        return try format.write(workbook, controller: controller)
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, completionHandler: @escaping (Error?) -> Void) {
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            if error == nil, saveOperation != .autosaveElsewhereOperation, saveOperation != .saveToOperation {
                self?.format = DocumentFormat.from(typeName: typeName)
                (self?.windowControllers.first as? DocumentWindowController)?.updateSubtitle()
            }
            completionHandler(error)
        }
    }

    /// Flat formats lose sheets and formatting; warn once before saving over one.
    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        savePanel.isExtensionHidden = false
        return true
    }

    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        (windowControllers.first as? DocumentWindowController)?.updateSubtitle()
    }

    // MARK: - Printing and PDF

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        controller.commitEditingIfNeeded()
        let info = printInfo.copy() as! NSPrintInfo
        info.dictionary().addEntries(from: printSettings)
        let setup = controller.sheet.pageSetup
        info.orientation = setup.orientation == .landscape ? .landscape : .portrait
        info.topMargin = setup.margin
        info.bottomMargin = setup.margin
        info.leftMargin = setup.margin
        info.rightMargin = setup.margin
        info.horizontalPagination = setup.scaling == .actual ? .automatic : .fit
        info.verticalPagination = setup.scaling == .fitPage ? .fit : .automatic
        info.isHorizontallyCentered = setup.centerHorizontally
        info.isVerticallyCentered = false
        let view = SheetPrintView(controller: controller, sheetIndex: controller.activeSheetIndex, printInfo: info)
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = displayName
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.printPanel.options.formUnion([.showsOrientation, .showsScaling, .showsPreview, .showsPaperSize])
        return operation
    }

    @objc func exportPDF(_ sender: Any?) {
        guard let window = windowControllers.first?.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (displayName as NSString).deletingPathExtension + ".pdf"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                let operation = try self.printOperation(withSettings: [:])
                operation.printInfo.jobDisposition = .save
                operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
                operation.showsPrintPanel = false
                operation.showsProgressPanel = false
                operation.run()
            } catch {
                self.presentError(error)
            }
        }
    }

    @objc func exportAs(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let format = DocumentFormat(rawValue: raw),
              let window = windowControllers.first?.window else { return }
        let panel = NSSavePanel()
        if let type = UTType(format.typeIdentifier) { panel.allowedContentTypes = [type] }
        panel.nameFieldStringValue = (displayName as NSString).deletingPathExtension + "." + format.fileExtension
        if format.isFlat { panel.message = "Only the active sheet's values are exported." }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                let data = try format.write(self.controller.workbookForSaving(), controller: self.controller)
                try data.write(to: url, options: .atomic)
            } catch {
                self.presentError(error)
            }
        }
    }
}
