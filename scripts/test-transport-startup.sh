#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
{
    cat "$ROOT/shared/DeliveryReceipt.swift"
    sed '/^import AccessoryTransportExtension$/d; /^import CoreBluetooth$/d' "$ROOT/ios/TransportAppExtension/TransportEventHandler.swift"
    cat <<'SWIFT'
enum AccessoryTransport { case bluetooth }
struct TransportMessage { let sessionID: UUID; let data: Data }
enum AccessoryMessage { enum Result { case success, failure(Failure) }; enum Failure { case transportFailed } }
final class AccessoryTransportSession: @unchecked Sendable {
    protocol EventHandler {}
    struct Error: Swift.Error { let description: String }
    var transport: AccessoryTransport?
    var transportStateRestoreIdentifier: String? = "restored-session"
    func sendMessageToDataProvider(_ message: TransportMessage) throws {}
}
struct CBUUID { let uuidString: String }
enum DemoGATT {
    static let service = CBUUID(uuidString: "service")
    static let reverseNotify = CBUUID(uuidString: "reverse")
    static let notification = CBUUID(uuidString: "notification")
}
@MainActor final class AccessoryBLEWriter {
    static var instances: [AccessoryBLEWriter] = []
    let restoreIdentifier: String?
    var stopped = false
    var writes = 0
    var lastReceipt: UUID?
    var autoAcknowledge = false
    var onMessage: ((Data) -> Void)?
    init(category: String, serviceUUID: CBUUID, reverseUUID: CBUUID, restoreIdentifier: String?) {
        self.restoreIdentifier = restoreIdentifier
        Self.instances.append(self)
    }
    func write(_ data: Data, to: CBUUID) async throws {
        writes += 1
        let envelope = try JSONDecoder().decode(NotificationEnvelope.self, from: data)
        lastReceipt = envelope.receiptID
        if autoAcknowledge { onMessage?(try JSONEncoder().encode(DeliveryReceipt(id: envelope.receiptID!))) }
    }
    func stop() { stopped = true }
}
@MainActor final class CompletionFlag { var completed = false }
@main struct StartupRegression {
    @MainActor static func main() async {
        let handler = TransportEventHandler(session: AccessoryTransportSession())
        // Let the handler's main-actor startup run, without delivering any message.
        try? await Task.sleep(for: .milliseconds(20))
        precondition(AccessoryBLEWriter.instances.count == 1, "restoration must initialize Bluetooth before any message arrives")
        let writer = AccessoryBLEWriter.instances[0]
        precondition(writer.restoreIdentifier == "restored-session")
        precondition(writer.writes == 0)
        let completionFlag = CompletionFlag()
        handler.messageReceived(TransportMessage(sessionID: UUID(), data: Data([1]))) { result in
            guard case .success = result else { fatalError("message failed") }
            Task { @MainActor in completionFlag.completed = true }
        }
        try? await Task.sleep(for: .milliseconds(30))
        precondition(writer.writes == 1 && !completionFlag.completed, "BLE write alone must not report success")
        writer.onMessage?(try! JSONEncoder().encode(DeliveryReceipt(id: writer.lastReceipt!)))
        try? await Task.sleep(for: .milliseconds(150))
        precondition(completionFlag.completed, "Mac receipt must complete transmission")
        precondition(AccessoryBLEWriter.instances.count == 1 && writer.writes == 1, "messages must reuse the restored writer")
        handler.sessionInvalidated(error: nil)
        try? await Task.sleep(for: .milliseconds(20))
        precondition(writer.stopped, "invalidation must stop the writer")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            handler.messageReceived(TransportMessage(sessionID: UUID(), data: Data())) { result in
                guard case .failure = result else { fatalError("invalidated session accepted a message") }
                continuation.resume()
            }
        }
        precondition(writer.writes == 1, "invalidation must prevent further writes")
        print("PASS: message-free startup, restoration identifier, shared writer, invalidation")
    }
}
SWIFT
} > "$WORK/Test.swift"
xcrun swiftc -swift-version 6 -parse-as-library "$WORK/Test.swift" -o "$WORK/test"
"$WORK/test"
