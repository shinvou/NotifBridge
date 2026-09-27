import SwiftUI
import UIKit
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
    @Environment(\.scenePhase) private var scenePhase
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
                .onChange(of: scenePhase, initial: true) { _, phase in
                    UIApplication.shared.isIdleTimerDisabled = phase == .active
                }
        }
    }

    /// Schedule a local notification when launched with `--send-test-notif`.
    /// Used by the harness to drive end-to-end tests without manual interaction.
    /// Optional `--test-notif-body=<text>` overrides the body so a unique value
    /// per run flows through the AccessoryNotifications pipeline and lets the
    /// Mac receiver verify which notification it just decrypted.
    private static func handleTestNotifArgIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--send-test-notif") || args.contains("--verify-test-clear") else { return }
        let body = args.first(where: { $0.hasPrefix("--test-notif-body=") })
            .map { String($0.dropFirst("--test-notif-body=".count)) }
            ?? "Test \(UUID().uuidString.prefix(8))"
        if args.contains("--verify-test-clear") {
            for delay in [5.0, 30.0, 60.0, 120.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
                        let count = notifications.filter { $0.request.content.body == body }.count
                        print("TEST-CLEAR delivered=\(count) at=\(Int(delay))s")
                        appLog.notice("TEST-CLEAR delivered=\(count, privacy: .public) at=\(Int(delay), privacy: .public)s")
                    }
                }
            }
        }
        guard args.contains("--send-test-notif") else { return }
        let count = args.first(where: { $0.hasPrefix("--test-notif-count=") })
            .flatMap { Int(String($0.dropFirst("--test-notif-count=".count))) } ?? 1
        let initialDelay = args.first(where: { $0.hasPrefix("--test-notif-delay=") })
            .flatMap { Double(String($0.dropFirst("--test-notif-delay=".count))) } ?? 2.0
        let interval = args.first(where: { $0.hasPrefix("--test-notif-interval=") })
            .flatMap { Double(String($0.dropFirst("--test-notif-interval=".count))) } ?? 6.0
        appLog.notice("launch arg --send-test-notif detected; scheduling \(count, privacy: .public) notif(s) body=\(body, privacy: .public) interval=\(interval, privacy: .public)s")

        // .provisional auto-grants notification permission silently — no system
        // prompt. Authorization state becomes .provisional; notifications still
        // fire willPresent and reach AccessoryNotifications forwarding. Useful
        // for dev iteration cycles where the app gets uninstalled/reinstalled.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .provisional]) { granted, err in
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
                let delay = max(1, initialDelay) + Double(i) * interval
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
