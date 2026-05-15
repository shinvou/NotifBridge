import Foundation
import AccessoryTransportExtension
import CoreBluetooth
import CryptoKit
import os

private let secLog = Logger(subsystem: "com.shinvou.NotifBridge", category: "sec-ext")
private func L(_ msg: String) {
    secLog.notice("\(msg, privacy: .public)")
}

final class SecurityEventHandler: AccessorySecuritySession.EventHandler, @unchecked Sendable {
    private let session: AccessorySecuritySession
    private lazy var writer = AccessoryBLEWriter(category: "sec-ext-ble", serviceUUID: DemoGATT.service)
    private var privateKey: XWingMLKEM768X25519.PrivateKey?
    private var publicKeyData: Data?

    init(session: AccessorySecuritySession) {
        self.session = session
        L("SecurityEventHandler init — direct BLE DeviceAccessForMedia experiment")
        sendInitialPublicKey()
    }

    private func sendInitialPublicKey() {
        do {
            let priv = try XWingMLKEM768X25519.PrivateKey()
            let pubData = priv.publicKey.rawRepresentation
            self.privateKey = priv
            self.publicKeyData = pubData
            L("proactive pubkey: generated XWing keypair, pub=\(pubData.count)B — sending to system")
            let msg = SecurityMessage(
                keyType: .publicKey,
                cipherSuite: .xWing,
                version: .version1,
                key: pubData,
                supportedTransports: [.bluetooth]
            )
            try session.sendSecurityMessage(msg)
            L("proactive pubkey: sendSecurityMessage(.publicKey) OK")
        } catch {
            L("proactive pubkey FAILED: \(error.localizedDescription)")
        }
    }

    func messageReceived(
        _ message: SecurityMessage,
        completion: @escaping @Sendable (AccessoryMessage.Result) -> Void
    ) {
        L("messageReceived keyType=\(message.keyType.rawValue) cipher=\(message.cipherSuite) keyLen=\(message.key.count)")
        switch message.keyType {
        case .publicKey:
            handleKeyRequest(completion: completion)
        case .encapsulatedKey:
            handleKeyExchange(encapsulatedKey: message.key, message: message, completion: completion)
        @unknown default:
            L("  unknown keyType → success")
            completion(.success)
        }
    }

    private func handleKeyRequest(completion: @Sendable (AccessoryMessage.Result) -> Void) {
        do {
            let priv = try XWingMLKEM768X25519.PrivateKey()
            let pubData = priv.publicKey.rawRepresentation
            self.privateKey = priv
            self.publicKeyData = pubData
            L("  generated XWing keypair, pubKey=\(pubData.count) bytes — sending keyReply")
            let reply = SecurityMessage(
                keyType: .publicKey,
                cipherSuite: .xWing,
                version: .version1,
                key: pubData,
                supportedTransports: [.bluetooth]
            )
            try session.sendSecurityMessage(reply)
            L("  sendSecurityMessage(.publicKey) OK")
            completion(.success)
        } catch {
            L("  handleKeyRequest FAILED: \(error.localizedDescription)")
            completion(.failure(.transportFailed))
        }
    }

    private func handleKeyExchange(
        encapsulatedKey: Data,
        message: SecurityMessage,
        completion: @escaping @Sendable (AccessoryMessage.Result) -> Void
    ) {
        guard let priv = privateKey, let pubData = publicKeyData else {
            L("  missing key state — failure")
            completion(.failure(.transportFailed))
            return
        }
        let privSeed = priv.seedRepresentation
        let identifier = message.identifier ?? ""
        let cipher = String(describing: message.cipherSuite)
        let version = String(describing: message.version)
        L("  encapsulated=\(encapsulatedKey.count)B id=\(identifier) cipher=\(cipher) v=\(version) — writing ShareKeyEvent over BLE")

        Task { [self, session] in
            do {
                let payload = ShareKeyEvent(
                    identifier: identifier, ciphersuite: cipher, version: version,
                    encapsulatedKey: encapsulatedKey, publicKey: pubData, privateKeySeed: privSeed
                )
                let data = try JSONEncoder().encode(payload)
                try await self.writer.write(data, to: DemoGATT.keySharing)
                L("  direct BLE wrote ShareKeyEvent (\(data.count)B)")
                completion(.success)
            } catch {
                L("  direct BLE keySharing FAILED: \(error.localizedDescription)")
                completion(.failure(.transportFailed))
            }
        }
    }

    func sessionInvalidated(error: AccessorySecuritySession.Error?) {
        L("sessionInvalidated err=\(error?.description ?? "nil")")
    }
}

private struct ShareKeyEvent: Codable {
    let identifier: String
    let ciphersuite: String
    let version: String
    let encapsulatedKey: Data
    let publicKey: Data
    let privateKeySeed: Data
}
