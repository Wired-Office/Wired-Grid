import AppKit

/// A chart floating over the grid. Drag to move, drag a handle to resize,
/// double-click to edit.
final class ChartView: NSView {
    var chart: ChartObject { didSet { needsDisplay = true } }
    weak var controller: WorkbookController?
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    /// Screen points per chart point.
    var zoom: CGFloat = 1

    private enum Drag { case none, move(CGPoint, CGRect), resize(Int, CGPoint, CGRect) }
    private var drag: Drag = .none
    private let handleSize: CGFloat = 8

    init(chart: ChartObject) {
        self.chart = chart
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        setAccessibilityRole(.image)
        setAccessibilityLabel("\(chart.kind.title) chart: \(chart.title)")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isSelected }

    override func draw(_ dirtyRect: NSRect) {
        guard let controller else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let data = ChartData.read(chart, sheetIndex: controller.activeSheetIndex, controller: controller)
        let inner = bounds.insetBy(dx: handleSize / 2, dy: handleSize / 2)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: inner, xRadius: 5, yRadius: 5).addClip()
        ChartRenderer.draw(chart, data: data, in: inner, dark: dark, scale: min(max(zoom, 0.6), 2))
        NSGraphicsContext.restoreGraphicsState()
        let border = NSBezierPath(roundedRect: inner.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        (isSelected ? Theme.accent : NSColor.separatorColor).setStroke()
        border.lineWidth = isSelected ? 1.5 : 1
        border.stroke()
        if isSelected {
            for rect in handleRects() {
                let path = NSBezierPath(ovalIn: rect)
                NSColor.white.setFill()
                path.fill()
                Theme.accent.setStroke()
                path.lineWidth = 1.5
                path.stroke()
            }
        }
    }

    /// Eight resize handles, clockwise from top-left.
    private func handleRects() -> [CGRect] {
        let r = bounds.insetBy(dx: handleSize / 2, dy: handleSize / 2)
        let points = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
                      CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
        return points.map { CGRect(x: $0.x - handleSize / 2, y: $0.y - handleSize / 2, width: handleSize, height: handleSize) }
    }

    override func resetCursorRects() {
        guard isSelected else { return }
        let cursors: [NSCursor] = [.crosshair, .resizeUpDown, .crosshair, .resizeLeftRight, .crosshair, .resizeUpDown, .crosshair, .resizeLeftRight]
        for (rect, cursor) in zip(handleRects(), cursors) { addCursorRect(rect.insetBy(dx: -2, dy: -2), cursor: cursor) }
        addCursorRect(bounds.insetBy(dx: handleSize, dy: handleSize), cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard let controller else { return }
        if controller.isEditing { guard controller.commitEditingIfNeeded() else { return } }
        controller.selectedChartID = chart.id
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            controller.presenter?.presentChartEditor(chart)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let windowPoint = event.locationInWindow
        if let index = handleRects().firstIndex(where: { $0.insetBy(dx: -3, dy: -3).contains(point) }) {
            drag = .resize(index, windowPoint, chart.frame)
        } else {
            drag = .move(windowPoint, chart.frame)
            NSCursor.closedHand.push()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let current = event.locationInWindow
        switch drag {
        case .none: return
        case .move(let start, let original):
            let dx = (current.x - start.x) / zoom, dy = -(current.y - start.y) / zoom
            var frame = original.offsetBy(dx: dx, dy: dy)
            frame.origin.x = max(frame.origin.x, 0)
            frame.origin.y = max(frame.origin.y, 0)
            chart.frame = frame
        case .resize(let handle, let start, let original):
            let dx = (current.x - start.x) / zoom, dy = -(current.y - start.y) / zoom
            var f = original
            let minSize: CGFloat = 120
            if [0, 6, 7].contains(handle) { f.origin.x = min(original.minX + dx, original.maxX - minSize); f.size.width = original.maxX - f.origin.x }
            if [2, 3, 4].contains(handle) { f.size.width = max(original.width + dx, minSize) }
            if [0, 1, 2].contains(handle) { f.origin.y = min(original.minY + dy, original.maxY - minSize); f.size.height = original.maxY - f.origin.y }
            if [4, 5, 6].contains(handle) { f.size.height = max(original.height + dy, minSize) }
            chart.frame = f
        }
        superview.flatMap { $0 as? ObjectLayerView }?.layoutChart(self)
    }

    override func mouseUp(with event: NSEvent) {
        if case .move = drag { NSCursor.pop() }
        if case .none = drag { return }
        drag = .none
        controller?.updateChart(chart, actionName: "Move Chart")
        window?.invalidateCursorRects(for: self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            controller?.deleteChart(chart.id)
            return
        }
        if event.keyCode == 53 {
            controller?.selectedChartID = nil
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let controller else { return nil }
        controller.selectedChartID = chart.id
        let menu = NSMenu()
        let chart = self.chart
        menu.add("Edit Chart…", symbol: "slider.horizontal.3") { controller.presenter?.presentChartEditor(chart) }
        let types = NSMenu(title: "Change Chart Type")
        for kind in ChartKind.allCases {
            types.add(kind.title, symbol: kind.symbol, checked: kind == chart.kind) {
                var updated = chart
                updated.kind = kind
                controller.updateChart(updated, actionName: "Change Chart Type")
            }
        }
        menu.addSubmenu(types)
        menu.add(chart.showLegend ? "Hide Legend" : "Show Legend") {
            var updated = chart
            updated.showLegend.toggle()
            controller.updateChart(updated)
        }
        menu.add(chart.showDataLabels ? "Hide Data Labels" : "Show Data Labels") {
            var updated = chart
            updated.showDataLabels.toggle()
            controller.updateChart(updated)
        }
        menu.add("Bring to Front", symbol: "square.3.layers.3d.top.filled") { controller.bringChartToFront(chart.id) }
        menu.addItem(.separator())
        menu.add("Copy as Image", symbol: "doc.on.doc") { [weak self] in self?.copyImage() }
        menu.add("Delete Chart", symbol: "trash") { controller.deleteChart(chart.id) }
        return menu
    }

    func copyImage() {
        guard let controller else { return }
        let size = CGSize(width: chart.frame.width * 2, height: chart.frame.height * 2)
        let data = ChartData.read(chart, sheetIndex: controller.activeSheetIndex, controller: controller)
        let chart = self.chart
        let image = NSImage(size: CGSize(width: chart.frame.width, height: chart.frame.height), flipped: true) { rect in
            ChartRenderer.draw(chart, data: data, in: rect, dark: false)
            return true
        }
        _ = size
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }
}

/// Hosts the chart views above the scrolling cell area.
final class ObjectLayerView: NSView {
    weak var controller: WorkbookController?
    weak var gridView: GridView?
    private var chartViews: [UUID: ChartView] = [:]

    override var isFlipped: Bool { true }

    /// Only charts take clicks; everything else falls through to the grid.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    func sync() {
        guard let controller else { return }
        let charts = controller.sheet.charts
        let ids = Set(charts.map(\.id))
        for (id, view) in chartViews where !ids.contains(id) {
            view.removeFromSuperview()
            chartViews[id] = nil
        }
        for chart in charts {
            let view = chartViews[chart.id] ?? {
                let v = ChartView(chart: chart)
                v.controller = controller
                chartViews[chart.id] = v
                return v
            }()
            if view.superview == nil { addSubview(view) }
            view.chart = chart
            view.isSelected = controller.selectedChartID == chart.id
            view.needsDisplay = true
        }
        // Keep z-order matching the model.
        for chart in charts { if let view = chartViews[chart.id] { addSubview(view, positioned: .above, relativeTo: nil) } }
        layoutCharts()
    }

    func layoutCharts() {
        for view in chartViews.values { layoutChart(view) }
    }

    func layoutChart(_ view: ChartView) {
        guard let gridView else { return }
        let g = gridView.geometry
        let zoom = g.zoom
        view.zoom = zoom
        // Content coordinates → this layer (which starts at the frozen boundary).
        let x = view.chart.frame.minX * zoom - g.scroll.x - g.frozenWidth
        let y = view.chart.frame.minY * zoom - g.scroll.y - g.frozenHeight
        let pad: CGFloat = 4
        view.frame = CGRect(x: x - pad, y: y - pad, width: view.chart.frame.width * zoom + pad * 2, height: view.chart.frame.height * zoom + pad * 2)
    }

    func refreshContents() {
        for view in chartViews.values { view.needsDisplay = true }
    }
}
