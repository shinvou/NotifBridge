#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
{
cat "$ROOT/shared/DeliveryReceipt.swift"
cat "$ROOT/shared/KeyExchangePacket.swift"
cat "$ROOT/ios/TransportSecurityExtension/KeyExchangeJournal.swift"
sed '/^import AccessoryTransportExtension$/d; /^import CoreBluetooth$/d' "$ROOT/ios/TransportSecurityExtension/SecurityEventHandler.swift"
cat <<'SWIFT'
enum AccessoryMessage { enum Result: Sendable { case success, failure(Failure) }; enum Failure: Sendable { case transportFailed } }
struct SecurityMessage {
    enum KeyType: String { case publicKey, encapsulatedKey }
    enum Cipher { case xWing }
    enum Version { case version1 }
    enum Transport { case bluetooth }
    let keyType: KeyType
    let cipherSuite: Cipher
    let version: Version
    let key: Data
    var supportedTransports: [Transport] = [.bluetooth]
    var identifier: String? = "test"
}
final class AccessorySecuritySession: @unchecked Sendable {
    protocol EventHandler {}
    enum Error: Swift.Error { case unknown; var description: String { "unknown" } }
    func cancel(error: Error?) {}
    var sent = 0
    func sendSecurityMessage(_ message: SecurityMessage) throws { sent += 1 }
}
struct CBUUID { let uuidString: String }
enum DemoGATT {
    static let service = CBUUID(uuidString: "service")
    static let reverseNotify = CBUUID(uuidString: "reverse")
    static let keySharing = CBUUID(uuidString: "keys")
}
@MainActor final class AccessoryBLEWriter {
    static var instances: [AccessoryBLEWriter] = []
    var onMessage: ((Data) -> Void)?
    var receiptID: UUID?
    var stopped = false
    init(category: String, serviceUUID: CBUUID, reverseUUID: CBUUID, relayReceipts: Bool) {
        precondition(!relayReceipts, "key frames must not use notification-only relay wrappers")
        Self.instances.append(self)
    }
    func write(_ data: Data, to: CBUUID) async throws {
        receiptID = try JSONDecoder().decode(KeyExchangePacket.self, from: data).receiptID
    }
    func stop() { stopped = true }
}
@MainActor final class ResultBox { var completed = false }
@main struct Tests {
    @MainActor static func main() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let journal = KeyExchangeJournal(url: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = AccessorySecuritySession()
        let handler = SecurityEventHandler(session: session, journal: journal)
        precondition(session.sent == 0, "must not publish before Mac preparation")
        try await Task.sleep(for: .milliseconds(30))
        let writer = AccessoryBLEWriter.instances[0]
        precondition(session.sent == 0, "BLE prepare write alone must not publish key")
        precondition(try! journal.load()?.phase == .prepare, "preparation must survive extension termination")
        writer.onMessage?(try JSONEncoder().encode(DeliveryReceipt(id: writer.receiptID!)))
        try await Task.sleep(for: .milliseconds(150))
        precondition(session.sent == 1)
        let result = ResultBox()
        handler.messageReceived(SecurityMessage(keyType: .encapsulatedKey, cipherSuite: .xWing, version: .version1, key: Data(repeating: 1, count: 1120))) { outcome in
            guard case .success = outcome else { fatalError("key delivery failed") }
            Task { @MainActor in result.completed = true }
        }
        try await Task.sleep(for: .milliseconds(30))
        precondition(!result.completed, "activation BLE write alone must not complete exchange")
        let saved = try journal.load()!
        precondition(saved.phase == .activate && saved.publicKey == nil && saved.privateKeySeed == nil)
        // Model a security-extension process dying before the Mac's receipt.
        // A fresh handler must replay activation before advertising another key.
        let replacementSession = AccessorySecuritySession()
        let replacement = SecurityEventHandler(session: replacementSession, journal: journal)
        try await Task.sleep(for: .milliseconds(30))
        let replacementWriter = AccessoryBLEWriter.instances[1]
        precondition(replacementSession.sent == 0 && replacementWriter.receiptID == saved.receiptID)
        replacementWriter.onMessage?(try JSONEncoder().encode(DeliveryReceipt(id: saved.receiptID)))
        try await Task.sleep(for: .milliseconds(150))
        precondition(try! journal.load()?.phase == .prepare, "confirmed activation must advance to new preparation")
        precondition(replacementSession.sent == 0, "new preparation still requires a Mac receipt")
        replacementWriter.onMessage?(try JSONEncoder().encode(DeliveryReceipt(id: replacementWriter.receiptID!)))
        try await Task.sleep(for: .milliseconds(150))
        precondition(replacementSession.sent == 1)
        // Resolve the original fake process without letting it clear the new journal.
        writer.onMessage?(try JSONEncoder().encode(DeliveryReceipt(id: saved.receiptID)))
        try await Task.sleep(for: .milliseconds(150))
        precondition(result.completed && (try! journal.load()) != nil)
        replacement.sessionInvalidated(error: nil)
        handler.sessionInvalidated(error: nil)
        try await Task.sleep(for: .milliseconds(20))
        precondition(writer.stopped && replacementWriter.stopped)
        print("PASS: prepare-before-publish, durable activation replay after termination, stale receipt isolation, cleanup")
    }
}
SWIFT
} > "$WORK/Test.swift"
xcrun swiftc -swift-version 6 -parse-as-library "$WORK/Test.swift" -o "$WORK/test"
"$WORK/test"
