import Foundation

/// The extension's OWN container is writable; the app-group container is not.
/// Save Apple's encapsulation before BLE I/O so a later security session can
/// finish an exchange whose extension was terminated mid-transfer.
struct KeyExchangeJournal {
    private let url: URL
    init(url: URL = URL.applicationSupportDirectory.appendingPathComponent("pending-key-exchange.json")) {
        self.url = url
    }
    func load() throws -> KeyExchangePacket? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count <= 16 * 1024 else { throw Failure.invalidRecord }
        let packet = try JSONDecoder().decode(KeyExchangePacket.self, from: data)
        return packet
    }
    func save(_ packet: KeyExchangePacket) throws {
        if let existing = try load(), existing.receiptID != packet.receiptID,
           !(existing.phase == .prepare && packet.phase == .activate && existing.exchangeID == packet.exchangeID) {
            throw Failure.pendingExchange
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(packet)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
    func clear(_ receiptID: UUID) throws {
        guard try load()?.receiptID == receiptID else { return }
        try FileManager.default.removeItem(at: url)
    }
    enum Failure: Error { case invalidRecord, pendingExchange }
}
