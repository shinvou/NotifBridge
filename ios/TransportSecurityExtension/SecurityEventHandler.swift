import Foundation
import AccessoryTransportExtension
import CoreBluetooth
import CryptoKit
import os

private let secLog = Logger(subsystem: "com.shinvou.NotifBridge", category: "sec-ext")
private func L(_ msg: String) { secLog.notice("\(msg, privacy: .public)") }

/// First prepare and persist the keypair on Mac. Only then advertise its public
/// key to iOS. Never depend on the security extension surviving a BLE transfer.
final class SecurityEventHandler: AccessorySecuritySession.EventHandler, @unchecked Sendable {
    private let session: AccessorySecuritySession
    private let journal: KeyExchangeJournal
    @MainActor private lazy var receipts = DeliveryReceipts()
    @MainActor private var writer: AccessoryBLEWriter?
    @MainActor private var invalidated = false
    @MainActor private var preparedKey: (id: UUID, publicKey: Data)?
    @MainActor private var activationInProgress = false

    init(session: AccessorySecuritySession, journal: KeyExchangeJournal = KeyExchangeJournal()) {
        self.session = session
        self.journal = journal
        L("SecurityEventHandler init pid=\(ProcessInfo.processInfo.processIdentifier)")
        Task { @MainActor [self] in
            do {
                var preparation: KeyExchangePacket?
                if let pending = try journal.load() {
                    if pending.phase == .activate {
                        L("Recovering interrupted key activation")
                        try await transmit(pending)
                        try journal.clear(pending.receiptID)
                        L("Interrupted key activation recovered")
                    } else {
                        preparation = pending
                    }
                }
                guard !invalidated else { return }
                if preparation == nil {
                    let key = try XWingMLKEM768X25519.PrivateKey()
                    preparation = KeyExchangePacket(phase: .prepare, exchangeID: UUID(), receiptID: UUID(),
                        publicKey: key.publicKey.rawRepresentation, privateKeySeed: key.seedRepresentation)
                }
                guard let packet = preparation, let publicKey = packet.publicKey else {
                    throw KeyExchangeJournal.Failure.invalidRecord
                }
                // This also verifies own-container persistence before iOS can
                // switch keys. Reuse it if the extension dies before activation.
                try journal.save(packet)
                try await transmit(packet)
                guard !invalidated else { return }
                preparedKey = (packet.exchangeID, publicKey)
                try publishPreparedKey()
            } catch {
                L("Key preparation/recovery failed: \(error.localizedDescription)")
                if !invalidated { self.session.cancel(error: .unknown) }
            }
        }
    }

    @MainActor private func getWriter() throws -> AccessoryBLEWriter {
        guard !invalidated else { throw DeliveryReceipts.Failure.stopped }
        if let writer { return writer }
        let writer = AccessoryBLEWriter(category: "sec-ext-ble", serviceUUID: DemoGATT.service,
            reverseUUID: DemoGATT.reverseNotify, relayReceipts: false)
        writer.onMessage = { [weak self] data in
            if let receipt = DeliveryReceipt.decode(data) { self?.receipts.receive(receipt) }
        }
        self.writer = writer
        return writer
    }

    @MainActor private func transmit(_ packet: KeyExchangePacket) async throws {
        let data = try JSONEncoder().encode(packet)
        let writer = try getWriter()
        try await receipts.send(id: packet.receiptID) { try await writer.write(data, to: DemoGATT.keySharing) }
        L("Mac confirmed key phase=\(packet.phase.rawValue) bytes=\(data.count)")
    }

    @MainActor private func publishPreparedKey() throws {
        guard !invalidated, let preparedKey else { throw DeliveryReceipts.Failure.stopped }
        try session.sendSecurityMessage(SecurityMessage(keyType: .publicKey, cipherSuite: .xWing,
            version: .version1, key: preparedKey.publicKey, supportedTransports: [.bluetooth]))
        L("Published public key after Mac durable preparation")
    }

    func messageReceived(_ message: SecurityMessage,
                         completion: @escaping @Sendable (AccessoryMessage.Result) -> Void) {
        Task { @MainActor [self] in
            do {
                guard !invalidated else { throw DeliveryReceipts.Failure.stopped }
                switch message.keyType {
                case .publicKey:
                    // Reuse the prepared pair; replacing it here can orphan a
                    // concurrently arriving encapsulation for the previous pair.
                    try publishPreparedKey()
                case .encapsulatedKey:
                    guard let preparedKey, !activationInProgress else { throw DeliveryReceipts.Failure.stopped }
                    activationInProgress = true
                    defer { activationInProgress = false }
                    let packet = KeyExchangePacket(phase: .activate, exchangeID: preparedKey.id, receiptID: UUID(),
                        encapsulatedKey: message.key, identifier: message.identifier ?? "",
                        ciphersuite: String(describing: message.cipherSuite), version: String(describing: message.version))
                    try journal.save(packet)
                    L("Key activation journaled before BLE write")
                    try await transmit(packet)
                    try journal.clear(packet.receiptID)
                @unknown default:
                    throw DeliveryReceipts.Failure.stopped
                }
                completion(.success)
            } catch {
                L("Key exchange failed: \(error.localizedDescription)")
                completion(.failure(.transportFailed))
            }
        }
    }

    func sessionInvalidated(error: AccessorySecuritySession.Error?) {
        Task { @MainActor [self] in
            invalidated = true
            receipts.stop()
            writer?.stop()
        }
        L("sessionInvalidated err=\(error?.description ?? "nil")")
    }
}
