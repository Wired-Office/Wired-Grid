import AppKit
import SwiftUI

/// Wired Grid's visual identity: an emerald accent over neutral chrome.
enum Theme {
    private static func dynamic(light: NSColor, dark: NSColor, name: String) -> NSColor {
        NSColor(name: name) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static let accent = dynamic(
        light: NSColor(srgbRed: 0.09, green: 0.525, blue: 0.345, alpha: 1),
        dark: NSColor(srgbRed: 0.33, green: 0.80, blue: 0.56, alpha: 1),
        name: "WGAccent"
    )

    /// The selection outline and fill handle.
    static let selection = dynamic(
        light: NSColor(srgbRed: 0.09, green: 0.525, blue: 0.345, alpha: 1),
        dark: NSColor(srgbRed: 0.30, green: 0.78, blue: 0.52, alpha: 1),
        name: "WGSelection"
    )

    static let barBackground = dynamic(
        light: NSColor(srgbRed: 0.972, green: 0.976, blue: 0.974, alpha: 1),
        dark: NSColor(srgbRed: 0.165, green: 0.172, blue: 0.170, alpha: 1),
        name: "WGBarBackground"
    )

    /// The sheet itself.
    static let cellBackground = dynamic(
        light: .white,
        dark: NSColor(srgbRed: 0.118, green: 0.122, blue: 0.122, alpha: 1),
        name: "WGCellBackground"
    )

    static let gridline = dynamic(
        light: NSColor(srgbRed: 0.855, green: 0.863, blue: 0.859, alpha: 1),
        dark: NSColor(srgbRed: 0.24, green: 0.25, blue: 0.248, alpha: 1),
        name: "WGGridline"
    )

    static let headerBackground = dynamic(
        light: NSColor(srgbRed: 0.955, green: 0.960, blue: 0.957, alpha: 1),
        dark: NSColor(srgbRed: 0.185, green: 0.192, blue: 0.19, alpha: 1),
        name: "WGHeaderBackground"
    )

    static let headerSelected = dynamic(
        light: NSColor(srgbRed: 0.86, green: 0.93, blue: 0.89, alpha: 1),
        dark: NSColor(srgbRed: 0.18, green: 0.32, blue: 0.25, alpha: 1),
        name: "WGHeaderSelected"
    )

    static let headerFullySelected = dynamic(
        light: NSColor(srgbRed: 0.09, green: 0.525, blue: 0.345, alpha: 1),
        dark: NSColor(srgbRed: 0.24, green: 0.62, blue: 0.43, alpha: 1),
        name: "WGHeaderFullySelected"
    )

    static let headerText = dynamic(
        light: NSColor(srgbRed: 0.36, green: 0.39, blue: 0.38, alpha: 1),
        dark: NSColor(srgbRed: 0.68, green: 0.70, blue: 0.69, alpha: 1),
        name: "WGHeaderText"
    )

    static let headerLine = dynamic(
        light: NSColor(srgbRed: 0.80, green: 0.81, blue: 0.805, alpha: 1),
        dark: NSColor(srgbRed: 0.28, green: 0.29, blue: 0.288, alpha: 1),
        name: "WGHeaderLine"
    )

    /// "Automatic" text: black on a light sheet, light gray on a dark one.
    static let cellText = dynamic(
        light: .black,
        dark: NSColor(srgbRed: 0.90, green: 0.91, blue: 0.905, alpha: 1),
        name: "WGCellText"
    )

    static let linkText = dynamic(
        light: NSColor(srgbRed: 0.05, green: 0.40, blue: 0.75, alpha: 1),
        dark: NSColor(srgbRed: 0.45, green: 0.70, blue: 1.0, alpha: 1),
        name: "WGLinkText"
    )

    static var accentColor: Color { Color(nsColor: accent) }

    /// Colors for formula references while editing, in order.
    static let referenceColors: [NSColor] = [
        NSColor(srgbRed: 0.18, green: 0.44, blue: 0.86, alpha: 1),
        NSColor(srgbRed: 0.85, green: 0.25, blue: 0.25, alpha: 1),
        NSColor(srgbRed: 0.55, green: 0.30, blue: 0.80, alpha: 1),
        NSColor(srgbRed: 0.10, green: 0.58, blue: 0.35, alpha: 1),
        NSColor(srgbRed: 0.85, green: 0.45, blue: 0.10, alpha: 1),
        NSColor(srgbRed: 0.75, green: 0.20, blue: 0.55, alpha: 1),
        NSColor(srgbRed: 0.10, green: 0.55, blue: 0.65, alpha: 1),
    ]

    static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
