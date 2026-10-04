import AppKit
import SwiftUI

// MARK: - Insert

struct InsertTab: View {
    @ObservedObject var controller: WorkbookController

    var body: some View {
        HStack(spacing: 0) {
            CaptionedGroup(title: "Tables") {
                RibbonLargeButton(title: "Table", symbol: "tablecells", help: "Format the data around the selection as a table") {
                    controller.formatAsTable(.green)
                }
            }
            CaptionedGroup(title: "Charts") {
                RibbonLargeButton(title: "Column", symbol: ChartKind.column.symbol, menu: {
                    let menu = NSMenu()
                    menu.add("Clustered Column", symbol: ChartKind.column.symbol) { controller.insertChart(.column) }
                    menu.add("Stacked Column", symbol: ChartKind.stackedColumn.symbol) { controller.insertChart(.stackedColumn) }
                    return menu
                }) { controller.insertChart(.column) }
                RibbonLargeButton(title: "Bar", symbol: ChartKind.bar.symbol) { controller.insertChart(.bar) }
                RibbonLargeButton(title: "Line", symbol: ChartKind.line.symbol) { controller.insertChart(.line) }
                RibbonLargeButton(title: "Area", symbol: ChartKind.area.symbol) { controller.insertChart(.area) }
                RibbonLargeButton(title: "Pie", symbol: ChartKind.pie.symbol, menu: {
                    let menu = NSMenu()
                    menu.add("Pie", symbol: ChartKind.pie.symbol) { controller.insertChart(.pie) }
                    menu.add("Doughnut", symbol: ChartKind.doughnut.symbol) { controller.insertChart(.doughnut) }
                    return menu
                }) { controller.insertChart(.pie) }
                RibbonLargeButton(title: "Scatter", symbol: ChartKind.scatter.symbol) { controller.insertChart(.scatter) }
            }
            CaptionedGroup(title: "Links & Notes") {
                RibbonLargeButton(title: "Link", symbol: "link") {
                    let address = controller.selection.active
                    controller.presenter?.presentTextPrompt(title: "Insert Hyperlink", message: "Address (web page, email or #Sheet!A1):",
                                                            value: controller.sheet.cells[address]?.link ?? "https://") { url in
                        controller.setLink(url, at: address, displayText: nil)
                    }
                }
                RibbonLargeButton(title: "Note", symbol: "note.text.badge.plus") {
                    controller.presenter?.presentNoteEditor(at: controller.selection.active)
                }
            }
            CaptionedGroup(title: "Text", showsDivider: false) {
                RibbonColumn {
                    RibbonCompactButton(title: "Date", symbol: "calendar", help: "Insert today's date (⌘;)") { controller.insertCurrentDate() }
                    RibbonCompactButton(title: "Time", symbol: "clock", help: "Insert the current time (⇧⌘;)") { controller.insertCurrentTime() }
                    RibbonCompactButton(title: "Symbol", symbol: "character", help: "Emoji & Symbols") { NSApp.orderFrontCharacterPalette(nil) }
                }
                RibbonLargeButton(title: "Function", symbol: "function") { controller.presenter?.presentInsertFunction(category: nil) }
            }
        }
    }
}

// MARK: - Page Layout

struct PageLayoutTab: View {
    @ObservedObject var controller: WorkbookController

    private var setup: PageSetup { controller.sheet.pageSetup }

    private func update(_ change: (inout PageSetup) -> Void) {
        var copy = setup
        change(&copy)
        controller.updatePageSetup(copy)
    }

    var body: some View {
        HStack(spacing: 0) {
            CaptionedGroup(title: "Page Setup") {
                RibbonLargeButton(title: "Margins", symbol: "rectangle.inset.filled", menu: {
                    let menu = NSMenu()
                    for (title, points) in [("Narrow", 18.0), ("Normal", 36.0), ("Wide", 72.0)] {
                        menu.add(title, checked: setup.margin == points) { update { $0.margin = points } }
                    }
                    return menu
                })
                RibbonLargeButton(title: "Orientation", symbol: setup.orientation == .portrait ? "doc" : "doc.plaintext", menu: {
                    let menu = NSMenu()
                    menu.add("Portrait", symbol: "doc", checked: setup.orientation == .portrait) { update { $0.orientation = .portrait } }
                    menu.add("Landscape", symbol: "rectangle", checked: setup.orientation == .landscape) { update { $0.orientation = .landscape } }
                    return menu
                })
                RibbonLargeButton(title: "Print Area", symbol: "printer.dotmatrix", menu: {
                    let menu = NSMenu()
                    menu.add("Set Print Area") { controller.setPrintArea() }
                    menu.add("Clear Print Area", enabled: setup.printArea != nil) { controller.clearPrintArea() }
                    return menu
                })
                RibbonLargeButton(title: "Page Setup", symbol: "doc.badge.gearshape") { controller.presenter?.presentPageSetup() }
            }
            CaptionedGroup(title: "Scale to Fit") {
                RibbonColumn {
                    RibbonCompactButton(title: "Actual Size", symbol: "1.magnifyingglass", isOn: setup.scaling == .actual) { update { $0.scaling = .actual } }
                    RibbonCompactButton(title: "Fit All Columns on One Page", symbol: "arrow.left.and.right.square", isOn: setup.scaling == .fitWidth) { update { $0.scaling = .fitWidth } }
                    RibbonCompactButton(title: "Fit Sheet on One Page", symbol: "arrow.up.left.and.arrow.down.right.square", isOn: setup.scaling == .fitPage) { update { $0.scaling = .fitPage } }
                }
            }
            CaptionedGroup(title: "Sheet Options", showsDivider: false) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Gridlines").font(.system(size: 11, weight: .medium))
                    Toggle("View", isOn: Binding(get: { controller.sheet.showGridlines }, set: { _ in controller.toggleGridlines() }))
                    Toggle("Print", isOn: Binding(get: { setup.printGridlines }, set: { v in update { $0.printGridlines = v } }))
                }
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5))
                .padding(.horizontal, 6)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Headings").font(.system(size: 11, weight: .medium))
                    Toggle("View", isOn: Binding(get: { controller.sheet.showHeadings }, set: { _ in controller.toggleHeadings() }))
                    Toggle("Print", isOn: Binding(get: { setup.printHeadings }, set: { v in update { $0.printHeadings = v } }))
                }
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5))
                .padding(.horizontal, 6)
            }
        }
    }
}

// MARK: - Formulas

struct FormulasTab: View {
    @ObservedObject var controller: WorkbookController

    private func functionMenu(_ categories: [FunctionCategory]) -> NSMenu {
        let menu = NSMenu()
        for category in categories {
            if categories.count > 1 {
                let sub = NSMenu(title: category.rawValue)
                for spec in FunctionLibrary.shared.functions(in: category) {
                    let item = sub.add(spec.name) { controller.insertFunctionHandler?(spec.name) }
                    item.toolTip = spec.syntax + "\n" + spec.summary
                }
                menu.addSubmenu(sub)
            } else {
                for spec in FunctionLibrary.shared.functions(in: category) {
                    let item = menu.add(spec.name) { controller.insertFunctionHandler?(spec.name) }
                    item.toolTip = spec.syntax + "\n" + spec.summary
                }
            }
        }
        menu.addItem(.separator())
        menu.add("Insert Function…", symbol: "function") { controller.presenter?.presentInsertFunction(category: categories.first) }
        return menu
    }

    var body: some View {
        HStack(spacing: 0) {
            CaptionedGroup(title: "Function Library") {
                RibbonLargeButton(title: "Insert Function", symbol: "function") { controller.presenter?.presentInsertFunction(category: nil) }
                RibbonLargeButton(title: "AutoSum", symbol: "sum", menu: { AutoSumMenu.make(controller) }) { controller.autoSum() }
                RibbonLargeButton(title: "Financial", symbol: FunctionCategory.financial.symbol, menu: { functionMenu([.financial]) })
                RibbonLargeButton(title: "Logical", symbol: FunctionCategory.logical.symbol, menu: { functionMenu([.logical]) })
                RibbonLargeButton(title: "Text", symbol: FunctionCategory.text.symbol, menu: { functionMenu([.text]) })
                RibbonLargeButton(title: "Date & Time", symbol: FunctionCategory.date.symbol, menu: { functionMenu([.date]) })
                RibbonLargeButton(title: "Lookup", symbol: FunctionCategory.lookup.symbol, menu: { functionMenu([.lookup]) })
                RibbonLargeButton(title: "Math & Trig", symbol: "x.squareroot", menu: { functionMenu([.math]) })
                RibbonLargeButton(title: "More", symbol: "ellipsis.circle", menu: { functionMenu([.statistical, .information]) })
            }
            CaptionedGroup(title: "Defined Names") {
                RibbonLargeButton(title: "Name Manager", symbol: "tag") { controller.presenter?.presentNameManager() }
                RibbonColumn {
                    RibbonCompactButton(title: "Define Name", symbol: "plus") {
                        controller.presenter?.presentTextPrompt(title: "Define Name", message: "Name for \(controller.selection.primary.a1):", value: "") { name in
                            _ = controller.nameSelection(name)
                        }
                    }
                    RibbonMenuButton(symbol: "text.insert", help: "Use in Formula", label: "Use in Formula") {
                        let menu = NSMenu()
                        if controller.workbook.names.isEmpty {
                            menu.add("No Names Defined", enabled: false) {}
                        }
                        for name in controller.workbook.names {
                            menu.add(name.name) { controller.insertFunctionHandler?("#NAME:" + name.name) }
                        }
                        return menu
                    }
                }
            }
            CaptionedGroup(title: "Calculation", showsDivider: false) {
                RibbonLargeButton(title: "Show Formulas", symbol: "eye", isOn: controller.showFormulas) { controller.showFormulas.toggle() }
                RibbonLargeButton(title: "Calculate Now", symbol: "arrow.clockwise") { controller.recalculate() }
            }
        }
    }
}

// MARK: - Data

struct DataTab: View {
    @ObservedObject var controller: WorkbookController

    var body: some View {
        HStack(spacing: 0) {
            CaptionedGroup(title: "Get Data") {
                RibbonLargeButton(title: "From Text/CSV", symbol: "doc.text") { NSApp.sendAction(#selector(WorkbookViewController.importDelimited(_:)), to: nil, from: nil) }
            }
            CaptionedGroup(title: "Sort & Filter") {
                RibbonColumn {
                    RibbonCompactButton(title: "A → Z", symbol: "arrow.up") { controller.quickSort(ascending: true) }
                    RibbonCompactButton(title: "Z → A", symbol: "arrow.down") { controller.quickSort(ascending: false) }
                }
                RibbonLargeButton(title: "Sort", symbol: "arrow.up.arrow.down") { controller.presenter?.presentSort() }
                RibbonLargeButton(title: "Filter", symbol: "line.3.horizontal.decrease.circle", isOn: controller.sheet.filter != nil) { controller.toggleFilter() }
                RibbonColumn {
                    RibbonCompactButton(title: "Clear", symbol: "xmark.circle", isEnabled: !(controller.sheet.filter?.criteria.isEmpty ?? true)) { controller.clearFilters() }
                    RibbonCompactButton(title: "Reapply", symbol: "arrow.clockwise", isEnabled: controller.sheet.filter != nil) { controller.reapplyFilter() }
                }
            }
            CaptionedGroup(title: "Data Tools", showsDivider: false) {
                RibbonLargeButton(title: "Text to Columns", symbol: "rectangle.split.3x1") { controller.presenter?.presentTextToColumns() }
                RibbonLargeButton(title: "Remove Duplicates", symbol: "square.stack.3d.up.slash") { controller.removeDuplicates() }
                RibbonLargeButton(title: "Flash Fill", symbol: "bolt") { controller.fill(down: true) }
            }
        }
    }
}

// MARK: - Review

struct ReviewTab: View {
    @ObservedObject var controller: WorkbookController

    var body: some View {
        HStack(spacing: 0) {
            CaptionedGroup(title: "Notes") {
                RibbonLargeButton(title: controller.note(at: controller.selection.active) == nil ? "New Note" : "Edit Note", symbol: "note.text.badge.plus") {
                    controller.presenter?.presentNoteEditor(at: controller.selection.active)
                }
                RibbonLargeButton(title: "Delete Note", symbol: "trash", isEnabled: controller.note(at: controller.selection.active) != nil) {
                    controller.setNote(nil, at: controller.selection.active)
                }
                RibbonColumn {
                    RibbonCompactButton(title: "Previous", symbol: "chevron.up") { jumpToNote(forward: false) }
                    RibbonCompactButton(title: "Next", symbol: "chevron.down") { jumpToNote(forward: true) }
                }
            }
            CaptionedGroup(title: "Proofing", showsDivider: false) {
                RibbonLargeButton(title: "Workbook Statistics", symbol: "chart.bar.doc.horizontal") { showStatistics() }
            }
        }
    }

    private func jumpToNote(forward: Bool) {
        let notes = controller.sheet.notes.keys.sorted()
        guard !notes.isEmpty else { return }
        let active = controller.selection.active
        let next = forward ? (notes.first { $0 > active } ?? notes.first!) : (notes.last { $0 < active } ?? notes.last!)
        controller.select(next)
    }

    private func showStatistics() {
        let wb = controller.workbook
        let cells = wb.sheets.reduce(0) { $0 + $1.cells.values.filter(\.hasContent).count }
        let formulas = wb.sheets.reduce(0) { $0 + $1.cells.values.filter(\.isFormula).count }
        let charts = wb.sheets.reduce(0) { $0 + $1.charts.count }
        let notes = wb.sheets.reduce(0) { $0 + $1.notes.count }
        let current = controller.sheet
        let info = """
        Current sheet — \(current.name)
          End of sheet: \(current.contentExtent.a1)
          Cells with data: \(current.cells.values.filter(\.hasContent).count)
          Formulas: \(current.cells.values.filter(\.isFormula).count)

        Workbook
          Sheets: \(wb.sheets.count)
          Cells with data: \(cells)
          Formulas: \(formulas)
          Charts: \(charts)
          Notes: \(notes)
          Defined names: \(wb.names.count)
        """
        controller.presenter?.presentAlert("Workbook Statistics", info: info)
    }
}

// MARK: - View

struct ViewTab: View {
    @ObservedObject var controller: WorkbookController
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 0) {
            CaptionedGroup(title: "Show") {
                VStack(alignment: .leading, spacing: 5) {
                    Toggle("Gridlines", isOn: Binding(get: { controller.sheet.showGridlines }, set: { _ in controller.toggleGridlines() }))
                    Toggle("Headings", isOn: Binding(get: { controller.sheet.showHeadings }, set: { _ in controller.toggleHeadings() }))
                    Toggle("Formula Bar", isOn: $settings.showFormulaBar)
                }
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5))
                .padding(.horizontal, 6)
                VStack(alignment: .leading, spacing: 5) {
                    Toggle("Formulas", isOn: $controller.showFormulas)
                    Toggle("Status Bar", isOn: $settings.showStatusBar)
                }
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5))
                .padding(.horizontal, 6)
            }
            CaptionedGroup(title: "Zoom") {
                RibbonLargeButton(title: "Zoom In", symbol: "plus.magnifyingglass") { controller.setZoom(controller.sheet.zoom * 1.25) }
                RibbonLargeButton(title: "Zoom Out", symbol: "minus.magnifyingglass") { controller.setZoom(controller.sheet.zoom / 1.25) }
                RibbonLargeButton(title: "100%", symbol: "1.magnifyingglass") { controller.setZoom(1) }
                RibbonLargeButton(title: "Zoom to Selection", symbol: "arrow.up.left.and.arrow.down.right") {
                    NSApp.sendAction(#selector(WorkbookViewController.zoomToSelection(_:)), to: nil, from: nil)
                }
            }
            CaptionedGroup(title: "Window", showsDivider: false) {
                RibbonLargeButton(title: "Freeze Panes", symbol: "snowflake", isOn: controller.hasFrozenPanes, menu: {
                    let menu = NSMenu()
                    menu.add(controller.hasFrozenPanes ? "Unfreeze Panes" : "Freeze Panes", symbol: "snowflake") { controller.freezePanes() }
                    menu.add("Freeze Top Row", symbol: "rectangle.tophalf.inset.filled") { controller.freezeTopRow() }
                    menu.add("Freeze First Column", symbol: "rectangle.lefthalf.inset.filled") { controller.freezeFirstColumn() }
                    return menu
                })
            }
        }
    }
}
