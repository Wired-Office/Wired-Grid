import SwiftUI

/// Mode, selection statistics and zoom along the bottom of the window.
struct StatusBarView: View {
    @ObservedObject var controller: WorkbookController

    private var mode: String {
        if controller.isEditing { return "Edit" }
        if controller.formatPainter != nil { return "Format Painter" }
        if controller.clipboardMarquee != nil { return "Select destination and press Return or choose Paste" }
        return "Ready"
    }

    var body: some View {
        let summary = controller.selectionSummary()
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle()
                    .fill(controller.isEditing ? Color.orange : Theme.accentColor)
                    .frame(width: 7, height: 7)
                Text(controller.statusMessage ?? mode)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            if summary.count > 1 || (summary.numericalCount >= 1 && !controller.selection.isSingleCell) {
                if let average = summary.average { stat("Average", average) }
                Text("Count: \(summary.count)").monospacedDigit()
                if let sum = summary.sum { stat("Sum", sum) }
                if let minimum = summary.minimum, summary.numericalCount > 1, controller.selection.primary.cellCount > 2 {
                    stat("Min", minimum).opacity(0.75)
                }
                if let maximum = summary.maximum, summary.numericalCount > 1, controller.selection.primary.cellCount > 2 {
                    stat("Max", maximum).opacity(0.75)
                }
            }
            Divider().frame(height: 14)
            zoomControl
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 12)
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: Theme.barBackground))
    }

    private func stat(_ label: String, _ value: Double) -> some View {
        let format = controller.activeStyle.numberFormat
        let text = format == NumberFormat.generalCode || NumberFormat.isDate(format) && label == "Sum"
            ? NumberFormat.formatNumber(value, abs(value) >= 1000 ? "#,##0.##########" : "General").text
            : NumberFormat.formatNumber(value, format).text
        return Text("\(label): \(text.hasSuffix(".") ? String(text.dropLast()) : text)")
            .monospacedDigit()
            .textSelection(.enabled)
    }

    private var zoomControl: some View {
        let zoom = controller.sheet.zoom
        return HStack(spacing: 6) {
            Button { controller.setZoom(max(0.1, (zoom * 10).rounded(.down) / 10 - 0.1)) } label: { Image(systemName: "minus") }
                .buttonStyle(.plain)
                .help("Zoom Out")
            Slider(value: Binding(get: { log2(zoom) }, set: { controller.setZoom(pow(2, $0)) }), in: log2(0.25)...log2(4))
                .controlSize(.mini)
                .frame(width: 100)
            Button { controller.setZoom(min(4, (zoom * 10).rounded(.up) / 10 + 0.1)) } label: { Image(systemName: "plus") }
                .buttonStyle(.plain)
                .help("Zoom In")
            Menu {
                ForEach([0.5, 0.75, 1, 1.25, 1.5, 2, 3], id: \.self) { level in
                    Button("\(Int(level * 100))%") { controller.setZoom(level) }
                }
            } label: {
                Text("\(Int((zoom * 100).rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}
