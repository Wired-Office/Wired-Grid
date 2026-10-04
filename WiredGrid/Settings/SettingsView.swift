import SwiftUI

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SettingsView(settings: .shared))
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        if window?.isVisible == false { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("General") {
                Toggle("Show the template chooser when Wired Grid opens", isOn: $settings.showTemplateChooserOnLaunch)
                Toggle("Save changes automatically (AutoSave)", isOn: $settings.autoSave)
                Stepper("Sheets in a new workbook: \(settings.defaultSheetCount)", value: $settings.defaultSheetCount, in: 1...16)
                TextField("Author name", text: $settings.authorName)
            }
            Section("Editing") {
                Picker("After pressing Return, move", selection: $settings.enterDirection) {
                    ForEach(EnterDirection.allCases) { Text($0.title).tag($0) }
                }
                Toggle("AutoComplete cell values from the same column", isOn: $settings.autoComplete)
                Toggle("Show function suggestions and argument hints", isOn: $settings.functionHints)
            }
            Section("New Workbooks") {
                HStack {
                    Text("Default font")
                    Spacer()
                    FontFamilyPicker(family: settings.defaultFontName) { settings.defaultFontName = $0 }.frame(width: 200)
                }
                Stepper("Default size: \(Int(settings.defaultFontSize)) pt", value: $settings.defaultFontSize, in: 8...24)
            }
            Section("View") {
                Toggle("Show formula bar", isOn: $settings.showFormulaBar)
                Toggle("Show status bar", isOn: $settings.showStatusBar)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
