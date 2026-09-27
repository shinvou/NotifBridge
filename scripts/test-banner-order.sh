#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
python3 - "$ROOT" "$WORK/Present.swift" <<'PY'
import sys
s=open(sys.argv[1]+'/macos/NotifBridge/BannerManager.swift').read();a=s.index('    func present(');b=s.index(') {',a)+2;i=b+1;depth=1
while depth:
 depth+=(s[i]=='{')-(s[i]=='}');i+=1
open(sys.argv[2],'w').write(s[a:i])
PY
{
cat "$ROOT/shared/NotifWire.swift"
cat <<'SWIFT'
import UserNotifications
import os
typealias NotifFrame = NotifWire.Notification
@MainActor enum ReceiverModel { final class ActionStatus {} }
@MainActor final class FakeCenter {
    var added: [String] = []
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { true }
    func notificationCategories() async -> Set<UNNotificationCategory> { [] }
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {}
    func add(_ request: UNNotificationRequest) async throws { added.append(request.identifier) }
    func removeDeliveredNotifications(withIdentifiers: [String]) {}
    func deliveredNotifications() async -> [UNNotification] { [] }
}
@MainActor final class Harness {
    let center = FakeCenter()
    var versions: [String: UUID] = [:]
    var presentations: [String: (Bool) -> Void] = [:]
    var categories: [String: UNNotificationCategory] = [:]
    var submissionTask: Task<Void, Never>?
    var onError: ((String) -> Void)?
    let log = Logger(subsystem: "test.order", category: "banner")
    static func category(for: NotifFrame) -> UNNotificationCategory {
        UNNotificationCategory(identifier: "test", actions: [], intentIdentifiers: [], options: [])
    }
    func content(for frame: NotifFrame) async -> UNNotificationContent {
        try? await Task.sleep(for: .milliseconds(frame.notificationIdentifier == "first" ? 100 : 1))
        return UNMutableNotificationContent()
    }
    func finishPresentation(_ id: String, alerted: Bool) { presentations.removeValue(forKey: id)?(alerted) }
SWIFT
cat "$WORK/Present.swift"
cat <<'SWIFT'
}
@main struct Tests {
    @MainActor static func main() async throws {
        let h = Harness()
        let a = NotifFrame(sourceIdentifier: "test", notificationIdentifier: "first")
        let b = NotifFrame(sourceIdentifier: "test", notificationIdentifier: "second")
        h.present(a, status: .init()); h.present(b, status: .init())
        try await Task.sleep(for: .milliseconds(250))
        precondition(h.center.added == [a.id, b.id], "slow icon preparation must not reorder native submission, or add a two-second verification delay")
        print("PASS: asynchronous icon preparation preserves native submission order without waiting for retention checks")
    }
}
SWIFT
} > "$WORK/Test.swift"
xcrun swiftc -swift-version 6 -parse-as-library "$WORK/Test.swift" -o "$WORK/test"
"$WORK/test"
