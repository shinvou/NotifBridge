import SwiftUI
import UserNotifications

struct ContentView: View {
    @Environment(PairingViewModel.self) private var model
    @Environment(HostBLEMonitor.self) private var monitor
    @State private var testNotificationStatus: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    LabeledContent("Accessory", value: model.accessoryName ?? "—")
                    LabeledContent("Forwarding", value: model.decision?.description ?? "—")
                    LabeledContent("BLE link", value: monitor.statusText)
                }

                Section("Test") {
                    Button("Send test notification") {
                        Task { await sendTestNotification() }
                    }
                    .accessibilityIdentifier("send-test-notification-button")
                    if let testNotificationStatus {
                        Text(testNotificationStatus)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Actions") {
                    Button(model.accessory == nil ? "Pair accessory…" : "Accessory paired") {
                        Task { await model.pair() }
                    }
                    .disabled(model.accessory != nil)
                    .accessibilityIdentifier("pair-accessory-button")

                    Button("Request notification forwarding") {
                        Task { await model.requestForwarding() }
                    }
                    .disabled(model.accessory == nil)
                    .accessibilityIdentifier("request-forwarding-button")

                    Button("Refresh status") {
                        Task { await model.refreshStatus() }
                    }
                    .disabled(model.accessory == nil)

                    Button("Open per-app settings") {
                        Task { await model.openSettings() }
                    }
                    .disabled(model.accessory == nil)

                    Button("DIAG: print featureIDs + LA auth") {
                        Task { await model.diagnose() }
                    }
                }

                if let err = model.lastError {
                    Section("Error") {
                        Text(err).foregroundStyle(.red).font(.footnote)
                    }
                }
            }
            .navigationTitle("NotifBridge")
        }
    }

    private func sendTestNotification() async {
        do {
            let center = UNUserNotificationCenter.current()
            // No requestAuthorization here — NotifBridgeApp already requested
            // `.provisional` at init which silently grants. Re-requesting would
            // pop a system alert that blocks the notif scheduling.
            let content = UNMutableNotificationContent()
            content.title = "NotifBridge test"
            content.body = "Local notification \(Date().formatted(date: .omitted, time: .standard))"
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
            try await center.add(request)
            testNotificationStatus = "Scheduled local test notification"
        } catch {
            testNotificationStatus = "Failed to schedule notification: \(error.localizedDescription)"
        }
    }
}
