import SwiftUI

struct ContentView: View {
    @Environment(ReceiverModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Bluetooth", systemImage: model.bluetoothReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(model.bluetoothReady ? .green : .orange)
                Text(model.statusLine).font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("HPKE state").font(.headline)
                Text(model.hpkeReady
                     ? "keys installed — ready to decrypt"
                     : "waiting for iPhone Security extension to deliver keys…")
                    .font(.caption)
                    .foregroundStyle(model.hpkeReady ? .green : .secondary)
                if !model.keyInfo.isEmpty {
                    Text(model.keyInfo).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
                if let err = model.lastError {
                    Text(err).font(.caption2).foregroundStyle(.red)
                }
            }

            Divider()

            VStack(alignment: .leading) {
                Text("Recent notifications").font(.headline)
                List(model.received) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title.isEmpty ? "(no title)" : entry.title).font(.body)
                        if !entry.body.isEmpty {
                            Text(entry.body).font(.callout).foregroundStyle(.secondary)
                        }
                        Text("\(entry.source) · \(entry.timestamp.formatted(date: .omitted, time: .standard))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding()
    }
}
