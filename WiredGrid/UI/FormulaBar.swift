import AppKit

/// The formula text field: focusing it starts an edit of the active cell.
final class FormulaTextField: NSTextField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }
}

/// Name box, cancel/enter/fx buttons and the formula field.
final class FormulaBarView: NSView, NSTextFieldDelegate, NSComboBoxDelegate {
    private let controller: WorkbookController
    weak var editing: CellEditingController?
    private let nameBox = NSComboBox()
    private let cancelButton = NSButton()
    private let enterButton = NSButton()
    private let functionButton = NSButton()
    private let field = FormulaTextField()
    private let separator = NSBox()
    private var updatingField = false

    static let height: CGFloat = 32

    init(controller: WorkbookController) {
        self.controller = controller
        super.init(frame: .zero)

        nameBox.isEditable = true
        nameBox.completes = true
        nameBox.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        nameBox.alignment = .center
        nameBox.delegate = self
        nameBox.target = self
        nameBox.action = #selector(nameBoxCommitted)
        nameBox.toolTip = "Name Box: type a reference or name to go there, or a new name to name the selection."
        nameBox.setAccessibilityLabel("Name Box")

        configure(cancelButton, symbol: "xmark", help: "Cancel", action: #selector(cancelEdit))
        configure(enterButton, symbol: "checkmark", help: "Enter", action: #selector(commitEdit))
        configure(functionButton, symbol: "function", help: "Insert Function", action: #selector(insertFunction))

        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        field.placeholderString = ""
        field.setAccessibilityLabel("Formula Bar")
        field.onFocus = { [weak self] in self?.editing?.beginFromFormulaBar() }

        separator.boxType = .separator

        for view in [nameBox, cancelButton, enterButton, functionButton, field, separator] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        NSLayoutConstraint.activate([
            nameBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            nameBox.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameBox.widthAnchor.constraint(equalToConstant: 118),
            divider.leadingAnchor.constraint(equalTo: nameBox.trailingAnchor, constant: 8),
            divider.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            divider.widthAnchor.constraint(equalToConstant: 1),
            cancelButton.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 6),
            cancelButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            enterButton.leadingAnchor.constraint(equalTo: cancelButton.trailingAnchor, constant: 2),
            enterButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            functionButton.leadingAnchor.constraint(equalTo: enterButton.trailingAnchor, constant: 2),
            functionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.leadingAnchor.constraint(equalTo: functionButton.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configure(_ button: NSButton, symbol: String, help: String, action: Selector) {
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        button.imagePosition = .imageOnly
        button.toolTip = help
        button.target = self
        button.action = action
        button.setAccessibilityLabel(help)
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.barBackground.setFill()
        bounds.fill()
    }

    // MARK: - State

    func refresh() {
        nameBox.removeAllItems()
        nameBox.addItems(withObjectValues: controller.workbook.names.map(\.name))
        if nameBox.currentEditor() == nil { nameBox.stringValue = controller.nameBoxText }
        let editing = controller.isEditing
        cancelButton.isEnabled = editing
        enterButton.isEnabled = editing
        cancelButton.contentTintColor = editing ? .systemRed : .tertiaryLabelColor
        enterButton.contentTintColor = editing ? Theme.accent : .tertiaryLabelColor
        if !editing, activeFieldEditor == nil {
            updatingField = true
            field.stringValue = controller.inputText(at: controller.sheet.merge(containing: controller.selection.active)?.start ?? controller.selection.active)
            updatingField = false
        }
    }

    /// Mirrors the cell editor's text while editing.
    func showEditingText(_ text: String) {
        cancelButton.isEnabled = true
        enterButton.isEnabled = true
        cancelButton.contentTintColor = .systemRed
        enterButton.contentTintColor = Theme.accent
        if let editor = activeFieldEditor {
            if editor.string != text {
                updatingField = true
                let selection = editor.selectedRange()
                editor.string = text
                editor.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
                updatingField = false
            }
        } else {
            updatingField = true
            field.stringValue = text
            updatingField = false
        }
    }

    func endEditing() {
        if activeFieldEditor != nil {
            field.abortEditing()
        }
        refresh()
    }

    func focusField() {
        window?.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
        }
    }

    /// The formula field's editor, when it has focus.
    var activeFieldEditor: NSTextView? {
        guard let editor = field.currentEditor() as? NSTextView, window?.firstResponder === editor else { return nil }
        return editor
    }

    var fieldFrameInWindow: NSRect {
        field.convert(field.bounds, to: nil)
    }

    // MARK: - Field delegate

    func controlTextDidChange(_ notification: Notification) {
        guard !updatingField, notification.object as? NSTextField === field else { return }
        if !controller.isEditing { editing?.beginFromFormulaBar() }
        editing?.formulaBarTextChanged(field.currentEditor()?.string ?? field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === field {
            return editing?.handleCommand(commandSelector, in: textView) ?? false
        }
        if control === nameBox, commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            nameBox.stringValue = controller.nameBoxText
            window?.makeFirstResponder(editing?.container.gridView)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if notification.object as? NSTextField === field, controller.isEditing, editing?.editorView.window?.firstResponder !== editing?.editorView {
            // Focus moved elsewhere (another control): keep the edit open in the cell.
        }
    }

    // MARK: - Actions

    @objc private func nameBoxCommitted() {
        let text = nameBox.stringValue.trimmingCharacters(in: .whitespaces)
        defer {
            nameBox.stringValue = controller.nameBoxText
            window?.makeFirstResponder(editing?.container.gridView)
        }
        guard !text.isEmpty else { return }
        if controller.goTo(text) { return }
        if WorkbookController.isValidName(text) {
            _ = controller.nameSelection(text)
        } else {
            controller.presenter?.presentAlert("Reference isn't valid.", info: "Type a cell reference such as B7 or C2:F9, or a name.")
        }
    }

    @objc private func cancelEdit() { editing?.cancel() }
    @objc private func commitEdit() { editing?.commit(move: nil) }
    @objc private func insertFunction() { controller.presenter?.presentInsertFunction(category: nil) }
}
