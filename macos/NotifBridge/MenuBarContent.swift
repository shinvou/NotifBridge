import SwiftUI

struct MenuBarContent: View {
    @Environment(ReceiverModel.self) private var model
    @Environment(LaunchAtLogin.self) private var launch
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().scaledToFit().frame(width: 44, height: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("NotifBridge").font(.headline)
                    Label(model.bluetoothReady ? "Connected to bridge" : "Waiting for connection",
                          systemImage: model.bluetoothReady ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                        .font(.subheadline)
                        .foregroundStyle(model.bluetoothReady ? .green : .secondary)
                }
            }
            Button(action: openHistory) {
                HStack {
                    Label("Notification inbox", systemImage: "tray")
                    Spacer()
                    Text("\(model.received.filter { !$0.isCleared }.count)")
                        .foregroundStyle(.secondary).monospacedDigit()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }.padding(.vertical, 6)
            }
            .keyboardShortcut("r")
            .buttonStyle(.bordered)
            .controlSize(.large)

            Divider()
            VStack(spacing: 12) {
                preference("Notification sound", systemImage: "speaker.wave.2", isOn: $model.soundEnabled)
                preference("Show quiet notifications", systemImage: "moon", isOn: $model.showQuietNotifications)
                    .help("Include notifications silenced by iPhone Focus or quiet delivery. Mac notification settings and app muting still apply.")
                preference("Launch at login", systemImage: "power", isOn: Binding(
                    get: { launch.isEnabled }, set: { launch.setEnabled($0) }
                ))
            }.toggleStyle(.switch)
            if !launch.isEnabled && launch.status == .requiresApproval {
                Text(launch.statusDescription).font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Connection details") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.statusLine)
                    if !model.keyInfo.isEmpty { Text(model.keyInfo).textSelection(.enabled) }
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }
            Divider()
            HStack {
                Button("Test notification", systemImage: "bell.badge") { model.presentTestBanner() }
                    .keyboardShortcut("t")
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }.buttonStyle(.borderless)
        }
        .padding(20)
        .frame(width: 360)
    }

    private func preference(_ title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(title)
            Spacer(minLength: 12)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openHistory() {
        openWindow(id: "recent")
        NSApp.activate(ignoringOtherApps: true)
    }
}
