import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Lays out the ribbon, formula bar, grid, sheet tabs and status bar, and
/// handles menu commands for the workbook.
final class WorkbookViewController: NSViewController, NSMenuItemValidation {
    let controller: WorkbookController
    let ribbonModel = RibbonModel()
    private(set) var gridContainer: GridContainerView!
    private var formulaBar: FormulaBarView!
    private var sheetTabs: SheetTabBar!
    private var ribbonHost: NSHostingView<RibbonView>!
    private var statusHost: NSHostingView<StatusBarView>!
    private var ribbonHeight: NSLayoutConstraint!
    private var formulaBarHeight: NSLayoutConstraint!
    private var statusHeight: NSLayoutConstraint!
    private var cancellables = Set<AnyCancellable>()

    init(controller: WorkbookController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        ribbonHost = NSHostingView(rootView: RibbonView(model: ribbonModel, controller: controller))
        formulaBar = FormulaBarView(controller: controller)
        gridContainer = GridContainerView(controller: controller)
        sheetTabs = SheetTabBar(controller: controller)
        statusHost = NSHostingView(rootView: StatusBarView(controller: controller))
        let ribbonDivider = NSBox()
        ribbonDivider.boxType = .separator

        for view in [ribbonHost, ribbonDivider, formulaBar, gridContainer, sheetTabs, statusHost] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        ribbonHeight = ribbonHost.heightAnchor.constraint(equalToConstant: ribbonModel.height)
        formulaBarHeight = formulaBar.heightAnchor.constraint(equalToConstant: FormulaBarView.height)
        formulaBarHeight.priority = .required
        statusHeight = statusHost.heightAnchor.constraint(equalToConstant: 24)
        NSLayoutConstraint.activate([
            ribbonHost.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            ribbonHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            ribbonHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ribbonHeight,
            ribbonDivider.topAnchor.constraint(equalTo: ribbonHost.bottomAnchor),
            ribbonDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            ribbonDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            formulaBar.topAnchor.constraint(equalTo: ribbonDivider.bottomAnchor),
            formulaBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            formulaBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            gridContainer.topAnchor.constraint(equalTo: formulaBar.bottomAnchor),
            gridContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            gridContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sheetTabs.topAnchor.constraint(equalTo: gridContainer.bottomAnchor),
            sheetTabs.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sheetTabs.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sheetTabs.heightAnchor.constraint(equalToConstant: SheetTabBar.height),
            statusHost.topAnchor.constraint(equalTo: sheetTabs.bottomAnchor),
            statusHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusHeight,
        ])
        view = root

        formulaBar.editing = gridContainer.editing
        gridContainer.editing.formulaBar = formulaBar
        gridContainer.formulaBarRefresh = { [weak self] in self?.formulaBar.refresh() }
        ribbonModel.onCollapseChange = { [weak self] _ in self?.updateBars() }
        controller.presenter = self
        controller.insertFunctionHandler = { [weak self] name in self?.insertFunction(name) }
        controller.$revision.receive(on: RunLoop.main).sink { [weak self] _ in self?.sheetTabs.refresh() }.store(in: &cancellables)
        controller.$activeSheetIndex.receive(on: RunLoop.main).sink { [weak self] _ in self?.sheetTabs.refresh() }.store(in: &cancellables)
        controller.$isEditing.receive(on: RunLoop.main).sink { [weak self] _ in self?.formulaBar.refresh() }.store(in: &cancellables)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: AppSettings.didChange, object: nil)
        updateBars()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(gridContainer.gridView)
        gridContainer.geometryChanged()
        gridContainer.scrollToSelection()
    }

    @objc private func settingsChanged() { updateBars() }

    private func updateBars() {
        ribbonHeight.constant = ribbonModel.height
        formulaBar.isHidden = !AppSettings.shared.showFormulaBar
        formulaBarHeight.constant = AppSettings.shared.showFormulaBar ? FormulaBarView.height : 0
        formulaBarHeight.isActive = true
        statusHost.isHidden = !AppSettings.shared.showStatusBar
        statusHeight.constant = AppSettings.shared.showStatusBar ? 24 : 0
    }

    private func insertFunction(_ name: String) {
        let editing = gridContainer.editing
        let isName = name.hasPrefix("#NAME:")
        let text = isName ? String(name.dropFirst(6)) : name + "("
        if controller.isEditing {
            let textView = editing.activeTextView
            if !textView.string.hasPrefix("=") && textView.string.isEmpty { textView.insertText("=", replacementRange: textView.selectedRange()) }
            textView.insertText(text, replacementRange: textView.selectedRange())
        } else {
            gridContainer.beginEditing(initial: "=" + text, mode: .enter, clickPoint: nil)
        }
    }

    // MARK: - Validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(paste(_:)), #selector(pasteValues(_:)), #selector(pasteFormatting(_:)), #selector(pasteTransposed(_:)):
            return controller.canPaste
        case #selector(toggleBold(_:)):
            item.state = controller.activeStyle.bold ? .on : .off
        case #selector(toggleItalic(_:)):
            item.state = controller.activeStyle.italic ? .on : .off
        case #selector(toggleUnderline(_:)):
            item.state = controller.activeStyle.underline ? .on : .off
        case #selector(toggleShowFormulas(_:)):
            item.state = controller.showFormulas ? .on : .off
        case #selector(toggleGridlines(_:)):
            item.state = controller.sheet.showGridlines ? .on : .off
        case #selector(toggleHeadings(_:)):
            item.state = controller.sheet.showHeadings ? .on : .off
        case #selector(toggleFormulaBar(_:)):
            item.state = AppSettings.shared.showFormulaBar ? .on : .off
        case #selector(toggleStatusBar(_:)):
            item.state = AppSettings.shared.showStatusBar ? .on : .off
        case #selector(toggleRibbon(_:)):
            item.title = ribbonModel.isCollapsed ? "Show Ribbon" : "Collapse Ribbon"
        case #selector(toggleFilter(_:)):
            item.state = controller.sheet.filter != nil ? .on : .off
        case #selector(freezePanes(_:)):
            item.title = controller.hasFrozenPanes ? "Unfreeze Panes" : "Freeze Panes"
        case #selector(deleteSheet(_:)):
            return controller.sheets.count > 1
        case #selector(mergeCells(_:)):
            item.state = controller.selectionIsMerged ? .on : .off
        case #selector(toggleWrapText(_:)):
            item.state = controller.activeStyle.wrap ? .on : .off
        default:
            break
        }
        return true
    }

    // MARK: - Edit menu

    @objc func cut(_ sender: Any?) { controller.copySelection(cut: true) }
    @objc func copy(_ sender: Any?) { controller.copySelection() }
    @objc func paste(_ sender: Any?) { controller.paste() }
    @objc func pasteValues(_ sender: Any?) { controller.paste(.values) }
    @objc func pasteFormatting(_ sender: Any?) { controller.paste(.formats) }
    @objc func pasteTransposed(_ sender: Any?) { controller.paste(.transpose) }
    @objc func pasteSpecialMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = PasteMode(rawValue: raw) { controller.paste(mode) }
    }
    @objc func delete(_ sender: Any?) {
        if let chart = controller.selectedChartID { controller.deleteChart(chart); return }
        controller.clearContents()
    }
    @objc override func selectAll(_ sender: Any?) { controller.selectAll() }
    @objc func clearAll(_ sender: Any?) { controller.clearAll() }
    @objc func clearFormats(_ sender: Any?) { controller.clearFormats() }
    @objc func fillDown(_ sender: Any?) { controller.fill(down: true) }
    @objc func fillRight(_ sender: Any?) { controller.fill(down: false) }
    @objc func findCells(_ sender: Any?) { presentFindReplace(replace: false) }
    @objc func replaceCells(_ sender: Any?) { presentFindReplace(replace: true) }
    @objc func findNextMatch(_ sender: Any?) {
        if !controller.findNext(FindReplaceModel.shared.options) { NSSound.beep() }
    }
    @objc func findPreviousMatch(_ sender: Any?) {
        if !controller.findNext(FindReplaceModel.shared.options, backwards: true) { NSSound.beep() }
    }
    @objc func goToCell(_ sender: Any?) { presentGoTo() }
    @objc func editActiveCell(_ sender: Any?) { gridContainer.beginEditing(initial: nil, mode: .edit, clickPoint: nil) }

    // MARK: - Insert menu

    @objc func insertRows(_ sender: Any?) { controller.insertSheetRows() }
    @objc func insertColumns(_ sender: Any?) { controller.insertSheetColumns() }
    @objc func insertCellsDown(_ sender: Any?) { controller.insertCells(shiftDown: true) }
    @objc func deleteRows(_ sender: Any?) { controller.deleteSheetRows() }
    @objc func deleteColumns(_ sender: Any?) { controller.deleteSheetColumns() }
    @objc func deleteCellsUp(_ sender: Any?) { controller.deleteCells(shiftUp: true) }
    @objc func insertSheet(_ sender: Any?) { controller.addSheet() }
    @objc func deleteSheet(_ sender: Any?) { controller.deleteSheet(controller.activeSheetIndex) }
    @objc func renameSheet(_ sender: Any?) { sheetTabs.beginRename(controller.activeSheetIndex) }
    @objc func duplicateSheet(_ sender: Any?) { controller.duplicateSheet(controller.activeSheetIndex) }
    @objc func nextSheet(_ sender: Any?) { controller.activateSheet(min(controller.activeSheetIndex + 1, controller.sheets.count - 1)) }
    @objc func previousSheet(_ sender: Any?) { controller.activateSheet(max(controller.activeSheetIndex - 1, 0)) }
    @objc func insertChart(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let kind = ChartKind(rawValue: raw) { controller.insertChart(kind) }
    }
    @objc func insertNote(_ sender: Any?) { presentNoteEditor(at: controller.selection.active) }
    @objc func insertFunctionDialog(_ sender: Any?) { presentInsertFunction(category: nil) }
    @objc func autoSum(_ sender: Any?) { controller.autoSum() }
    @objc func insertDate(_ sender: Any?) { controller.insertCurrentDate() }
    @objc func insertTime(_ sender: Any?) { controller.insertCurrentTime() }
    @objc func insertHyperlink(_ sender: Any?) {
        let address = controller.selection.active
        presentTextPrompt(title: "Insert Hyperlink", message: "Address (web page, email or #Sheet!A1):", value: controller.sheet.cells[address]?.link ?? "https://") { [controller] url in
            controller.setLink(url, at: address, displayText: nil)
        }
    }
    @objc func defineName(_ sender: Any?) { presentNameManager() }

    // MARK: - Format menu

    @objc func formatCells(_ sender: Any?) { presentFormatCells(tab: .number) }
    @objc func toggleBold(_ sender: Any?) { controller.toggleBold() }
    @objc func toggleItalic(_ sender: Any?) { controller.toggleItalic() }
    @objc func toggleUnderline(_ sender: Any?) { controller.toggleUnderline() }
    @objc func toggleStrikethrough(_ sender: Any?) { controller.toggleStrikethrough() }
    @objc func toggleWrapText(_ sender: Any?) { controller.toggleWrap() }
    @objc func mergeCells(_ sender: Any?) { controller.merge(.mergeAndCenter) }
    @objc func alignLeftCells(_ sender: Any?) { controller.setHorizontalAlignment(.left) }
    @objc func alignCenterCells(_ sender: Any?) { controller.setHorizontalAlignment(.center) }
    @objc func alignRightCells(_ sender: Any?) { controller.setHorizontalAlignment(.right) }
    @objc func increaseDecimal(_ sender: Any?) { controller.adjustDecimals(1) }
    @objc func decreaseDecimal(_ sender: Any?) { controller.adjustDecimals(-1) }
    @objc func increaseFontSize(_ sender: Any?) { controller.growFont(true) }
    @objc func decreaseFontSize(_ sender: Any?) { controller.growFont(false) }
    @objc func applyNumberPreset(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let preset = NumberFormatPreset(rawValue: raw) { controller.setNumberFormat(preset.code) }
    }
    @objc func conditionalFormatting(_ sender: Any?) { presentConditionalFormat(nil) }
    @objc func manageRules(_ sender: Any?) { presentManageRules() }
    @objc func autoFitColumns(_ sender: Any?) { controller.autoFitColumns(controller.selectedColumnIndices) }
    @objc func autoFitRows(_ sender: Any?) { controller.autoFitRows(controller.selectedRowIndices) }
    @objc func columnWidth(_ sender: Any?) { gridContainer.promptColumnWidth() }
    @objc func rowHeight(_ sender: Any?) { gridContainer.promptRowHeight() }
    @objc func hideRows(_ sender: Any?) { controller.hideRows() }
    @objc func hideColumns(_ sender: Any?) { controller.hideColumns() }
    @objc func unhideRows(_ sender: Any?) { controller.unhideRows() }
    @objc func unhideColumns(_ sender: Any?) { controller.unhideColumns() }

    // MARK: - Data menu

    @objc func sortAscending(_ sender: Any?) { controller.quickSort(ascending: true) }
    @objc func sortDescending(_ sender: Any?) { controller.quickSort(ascending: false) }
    @objc func customSort(_ sender: Any?) { presentSort() }
    @objc func toggleFilter(_ sender: Any?) { controller.toggleFilter() }
    @objc func clearFilter(_ sender: Any?) { controller.clearFilters() }
    @objc func reapplyFilter(_ sender: Any?) { controller.reapplyFilter() }
    @objc func removeDuplicates(_ sender: Any?) { controller.removeDuplicates() }
    @objc func textToColumns(_ sender: Any?) { presentTextToColumns() }
    @objc func calculateNow(_ sender: Any?) { controller.recalculate() }
    @objc func toggleShowFormulas(_ sender: Any?) { controller.showFormulas.toggle() }

    @objc func importDelimited(_ sender: Any?) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.message = "Choose a text file to import at the selected cell."
        panel.beginSheetModal(for: window) { [controller] response in
            guard response == .OK, let url = panel.url, let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return }
            let separator: Character = url.pathExtension.lowercased() == "tsv" || text.contains("\t") ? "\t" : ","
            let rows = WorkbookController.parseDelimited(text, separator: separator)
            let tsv = rows.map { $0.map { $0.replacingOccurrences(of: "\t", with: " ") }.joined(separator: "\t") }.joined(separator: "\n")
            controller.pasteText(tsv)
        }
    }

    // MARK: - View menu

    @objc func zoomIn(_ sender: Any?) { controller.setZoom(controller.sheet.zoom * 1.25) }
    @objc func zoomOut(_ sender: Any?) { controller.setZoom(controller.sheet.zoom / 1.25) }
    @objc func actualSize(_ sender: Any?) { controller.setZoom(1) }
    @objc func zoomToSelection(_ sender: Any?) {
        let g = gridContainer.gridView.geometry
        let range = controller.boundedToContent(controller.selection.primary)
        let rect = g.rect(range)
        guard rect.width > 0, rect.height > 0 else { return }
        let body = g.cellAreaRect
        let factor = min(body.width / rect.width, body.height / rect.height) * 0.95
        controller.setZoom(controller.sheet.zoom * factor)
        gridContainer.scrollToCell(range.start)
    }
    @objc func toggleGridlines(_ sender: Any?) { controller.toggleGridlines() }
    @objc func toggleHeadings(_ sender: Any?) { controller.toggleHeadings() }
    @objc func toggleFormulaBar(_ sender: Any?) { AppSettings.shared.showFormulaBar.toggle() }
    @objc func toggleStatusBar(_ sender: Any?) { AppSettings.shared.showStatusBar.toggle() }
    @objc func toggleRibbon(_ sender: Any?) { ribbonModel.isCollapsed.toggle() }
    @objc func freezePanes(_ sender: Any?) { controller.freezePanes() }
    @objc func freezeTopRow(_ sender: Any?) { controller.freezeTopRow() }
    @objc func freezeFirstColumn(_ sender: Any?) { controller.freezeFirstColumn() }
    @objc func showRibbonTab(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let tab = RibbonModel.Tab(rawValue: raw) {
            ribbonModel.tab = tab
            ribbonModel.isCollapsed = false
        }
    }
}

// MARK: - Dialogs

extension WorkbookViewController: SheetPresenting {
    private func present<Content: View>(@ViewBuilder _ content: (_ dismiss: @escaping () -> Void) -> Content) {
        guard let window = view.window else { return }
        controller.commitEditingIfNeeded()
        SheetPresenter.present(in: window, content: content)
    }

    func presentFormatCells(tab: FormatCellsTab) {
        present { dismiss in FormatCellsSheet(controller: controller, initialTab: tab, dismiss: dismiss) }
    }

    func presentAlert(_ message: String, info: String?) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info ?? ""
        alert.addButton(withTitle: "OK")
        if window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    func presentFindReplace(replace: Bool) {
        FindReplaceWindowController.shared.show(for: controller, replace: replace)
    }

    func presentInsertFunction(category: FunctionCategory?) {
        present { dismiss in
            InsertFunctionSheet(initialCategory: category, dismiss: dismiss) { [weak self] name in self?.insertFunction(name) }
        }
    }

    func presentChartEditor(_ chart: ChartObject) {
        present { dismiss in ChartEditorSheet(controller: controller, chart: chart, dismiss: dismiss) }
    }

    func presentSort() {
        present { dismiss in SortSheet(controller: controller, dismiss: dismiss) }
    }

    func presentConditionalFormat(_ rule: ConditionalFormat.Rule?) {
        present { dismiss in ConditionalFormatSheet(controller: controller, initialRule: rule, dismiss: dismiss) }
    }

    func presentManageRules() {
        present { dismiss in ManageRulesSheet(controller: controller, dismiss: dismiss) }
    }

    func presentNameManager() {
        present { dismiss in NameManagerSheet(controller: controller, dismiss: dismiss) }
    }

    func presentGoTo() {
        presentTextPrompt(title: "Go To", message: "Reference or name (for example B12, Sheet2!A1:C4 or TaxRate):", value: controller.nameBoxText) { [weak self] text in
            guard let self else { return }
            if !self.controller.goTo(text) { self.presentAlert("Reference isn't valid.", info: nil) }
        }
    }

    func presentNumberPrompt(title: String, message: String, value: Double, completion: @escaping (Double) -> Void) {
        present { dismiss in
            PromptSheet(title: title, message: message, initial: NumberFormat.general(value), dismiss: dismiss) { text in
                if let number = Double(text.trimmingCharacters(in: .whitespaces)) { completion(number) }
            }
        }
    }

    func presentTextPrompt(title: String, message: String, value: String, completion: @escaping (String) -> Void) {
        present { dismiss in PromptSheet(title: title, message: message, initial: value, dismiss: dismiss, onCommit: completion) }
    }

    func presentNoteEditor(at address: CellAddress) {
        present { dismiss in
            NoteEditorSheet(address: address, initial: controller.note(at: address) ?? "", dismiss: dismiss) { [controller] text in
                controller.setNote(text, at: address)
            }
        }
    }

    func presentTextToColumns() {
        present { dismiss in TextToColumnsSheet(controller: controller, dismiss: dismiss) }
    }

    func presentPageSetup() {
        present { dismiss in PageSetupSheet(controller: controller, dismiss: dismiss) }
    }
}
