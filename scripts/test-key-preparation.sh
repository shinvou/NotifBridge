#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/Test.swift" <<'SWIFT'
import Foundation
import CryptoKit
enum KeychainStore {
    static var storage: [String: Data] = [:]
    static var failSave = false
    enum Failure: Error { case unavailable }
    static func load<T: Codable>(_ type: T.Type, account: String) -> T? {
        storage[account].flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
    static func save<T: Codable>(_ value: T, account: String) throws {
        if failSave { throw Failure.unavailable }
        storage[account] = try JSONEncoder().encode(value)
    }
    static func delete(account: String) { storage.removeValue(forKey: account) }
}
@main struct Tests {
    static func main() throws {
        let key = try XWingMLKEM768X25519.PrivateKey()
        let id = UUID(), session = UUID().uuidString
        let prepare = KeyExchangePacket(phase: .prepare, exchangeID: id, receiptID: UUID(),
            publicKey: key.publicKey.rawRepresentation, privateKeySeed: key.seedRepresentation)
        let beforeRestart = HPKEDecryptor()
        try beforeRestart.acceptKeyPacket(prepare)
        precondition(!beforeRestart.keysInstalled, "prepare must not replace working encryption")
        let sender = try HPKE.Sender(recipientKey: key.publicKey,
            ciphersuite: .XWingMLKEM768X25519_SHA256_AES_GCM_256, info: Data("XWing-Version1-test".utf8))
        let activate = KeyExchangePacket(phase: .activate, exchangeID: id, receiptID: UUID(),
            encapsulatedKey: sender.encapsulatedKey, identifier: "test", ciphersuite: "XWing", version: "Version1")
        let afterRestart = HPKEDecryptor()
        try afterRestart.acceptKeyPacket(activate)
        let secret = try sender.exportSecret(context: Data("XWing-Version1-test-HostToAccessory-\(session)".utf8), outputByteCount: 32)
        let message = Data("interrupted activation recovered".utf8)
        let encrypted = try AES.GCM.seal(message, using: SymmetricKey(data: secret)).combined!
        let decoded = try afterRestart.decrypt(encrypted, sessionID: session)
        precondition(decoded == message)
        try afterRestart.acceptKeyPacket(activate) // lost receipt: idempotent replay
        let restored = HPKEDecryptor()
        precondition(restored.restoreFromKeychain() != nil)
        let restoredPlaintext = try restored.decrypt(encrypted, sessionID: session)
        precondition(restoredPlaintext == message)
        let unknown = KeyExchangePacket(phase: .activate, exchangeID: UUID(), receiptID: UUID(),
            encapsulatedKey: sender.encapsulatedKey, identifier: "test", ciphersuite: "XWing", version: "Version1")
        do { try afterRestart.acceptKeyPacket(unknown); fatalError("accepted unknown generation") } catch {}
        KeychainStore.failSave = true
        do {
            try HPKEDecryptor().acceptKeyPacket(KeyExchangePacket(phase: .prepare, exchangeID: UUID(), receiptID: UUID(),
                publicKey: key.publicKey.rawRepresentation, privateKeySeed: key.seedRepresentation))
            fatalError("acknowledged failed persistence")
        } catch {}
        do { try afterRestart.acceptKeyPacket(activate); fatalError("activation ignored persistence failure") } catch {}
        print("PASS: Mac restart between phases, real decryption, durable active keys, idempotent activation, unknown generation and persistence failure")
    }
}
SWIFT
xcrun swiftc -parse-as-library "$ROOT/shared/KeyExchangePacket.swift" "$ROOT/macos/NotifBridge/HPKEDecryptor.swift" "$WORK/Test.swift" -o "$WORK/test"
"$WORK/test"
