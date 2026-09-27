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
    private static let keychainAccount = "nb-hpke-keys-v1"

    private struct KeyMaterial {
        let privateKey: XWingMLKEM768X25519.PrivateKey
        let encapsulatedKey: Data
        let identifier: String
        let cipherStr: String
        let version: String
        var expiresAt: Date?
        var protocolInfo: String { "\(cipherStr)-\(version)-\(identifier)" }
    }
    private var keys: [KeyMaterial] = []
    private let previousKeyLifetime: TimeInterval
    init(previousKeyLifetime: TimeInterval = 300) { self.previousKeyLifetime = previousKeyLifetime }
    private func discardExpiredKeys() {
        keys.removeAll { $0.expiresAt.map { $0 <= Date() } ?? false }
    }

    /// Persisted to Keychain so Mac restarts don't lose keys (iPhone's
    /// TransportSecurity only fires on initial-pair / explicit rekey; without
    /// persistence we'd be stuck `QUEUED — keys not yet installed` after every
    /// Mac restart).
    private struct StoredKeys: Codable {
        let privateKeySeed: Data
        let publicKey: Data
        let encapsulatedKey: Data
        let identifier: String
        let cipherStr: String
        let version: String
    }

    private struct PreparedKey: Codable {
        let id: UUID
        let seed: Data
        let publicKey: Data
    }
    private static let preparedAccount = "nb-hpke-prepared-v1"

    /// Receipt must follow durable storage, so extension termination and Mac
    /// restart between prepare and activate cannot lose the prepared keypair.
    func acceptKeyPacket(_ packet: KeyExchangePacket) throws {
        var prepared = KeychainStore.load([PreparedKey].self, account: Self.preparedAccount) ?? []
        switch packet.phase {
        case .prepare:
            guard let seed = packet.privateKeySeed, seed.count == 32,
                  let publicKey = packet.publicKey, publicKey.count == 1216,
                  packet.encapsulatedKey == nil else { throw Failure.invalidKeyPacket }
            let pub = try XWingMLKEM768X25519.PublicKey(rawRepresentation: publicKey)
            _ = try XWingMLKEM768X25519.PrivateKey(seedRepresentation: seed, publicKey: pub)
            if let existing = prepared.first(where: { $0.id == packet.exchangeID }) {
                guard existing.seed == seed, existing.publicKey == publicKey else { throw Failure.invalidKeyPacket }
                return
            }
            prepared.append(PreparedKey(id: packet.exchangeID, seed: seed, publicKey: publicKey))
            if prepared.count > 4 { prepared.removeFirst(prepared.count - 4) }
            try KeychainStore.save(prepared, account: Self.preparedAccount)
        case .activate:
            guard let key = prepared.first(where: { $0.id == packet.exchangeID }),
                  let enc = packet.encapsulatedKey, enc.count == 1120,
                  let identifier = packet.identifier, let cipher = packet.ciphersuite,
                  let version = packet.version else { throw Failure.invalidKeyPacket }
            try installKeys(privateKeySeed: key.seed, publicKey: key.publicKey,
                encapsulatedKey: enc, identifier: identifier, ciphersuite: cipher, version: version)
        }
    }

    var keysInstalled: Bool {
        !keys.isEmpty
    }

    /// Returns a short info string when keys were restored from Keychain so
    /// callers can mirror the same "keys installed" UX they emit on fresh
    /// install. Returns nil if no persisted keys or restore fails.
    @discardableResult
    func restoreFromKeychain() -> String? {
        guard let stored = KeychainStore.load(StoredKeys.self, account: Self.keychainAccount) else {
            log.notice("no persisted keys in Keychain")
            return nil
        }
        do {
            try installKeysInternal(
                privateKeySeed: stored.privateKeySeed,
                publicKey: stored.publicKey,
                encapsulatedKey: stored.encapsulatedKey,
                identifier: stored.identifier,
                cipherStr: stored.cipherStr,
                version: stored.version,
                source: "Keychain"
            )
            return "cipher=\(stored.cipherStr) v=\(stored.version) id=\(stored.identifier.prefix(8)) priv=\(stored.privateKeySeed.count)B (restored)"
        } catch {
            log.error("Keychain restore failed: \(error.localizedDescription, privacy: .public) — purging stale entry")
            KeychainStore.delete(account: Self.keychainAccount)
            return nil
        }
    }

    func installKeys(privateKeySeed: Data, publicKey pubKey: Data,
                     encapsulatedKey enc: Data, identifier: String,
                     ciphersuite cipherStr: String, version: String) throws {
        try installKeysInternal(
            privateKeySeed: privateKeySeed,
            publicKey: pubKey,
            encapsulatedKey: enc,
            identifier: identifier,
            cipherStr: cipherStr,
            version: version,
            source: "BLE"
        )
        // A retransmission of a retained older generation must not replace the
        // current generation in Keychain.
        guard keys.first?.encapsulatedKey == enc, keys.first?.identifier == identifier else { return }
        let stored = StoredKeys(
            privateKeySeed: privateKeySeed,
            publicKey: pubKey,
            encapsulatedKey: enc,
            identifier: identifier,
            cipherStr: cipherStr,
            version: version
        )
        do {
            try KeychainStore.save(stored, account: Self.keychainAccount)
            log.notice("keys persisted to Keychain")
        } catch {
            log.error("Keychain save failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func installKeysInternal(privateKeySeed: Data, publicKey pubKey: Data,
                                     encapsulatedKey enc: Data, identifier: String,
                                     cipherStr: String, version: String,
                                     source: String) throws {
        let pub = try XWingMLKEM768X25519.PublicKey(rawRepresentation: pubKey)
        let priv = try XWingMLKEM768X25519.PrivateKey(seedRepresentation: privateKeySeed,
                                                     publicKey: pub)
        _ = try HPKE.Recipient(privateKey: priv, ciphersuite: ciphersuite,
            info: Data("\(cipherStr)-\(version)-\(identifier)".utf8), encapsulatedKey: enc)
        discardExpiredKeys()
        if keys.contains(where: { $0.encapsulatedKey == enc && $0.identifier == identifier &&
            $0.cipherStr == cipherStr && $0.version == version &&
            $0.privateKey.publicKey.rawRepresentation == pubKey }) { return }
        if !keys.isEmpty { keys[0].expiresAt = Date().addingTimeInterval(previousKeyLifetime) }
        keys.insert(KeyMaterial(privateKey: priv, encapsulatedKey: enc, identifier: identifier,
            cipherStr: cipherStr, version: version), at: 0)
        if keys.count > 4 { keys.removeLast(keys.count - 4) }
        log.notice("keys loaded (\(source, privacy: .public)): id=\(identifier, privacy: .public) cipher=\(cipherStr, privacy: .public) v=\(version, privacy: .public) seed=\(privateKeySeed.count, privacy: .public)B pub=\(pubKey.count, privacy: .public)B enc=\(enc.count, privacy: .public)B")
    }

    func decrypt(_ ciphertext: Data, sessionID: String) throws -> Data {
        discardExpiredKeys()
        guard !keys.isEmpty else { throw Failure.notInitialized }
        let sealed = try AES.GCM.SealedBox(combined: ciphertext)
        var lastError: any Error = CryptoKitError.authenticationFailure
        for material in keys {
            do {
                let recipient = try HPKE.Recipient(privateKey: material.privateKey,
                    ciphersuite: ciphersuite, info: Data(material.protocolInfo.utf8),
                    encapsulatedKey: material.encapsulatedKey)
                let secret = try recipient.exportSecret(
                    context: Data("\(material.protocolInfo)-HostToAccessory-\(sessionID)".utf8), outputByteCount: 32)
                return try AES.GCM.open(sealed, using: SymmetricKey(data: secret))
            } catch { lastError = error }
        }
        throw lastError
    }

    /// Encrypt replies with the direction-specific key expected by iOS.
    func encryptReverse(_ plaintext: Data, sessionID: String) throws -> Data {
        guard let material = keys.first else {
            throw Failure.notInitialized
        }
        let protocolInfo = material.protocolInfo
        let recipient = try HPKE.Recipient(privateKey: material.privateKey, ciphersuite: ciphersuite,
            info: Data(protocolInfo.utf8), encapsulatedKey: material.encapsulatedKey)
        let secret = try recipient.exportSecret(
            context: Data("\(protocolInfo)-AccessoryToHost-\(sessionID)".utf8),
            outputByteCount: 32)
        return try AES.GCM.seal(plaintext, using: SymmetricKey(data: secret)).combined!
    }

    enum Failure: Error, CustomStringConvertible {
        case notInitialized, invalidKeyPacket
        var description: String {
            switch self {
            case .notInitialized: "HPKE keys not yet received from iPhone"
            case .invalidKeyPacket: "Invalid or unknown prepared key generation"
            }
        }
    }
}
