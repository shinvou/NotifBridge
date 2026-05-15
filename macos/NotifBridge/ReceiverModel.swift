import Foundation
import Observation
import UserNotifications
import os

private let plaintextLog = Logger(subsystem: "com.shinvou.NotifBridge.Mac", category: "hpke")

struct ReceivedNotification: Identifiable {
    let id = UUID()
    let title: String
    let body: String
    let source: String
    let timestamp = Date()
}

@Observable
@MainActor
final class ReceiverModel {
    var bluetoothReady = false
    var statusLine = "starting…"
    var hpkeReady = false
    var keyInfo = ""
    var received: [ReceivedNotification] = []
    var lastError: String?

    private var peripheral: PeripheralManager?
    private let hpke = HPKEDecryptor()
    private var pendingEnvelopes: [NotificationEnvelope] = []

    init() {
        Task { @MainActor in
            await start()
        }
    }

    private func start() async {
        peripheral = PeripheralManager(
            onStateChange: { [weak self] line, ready in
                Task { @MainActor in
                    self?.statusLine = line
                    self?.bluetoothReady = ready
                }
            },
            onKeys: { [weak self] evt in
                Task { @MainActor in self?.handleKeys(evt) }
            },
            onNotification: { [weak self] env in
                Task { @MainActor in self?.handleNotification(env) }
            }
        )
    }

    private func handleKeys(_ evt: ShareKeyEvent) {
        do {
            try hpke.installKeys(
                privateKeySeed: evt.privateKeySeed,
                publicKey: evt.publicKey,
                encapsulatedKey: evt.encapsulatedKey,
                identifier: evt.identifier,
                ciphersuite: evt.ciphersuite,
                version: evt.version
            )
            hpkeReady = true
            keyInfo = "cipher=\(evt.ciphersuite) v=\(evt.version) id=\(evt.identifier.prefix(8)) priv=\(evt.privateKeySeed.count)B pub=\(evt.publicKey.count)B enc=\(evt.encapsulatedKey.count)B"
            // Drain pending notif envelopes that arrived before keys.
            let buffered = pendingEnvelopes
            pendingEnvelopes.removeAll()
            for env in buffered { handleNotification(env) }
        } catch {
            lastError = "key install failed: \(error.localizedDescription)"
        }
    }

    private func handleNotification(_ env: NotificationEnvelope) {
        guard hpkeReady else {
            pendingEnvelopes.append(env)
            return
        }
        do {
            let plaintext = try hpke.decrypt(env.data, sessionID: env.sessionID)
            let ascii = String(data: plaintext.filter { $0 >= 0x20 && $0 < 0x7f }, encoding: .ascii) ?? ""
            plaintextLog.notice("HPKE-PLAINTEXT ascii=\(ascii, privacy: .public)")
            let n = parseFrame(plaintext)
            received.insert(n, at: 0)
            Task { await present(n) }
        } catch {
            plaintextLog.error("decrypt failed for sess=\(env.sessionID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            lastError = "decrypt failed: \(error.localizedDescription)"
        }
    }

    // Mirror NotificationHandler.encode(_:ctx:) on iOS.
    // [kind:1][titleLen:2][title][bodyLen:2][body][srcLen:1][source][idLen:1][id][hasSound:1]
    private func parseFrame(_ data: Data) -> ReceivedNotification {
        var c = Cursor(data)
        _ = c.u8()  // kind
        let title = c.lp16() ?? ""
        let body = c.lp16() ?? ""
        let source = c.lp8() ?? ""
        return ReceivedNotification(title: title, body: body, source: source)
    }

    private func present(_ n: ReceivedNotification) async {
        let content = UNMutableNotificationContent()
        content.title = "\(n.source): \(n.title)"
        content.body = n.body
        let req = UNNotificationRequest(identifier: n.id.uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }
}

private struct Cursor {
    private let data: Data
    private var i: Int = 0
    init(_ data: Data) { self.data = data }

    mutating func u8() -> UInt8? {
        guard i < data.count else { return nil }
        defer { i += 1 }
        return data[i]
    }

    mutating func u16() -> UInt16? {
        guard i + 1 < data.count else { return nil }
        defer { i += 2 }
        return UInt16(data[i]) << 8 | UInt16(data[i + 1])
    }

    mutating func lp8() -> String? {
        guard let len = u8() else { return nil }
        return readString(Int(len))
    }

    mutating func lp16() -> String? {
        guard let len = u16() else { return nil }
        return readString(Int(len))
    }

    private mutating func readString(_ n: Int) -> String? {
        guard i + n <= data.count else { return nil }
        defer { i += n }
        return String(data: data.subdata(in: i..<i + n), encoding: .utf8)
    }
}
