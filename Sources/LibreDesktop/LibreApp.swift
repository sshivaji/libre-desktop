import AppKit
import SwiftUI

@MainActor final class LibreAppDelegate: NSObject, NSApplicationDelegate {
    let store = LibreStore()
    private var widget: NSPanel!
    private var statusItem: NSStatusItem!
    private var statusTimer: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMenus()
        let height = min(760, (NSScreen.main?.visibleFrame.height ?? 800) - 32)
        widget = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: height), styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow, .fullSizeContentView], backing: .buffered, defer: false)
        widget.title = "Libre Desktop"; widget.titleVisibility = .hidden; widget.titlebarAppearsTransparent = true
        widget.isMovableByWindowBackground = true; widget.hidesOnDeactivate = false
        widget.isReleasedWhenClosed = false; widget.minSize = NSSize(width: 410, height: 630)
        widget.appearance = NSAppearance(named: .darkAqua)
        widget.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        widget.contentView = NSHostingView(rootView: LibreWidget(store: store, pin: { [weak self] in
            guard let self else { return }
            self.widget.level = self.widget.level == .floating ? .normal : .floating
        }))
        widget.setFrameAutosaveName("LibreDesktopWidget")
        if !widget.setFrameUsingName("LibreDesktopWidget"), let screen = NSScreen.main {
            widget.setFrameOrigin(NSPoint(x: max(screen.visibleFrame.minX, screen.visibleFrame.maxX - 465), y: max(screen.visibleFrame.minY, screen.visibleFrame.maxY - height - 25)))
        }
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "LibreStatusPlaced") {
            defaults.set(210.0, forKey: "NSStatusItem Preferred Position LibreDesktopStatus")
            defaults.set(true, forKey: "LibreStatusPlaced")
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "LibreDesktopStatus"; statusItem.isVisible = true
        if let button = statusItem.button {
            let icon = NSImage(systemSymbolName: "drop.fill", accessibilityDescription: "Libre Desktop glucose")
            icon?.isTemplate = true; button.image = icon; button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        }
        let menu = NSMenu()
        menu.addItem(item("Show glucose widget", #selector(showWidget)))
        menu.addItem(item("Refresh readings", #selector(refresh)))
        menu.addItem(.separator())
        menu.addItem(item("Sign out of LibreLinkUp", #selector(signOut)))
        menu.addItem(item("Quit Libre Desktop", #selector(quit), key: "q"))
        statusItem.menu = menu
        store.onChange = { [weak self] in self?.updateStatus() }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStatus() }
        }
        updateStatus()
        if !CommandLine.arguments.contains("--background") { showWidget() }
        let stdinLogin = CommandLine.arguments.contains("--login-stdin")
        let historyLogin = CommandLine.arguments.contains("--libreview-login-stdin")
        store.start(restoreSavedAccount: !stdinLogin, restoreSavedHistory: !historyLogin)
        if stdinLogin || historyLogin {
            // Explicit local automation only. Secrets travel over stdin and
            // are never command arguments, files, or log output.
            Task {
                let login = await Task.detached { () -> LibreStdinLogin? in
                    var bytes = Data()
                    while bytes.count < 16384 {
                        guard let chunk = try? FileHandle.standardInput.read(upToCount: 1024), !chunk.isEmpty else { break }
                        bytes.append(chunk)
                        if bytes.contains(10) { break }
                    }
                    guard bytes.count < 16384 else { return nil }
                    return try? JSONDecoder().decode(LibreStdinLogin.self, from: bytes)
                }.value
                if let login {
                    if historyLogin { store.trends.signIn(email: login.email, password: login.password) }
                    else { store.signIn(email: login.email, password: login.password, region: login.region ?? "Auto") }
                }
            }
        }
    }
    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; return item
    }
    private func installMenus() {
        let main = NSMenu(), appMenu = NSMenu(title: "Libre Desktop"), root = NSMenuItem()
        appMenu.addItem(item("Show glucose widget", #selector(showWidget), key: "1"))
        appMenu.addItem(.separator()); appMenu.addItem(item("Quit Libre Desktop", #selector(quit), key: "q"))
        root.submenu = appMenu; main.addItem(root)
        let editRoot = NSMenuItem(), edit = NSMenu(title: "Edit")
        for (title, selector, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key))
        }
        editRoot.submenu = edit; main.addItem(editRoot); NSApp.mainMenu = main
    }
    private func updateStatus() {
        if let reading = store.reading {
            let old = reading.isStale() || !store.online
            statusItem?.button?.title = " \(reading.display(in: store.displayUnit)) \(old ? "· old" : reading.arrow)"
            statusItem?.button?.toolTip = "Libre Desktop · \(store.displayUnit.label) · \(reading.age())"
        } else {
            statusItem?.button?.title = " BG —"
            statusItem?.button?.toolTip = "Libre Desktop — open to \(store.needsSignIn ? "sign in to LibreLinkUp" : "view glucose")"
        }
    }
    @objc func showWidget() { widget.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func refresh() { if store.canRetryAccountSetup { store.retryAccountSetup() } else { store.refresh() } }
    @objc func signOut() { store.signOut() }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWidget(); return true }
    func applicationWillTerminate(_ notification: Notification) { statusTimer?.invalidate(); store.stop() }
}

private struct LibreStdinLogin: Decodable, Sendable {
    let email: String
    let password: String
    let region: String?
}
