import SwiftUI
import UserNotifications
import os

private let appLog = Logger(subsystem: "com.shinvou.NotifBridge", category: "app")

final class ForegroundBannerDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        appLog.notice("willPresent fired — returning [.banner, .list, .sound] so AccessoryNotifications forwards")
        completionHandler([.banner, .list, .sound])
    }
}

@MainActor private let foregroundDelegate = ForegroundBannerDelegate()

@main
struct NotifBridgeApp: App {
    @State private var model = PairingViewModel()
    @State private var monitor = HostBLEMonitor()

    init() {
        appLog.notice("NotifBridgeApp init")
        UNUserNotificationCenter.current().delegate = foregroundDelegate
        Self.handleTestNotifArgIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .environment(monitor)
                .onAppear { monitor.start() }
        }
    }

    /// Schedule a local notification when launched with `--send-test-notif`.
    /// Used by the harness to drive end-to-end tests without manual interaction.
    /// Optional `--test-notif-body=<text>` overrides the body so a unique value
    /// per run flows through the AccessoryNotifications pipeline and lets the
    /// Mac receiver verify which notification it just decrypted.
    private static func handleTestNotifArgIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--send-test-notif") else { return }
        let body = args.first(where: { $0.hasPrefix("--test-notif-body=") })
            .map { String($0.dropFirst("--test-notif-body=".count)) }
            ?? "Test \(UUID().uuidString.prefix(8))"
        let count = args.first(where: { $0.hasPrefix("--test-notif-count=") })
            .flatMap { Int(String($0.dropFirst("--test-notif-count=".count))) } ?? 1
        appLog.notice("launch arg --send-test-notif detected; scheduling \(count, privacy: .public) notif(s) body=\(body, privacy: .public)")

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, err in
            if let err = err {
                appLog.error("auth err: \(err.localizedDescription, privacy: .public)")
                return
            }
            appLog.notice("UN auth granted=\(granted, privacy: .public)")
            for i in 0..<count {
                let content = UNMutableNotificationContent()
                content.title = "NotifBridge"
                content.body = count > 1 ? "\(body)-\(i + 1)" : body
                content.sound = .default
                let delay = 2.0 + Double(i) * 6.0
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
                let req = UNNotificationRequest(
                    identifier: "test-notif-\(UUID().uuidString)",
                    content: content,
                    trigger: trigger
                )
                UNUserNotificationCenter.current().add(req) { err in
                    if let err = err {
                        appLog.error("add notif #\(i + 1) err: \(err.localizedDescription, privacy: .public)")
                    } else {
                        appLog.notice("test notif #\(i + 1) scheduled (fires in \(delay, privacy: .public)s)")
                    }
                }
            }
        }
    }
}
