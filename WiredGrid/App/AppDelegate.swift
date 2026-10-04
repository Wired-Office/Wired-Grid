import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let recentDocumentsMenu = RecentDocumentsMenuController()
    private var referenceWindow: NSWindow?

    /// True when the app is hosting unit tests: stay in the background and open no windows.
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil

    func applicationWillFinishLaunching(_ notification: Notification) {
        if Self.isRunningTests {
            NSApp.setActivationPolicy(.prohibited)
            UserDefaults.standard.setVolatileDomain(["ApplePersistenceIgnoreState": true], forName: UserDefaults.argumentDomain)
        }
        NSApp.mainMenu = MainMenuBuilder.build(recentDocumentsDelegate: recentDocumentsMenu)
        NSWindow.allowsAutomaticWindowTabbing = true
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        if Self.isRunningTests { return false }
        #if DEBUG
        if DebugAutomation.runIfRequested() { return false }
        #endif
        guard AppSettings.shared.showTemplateChooserOnLaunch else { return true }
        TemplateChooserWindowController.shared.show()
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - Actions

    @objc func showTemplateChooser(_ sender: Any?) {
        TemplateChooserWindowController.shared.show()
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    @objc func showFunctionReference(_ sender: Any?) {
        if referenceWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Function Reference"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: FunctionReferenceView())
            window.center()
            referenceWindow = window
        }
        referenceWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showAboutPanel(_ sender: Any?) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSAttributedString(
            string: "A fast, familiar spreadsheet for macOS.\n\(FunctionLibrary.shared.functions.count) built-in functions.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]
        )
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Wired Grid", .credits: credits])
    }
}
