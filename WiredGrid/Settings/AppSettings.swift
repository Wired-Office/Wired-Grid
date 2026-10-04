import AppKit
import Combine

enum EnterDirection: String, CaseIterable, Identifiable {
    case down, right, up, left, none
    var id: String { rawValue }

    var title: String {
        switch self {
        case .down: "Down"
        case .right: "Right"
        case .up: "Up"
        case .left: "Left"
        case .none: "Don't Move"
        }
    }
}

/// User preferences, persisted in UserDefaults. Observable from SwiftUI and
/// broadcast to open workbooks via `AppSettings.didChange`.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    static let didChange = Notification.Name("WGAppSettingsDidChange")

    private enum Key: String {
        case showTemplateChooserOnLaunch, defaultFontName, defaultFontSize, enterDirection
        case showFormulaBar, showStatusBar, autoComplete, functionHints, authorName, defaultSheetCount
        case autoSave, gridlineColor
    }

    private let defaults: UserDefaults

    @Published var showTemplateChooserOnLaunch: Bool { didSet { store(showTemplateChooserOnLaunch, .showTemplateChooserOnLaunch) } }
    @Published var defaultFontName: String { didSet { store(defaultFontName, .defaultFontName) } }
    @Published var defaultFontSize: Double { didSet { store(defaultFontSize, .defaultFontSize) } }
    /// Where the selection moves after pressing Return.
    @Published var enterDirection: EnterDirection { didSet { store(enterDirection.rawValue, .enterDirection) } }
    @Published var showFormulaBar: Bool { didSet { store(showFormulaBar, .showFormulaBar) } }
    @Published var showStatusBar: Bool { didSet { store(showStatusBar, .showStatusBar) } }
    /// Suggest earlier entries from the same column while typing.
    @Published var autoComplete: Bool { didSet { store(autoComplete, .autoComplete) } }
    /// Show function suggestions and argument hints while typing formulas.
    @Published var functionHints: Bool { didSet { store(functionHints, .functionHints) } }
    @Published var authorName: String { didSet { store(authorName, .authorName) } }
    @Published var defaultSheetCount: Int { didSet { store(defaultSheetCount, .defaultSheetCount) } }
    @Published var autoSave: Bool { didSet { store(autoSave, .autoSave) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.showTemplateChooserOnLaunch.rawValue: true,
            Key.defaultFontName.rawValue: CellStyle.defaultFontName,
            Key.defaultFontSize.rawValue: CellStyle.defaultFontSize,
            Key.enterDirection.rawValue: EnterDirection.down.rawValue,
            Key.showFormulaBar.rawValue: true,
            Key.showStatusBar.rawValue: true,
            Key.autoComplete.rawValue: true,
            Key.functionHints.rawValue: true,
            Key.authorName.rawValue: NSFullUserName(),
            Key.defaultSheetCount.rawValue: 1,
            Key.autoSave.rawValue: true,
        ])
        showTemplateChooserOnLaunch = defaults.bool(forKey: Key.showTemplateChooserOnLaunch.rawValue)
        defaultFontName = defaults.string(forKey: Key.defaultFontName.rawValue) ?? CellStyle.defaultFontName
        let size = defaults.double(forKey: Key.defaultFontSize.rawValue)
        defaultFontSize = size > 0 ? size : CellStyle.defaultFontSize
        enterDirection = EnterDirection(rawValue: defaults.string(forKey: Key.enterDirection.rawValue) ?? "") ?? .down
        showFormulaBar = defaults.bool(forKey: Key.showFormulaBar.rawValue)
        showStatusBar = defaults.bool(forKey: Key.showStatusBar.rawValue)
        autoComplete = defaults.bool(forKey: Key.autoComplete.rawValue)
        functionHints = defaults.bool(forKey: Key.functionHints.rawValue)
        authorName = defaults.string(forKey: Key.authorName.rawValue) ?? ""
        defaultSheetCount = max(1, min(defaults.integer(forKey: Key.defaultSheetCount.rawValue), 16))
        autoSave = defaults.bool(forKey: Key.autoSave.rawValue)
    }

    private func store(_ value: Any, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
