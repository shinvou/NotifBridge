import Foundation

/// Prepare the Mac before exposing a new key to iOS. Activation carries only
/// Apple's encapsulation; the keypair is already durably stored on the Mac.
struct KeyExchangePacket: Codable, Sendable {
    enum Phase: String, Codable { case prepare, activate }
    let phase: Phase
    let exchangeID: UUID
    let receiptID: UUID
    var publicKey: Data? = nil
    var privateKeySeed: Data? = nil
    var encapsulatedKey: Data? = nil
    var identifier: String? = nil
    var ciphersuite: String? = nil
    var version: String? = nil
}
