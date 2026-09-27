#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/Test.swift" <<'SWIFT'
import Foundation
import CryptoKit
// Never touch the user's paired Keychain while running unit tests.
enum KeychainStore {
    static func load<T: Decodable>(_ type: T.Type, account: String) -> T? { nil }
    static func save<T: Encodable>(_ value: T, account: String) throws {}
    static func delete(account: String) {}
}
@main struct Tests {
    static func main() throws {
        let decryptor = HPKEDecryptor()
        let expiring = HPKEDecryptor(previousKeyLifetime: 0)
        let session = UUID().uuidString
        var ciphertexts: [Data] = []
        for i in 0..<5 {
            let key = try XWingMLKEM768X25519.PrivateKey()
            let info = "xWing-Version1-key\(i)"
            let sender = try HPKE.Sender(recipientKey: key.publicKey,
                ciphersuite: .XWingMLKEM768X25519_SHA256_AES_GCM_256, info: Data(info.utf8))
            let secret = try sender.exportSecret(context: Data("\(info)-HostToAccessory-\(session)".utf8), outputByteCount: 32)
            let plaintext = Data("message\(i)".utf8)
            let ciphertext = try AES.GCM.seal(plaintext, using: SymmetricKey(data: secret)).combined!
            ciphertexts.append(ciphertext)
            if i == 0 {
                do { _ = try decryptor.decrypt(ciphertext, sessionID: session); fatalError("accepted before keys") } catch {}
            }
            try decryptor.installKeys(privateKeySeed: key.seedRepresentation, publicKey: key.publicKey.rawRepresentation,
                encapsulatedKey: sender.encapsulatedKey, identifier: "key\(i)", ciphersuite: "xWing", version: "Version1")
            try expiring.installKeys(privateKeySeed: key.seedRepresentation, publicKey: key.publicKey.rawRepresentation,
                encapsulatedKey: sender.encapsulatedKey, identifier: "key\(i)", ciphersuite: "xWing", version: "Version1")
            if i > 0 {
                do { _ = try expiring.decrypt(ciphertexts[i-1], sessionID: session); fatalError("expired key accepted") } catch {}
            }
            let decoded = try decryptor.decrypt(ciphertext, sessionID: session)
            precondition(decoded == plaintext)
            if i > 0 {
                let previous = try decryptor.decrypt(ciphertexts[i-1], sessionID: session)
                precondition(previous == Data("message\(i-1)".utf8), "rotation lost in-flight key")
            }
            let reverse = try decryptor.encryptReverse(plaintext, sessionID: session)
            let reverseSecret = try sender.exportSecret(context: Data("\(info)-AccessoryToHost-\(session)".utf8), outputByteCount: 32)
            let opened = try AES.GCM.open(AES.GCM.SealedBox(combined: reverse), using: SymmetricKey(data: reverseSecret))
            precondition(opened == plaintext, "fallback decryption must not switch reverse encryption to obsolete keys")
        }
        do { _ = try decryptor.decrypt(ciphertexts[0], sessionID: session); fatalError("keyring unbounded") } catch {}
        var corrupt = ciphertexts[4]; corrupt[corrupt.count - 1] ^= 1
        do { _ = try decryptor.decrypt(corrupt, sessionID: session); fatalError("accepted corrupt ciphertext") } catch {}
        do { _ = try decryptor.decrypt(ciphertexts[4], sessionID: UUID().uuidString); fatalError("accepted wrong session") } catch {}
        print("PASS: real XWing/AES-GCM delayed keys, rotation, bounded keyring, current reverse key, integrity and session checks")
    }
}
SWIFT
xcrun swiftc -parse-as-library "$ROOT/shared/KeyExchangePacket.swift" "$ROOT/macos/NotifBridge/HPKEDecryptor.swift" "$WORK/Test.swift" -o "$WORK/test"
"$WORK/test"
