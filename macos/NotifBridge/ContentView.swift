import SwiftUI

struct ContentView: View {
    @Environment(ReceiverModel.self) private var model
    @State private var query = ""
    @State private var selectedSource = ""
    @State private var includeCleared = false
    @State private var selection: String?
    @State private var confirmErase = false
    private var sources: [String] { Array(Set(model.received.map(\.sourceIdentifier))).sorted() }
    private var filtered: [NotifFrame] {
        model.received.filter { item in
            (includeCleared || !item.isCleared) && (selectedSource.isEmpty || item.sourceIdentifier == selectedSource)
                && (query.isEmpty || [item.title, item.body, item.summary, item.sourceName].contains { $0.localizedStandardContains(query) })
        }.sorted { $0.deliveryDate > $1.deliveryDate }
    }
    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if let error = model.lastError {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.callout)
                    Spacer()
                    Button("Dismiss") { model.lastError = nil }
                }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 20).padding(.bottom, 12)
            }
            HStack {
                Picker("App", selection: $selectedSource) {
                    Text("All apps").tag("")
                    ForEach(sources, id: \.self) { source in Text(model.received.first { $0.sourceIdentifier == source }?.sourceName ?? source).tag(source) }
                }.frame(maxWidth: 260)
                Toggle("Include cleared", isOn: $includeCleared)
                Spacer()
            }.padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            HSplitView {
                List(selection: $selection) {
                    ForEach(filtered) { item in
                        HStack(alignment: .top, spacing: 10) {
                            if let icon = item.displayIcon {
                                Image(nsImage: icon).resizable().scaledToFit()
                                    .frame(width: 30, height: 30).accessibilityHidden(true)
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(item.sourceName).lineLimit(1)
                                    Spacer()
                                    Text(item.deliveryDate, format: .dateTime.month(.abbreviated).day().hour().minute())
                                        .lineLimit(1)
                                }.font(.caption).foregroundStyle(.secondary)
                                Text(item.title.isEmpty ? item.sourceName : item.title)
                                    .font(.body.weight(.semibold)).lineLimit(1)
                                Text(item.summary.isEmpty ? item.body : item.summary)
                                    .font(.callout).lineLimit(2).foregroundStyle(.secondary)
                                if item.isCleared { Label("Cleared", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary) }
                                if item.isSuppressedByFocus { Label("Focus", systemImage: "moon").font(.caption).foregroundStyle(.secondary) }
                            }
                        }.padding(.vertical, 8).tag(item.id)
                                .contextMenu {
                                    Button(model.mutedApps.contains(item.sourceIdentifier) ? "Unmute this app on Mac" : "Mute this app on Mac") { model.toggleMute(item.sourceIdentifier) }
                                    Button("Clear from iPhone") { model.handle(.clearOnIPhone(item)) }
                                        .disabled(item.isCleared || item.transportSessionID == nil)
                                }
                    }
                }
                .listStyle(.inset)
                .frame(minWidth: 300, idealWidth: 350, maxWidth: 420)
                .overlay { if filtered.isEmpty { ContentUnavailableView(query.isEmpty && selectedSource.isEmpty ? "No notifications" : "No matching notifications", systemImage: "bell", description: Text("Forwarded notifications appear here, including those delivered silently.")) } }
                Group {
                    if let item = filtered.first(where: { $0.id == selection }) {
                        BannerView(frame: item, status: model.status(for: item), compact: false,
                            onDismiss: {}, onClear: { model.handle(.clearOnIPhone(item)) },
                            onAction: { action, text in model.handle(.actionInvoked(item, action, userText: text)) },
                            onRetry: { model.handle(.retry(item)) }).padding(28)
                    } else { ContentUnavailableView("Select a notification", systemImage: "bell.badge", description: Text("View content, attachments, and actions.")) }
                }.frame(minWidth: 360, idealWidth: 500, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            HStack {
                Text("\(filtered.count) notifications")
                Spacer()
                Label(model.bluetoothReady ? "Connected to bridge" : "Disconnected",
                      systemImage: model.bluetoothReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(model.bluetoothReady ? .green : .secondary)
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
        }
        .toolbar {
            ToolbarItemGroup {
                Toggle("Notification sound", systemImage: "speaker.wave.2", isOn: $model.soundEnabled)
                    .help("Play a sound when a notification arrives")
                Menu("Inbox options", systemImage: "ellipsis.circle") {
                    Toggle("Show quiet iPhone notifications", isOn: $model.showQuietNotifications)
                    Divider()
                    Button("Delete saved history…", systemImage: "trash", role: .destructive) { confirmErase = true }
                }
            }
        }
        .searchable(text: $query, prompt: "Search notifications")
        .confirmationDialog("Delete notification history from this Mac?", isPresented: $confirmErase) {
            Button("Delete saved history", role: .destructive) { model.eraseLocalHistory() }
        } message: { Text("Notifications on your iPhone are not affected.") }
    }
}
