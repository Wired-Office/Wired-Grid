import AppKit

/// Keeps the Dock icon in step with the system's Light or Dark Mode.
///
/// The bundle's icon only switches when macOS itself uses dark app icons (an
/// icon style setting on macOS 26+, never on 14 and 15). While the app runs it
/// shows the dark icon (`AppIconDark`, from Scripts/generate-icon.swift) in Dark
/// Mode and the bundle's own icon in Light Mode, switching as the system does.
final class AppIconAppearance {
    private var observation: NSKeyValueObservation?
    private var showsDarkIcon = false

    func start() {
        update()
        observation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.update() }
        }
    }

    private func update() {
        let dark = Self.isDark(NSApp.effectiveAppearance) && !Self.systemUsesStyledIcons
        guard dark != showsDarkIcon else { return }
        showsDarkIcon = dark
        // nil restores the bundle's icon.
        NSApp.applicationIconImage = dark ? NSImage(named: "AppIconDark") : nil
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Clear and tinted icon styles (macOS 26+) are rendered by the system from
    /// AppIcon.icon; a fixed dark image would override them.
    private static var systemUsesStyledIcons: Bool {
        let style = UserDefaults.standard.string(forKey: "AppleIconAppearanceTheme") ?? ""
        return style.localizedCaseInsensitiveContains("clear") || style.localizedCaseInsensitiveContains("tint")
    }
}
