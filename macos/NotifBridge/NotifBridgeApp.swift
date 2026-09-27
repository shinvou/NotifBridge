import SwiftUI
import UserNotifications
import os

private let appLog = Logger(subsystem: "com.shinvou.NotifBridge.Mac", category: "app")

@main
struct NotifBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = ReceiverModel()
    @Environment(\.openWindow) private var openWindow
    @State private var launch = LaunchAtLogin()

    init() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let stamp = ISO8601DateFormatter().string(from: Date())
        appLog.notice("NotifBridge Mac app launched @ \(stamp, privacy: .public) pid=\(pid, privacy: .public)")
        NSLog("[NB] NotifBridge Mac app launched @ %@ pid=%d", stamp, pid)

    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environment(model)
                .environment(launch)
        } label: {
            Image(systemName: model.bluetoothReady ? "bell.badge.fill" : "bell.slash")
                .onReceive(NotificationCenter.default.publisher(for: BannerManager.openHistory)) { _ in
                    openWindow(id: "recent")
                }
        }
        .menuBarExtraStyle(.window)

        Window("Recent Notifications", id: "recent") {
            ContentView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 520)
                .onAppear {
                    if ProcessInfo.processInfo.arguments.contains("--show-history") {
                        NSApp.setActivationPolicy(.regular)
                        NSApp.activate()
                    }
                }
        }
        .commands {
            CommandMenu("Notifications") {
                Button("Send Test Banner") { model.presentTestBanner() }
            }
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(ProcessInfo.processInfo.arguments.contains("--show-history") ? .presented : .automatic)
    }
}
