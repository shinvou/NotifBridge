import Foundation
import AccessoryTransportExtension
import CoreBluetooth
import os

private let txLog = Logger(subsystem: "com.shinvou.NotifBridge", category: "tx-ext")
private func L(_ msg: String) {
    txLog.notice("\(msg, privacy: .public)")
}

/// Receives encrypted notification payloads from the system and writes them to
/// the accessory over BLE. Per docs/FINDINGS.md the Transport extension is the
/// AccessoryTransport context that DeviceAccess grants Bluetooth to — and the
/// Security extension also gets BLE access once the Transport session is open.
final class TransportEventHandler: AccessoryTransportSession.EventHandler, @unchecked Sendable {
    private let session: AccessoryTransportSession
    // One central owns both directions, so reverse commands use the same
    // authorized Bluetooth connection as outgoing messages.
    @MainActor private var writer: AccessoryBLEWriter?
    @MainActor private var invalidated = false
    @MainActor private lazy var receipts = DeliveryReceipts()
    private enum HandlerError: Error { case invalidated }
    @MainActor private func getWriter() throws -> AccessoryBLEWriter {
        guard !invalidated else { throw HandlerError.invalidated }
        if let writer { return writer }
        let writer = AccessoryBLEWriter(category: "tx-ext-ble", serviceUUID: DemoGATT.service,
            reverseUUID: DemoGATT.reverseNotify, restoreIdentifier: session.transportStateRestoreIdentifier)
        writer.onMessage = { [weak self] data in self?.receiveReverseMessage(data) }
        self.writer = writer
        return writer
    }

    init(session: AccessoryTransportSession) {
        self.session = session
        session.transport = .bluetooth
        L("TransportEventHandler init — transport=\(String(describing: session.transport)) restoreID=\(session.transportStateRestoreIdentifier ?? "nil") session=\(ObjectIdentifier(session))")
        // A restoration launch may have no message to deliver until Bluetooth
        // is re-established. Create the central after accepting the session,
        // on its delegate queue, rather than waiting for messageReceived.
        Task { @MainActor [self] in
            guard !invalidated else { return }
            _ = try? getWriter()
            L("Transport Bluetooth startup requested")
        }
    }

    @MainActor private func receiveReverseMessage(_ data: Data) {
        if let receipt = DeliveryReceipt.decode(data) { receipts.receive(receipt); return }
        do {
            let envelope = try JSONDecoder().decode(NotificationEnvelope.self, from: data)
            guard let sessionID = UUID(uuidString: envelope.sessionID) else {
                L("reverse message rejected: invalid session ID")
                return
            }
            try session.sendMessageToDataProvider(TransportMessage(
                sessionID: sessionID, data: envelope.data))
            L("reverse message forwarded to DataProvider (\(envelope.data.count) encrypted bytes)")
        } catch {
            L("reverse message FAILED: \(error.localizedDescription)")
        }
    }

    func messageReceived(
        _ message: TransportMessage,
        completion: @escaping @Sendable (AccessoryMessage.Result) -> Void
    ) {
        let t0 = Date()
        L("messageReceived ENTER \(message.data.count)B sessionID=\(message.sessionID) t0=\(t0.timeIntervalSince1970)")
        Task { @MainActor [self] in
            do {
                let envelope = NotificationEnvelope(
                    sessionID: message.sessionID.uuidString,
                    data: message.data, receiptID: UUID()
                )
                let payload = try JSONEncoder().encode(envelope)
                L("  envelope encoded \(payload.count)B — calling writer.write to \(DemoGATT.notification.uuidString)")
                let writeStart = Date()
                let writer = try self.getWriter()
                try await receipts.send(id: envelope.receiptID!) {
                    try await writer.write(payload, to: DemoGATT.notification)
                }
                let writeDt = Date().timeIntervalSince(writeStart) * 1000
                L("  Mac accepted message after \(Int(writeDt))ms — calling completion(.success)")
                completion(.success)
                let totalDt = Date().timeIntervalSince(t0) * 1000
                L("messageReceived EXIT success total=\(Int(totalDt))ms")
            } catch {
                let totalDt = Date().timeIntervalSince(t0) * 1000
                L("  write FAILED: \(error.localizedDescription) after \(Int(totalDt))ms — calling completion(.transportFailed)")
                completion(.failure(.transportFailed))
            }
        }
    }

    func sessionInvalidated(error: AccessoryTransportSession.Error?) {
        Task { @MainActor [self] in
            invalidated = true
            receipts.stop()
            writer?.stop()
        }
        L("sessionInvalidated err=\(error?.description ?? "nil")")
    }
}
