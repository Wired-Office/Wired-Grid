import AppKit
import SwiftUI

/// Presents a SwiftUI view as a document-modal sheet.
enum SheetPresenter {
    static func present<Content: View>(
        in window: NSWindow,
        @ViewBuilder content: (_ dismiss: @escaping () -> Void) -> Content
    ) {
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        var dismissAction: () -> Void = {}
        let host = NSHostingController(rootView: content({ dismissAction() }))
        host.sizingOptions = [.preferredContentSize]
        sheet.contentViewController = host
        dismissAction = { [weak window, weak sheet] in
            guard let sheet else { return }
            window?.endSheet(sheet)
        }
        window.beginSheet(sheet)
    }
}
