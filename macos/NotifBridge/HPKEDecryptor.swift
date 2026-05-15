import Foundation
import CryptoKit
import os

/// XWingMLKEM768X25519 hybrid post-quantum HPKE decryptor.
///
/// The iPhone Security extension generates the keypair and delivers the private key
/// seed + public key + encapsulated key to us via the `keySharing` characteristic.
/// On the `notification` characteristic, the Transport extension writes ciphertext
/// that iOS encrypted using an HPKE-exported AES-GCM key.
///
/// Empirically determined strategy (matches what iOS 26.5 AccessoryTransportSession
/// uses when `transport = .bluetooth`):
///
///   1. HPKE.Recipient(info: "<cipher>-<version>-<identifier>", encapsulatedKey: ...)
///   2. exportSecret(context: "<cipher>-<version>-<identifier>-HostToAccessory-<sessionID>",
///                   outputByteCount: 32) → AES-256 key
///   3. AES.GCM.open(SealedBox(combined: ciphertext), using: key)
final class HPKEDecryptor {
    private let log = Logger(subsystem: "com.shinvou.NotifBridge.Mac", category: "hpke")
    private let ciphersuite: HPKE.Ciphersuite = .XWingMLKEM768X25519_SHA256_AES_GCM_256

    private var privateKey: XWingMLKEM768X25519.PrivateKey?
    private var encapsulatedKey: Data?
    private var identifier: String = ""
    private var cipherStr: String = ""
    private var version: String = ""

    var keysInstalled: Bool {
        privateKey != nil && encapsulatedKey != nil
    }

    func installKeys(privateKeySeed: Data, publicKey pubKey: Data,
                     encapsulatedKey enc: Data, identifier: String,
                     ciphersuite cipherStr: String, version: String) throws {
        let pub = try XWingMLKEM768X25519.PublicKey(rawRepresentation: pubKey)
        let priv = try XWingMLKEM768X25519.PrivateKey(seedRepresentation: privateKeySeed,
                                                     publicKey: pub)
        self.privateKey = priv
        self.encapsulatedKey = enc
        self.identifier = identifier
        self.cipherStr = cipherStr
        self.version = version
        log.notice("keys installed: id=\(identifier, privacy: .public) cipher=\(cipherStr, privacy: .public) v=\(version, privacy: .public) seed=\(privateKeySeed.count, privacy: .public)B pub=\(pubKey.count, privacy: .public)B enc=\(enc.count, privacy: .public)B")
    }

    func decrypt(_ ciphertext: Data, sessionID: String) throws -> Data {
        guard let priv = privateKey, let enc = encapsulatedKey else {
            throw Failure.notInitialized
        }
        let protocolInfo = "\(cipherStr)-\(version)-\(identifier)"
        let exportContext = "\(protocolInfo)-HostToAccessory-\(sessionID)"
        let recipient = try HPKE.Recipient(
            privateKey: priv,
            ciphersuite: ciphersuite,
            info: Data(protocolInfo.utf8),
            encapsulatedKey: enc
        )
        let secret = try recipient.exportSecret(
            context: Data(exportContext.utf8),
            outputByteCount: 32
        )
        let aesKey = SymmetricKey(data: secret)
        let sealed = try AES.GCM.SealedBox(combined: ciphertext)
        let plaintext = try AES.GCM.open(sealed, using: aesKey)
        log.notice("decrypted \(plaintext.count, privacy: .public)B from \(ciphertext.count, privacy: .public)B sess=\(sessionID, privacy: .public)")
        return plaintext
    }

    enum Failure: Error, CustomStringConvertible {
        case notInitialized
        var description: String {
            switch self {
            case .notInitialized: "HPKE keys not yet received from iPhone"
            }
        }
    }
}
