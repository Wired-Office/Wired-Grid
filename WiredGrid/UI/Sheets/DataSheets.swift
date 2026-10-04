import SwiftUI

// MARK: - Find & Replace

/// Shared find options, so ⌘G repeats the last search.
final class FindReplaceModel: ObservableObject {
    static let shared = FindReplaceModel()
    @Published var options = FindOptions()
    @Published var message = ""
    @Published var results: [(sheet: Int, address: CellAddress, text: String)] = []
}

final class FindReplaceWindowController: NSWindowController {
    static let shared = FindReplaceWindowController()
    private weak var controller: WorkbookController?

    private init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 250), styleMask: [.titled, .closable, .utilityWindow, .resizable], backing: .buffered, defer: true)
        panel.title = "Find & Replace"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = true
        super.init(window: panel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(for controller: WorkbookController, replace: Bool) {
        self.controller = controller
        let selected = controller.selection
        if !selected.isSingleCell || FindReplaceModel.shared.options.text.isEmpty {
            // Seed with the active cell's text? Excel keeps the last search; so do we.
        }
        window?.contentViewController = NSHostingController(rootView: FindReplaceView(controller: controller, model: FindReplaceModel.shared, showReplace: replace) { [weak self] in
            self?.close()
        })
        if window?.isVisible == false { window?.center() }
        showWindow(nil)
        window?.makeKey()
    }
}

struct FindReplaceView: View {
    let controller: WorkbookController
    @ObservedObject var model: FindReplaceModel
    @State var showReplace: Bool
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $showReplace) {
                Text("Find").tag(false)
                Text("Replace").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)

            TextField("Find what", text: $model.options.text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { find() }
            if showReplace {
                TextField("Replace with", text: $model.options.replacement)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 16) {
                Toggle("Match case", isOn: $model.options.matchCase)
                Toggle("Entire cell", isOn: $model.options.entireCell)
                Picker("", selection: $model.options.searchFormulas) {
                    Text("Formulas").tag(true)
                    Text("Values").tag(false)
                }
                .labelsHidden()
                .frame(width: 100)
                Picker("", selection: $model.options.wholeWorkbook) {
                    Text("Sheet").tag(false)
                    Text("Workbook").tag(true)
                }
                .labelsHidden()
                .frame(width: 110)
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 12))

            if !model.results.isEmpty {
                List(model.results.indices, id: \.self) { i in
                    let result = model.results[i]
                    Button {
                        if controller.activeSheetIndex != result.sheet { controller.activateSheet(result.sheet) }
                        controller.select(result.address)
                    } label: {
                        HStack {
                            Text(controller.sheets[result.sheet].name).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                            Text(result.address.a1).monospaced().frame(width: 56, alignment: .leading)
                            Text(result.text).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(minHeight: 120)
            }

            HStack {
                Text(model.message).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if showReplace {
                    Button("Replace All") {
                        let count = controller.replaceAll(model.options)
                        model.message = count == 0 ? "No matches" : "Replaced \(count) cell\(count == 1 ? "" : "s")"
                    }
                    Button("Replace") { controller.replaceCurrent(model.options) }
                }
                Button("Find All") {
                    model.results = controller.findAll(model.options).prefix(500).map { ($0.sheet, $0.address, controller.inputText(at: $0.address, sheetIndex: $0.sheet)) }
                    model.message = "\(model.results.count) cell\(model.results.count == 1 ? "" : "s") found"
                }
                Button("Find Next") { find() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 460)
    }

    private func find() {
        model.message = controller.findNext(model.options) ? "" : "No matches for “\(model.options.text)”"
    }
}

// MARK: - Sort

struct SortSheet: View {
    let controller: WorkbookController
    let dismiss: () -> Void

    @State private var range = CellRange(.origin)
    @State private var hasHeader = true
    @State private var keys: [SortKey] = []

    private func columnName(_ column: Int) -> String {
        if hasHeader {
            let header = controller.displayText(at: CellAddress(row: range.minRow, column: column))
            if !header.isEmpty { return header }
        }
        return "Column " + CellAddress.columnName(column)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sort \(range.a1)").font(.headline)
            Toggle("My data has headers", isOn: $hasHeader).toggleStyle(.checkbox)
            ForEach($keys) { $key in
                HStack {
                    Text(key.id == keys.first?.id ? "Sort by" : "Then by").frame(width: 60, alignment: .leading)
                    Picker("", selection: $key.column) {
                        ForEach(Array(range.columns), id: \.self) { Text(columnName($0)).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    Picker("", selection: $key.ascending) {
                        Text("A → Z / Smallest first").tag(true)
                        Text("Z → A / Largest first").tag(false)
                    }
                    .labelsHidden()
                    .frame(width: 190)
                    Button {
                        keys.removeAll { $0.id == key.id }
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.plain)
                    .disabled(keys.count == 1)
                }
            }
            Button {
                keys.append(SortKey(column: range.minColumn))
            } label: { Label("Add Level", systemImage: "plus") }
            HStack {
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Sort") {
                    controller.sort(range, keys: keys, hasHeader: hasHeader)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            range = controller.dataRangeForCommand
            hasHeader = controller.looksLikeHeader(range)
            let column = range.columns.contains(controller.selection.active.column) ? controller.selection.active.column : range.minColumn
            keys = [SortKey(column: column)]
        }
    }
}

// MARK: - Text to Columns

struct TextToColumnsSheet: View {
    let controller: WorkbookController
    let dismiss: () -> Void
    @State private var delimiter = ","
    @State private var custom = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Split Text into Columns").font(.headline)
            Text("Splits each cell in \(controller.selection.primary.a1) at the delimiter, filling the columns to the right.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Delimiter", selection: $delimiter) {
                Text("Comma").tag(",")
                Text("Tab").tag("\t")
                Text("Semicolon").tag(";")
                Text("Space").tag(" ")
                Text("Other").tag("other")
            }
            .pickerStyle(.radioGroup)
            if delimiter == "other" {
                TextField("Delimiter", text: $custom).textFieldStyle(.roundedBorder).frame(width: 80)
            }
            HStack {
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Split") {
                    controller.textToColumns(delimiter: delimiter == "other" ? custom : delimiter)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(delimiter == "other" && custom.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

// MARK: - Prompts

struct PromptSheet: View {
    let title: String
    let message: String
    let initial: String
    let dismiss: () -> Void
    let onCommit: (String) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button("OK", action: commit).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear { text = initial }
    }

    private func commit() {
        dismiss()
        onCommit(text)
    }
}

struct NoteEditorSheet: View {
    let address: CellAddress
    let initial: String
    let dismiss: () -> Void
    let onCommit: (String?) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Note for \(address.a1)", systemImage: "note.text").font(.headline)
            TextEditor(text: $text)
                .font(.system(size: 13))
                .frame(width: 360, height: 140)
                .padding(4)
                .background(Color(nsColor: NSColor(srgbRed: 1, green: 0.98, blue: 0.82, alpha: 1)))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
            HStack {
                if !initial.isEmpty {
                    Button("Delete Note", role: .destructive) { dismiss(); onCommit(nil) }
                }
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Save") { dismiss(); onCommit(text) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear { text = initial }
    }
}

// MARK: - Page setup

struct PageSetupSheet: View {
    let controller: WorkbookController
    let dismiss: () -> Void
    @State private var setup = PageSetup()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Picker("Orientation", selection: $setup.orientation) {
                    Text("Portrait").tag(PageSetup.Orientation.portrait)
                    Text("Landscape").tag(PageSetup.Orientation.landscape)
                }
                .pickerStyle(.segmented)
                Picker("Scaling", selection: $setup.scaling) {
                    Text("Actual size").tag(PageSetup.Scaling.actual)
                    Text("Fit all columns on one page").tag(PageSetup.Scaling.fitWidth)
                    Text("Fit sheet on one page").tag(PageSetup.Scaling.fitPage)
                }
                Picker("Margins", selection: $setup.margin) {
                    Text("Narrow (0.25\")").tag(18.0)
                    Text("Normal (0.5\")").tag(36.0)
                    Text("Wide (1\")").tag(72.0)
                }
                Toggle("Print gridlines", isOn: $setup.printGridlines)
                Toggle("Print row and column headings", isOn: $setup.printHeadings)
                Toggle("Center horizontally", isOn: $setup.centerHorizontally)
                LabeledContent("Print area") {
                    HStack {
                        Text(setup.printArea?.a1 ?? "Used range").foregroundStyle(.secondary)
                        if setup.printArea != nil { Button("Clear") { setup.printArea = nil } }
                        Button("Use Selection") { setup.printArea = controller.boundedToContent(controller.selection.primary) }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button("OK") { controller.updatePageSetup(setup); dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 460)
        .onAppear { setup = controller.sheet.pageSetup }
    }
}
