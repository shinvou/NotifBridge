#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat "$ROOT/macos/NotifBridge/AppDelegate.swift" > "$WORK/Test.swift"
cat >> "$WORK/Test.swift" <<'SWIFT'
@main struct WindowLifecycleTest {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        app.setActivationPolicy(.regular)
        let other = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        other.identifier = NSUserInterfaceItemIdentifier("other")
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: other)
        precondition(app.activationPolicy() == .regular, "unrelated windows must not change activation policy")
        let inbox = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        inbox.identifier = NSUserInterfaceItemIdentifier("recent")
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: inbox)
        precondition(app.activationPolicy() == .accessory, "closing inbox must remove Dock presence without terminating the app")
        print("PASS: inbox close restores menu-bar-only activation; unrelated windows leave policy unchanged")
    }
}
SWIFT
xcrun swiftc -swift-version 6 -parse-as-library "$WORK/Test.swift" -o "$WORK/test"
"$WORK/test"
