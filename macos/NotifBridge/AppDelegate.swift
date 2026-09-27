import AppKit
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "com.shinvou.NotifBridge.Mac", category: "app")

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.identifier?.rawValue == "recent" else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil)
        // Load the bundled artwork directly instead of resolving a cached app icon.
        guard let url = Bundle.main.url(forResource: "NotifBridgeIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: url) else {
            log.error("Could not load bundled startup app icon")
            return
        }

        NSApplication.shared.applicationIconImage = icon
        log.notice("Applied bundled app icon at startup: \(url.path, privacy: .public)")
    }
}
