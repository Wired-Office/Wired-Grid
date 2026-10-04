import AppKit

/// Builds the application's main menu in code (no nib required).
///
/// Items are nil-targeted so they travel the responder chain:
/// grid (or cell editor) → workbook view controller → window → window controller →
/// document → app delegate → document controller.
enum MainMenuBuilder {
    typealias VC = WorkbookViewController

    static func build(recentDocumentsDelegate: NSMenuDelegate) -> NSMenu {
        let main = NSMenu(title: "Main Menu")
        main.addItem(submenuItem(appMenu()))
        main.addItem(submenuItem(fileMenu(recentDocumentsDelegate: recentDocumentsDelegate)))
        main.addItem(submenuItem(editMenu()))
        main.addItem(submenuItem(viewMenu()))
        main.addItem(submenuItem(insertMenu()))
        main.addItem(submenuItem(formatMenu()))
        main.addItem(submenuItem(dataMenu()))
        let window = windowMenu()
        main.addItem(submenuItem(window))
        NSApp.windowsMenu = window
        let help = NSMenu(title: "Help")
        help.addItem(item("Wired Grid Function Reference", #selector(AppDelegate.showFunctionReference(_:))))
        main.addItem(submenuItem(help))
        NSApp.helpMenu = help
        return main
    }

    // MARK: - Menus

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Wired Grid")
        menu.addItem(item("About Wired Grid", #selector(AppDelegate.showAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ","))
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        menu.addItem(submenuItem(services))
        menu.addItem(.separator())
        menu.addItem(item("Hide Wired Grid", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit Wired Grid", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu(recentDocumentsDelegate: NSMenuDelegate) -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("New", #selector(NSDocumentController.newDocument(_:)), "n"))
        menu.addItem(item("New from Template…", #selector(AppDelegate.showTemplateChooser(_:)), "n", [.command, .shift]))
        menu.addItem(item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"))
        let recent = NSMenu(title: "Open Recent")
        recent.delegate = recentDocumentsDelegate
        menu.addItem(submenuItem(recent))
        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(item("Save", #selector(NSDocument.save(_:)), "s"))
        menu.addItem(item("Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift]))
        menu.addItem(item("Duplicate", #selector(NSDocument.duplicate(_:))))
        menu.addItem(item("Rename…", #selector(NSDocument.rename(_:))))
        menu.addItem(item("Move To…", #selector(NSDocument.move(_:))))
        menu.addItem(item("Revert To", #selector(NSDocument.browseVersions(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Import Text/CSV…", #selector(VC.importDelimited(_:))))
        let export = NSMenu(title: "Export To")
        export.addItem(item("PDF…", #selector(GridDocument.exportPDF(_:))))
        for format in DocumentFormat.allCases where !format.isNative {
            let entry = item(format.displayName + "…", #selector(GridDocument.exportAs(_:)))
            entry.representedObject = format.rawValue
            export.addItem(entry)
        }
        menu.addItem(submenuItem(export))
        menu.addItem(.separator())
        menu.addItem(item("Page Setup…", #selector(NSDocument.runPageLayout(_:)), "p", [.command, .shift]))
        menu.addItem(item("Print…", #selector(NSDocument.printDocument(_:)), "p"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        let special = NSMenu(title: "Paste Special")
        special.addItem(item("Paste Values", #selector(VC.pasteValues(_:)), "v", [.command, .shift]))
        special.addItem(item("Paste Formatting", #selector(VC.pasteFormatting(_:)), "v", [.command, .option]))
        special.addItem(item("Paste Transposed", #selector(VC.pasteTransposed(_:))))
        for mode in [PasteMode.formulas, .valuesAndNumberFormats, .noBorders, .columnWidths, .link] {
            let entry = item(mode.title, #selector(VC.pasteSpecialMode(_:)))
            entry.representedObject = mode.rawValue
            special.addItem(entry)
        }
        menu.addItem(submenuItem(special))
        menu.addItem(item("Delete", #selector(NSText.delete(_:))))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())
        let fill = NSMenu(title: "Fill")
        fill.addItem(item("Down", #selector(VC.fillDown(_:)), "d"))
        fill.addItem(item("Right", #selector(VC.fillRight(_:)), "r"))
        menu.addItem(submenuItem(fill))
        let clear = NSMenu(title: "Clear")
        clear.addItem(item("All", #selector(VC.clearAll(_:))))
        clear.addItem(item("Formats", #selector(VC.clearFormats(_:))))
        clear.addItem(item("Contents", #selector(NSText.delete(_:))))
        menu.addItem(submenuItem(clear))
        menu.addItem(item("Edit Cell", #selector(VC.editActiveCell(_:)), "u", [.control]))
        menu.addItem(.separator())
        let find = NSMenu(title: "Find")
        find.addItem(item("Find…", #selector(VC.findCells(_:)), "f"))
        find.addItem(item("Replace…", #selector(VC.replaceCells(_:)), "h", [.control]))
        find.addItem(item("Find Next", #selector(VC.findNextMatch(_:)), "g"))
        find.addItem(item("Find Previous", #selector(VC.findPreviousMatch(_:)), "g", [.command, .shift]))
        find.addItem(item("Go To…", #selector(VC.goToCell(_:)), "g", [.control]))
        menu.addItem(submenuItem(find))
        menu.addItem(.separator())
        menu.addItem(item("Emoji & Symbols", #selector(NSApplication.orderFrontCharacterPalette(_:)), " ", [.command, .control]))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Zoom In", #selector(VC.zoomIn(_:)), "+"))
        menu.addItem(item("Zoom Out", #selector(VC.zoomOut(_:)), "-"))
        menu.addItem(item("Actual Size", #selector(VC.actualSize(_:)), "0"))
        menu.addItem(item("Zoom to Selection", #selector(VC.zoomToSelection(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Formula Bar", #selector(VC.toggleFormulaBar(_:))))
        menu.addItem(item("Status Bar", #selector(VC.toggleStatusBar(_:))))
        menu.addItem(item("Collapse Ribbon", #selector(VC.toggleRibbon(_:)), "r", [.command, .option]))
        menu.addItem(item("Gridlines", #selector(VC.toggleGridlines(_:))))
        menu.addItem(item("Headings", #selector(VC.toggleHeadings(_:))))
        menu.addItem(item("Formulas", #selector(VC.toggleShowFormulas(_:)), "`", [.control]))
        menu.addItem(.separator())
        menu.addItem(item("Freeze Panes", #selector(VC.freezePanes(_:))))
        menu.addItem(item("Freeze Top Row", #selector(VC.freezeTopRow(_:))))
        menu.addItem(item("Freeze First Column", #selector(VC.freezeFirstColumn(_:))))
        menu.addItem(.separator())
        let tabs = NSMenu(title: "Ribbon Tab")
        for (index, tab) in RibbonModel.Tab.allCases.enumerated() {
            let entry = item(tab.title, #selector(VC.showRibbonTab(_:)), "\(index + 1)", [.command, .control])
            entry.representedObject = tab.rawValue
            tabs.addItem(entry)
        }
        menu.addItem(submenuItem(tabs))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func insertMenu() -> NSMenu {
        let menu = NSMenu(title: "Insert")
        menu.addItem(item("Rows", #selector(VC.insertRows(_:)), "+", [.command, .shift]))
        menu.addItem(item("Columns", #selector(VC.insertColumns(_:))))
        menu.addItem(item("Cells (Shift Down)", #selector(VC.insertCellsDown(_:))))
        menu.addItem(item("Sheet", #selector(VC.insertSheet(_:)), "t", [.command, .shift, .option]))
        menu.addItem(.separator())
        let charts = NSMenu(title: "Chart")
        for kind in ChartKind.allCases {
            let entry = item(kind.title, #selector(VC.insertChart(_:)))
            entry.representedObject = kind.rawValue
            entry.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)
            charts.addItem(entry)
        }
        menu.addItem(submenuItem(charts))
        menu.addItem(item("Function…", #selector(VC.insertFunctionDialog(_:)), "f", [.command, .shift, .option]))
        menu.addItem(item("AutoSum", #selector(VC.autoSum(_:)), "t", [.command, .shift]))
        menu.addItem(item("Note", #selector(VC.insertNote(_:)), "m", [.command, .shift]))
        menu.addItem(item("Hyperlink…", #selector(VC.insertHyperlink(_:)), "k"))
        menu.addItem(item("Name…", #selector(VC.defineName(_:)), "l", [.command, .shift, .option]))
        menu.addItem(.separator())
        menu.addItem(item("Today's Date", #selector(VC.insertDate(_:)), ";"))
        menu.addItem(item("Current Time", #selector(VC.insertTime(_:)), ";", [.command, .shift]))
        return menu
    }

    private static func formatMenu() -> NSMenu {
        let menu = NSMenu(title: "Format")
        menu.addItem(item("Cells…", #selector(VC.formatCells(_:)), "1"))
        menu.addItem(.separator())
        let font = NSMenu(title: "Font")
        font.addItem(item("Bold", #selector(VC.toggleBold(_:)), "b"))
        font.addItem(item("Italic", #selector(VC.toggleItalic(_:)), "i"))
        font.addItem(item("Underline", #selector(VC.toggleUnderline(_:)), "u"))
        font.addItem(item("Strikethrough", #selector(VC.toggleStrikethrough(_:)), "x", [.command, .shift]))
        font.addItem(.separator())
        font.addItem(item("Bigger", #selector(VC.increaseFontSize(_:)), ">", [.command, .shift]))
        font.addItem(item("Smaller", #selector(VC.decreaseFontSize(_:)), "<", [.command, .shift]))
        menu.addItem(submenuItem(font))
        let alignment = NSMenu(title: "Alignment")
        alignment.addItem(item("Align Left", #selector(VC.alignLeftCells(_:)), "l"))
        alignment.addItem(item("Center", #selector(VC.alignCenterCells(_:)), "e"))
        alignment.addItem(item("Align Right", #selector(VC.alignRightCells(_:))))
        alignment.addItem(.separator())
        alignment.addItem(item("Wrap Text", #selector(VC.toggleWrapText(_:))))
        alignment.addItem(item("Merge & Center", #selector(VC.mergeCells(_:))))
        menu.addItem(submenuItem(alignment))
        let number = NSMenu(title: "Number")
        for preset in NumberFormatPreset.allCases {
            let entry = item(preset.title, #selector(VC.applyNumberPreset(_:)))
            entry.representedObject = preset.rawValue
            number.addItem(entry)
        }
        number.addItem(.separator())
        number.addItem(item("Increase Decimal", #selector(VC.increaseDecimal(_:))))
        number.addItem(item("Decrease Decimal", #selector(VC.decreaseDecimal(_:))))
        menu.addItem(submenuItem(number))
        menu.addItem(.separator())
        let row = NSMenu(title: "Row")
        row.addItem(item("Height…", #selector(VC.rowHeight(_:))))
        row.addItem(item("AutoFit", #selector(VC.autoFitRows(_:))))
        row.addItem(item("Hide", #selector(VC.hideRows(_:)), "9", [.control]))
        row.addItem(item("Unhide", #selector(VC.unhideRows(_:)), "9", [.control, .shift]))
        menu.addItem(submenuItem(row))
        let column = NSMenu(title: "Column")
        column.addItem(item("Width…", #selector(VC.columnWidth(_:))))
        column.addItem(item("AutoFit Selection", #selector(VC.autoFitColumns(_:))))
        column.addItem(item("Hide", #selector(VC.hideColumns(_:)), "0", [.control]))
        column.addItem(item("Unhide", #selector(VC.unhideColumns(_:)), "0", [.control, .shift]))
        menu.addItem(submenuItem(column))
        let sheet = NSMenu(title: "Sheet")
        sheet.addItem(item("Rename", #selector(VC.renameSheet(_:))))
        sheet.addItem(item("Duplicate", #selector(VC.duplicateSheet(_:))))
        sheet.addItem(item("Delete", #selector(VC.deleteSheet(_:))))
        sheet.addItem(.separator())
        sheet.addItem(item("Next Sheet", #selector(VC.nextSheet(_:)), String(Character(UnicodeScalar(NSPageDownFunctionKey)!)), [.option]))
        sheet.addItem(item("Previous Sheet", #selector(VC.previousSheet(_:)), String(Character(UnicodeScalar(NSPageUpFunctionKey)!)), [.option]))
        menu.addItem(submenuItem(sheet))
        menu.addItem(.separator())
        menu.addItem(item("Conditional Formatting…", #selector(VC.conditionalFormatting(_:))))
        menu.addItem(item("Manage Rules…", #selector(VC.manageRules(_:))))
        return menu
    }

    private static func dataMenu() -> NSMenu {
        let menu = NSMenu(title: "Data")
        menu.addItem(item("Sort Ascending", #selector(VC.sortAscending(_:))))
        menu.addItem(item("Sort Descending", #selector(VC.sortDescending(_:))))
        menu.addItem(item("Custom Sort…", #selector(VC.customSort(_:)), "r", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Filter", #selector(VC.toggleFilter(_:)), "f", [.command, .shift]))
        menu.addItem(item("Clear Filter", #selector(VC.clearFilter(_:))))
        menu.addItem(item("Reapply Filter", #selector(VC.reapplyFilter(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Text to Columns…", #selector(VC.textToColumns(_:))))
        menu.addItem(item("Remove Duplicates", #selector(VC.removeDuplicates(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Calculate Now", #selector(VC.calculateNow(_:)), "="))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    // MARK: - Helpers

    static func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        return item
    }

    static func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
