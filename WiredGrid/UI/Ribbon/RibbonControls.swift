import AppKit
import SwiftUI

// MARK: - State

/// Which ribbon tab is showing and whether the ribbon is collapsed to its tabs.
final class RibbonModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case home, insert, pageLayout, formulas, data, review, view
        var id: String { rawValue }

        var title: String {
            switch self {
            case .home: "Home"
            case .insert: "Insert"
            case .pageLayout: "Page Layout"
            case .formulas: "Formulas"
            case .data: "Data"
            case .review: "Review"
            case .view: "View"
            }
        }
    }

    static let tabHeight: CGFloat = 34
    static let contentHeight: CGFloat = 100
    static var expandedHeight: CGFloat { tabHeight + contentHeight + 1 }
    static var collapsedHeight: CGFloat { tabHeight + 1 }

    @Published var tab: Tab {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "WGRibbonTab") }
    }

    @Published var isCollapsed: Bool {
        didSet {
            UserDefaults.standard.set(isCollapsed, forKey: "WGRibbonCollapsed")
            onCollapseChange?(isCollapsed)
        }
    }

    var onCollapseChange: ((Bool) -> Void)?

    init() {
        tab = Tab(rawValue: UserDefaults.standard.string(forKey: "WGRibbonTab") ?? "") ?? .home
        isCollapsed = UserDefaults.standard.bool(forKey: "WGRibbonCollapsed")
    }

    var height: CGFloat { isCollapsed ? Self.collapsedHeight : Self.expandedHeight }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    fileprivate let canRun: Bool

    init(_ title: String, symbol: String? = nil, checked: Bool = false, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        canRun = enabled
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = enabled
        state = checked ? .on : .off
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func fire() { handler() }
}

extension ClosureMenuItem: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { canRun }
}

extension NSMenu {
    @discardableResult
    func add(_ title: String, symbol: String? = nil, checked: Bool = false, enabled: Bool = true, _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title, symbol: symbol, checked: checked, enabled: enabled, handler: handler)
        addItem(item)
        return item
    }

    func addSubmenu(_ menu: NSMenu, title: String? = nil) {
        let item = NSMenuItem(title: title ?? menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        addItem(item)
    }

    func addSection(_ title: String) {
        if #available(macOS 14.0, *) {
            addItem(.sectionHeader(title: title))
        } else {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            addItem(item)
        }
    }
}

// MARK: - Menu anchoring

/// Lets a SwiftUI button pop up an AppKit menu directly below itself.
final class MenuAnchor {
    weak var view: NSView?

    func pop(_ menu: NSMenu) {
        guard let view else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }
}

private final class FlippedAnchorView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = FlippedAnchorView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

// MARK: - Buttons

struct RibbonButtonStyle: ButtonStyle {
    var isOn = false
    var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isOn ? Theme.accentColor : Color.primary.opacity(0.88))
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.15)
                          : isOn ? Theme.accentColor.opacity(hovering ? 0.24 : 0.17)
                          : hovering ? Color.primary.opacity(0.08) : .clear)
            )
    }
}

/// A tall button with an icon over a caption. With `menu`, it shows a chevron:
/// if there's also an action, only the caption area opens the menu.
struct RibbonLargeButton: View {
    let title: String
    let symbol: String
    var help: String?
    var isOn = false
    var isEnabled = true
    var tint: Color?
    var menu: (() -> NSMenu)?
    var action: (() -> Void)?

    @State private var hovering = false
    @State private var anchor = MenuAnchor()

    var body: some View {
        Button {
            if let action { action() } else if let menu { anchor.pop(menu()) }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(tint ?? (isOn ? Theme.accentColor : Color.primary.opacity(0.85)))
                    .frame(height: 30)
                let lines = RibbonLabel.lines(title)
                VStack(spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        HStack(spacing: 2) {
                            Text(line).font(.system(size: 11)).fixedSize()
                            if menu != nil && index == lines.count - 1 {
                                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                            }
                        }
                    }
                }
            }
            .frame(width: RibbonLabel.width(title, chevron: menu != nil), height: 68, alignment: .top)
            .padding(.horizontal, 4)
            .padding(.top, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(RibbonButtonStyle(isOn: isOn, hovering: hovering))
        .background(MenuAnchorView(anchor: anchor))
        .overlay(alignment: .bottom) {
            // Split button: the caption strip opens the menu.
            if action != nil, let menu {
                Color.clear
                    .frame(height: 26)
                    .contentShape(Rectangle())
                    .onTapGesture { anchor.pop(menu()) }
            }
        }
        .onHover { hovering = $0 }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .help(help ?? title)
        .accessibilityLabel(title)
    }
}

/// A small square icon button, optionally a toggle.
struct RibbonIconButton: View {
    let symbol: String
    let help: String
    var isOn = false
    var isEnabled = true
    var text: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let text {
                    Text(text).font(.system(size: 13, weight: .semibold, design: .serif))
                } else {
                    Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                }
            }
            .frame(width: 28, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(RibbonButtonStyle(isOn: isOn, hovering: hovering))
        .onHover { hovering = $0 }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// An icon (or short label) button that opens a menu, with a chevron.
struct RibbonMenuButton: View {
    let symbol: String
    let help: String
    var label: String?
    var isOn = false
    let menu: () -> NSMenu

    @State private var hovering = false
    @State private var anchor = MenuAnchor()

    var body: some View {
        Button {
            anchor.pop(menu())
        } label: {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                if let label { Text(label).font(.system(size: 12)) }
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .padding(.horizontal, 6)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(RibbonButtonStyle(isOn: isOn, hovering: hovering))
        .background(MenuAnchorView(anchor: anchor))
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// An icon button with a separate chevron that opens a menu.
struct RibbonSplitButton: View {
    let symbol: String
    let help: String
    var isOn = false
    let action: () -> Void
    let menu: () -> NSMenu

    @State private var hovering = false
    @State private var anchor = MenuAnchor()

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .help(help)
            Button {
                anchor.pop(menu())
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .frame(width: 12, height: 26)
                    .contentShape(Rectangle())
            }
            .help("\(help) Options")
        }
        .buttonStyle(RibbonButtonStyle(isOn: isOn, hovering: hovering))
        .background(MenuAnchorView(anchor: anchor))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(help)
    }
}

/// A group of controls followed by a divider.
struct RibbonGroup<Content: View>: View {
    var showsDivider = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            content()
            if showsDivider {
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 1, height: 64)
                    .padding(.horizontal, 7)
            }
        }
    }
}

/// Two rows of small controls.
struct RibbonRows<Top: View, Bottom: View>: View {
    @ViewBuilder let top: () -> Top
    @ViewBuilder let bottom: () -> Bottom

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) { top() }
            HStack(spacing: 2) { bottom() }
        }
    }
}

/// Three stacked small buttons (like Cut/Copy/Format Painter).
struct RibbonColumn<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 1) { content() }
    }
}

/// A small labelled button used in stacked columns.
struct RibbonCompactButton: View {
    let title: String
    let symbol: String
    var help: String?
    var isOn = false
    var isEnabled = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 12)).frame(width: 16)
                Text(title).font(.system(size: 11.5)).fixedSize()
            }
            .padding(.horizontal, 5)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(RibbonButtonStyle(isOn: isOn, hovering: hovering))
        .onHover { hovering = $0 }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .help(help ?? title)
    }
}

/// Splits large-button captions into at most two lines, only at spaces.
enum RibbonLabel {
    private static let font = NSFont.systemFont(ofSize: 11)

    static func measure(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    static func lines(_ title: String) -> [String] {
        let words = title.split(separator: " ").map(String.init)
        guard words.count > 1, measure(title) > 64 else { return [title] }
        // The split that makes the longer line shortest.
        var best = [title]
        var bestWidth = CGFloat.greatestFiniteMagnitude
        for split in 1..<words.count {
            let first = words[..<split].joined(separator: " ")
            let second = words[split...].joined(separator: " ")
            let width = max(measure(first), measure(second))
            if width < bestWidth {
                bestWidth = width
                best = [first, second]
            }
        }
        return best
    }

    static func width(_ title: String, chevron: Bool) -> CGFloat {
        let widest = lines(title).map(measure).max() ?? 0
        return max(widest + (chevron ? 11 : 0) + 8, 52)
    }
}
