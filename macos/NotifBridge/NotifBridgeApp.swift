import SwiftUI
import UserNotifications

final class ForegroundBannerDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

@MainActor private let foregroundDelegate = ForegroundBannerDelegate()

@main
struct NotifBridgeApp: App {
    @State private var model = ReceiverModel()

    init() {
        UNUserNotificationCenter.current().delegate = foregroundDelegate
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 480, minHeight: 360)
        }
    }
}
