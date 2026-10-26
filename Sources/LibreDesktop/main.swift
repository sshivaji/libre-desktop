import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = LibreAppDelegate()
    app.delegate = delegate
    app.run()
}
