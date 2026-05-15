import Foundation
import AccessoryTransportExtension
import CoreBluetooth
import os

private let txLog = Logger(subsystem: "com.shinvou.NotifBridge", category: "tx-ext")
private func L(_ msg: String) {
    txLog.notice("\(msg, privacy: .public)")
}

final class TransportEventHandler: AccessoryTransportSession.EventHandler, @unchecked Sendable {
    private let session: AccessoryTransportSession
    private lazy var writer = AccessoryBLEWriter(category: "tx-ext-ble", serviceUUID: DemoGATT.service)

    init(session: AccessoryTransportSession) {
        self.session = session
        session.transport = .bluetooth
        L("TransportEventHandler init — transport=\(String(describing: session.transport)) restoreID=\(session.transportStateRestoreIdentifier ?? "nil")")
    }

    func messageReceived(
        _ message: TransportMessage,
        completion: @escaping @Sendable (AccessoryMessage.Result) -> Void
    ) {
        L("messageReceived \(message.data.count)B sessionID=\(message.sessionID)")
        Task { [self] in
            do {
                let envelope = NotificationEnvelope(
                    sessionID: message.sessionID.uuidString,
                    data: message.data
                )
                let payload = try JSONEncoder().encode(envelope)
                try await self.writer.write(payload, to: DemoGATT.notification)
                L("  direct BLE wrote \(payload.count)B")
                completion(.success)
            } catch {
                L("  direct BLE write FAILED: \(error.localizedDescription)")
                completion(.failure(.transportFailed))
            }
        }
    }

    func sessionInvalidated(error: AccessoryTransportSession.Error?) {
        L("sessionInvalidated err=\(error?.description ?? "nil")")
    }
}

private struct NotificationEnvelope: Codable {
    let sessionID: String
    let data: Data
}
