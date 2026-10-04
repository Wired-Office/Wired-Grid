import AppKit

/// The text view that floats over a cell while you type in it.
final class CellEditorTextView: NSTextView {
    weak var session: CellEditingController?
    var borderColor: NSColor = Theme.selection

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        // F4 or ⌘T cycles absolute/relative references.
        if event.keyCode == 118 || (flags == [.command] && event.charactersIgnoringModifiers == "t") {
            session?.toggleAbsoluteReference(in: self)
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        borderColor.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        path.stroke()
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { session?.editorBecameFirstResponder() }
        return ok
    }
}

/// One editing session: the in-cell editor and the formula bar share the text,
/// and clicking cells while typing a formula inserts references.
final class CellEditingController: NSObject, NSTextViewDelegate {
    enum Mode { case enter, edit }

    unowned let container: GridContainerView
    let editorView: CellEditorTextView
    weak var formulaBar: FormulaBarView?
    let hints = FunctionHintController()

    private(set) var address = CellAddress.origin
    private(set) var sheetIndex = 0
    private(set) var mode: Mode = .enter
    /// The reference inserted by pointing, so the next click replaces it.
    private var pointRange: NSRange?
    private var pointCursor: CellAddress?
    private var pointAnchor: CellAddress?
    private var syncing = false
    private var lastEditWasInsertion = false

    var controller: WorkbookController { container.controller }
    var isActive: Bool { controller.isEditing }
    var text: String { editorView.string }
    var isFormula: Bool { text.hasPrefix("=") && text.count >= 1 }

    init(container: GridContainerView) {
        self.container = container
        editorView = CellEditorTextView(frame: .zero)
        super.init()
        editorView.session = self
        editorView.delegate = self
        editorView.isRichText = false
        editorView.importsGraphics = false
        editorView.allowsUndo = true
        editorView.isAutomaticQuoteSubstitutionEnabled = false
        editorView.isAutomaticDashSubstitutionEnabled = false
        editorView.isAutomaticTextReplacementEnabled = false
        editorView.isAutomaticSpellingCorrectionEnabled = false
        editorView.isContinuousSpellCheckingEnabled = false
        editorView.isGrammarCheckingEnabled = false
        editorView.drawsBackground = true
        editorView.isHorizontallyResizable = true
        editorView.isVerticallyResizable = true
        editorView.maxSize = NSSize(width: 100_000, height: 100_000)
        editorView.textContainer?.widthTracksTextView = false
        editorView.textContainer?.containerSize = NSSize(width: 100_000, height: 100_000)
        editorView.textContainer?.lineFragmentPadding = 2
        editorView.focusRingType = .none
        hints.onAccept = { [weak self] spec, range in self?.acceptSuggestion(spec, range: range) }
    }

    // MARK: - Lifecycle

    func begin(initial: String?, mode: Mode, clickPoint: CGPoint?, selection: NSRange? = nil, focusFormulaBar: Bool = false) {
        guard !isActive else { return }
        let sheet = controller.sheet
        address = sheet.merge(containing: controller.selection.active)?.start ?? controller.selection.active
        sheetIndex = controller.activeSheetIndex
        self.mode = mode
        pointRange = nil
        pointCursor = nil
        let startText = initial ?? controller.inputText(at: address)

        let style = sheet.style(at: address)
        let zoom = CGFloat(sheet.zoom)
        editorView.font = style.font(zoom: zoom)
        editorView.textColor = style.textColor?.nsColor ?? Theme.cellText
        editorView.backgroundColor = style.fillColor?.nsColor ?? Theme.cellBackground
        editorView.insertionPointColor = style.fillColor.map { $0.luminance < 0.45 ? NSColor.white : NSColor.black } ?? NSColor.textColor
        if let fill = style.fillColor, style.textColor == nil { editorView.textColor = fill.luminance < 0.45 ? .white : .black }
        editorView.alignment = .left
        editorView.textContainerInset = NSSize(width: 1, height: max(2, 3 * zoom))
        editorView.typingAttributes = [.font: editorView.font!, .foregroundColor: editorView.textColor!]
        syncing = true
        editorView.string = startText
        syncing = false
        editorView.undoManager?.removeAllActions(withTarget: editorView.textStorage as Any)

        controller.isEditing = true
        controller.commitEditingHandler = { [weak self] in self?.commit(move: nil) ?? true }
        controller.cancelEditingHandler = { [weak self] in self?.cancel() }

        container.gridView.addSubview(editorView)
        positionEditor()
        formulaBar?.showEditingText(startText)

        if focusFormulaBar {
            formulaBar?.focusField()
        } else {
            container.window?.makeFirstResponder(editorView)
            if let selection {
                editorView.setSelectedRange(selection)
            } else if let clickPoint {
                let local = editorView.convert(clickPoint, from: container.gridView)
                let index = editorView.characterIndexForInsertion(at: local)
                editorView.setSelectedRange(NSRange(location: min(index, (startText as NSString).length), length: 0))
            } else {
                editorView.setSelectedRange(NSRange(location: (startText as NSString).length, length: 0))
            }
        }
        refreshDecorations()
        container.gridView.needsDisplay = true
    }

    /// Starts a session because the formula bar gained focus.
    func beginFromFormulaBar() {
        guard !isActive else { return }
        begin(initial: nil, mode: .edit, clickPoint: nil, focusFormulaBar: true)
    }

    func editorBecameFirstResponder() {}

    /// Commits the entry. `move` is (rows, columns) to move afterwards; nil stays put.
    @discardableResult
    func commit(move: (Int, Int)?, fillSelection: Bool = false, reverseEnter: Bool = false, useEnterDirection: Bool = false) -> Bool {
        guard isActive else { return true }
        let entry = currentText()
        // Formulas must be committed on the sheet they were started on.
        if controller.activeSheetIndex != sheetIndex { controller.activateSheet(sheetIndex) }
        let original = controller.inputText(at: address)
        if entry != original || fillSelection {
            guard controller.setInput(entry, at: address, fillSelection: fillSelection) else {
                container.window?.makeFirstResponder(editorView)
                return false
            }
        }
        end()
        if useEnterDirection {
            controller.moveAfterEnter(reverse: reverseEnter)
        } else if let (rows, columns) = move {
            if rows != 0 || columns != 0 {
                if controller.selection.isSingleCell || (rows != 0 && columns != 0) {
                    controller.moveSelection(rows: rows, columns: columns, extend: false)
                } else {
                    controller.advanceWithinSelection(forward: rows + columns > 0, vertical: rows != 0)
                }
            }
        }
        return true
    }

    func cancel() {
        guard isActive else { return }
        end()
    }

    private func end() {
        hints.hide()
        editorView.removeFromSuperview()
        controller.isEditing = false
        controller.commitEditingHandler = nil
        controller.cancelEditingHandler = nil
        container.gridView.referenceHighlights = []
        formulaBar?.endEditing()
        container.window?.makeFirstResponder(container.gridView)
        container.gridView.needsDisplay = true
        container.refreshFormulaBar()
    }

    private func currentText() -> String {
        if let field = formulaBar?.activeFieldEditor { return field.string }
        return editorView.string
    }

    // MARK: - Layout

    func positionEditor() {
        guard isActive else { return }
        let gridView = container.gridView
        let g = gridView.geometry
        let sheet = controller.sheet
        let range = sheet.merge(containing: address) ?? CellRange(address)
        var cell = g.rect(range)
        let style = sheet.style(at: address)
        let maxWidth = max(gridView.bounds.maxX - cell.minX - 4, cell.width)
        let font = editorView.font ?? NSFont.systemFont(ofSize: 12)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)

        let textWidth: CGFloat
        if let layout = editorView.layoutManager, let container = editorView.textContainer {
            layout.ensureLayout(for: container)
            textWidth = ceil(layout.usedRect(for: container).width) + 12
        } else {
            textWidth = cell.width
        }
        var width = max(cell.width + 2, min(textWidth, maxWidth))
        let wraps = style.wrap || textWidth > maxWidth
        editorView.textContainer?.containerSize = NSSize(width: wraps ? width - 6 : 100_000, height: 100_000)
        var height = max(cell.height + 2, lineHeight + editorView.textContainerInset.height * 2)
        if let layout = editorView.layoutManager, let container = editorView.textContainer {
            layout.ensureLayout(for: container)
            height = max(height, ceil(layout.usedRect(for: container).height) + editorView.textContainerInset.height * 2 + 2)
        }
        if wraps { width = style.wrap ? cell.width + 2 : maxWidth }
        cell.origin.x -= 1
        cell.origin.y -= 1
        editorView.frame = CGRect(x: cell.minX, y: cell.minY, width: width, height: min(height, gridView.bounds.height - cell.minY))
        editorView.needsDisplay = true
    }

    // MARK: - Text changes

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        lastEditWasInsertion = !(replacementString ?? "").isEmpty && affectedCharRange.length == 0
        return true
    }

    func textDidChange(_ notification: Notification) {
        guard !syncing else { return }
        if !insertingReference { pointRange = nil; pointCursor = nil }
        formulaBar?.showEditingText(editorView.string)
        applyAutoComplete()
        positionEditor()
        refreshDecorations()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !syncing, isActive else { return }
        updateHints()
    }

    /// Called by the formula bar as you type in it.
    func formulaBarTextChanged(_ text: String) {
        guard isActive else { return }
        syncing = true
        editorView.string = text
        syncing = false
        if !insertingReference { pointRange = nil; pointCursor = nil }
        positionEditor()
        refreshDecorations()
    }

    private func applyAutoComplete() {
        guard lastEditWasInsertion, !isFormula else { return }
        lastEditWasInsertion = false
        let current = editorView.string
        let selected = editorView.selectedRange()
        guard selected.length == 0, selected.location == (current as NSString).length,
              let completion = controller.autoCompletion(for: current, at: address) else { return }
        let suffix = String(completion.dropFirst(current.count))
        guard !suffix.isEmpty else { return }
        syncing = true
        editorView.textStorage?.append(NSAttributedString(string: suffix, attributes: editorView.typingAttributes))
        editorView.setSelectedRange(NSRange(location: selected.location, length: (suffix as NSString).length))
        syncing = false
        formulaBar?.showEditingText(editorView.string)
    }

    /// Colors references in the editor and draws matching boxes on the grid.
    func refreshDecorations() {
        let text = editorView.string
        guard let layout = editorView.layoutManager else { return }
        let full = NSRange(location: 0, length: (text as NSString).length)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        var highlights: [(sheet: Int, range: CellRange, color: NSColor)] = []
        if text.hasPrefix("="), let tokens = try? FormulaLexer.tokenize(String(text.dropFirst())) {
            var colorIndex = 0
            var assigned: [String: NSColor] = [:]
            for token in tokens {
                var reference: (String?, CellRange)?
                switch token.kind {
                case .cell(let r): reference = (r.sheet, CellRange(r.address))
                case .range(let r): reference = (r.sheet, r.range)
                default: break
                }
                guard let (sheetName, range) = reference else { continue }
                let key = token.text.replacingOccurrences(of: "$", with: "").uppercased()
                let color = assigned[key] ?? Theme.referenceColors[colorIndex % Theme.referenceColors.count]
                if assigned[key] == nil { assigned[key] = color; colorIndex += 1 }
                let tokenRange = NSRange(location: token.range.location + 1, length: token.range.length)
                layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: tokenRange)
                let sheet = sheetName.flatMap { controller.workbook.sheetIndex(named: $0) } ?? sheetIndex
                highlights.append((sheet, range, color))
            }
        }
        container.gridView.referenceHighlights = highlights
        updateHints()
    }

    private func updateHints() {
        guard isActive, let window = container.window else { hints.hide(); return }
        let textView = activeTextView
        let context = FormulaContext.analyze(textView.string, caret: textView.selectedRange().location)
        let anchor: NSRect
        if formulaBar?.activeFieldEditor != nil, let bar = formulaBar {
            anchor = bar.fieldFrameInWindow
        } else {
            anchor = editorView.convert(editorView.bounds, to: nil)
        }
        hints.update(context, below: anchor, in: window)
    }

    private func acceptSuggestion(_ spec: FunctionSpec, range: NSRange) {
        let textView = activeTextView
        let replacement = spec.name + "("
        if textView.shouldChangeText(in: range, replacementString: replacement) {
            textView.replaceCharacters(in: range, with: replacement)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: range.location + (replacement as NSString).length, length: 0))
        }
        hints.hide()
        updateHints()
    }

    // MARK: - Pointing at references

    var activeTextView: NSTextView {
        formulaBar?.activeFieldEditor ?? editorView
    }

    /// True when the caret sits where a reference could go (after an operator, "(" or ",").
    var canInsertReference: Bool {
        guard isActive, isFormula else { return false }
        let textView = activeTextView
        let selection = textView.selectedRange()
        if let pointRange, NSMaxRange(pointRange) == selection.location || NSEqualRanges(pointRange, selection) { return true }
        let units = Array(textView.string.utf16)
        var i = min(selection.location, units.count) - 1
        while i >= 0, units[i] == 32 { i -= 1 }
        guard i >= 0, let scalar = UnicodeScalar(units[i]) else { return false }
        return "=(,;+-*/^&<>:".unicodeScalars.contains(scalar)
    }

    private var insertingReference = false

    func insertReference(_ range: CellRange, extend: Bool) {
        let textView = activeTextView
        var referenceText = range.isSingleCell ? range.start.a1 : range.a1
        if controller.activeSheetIndex != sheetIndex {
            referenceText = quotedSheetName(controller.sheet.name) + "!" + referenceText
        }
        let selection = textView.selectedRange()
        let target: NSRange
        if let pointRange, NSMaxRange(pointRange) == selection.location || NSEqualRanges(pointRange, selection) {
            target = pointRange
        } else {
            target = selection
        }
        insertingReference = true
        if textView.shouldChangeText(in: target, replacementString: referenceText) {
            textView.replaceCharacters(in: target, with: referenceText)
            textView.didChangeText()
        }
        insertingReference = false
        let inserted = NSRange(location: target.location, length: (referenceText as NSString).length)
        pointRange = inserted
        textView.setSelectedRange(NSRange(location: NSMaxRange(inserted), length: 0))
        if textView !== editorView { formulaBarTextChanged(textView.string) }
        refreshDecorations()
        container.window?.makeFirstResponder(textView)
    }

    /// Arrow keys in point mode move (or with Shift, extend) the pointed reference.
    private func movePointer(rows: Int, columns: Int, extend: Bool) {
        let cursor = pointCursor ?? address
        let next = CellAddress(row: cursor.row + rows, column: cursor.column + columns).clamped()
        if !extend || pointAnchor == nil { pointAnchor = extend ? cursor : next }
        pointCursor = next
        let range = extend ? CellRange(pointAnchor ?? next, next) : CellRange(next)
        if !extend { pointAnchor = next }
        insertReference(range, extend: extend)
        container.scrollToCell(next)
    }

    func toggleAbsoluteReference(in textView: NSTextView) {
        guard textView.string.hasPrefix("=") else { return }
        let body = String(textView.string.dropFirst())
        let caret = max(textView.selectedRange().location - 1, 0)
        guard let (updated, range) = FormulaRewriter.toggleAbsolute(body, caret: caret) else { return }
        let full = NSRange(location: 0, length: (textView.string as NSString).length)
        if textView.shouldChangeText(in: full, replacementString: "=" + updated) {
            textView.replaceCharacters(in: full, with: "=" + updated)
            textView.didChangeText()
        }
        textView.setSelectedRange(NSRange(location: NSMaxRange(range) + 1, length: 0))
        pointRange = nil
    }

    // MARK: - Keys

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        handleCommand(selector, in: textView)
    }

    /// Shared key handling for the cell editor and the formula bar.
    func handleCommand(_ selector: Selector, in textView: NSTextView) -> Bool {
        let flags = NSApp.currentEvent?.modifierFlags.intersection([.command, .shift, .option, .control]) ?? []
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if flags.contains(.control) || flags.contains(.command) {
                commit(move: nil, fillSelection: !controller.selection.isSingleCell)
            } else if flags.contains(.option) {
                textView.insertText("\n", replacementRange: textView.selectedRange())
            } else {
                commit(move: nil, reverseEnter: flags.contains(.shift), useEnterDirection: true)
            }
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), #selector(NSResponder.insertLineBreak(_:)):
            textView.insertText("\n", replacementRange: textView.selectedRange())
            return true
        case #selector(NSResponder.insertTab(_:)):
            if hints.isShowingList, let item = hints.selectedItem {
                acceptSuggestion(item, range: hints.replaceRange)
                return true
            }
            commit(move: (0, 1))
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            commit(move: (0, -1))
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if hints.isShowingList { hints.hide(); return true }
            cancel()
            return true
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
            if hints.isShowingList {
                hints.moveSelection(selector == #selector(NSResponder.moveUp(_:)) ? -1 : 1)
                return true
            }
            return arrow(selector == #selector(NSResponder.moveUp(_:)) ? (-1, 0) : (1, 0), extend: false, textView: textView)
        case #selector(NSResponder.moveLeft(_:)):
            return arrow((0, -1), extend: false, textView: textView)
        case #selector(NSResponder.moveRight(_:)):
            return arrow((0, 1), extend: false, textView: textView)
        case #selector(NSResponder.moveUpAndModifySelection(_:)):
            return arrow((-1, 0), extend: true, textView: textView)
        case #selector(NSResponder.moveDownAndModifySelection(_:)):
            return arrow((1, 0), extend: true, textView: textView)
        case #selector(NSResponder.moveLeftAndModifySelection(_:)):
            return arrow((0, -1), extend: true, textView: textView)
        case #selector(NSResponder.moveRightAndModifySelection(_:)):
            return arrow((0, 1), extend: true, textView: textView)
        default:
            return false
        }
    }

    private func arrow(_ delta: (Int, Int), extend: Bool, textView: NSTextView) -> Bool {
        // Point mode: arrows pick a reference.
        if isFormula, canInsertReference, mode == .enter || pointRange != nil {
            movePointer(rows: delta.0, columns: delta.1, extend: extend)
            return true
        }
        // Enter mode: arrows finish the entry and move.
        if mode == .enter && !extend && textView === editorView {
            commit(move: delta)
            return true
        }
        return false
    }
}
