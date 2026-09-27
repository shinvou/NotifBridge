import AppKit
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "com.shinvou.NotifBridge.Mac", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
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
