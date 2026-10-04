import AppKit

// The first NSDocumentController instantiated becomes the shared controller,
// so create our subclass before AppKit has a chance to create the default one.
_ = GridDocumentController()

let appDelegate = AppDelegate()
NSApplication.shared.delegate = appDelegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
