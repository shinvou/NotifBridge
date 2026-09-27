import Foundation

/// Link-local acceptance receipt over the paired BLE reverse channel. This is
/// separate from Apple's encrypted commands and does not claim a banner appeared.
struct DeliveryReceipt: Codable {
    let kind: String
    let id: UUID
    init(id: UUID) { kind = "notifbridge.accepted.v1"; self.id = id }
    static func decode(_ data: Data) -> DeliveryReceipt? {
        guard let receipt = try? JSONDecoder().decode(Self.self, from: data),
              receipt.kind == "notifbridge.accepted.v1" else { return nil }
        return receipt
    }
}

struct NotificationEnvelope: Codable {
    let sessionID: String
    let data: Data
    var receiptID: UUID? = nil
}

/// Keep the payload alive and don't complete Apple's transmission until the Mac
/// accepts it. Terminal failure is explicitly returned to the framework; there is
/// no assumption that Apple will retry after an extension is terminated.
@MainActor final class DeliveryReceipts {
    enum Failure: Error { case stopped, timeout, capacity }
    private var pending: [UUID: Bool] = [:]
    private var stopped = false
    private let timeout: Duration
    private let attempts: Int
    init(timeout: Duration = .seconds(20), attempts: Int = 3) {
        self.timeout = timeout
        self.attempts = attempts
    }
    func receive(_ receipt: DeliveryReceipt) {
        if pending[receipt.id] != nil { pending[receipt.id] = true }
    }
    func stop() { stopped = true; pending.removeAll() }
    func send(id: UUID, write: @MainActor () async throws -> Void) async throws {
        guard !stopped else { throw Failure.stopped }
        guard pending.count < 16, pending[id] == nil else { throw Failure.capacity }
        pending[id] = false
        defer { pending.removeValue(forKey: id) }
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            guard !stopped else { throw Failure.stopped }
            do { try await write() } catch {
                if stopped { throw Failure.stopped }
                if attempt == attempts - 1 { throw error }
            }
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while pending[id] != true {
                guard !stopped else { throw Failure.stopped }
                if ContinuousClock.now >= deadline { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            if pending[id] == true { return }
        }
        throw Failure.timeout
    }
}
