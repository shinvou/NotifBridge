#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/macos/Build"
{
cat "$ROOT/shared/NotifWire.swift" "$ROOT/macos/NotifBridge/BannerManager.swift"
cat <<'SWIFT'
typealias NotifFrame = NotifWire.Notification
@MainActor enum ReceiverModel { final class ActionStatus {} }
@main struct NativeNotificationTests {
    @MainActor static func main() {
        var frame = NotifFrame(title: "Message", body: "Hello", sourceName: "Messages",
            sourceIdentifier: "test.messages", notificationIdentifier: "message-123")
        precondition(BannerManager.communicationIntent(for: frame) == nil, "missing icon uses normal notification")
        frame.sourceIcon = Data("not an image".utf8)
        precondition(BannerManager.communicationIntent(for: frame) == nil, "invalid icon uses normal notification")
        let icon = NSImage(size: NSSize(width: 8, height: 8))
        icon.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        icon.unlockFocus()
        frame.sourceIcon = icon.tiffRepresentation!
        let intent = BannerManager.communicationIntent(for: frame)!
        precondition(intent.sender?.displayName == "Messages: Message")
        precondition(intent.sender?.personHandle?.value == "test.messages")
        precondition(intent.sender?.image != nil)
        precondition(intent.conversationIdentifier == frame.groupID)
        precondition(intent.content == frame.body)
        precondition(BannerManager.category(for: frame).actions.isEmpty, "local previews have no phone actions")
        precondition(BannerManager.command(for: BannerManager.clearAction, text: nil, frame: frame) == nil, "stale preview actions cannot clear on iPhone")
        frame.transportSessionID = "test-session"
        let noReply = BannerManager.category(for: frame)
        precondition(noReply.actions.map(\.identifier) == [BannerManager.clearAction])
        precondition(noReply.options.contains(.customDismissAction))
        let reply = NotifFrame.Action(id: "reply-original", title: "Reply", type: .textInput(placeholder: "Write a reply"))
        frame.actions = [.init(id: "mark-read", title: "Read", type: .background), reply,
                        .init(id: "unsupported", title: "Unknown", type: .unknown(7))]
        let category = BannerManager.category(for: frame)
        precondition(category.actions[0].identifier == BannerManager.clearAction)
        precondition(category.actions[1] is UNTextInputNotificationAction)
        precondition((category.actions[1] as? UNTextInputNotificationAction)?.textInputPlaceholder == "Write a reply")
        precondition(category.actions.count == 3 && category.identifier != noReply.identifier)
        precondition(BannerManager.category(for: frame).identifier == category.identifier)
        guard case .dismissLocally(let dismissed) = BannerManager.command(for: UNNotificationDismissActionIdentifier, text: nil, frame: frame) else { fatalError("X must only dismiss locally") }
        precondition(dismissed.identity == frame.identity)
        guard case .clearOnIPhone(let cleared) = BannerManager.command(for: BannerManager.clearAction, text: nil, frame: frame) else { fatalError("Clear must use the phone clear command") }
        precondition(cleared.identity == frame.identity)
        guard case .actionInvoked(let replied, let action, let text) = BannerManager.command(for: BannerManager.actionID(reply), text: "Hello 🌍", frame: frame) else { fatalError("native reply must route") }
        precondition(replied.identity == frame.identity && action.id == "reply-original" && text == "Hello 🌍")
        precondition(BannerManager.command(for: BannerManager.actionID(reply), text: nil, frame: frame) == nil)
        precondition(BannerManager.command(for: UNNotificationDefaultActionIdentifier, text: nil, frame: frame) == nil)
        precondition(BannerManager.command(for: "unrecognized", text: nil, frame: frame) == nil)
        print("PASS: native clear category, reply priority/input, stable categories, local-only X, original reply identifiers/text, unknown action rejection")
    }
}
SWIFT
} | xcrun swiftc -swift-version 6 -parse-as-library -target arm64-apple-macos26.0 -o "$ROOT/macos/Build/native-notification-tests" -
"$ROOT/macos/Build/native-notification-tests"
