import AppKit
import SwiftUI

struct NamedColor {
    let name: String
    let color: NSColor
}

enum ColorPalettes {
    static func hex(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    private static let neutrals: [UInt32] = [0x000000, 0x262626, 0x404040, 0x595959, 0x7F7F7F, 0xA6A6A6, 0xBFBFBF, 0xD9D9D9, 0xF2F2F2, 0xFFFFFF]
    private static let hues: [UInt32] = [0x9C1C1C, 0xD32F2F, 0xE8710A, 0xE0A100, 0x2E8B57, 0x13787F, 0x1F63C6, 0x1B3A6B, 0x6A3FA0, 0xB0307A]

    /// Rows of swatches for the text color popover.
    static let textGrid: [[NSColor]] = {
        let base = hues.map(hex)
        return [
            neutrals.map(hex),
            base,
            base.map { $0.blended(withFraction: 0.5, of: .white) ?? $0 },
            base.map { $0.blended(withFraction: 0.35, of: .black) ?? $0 },
        ]
    }()

    static let highlightGrid: [[NSColor]] = [
        [0xFFF176, 0xB9F6CA, 0x84FFFF, 0xFF9ED8, 0xAECBFA].map(hex),
        [0xFFD180, 0xFF8A80, 0xD7CCFF, 0xC8E6C9, 0xDDDDDD].map(hex),
    ]

    static let namedTextColors: [NamedColor] = [
        NamedColor(name: "Black", color: hex(0x000000)),
        NamedColor(name: "Dark Gray", color: hex(0x404040)),
        NamedColor(name: "Gray", color: hex(0x7F7F7F)),
        NamedColor(name: "Red", color: hex(0xD32F2F)),
        NamedColor(name: "Orange", color: hex(0xE8710A)),
        NamedColor(name: "Gold", color: hex(0xE0A100)),
        NamedColor(name: "Green", color: hex(0x2E8B57)),
        NamedColor(name: "Teal", color: hex(0x13787F)),
        NamedColor(name: "Blue", color: hex(0x1F63C6)),
        NamedColor(name: "Navy", color: hex(0x1B3A6B)),
        NamedColor(name: "Purple", color: hex(0x6A3FA0)),
    ]

    static let namedHighlightColors: [NamedColor] = [
        NamedColor(name: "Yellow", color: hex(0xFFF176)),
        NamedColor(name: "Green", color: hex(0xB9F6CA)),
        NamedColor(name: "Aqua", color: hex(0x84FFFF)),
        NamedColor(name: "Pink", color: hex(0xFF9ED8)),
        NamedColor(name: "Blue", color: hex(0xAECBFA)),
        NamedColor(name: "Orange", color: hex(0xFFD180)),
        NamedColor(name: "Gray", color: hex(0xDDDDDD)),
    ]

    static let defaultTextColor = hex(0xD32F2F)
    static let defaultHighlightColor = hex(0xFFF176)
}

struct ColorPaletteView: View {
    enum Kind { case text, highlight }

    static let fillGrid: [[NSColor]] = ColorPalettes.textGrid

    let kind: Kind
    let onPick: (NSColor?) -> Void
    let onMore: () -> Void

    private var grid: [[NSColor]] { kind == .text ? ColorPalettes.textGrid : ColorPalettes.textGrid.reversed().map { $0 } + ColorPalettes.highlightGrid }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                onPick(nil)
            } label: {
                Label(kind == .text ? "Automatic" : "No Fill",
                      systemImage: kind == .text ? "circle.lefthalf.filled" : "nosign")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(spacing: 4) {
                ForEach(grid.indices, id: \.self) { row in
                    HStack(spacing: 4) {
                        ForEach(grid[row].indices, id: \.self) { column in
                            SwatchButton(color: grid[row][column]) { onPick(grid[row][column]) }
                        }
                    }
                }
            }

            Divider()

            Button {
                onMore()
            } label: {
                Label("More Colors…", systemImage: "paintpalette")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 12))
        .padding(12)
        .fixedSize()
    }
}

private struct SwatchButton: View {
    let color: NSColor
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color(nsColor: color))
                .frame(width: 18, height: 18)
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(hovering ? Theme.accentColor : Color.primary.opacity(0.18), lineWidth: hovering ? 2 : 0.5)
                )
                .scaleEffect(hovering ? 1.12 : 1)
                .animation(.easeOut(duration: 0.1), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}


// MARK: - Icon buttons

struct FormatButtonStyle: ButtonStyle {
    var isOn = false
    var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isOn ? Theme.accentColor : Color.primary.opacity(0.85))
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(background(pressed: configuration.isPressed))
            )
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.12), value: isOn)
    }

    private func background(pressed: Bool) -> Color {
        if pressed { return Color.primary.opacity(0.14) }
        if isOn { return Theme.accentColor.opacity(hovering ? 0.22 : 0.16) }
        if hovering { return Color.primary.opacity(0.07) }
        return .clear
    }
}

struct FormatIconButton: View {
    let symbol: String
    let help: String
    var isOn = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(FormatButtonStyle(isOn: isOn, hovering: hovering))
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct FormatDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 20)
            .padding(.horizontal, 5)
    }
}

// MARK: - Color split button

struct ColorSplitButton: View {
    let symbol: String
    let help: String
    let color: NSColor
    let kind: ColorPaletteView.Kind
    let onApply: (NSColor?) -> Void
    let onMore: () -> Void

    @State private var showingPalette = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button {
                onApply(color)
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium))
                    Capsule()
                        .fill(Color(nsColor: color))
                        .frame(width: 16, height: 3.5)
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
                }
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
            }
            .help(help)

            Button {
                showingPalette.toggle()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .frame(width: 12, height: 26)
                    .contentShape(Rectangle())
            }
            .help("\(help) Options")
            .popover(isPresented: $showingPalette, arrowEdge: .bottom) {
                ColorPaletteView(kind: kind, onPick: { picked in
                    showingPalette = false
                    onApply(picked)
                }, onMore: {
                    showingPalette = false
                    onMore()
                })
            }
        }
        .buttonStyle(FormatButtonStyle(hovering: hovering))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(help)
    }
}

// MARK: - Font family pop-up (AppKit, for per-item font previews)

struct FontFamilyPicker: NSViewRepresentable {
    var family: String
    var onSelect: (String) -> Void

    private static let families: [String] = NSFontManager.shared.availableFontFamilies.sorted {
        $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.controlSize = .regular
        popUp.font = .systemFont(ofSize: 12)
        popUp.target = context.coordinator
        popUp.action = #selector(Coordinator.selectionChanged(_:))
        popUp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        popUp.toolTip = "Font"
        let menu = NSMenu()
        menu.delegate = context.coordinator
        for family in Self.families {
            menu.addItem(withTitle: family, action: nil, keyEquivalent: "")
        }
        popUp.menu = menu
        return popUp
    }

    func updateNSView(_ popUp: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        guard popUp.titleOfSelectedItem != family else { return }
        // Fonts not installed on this Mac still show their name.
        if let placeholder = popUp.menu?.items.first(where: { $0.tag == Coordinator.missingFontTag }) {
            popUp.menu?.removeItem(placeholder)
        }
        if popUp.item(withTitle: family) == nil {
            let item = NSMenuItem(title: family, action: nil, keyEquivalent: "")
            item.tag = Coordinator.missingFontTag
            popUp.menu?.insertItem(item, at: 0)
        }
        popUp.selectItem(withTitle: family)
    }

    final class Coordinator: NSObject, NSMenuDelegate {
        static let missingFontTag = -1
        var parent: FontFamilyPicker
        private var styled = false

        init(_ parent: FontFamilyPicker) {
            self.parent = parent
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            guard let title = sender.titleOfSelectedItem else { return }
            parent.onSelect(title)
        }

        /// Render each family in its own typeface the first time the menu opens.
        func menuNeedsUpdate(_ menu: NSMenu) {
            guard !styled else { return }
            styled = true
            for item in menu.items {
                guard let font = NSFontManager.shared.font(withFamily: item.title, traits: [], weight: 5, size: 13) else { continue }
                // Symbol fonts can't render their own names legibly.
                guard font.coveredCharacterSet.isSuperset(of: CharacterSet(charactersIn: item.title)) else { continue }
                item.attributedTitle = NSAttributedString(string: item.title, attributes: [.font: font])
            }
        }
    }
}

// MARK: - Font size combo box

struct FontSizeField: NSViewRepresentable {
    static let standardSizes: [CGFloat] = [8, 9, 10, 11, 12, 14, 16, 18, 20, 22, 24, 28, 32, 36, 48, 60, 72, 96]

    var size: CGFloat
    var onCommit: (CGFloat) -> Void

    static func format(_ size: CGFloat) -> String {
        size == size.rounded() ? String(Int(size)) : String(format: "%.1f", size)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox()
        box.addItems(withObjectValues: Self.standardSizes.map(Self.format))
        box.numberOfVisibleItems = 14
        box.completes = false
        box.isEditable = true
        box.controlSize = .regular
        box.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        box.target = context.coordinator
        box.action = #selector(Coordinator.commit(_:))
        box.toolTip = "Font Size"
        return box
    }

    func updateNSView(_ box: NSComboBox, context: Context) {
        context.coordinator.parent = self
        if box.currentEditor() == nil {
            box.stringValue = Self.format(size)
        }
    }

    final class Coordinator: NSObject {
        var parent: FontSizeField

        init(_ parent: FontSizeField) {
            self.parent = parent
        }

        @objc func commit(_ sender: NSComboBox) {
            let text = sender.stringValue.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
            guard let value = Double(text), value >= 1, value <= 1638 else {
                sender.stringValue = FontSizeField.format(parent.size)
                return
            }
            if abs(CGFloat(value) - parent.size) > 0.01 {
                parent.onCommit(CGFloat(value))
            }
        }
    }
}
