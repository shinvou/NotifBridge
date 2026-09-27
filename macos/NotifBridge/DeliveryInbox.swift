import Foundation
import CryptoKit

/// Bounded ciphertext waiting room. Decryption failures may be delayed key
/// delivery, so keep them until a rekey or retry instead of silently discarding.
@MainActor final class DeliveryInbox {
    private struct Pending {
        var envelope: NotificationEnvelope
        let receivedAt: Date
    }
    var deliver: ((NotificationEnvelope) throws -> Void)?
    var acknowledge: ((UUID) -> Void)?
    var onFailure: ((String) -> Void)?
    private var pending: [String: Pending] = [:]
    private var accepted: [String] = []
    private let maxCount: Int
    private let maxBytes: Int
    private let lifetime: TimeInterval
    var pendingCount: Int { pending.count }
    init(maxCount: Int = 16, maxBytes: Int = 8 * 1024 * 1024, lifetime: TimeInterval = 300) {
        self.maxCount = maxCount; self.maxBytes = maxBytes; self.lifetime = lifetime
    }
    func receive(_ envelope: NotificationEnvelope, now: Date = Date()) {
        expire(now: now)
        let identity = envelope.sessionID + ":" + SHA256.hash(data: envelope.data).map { String(format: "%02x", $0) }.joined()
        if accepted.contains(identity) {
            if let id = envelope.receiptID { acknowledge?(id) }
            return
        }
        do {
            guard let deliver else { throw InboxError.noReceiver }
            try deliver(envelope)
            pending.removeValue(forKey: identity)
            accepted.append(identity)
            if accepted.count > 256 { accepted.removeFirst() }
            if let id = envelope.receiptID { acknowledge?(id) }
        } catch {
            if pending[identity] != nil {
                pending[identity]?.envelope = envelope
                return
            }
            guard pending.count < maxCount,
                  pending.values.reduce(0, { $0 + $1.envelope.data.count }) + envelope.data.count <= maxBytes else {
                onFailure?("Notification retry buffer is full. Delivery was not acknowledged; reconnect the iPhone.")
                return
            }
            pending[identity] = Pending(envelope: envelope, receivedAt: now)
            onFailure?("A notification is waiting for matching encryption keys. Delivery will retry automatically.")
        }
    }
    func retryPending(now: Date = Date()) {
        expire(now: now)
        for item in pending.values.sorted(by: { $0.receivedAt < $1.receivedAt }) {
            receive(item.envelope, now: now)
        }
    }
    func expire(now: Date = Date()) {
        let expired = pending.filter { now.timeIntervalSince($0.value.receivedAt) >= lifetime }.map(\.key)
        for key in expired { pending.removeValue(forKey: key) }
        if !expired.isEmpty { onFailure?("\(expired.count) notification(s) could not be decrypted before the retry window expired.") }
    }
    private enum InboxError: Error { case noReceiver }
}
