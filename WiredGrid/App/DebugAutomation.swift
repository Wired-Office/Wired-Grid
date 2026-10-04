#if DEBUG
import AppKit

/// Appends a formatted line to wg-debug.log in the temporary directory.
func debugLog(_ format: String, _ args: CVarArg...) {
    let line = String(format: format, arguments: args) + "\n"
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wg-debug.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: url)
    }
}

/// Debug-only launch hooks for exercising the UI without a mouse:
///
///     "Wired Grid.app/Contents/MacOS/Wired Grid" -WGTemplate sales -WGScript "select B5; type 123; tab; chart column"
///
/// Commands are separated by semicolons and run half a second apart.
enum DebugAutomation {
    static func runIfRequested() -> Bool {
        let defaults = UserDefaults.standard
        guard let templateID = defaults.string(forKey: "WGTemplate") else { return false }
        let template = TemplateLibrary.all.first { $0.id == templateID } ?? TemplateLibrary.blank
        (NSDocumentController.shared as? GridDocumentController)?.newDocument(from: template)
        if let script = defaults.string(forKey: "WGScript") {
            let commands = script.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            run(commands, index: 0)
        }
        return true
    }

    private static func run(_ commands: [String], index: Int) {
        guard index < commands.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            perform(commands[index])
            run(commands, index: index + 1)
        }
    }

    private static func perform(_ command: String) {
        guard let window = NSApp.orderedWindows.first(where: { $0.windowController is DocumentWindowController }),
              let windowController = window.windowController as? DocumentWindowController else { return }
        let vc = windowController.contentController
        let controller = vc.controller
        let container = vc.gridContainer!
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        switch parts.first ?? "" {
        case "select":
            if let range = CellRange(a1: argument) { controller.select(range: range) }
        case "type":
            container.beginEditing(initial: "", mode: .enter, clickPoint: nil)
            container.editing.editorView.insertText(argument, replacementRange: container.editing.editorView.selectedRange())
        case "edit":
            container.beginEditing(initial: argument, mode: .edit, clickPoint: nil)
        case "point":
            if let range = CellRange(a1: argument) { container.editing.insertReference(range, extend: false) }
        case "commit", "return":
            _ = controller.commitEditingIfNeeded()
        case "tab":
            container.editing.commit(move: (0, 1))
        case "chart":
            if let kind = ChartKind(rawValue: argument) { controller.insertChart(kind) }
        case "ribbon":
            if let tab = RibbonModel.Tab(rawValue: argument) { vc.ribbonModel.tab = tab }
        case "zoom":
            controller.setZoom(Double(argument) ?? 1)
        case "filter":
            controller.toggleFilter()
        case "sheet":
            controller.activateSheet(Int(argument) ?? 0)
        case "copy":
            controller.copySelection()
        case "paste":
            controller.paste()
        case "fill":
            if let range = CellRange(a1: argument) { controller.autoFill(from: controller.selection.primary, to: range) }
        case "drag", "click":
            // drag B2 D6  → synthesized mouse events from the center of B2 to the center of D6
            let cells = argument.split(separator: " ").compactMap { CellAddress(a1: String($0)) }
            guard let first = cells.first else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            let grid = container.gridView
            let g = grid.geometry
            func windowPoint(_ a: CellAddress) -> CGPoint {
                let r = g.rect(a)
                return grid.convert(CGPoint(x: r.midX, y: r.midY), to: nil)
            }
            func send(_ type: NSEvent.EventType, _ p: CGPoint) {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(e)
                }
            }
            let start = windowPoint(first)
            send(.leftMouseDown, start)
            var last = start
            for target in cells.dropFirst() {
                let end = windowPoint(target)
                for step in 1...8 {
                    let t = CGFloat(step) / 8
                    last = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                    send(.leftMouseDragged, last)
                }
            }
            send(.leftMouseUp, last)
            debugLog("WGDEBUG selection %@", controller.selection.ranges.map(\.a1).joined(separator: ","))
        case "clickat":
            // clickat B10 top  → click 1 pt inside the top edge of B10 (right on the selection border)
            let tokens = argument.split(separator: " ").map(String.init)
            guard let address = CellAddress(a1: tokens.first ?? "") else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            let grid = container.gridView
            let r = grid.geometry.rect(address)
            let local = tokens.last == "top" ? CGPoint(x: r.midX, y: r.minY + 1) : CGPoint(x: r.midX, y: r.midY)
            let p = grid.convert(local, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(e)
                }
            }
            debugLog("WGDEBUG after clickat %@: %@", argument, controller.selection.ranges.map(\.a1).joined(separator: ","))
        case "scroll":
            // scroll 0 3000 → scroll by points
            let d = argument.split(separator: " ").compactMap { Double($0) }
            if d.count == 2 { container.scroll(by: CGSize(width: d[0], height: d[1])); container.gridView.display() }
        case "where":
            // Logs screen positions (top-left origin) of cell centers, for driving the real mouse.
            let grid = container.gridView
            let screenHeight = NSScreen.screens.first?.frame.height ?? 0
            for token in argument.split(separator: " ") {
                guard let address = CellAddress(a1: String(token)) else { continue }
                let r = grid.geometry.rect(address)
                let windowPoint = grid.convert(CGPoint(x: r.midX, y: r.midY), to: nil)
                let screen = window.convertPoint(toScreen: windowPoint)
                debugLog("WGDEBUG where %@ %.1f %.1f", address.a1, screen.x, screenHeight - screen.y)
            }
        case "dark":
            NSApp.appearance = NSAppearance(named: argument == "off" ? .aqua : .darkAqua)
        case "bold":
            controller.toggleBold()
        case "freeze":
            controller.freezePanes()
        case "dialog":
            switch argument {
            case "format": controller.presenter?.presentFormatCells(tab: .number)
            case "function": controller.presenter?.presentInsertFunction(category: nil)
            case "cf": controller.presenter?.presentConditionalFormat(nil)
            case "sort": controller.presenter?.presentSort()
            default: break
            }
        default:
            break
        }
    }
}
#endif
