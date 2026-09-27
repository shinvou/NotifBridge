#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/Test.swift" <<'SWIFT'
import Foundation
@main struct Tests {
    @MainActor static func main() async throws {
        let sender = DeliveryReceipts(timeout: .milliseconds(10), attempts: 3)
        let id = UUID()
        var writes = 0
        try await sender.send(id: id) {
            writes += 1
            if writes == 2 { sender.receive(DeliveryReceipt(id: id)) }
        }
        precondition(writes == 2, "lost receipt must cause retry")
        writes = 0
        do {
            try await sender.send(id: UUID()) { writes += 1; sender.receive(DeliveryReceipt(id: UUID())) }
            fatalError("unrelated receipt accepted")
        } catch {}
        precondition(writes == 3, "retries must be bounded")
        sender.stop()
        do { try await sender.send(id: UUID()) { fatalError("write after stop") }; fatalError() } catch {}

        let interrupted = DeliveryReceipts(timeout: .seconds(10))
        let flight = Task { @MainActor in
            do { try await interrupted.send(id: UUID()) {}; fatalError("invalidated delivery succeeded") }
            catch {}
        }
        try await Task.sleep(for: .milliseconds(10))
        interrupted.stop()
        await flight.value
        precondition(DeliveryReceipt.decode(Data("{\"kind\":\"other\",\"id\":\"\(UUID())\"}".utf8)) == nil)

        let inbox = DeliveryInbox()
        var ready = false, deliveries = 0, receipts = 0
        inbox.deliver = { _ in
            guard ready else { throw TestError.missingKey }
            deliveries += 1
        }
        inbox.acknowledge = { _ in receipts += 1 }
        let envelope = NotificationEnvelope(sessionID: UUID().uuidString, data: Data([1,2,3]), receiptID: UUID())
        inbox.receive(envelope)
        precondition(deliveries == 0 && receipts == 0 && inbox.pendingCount == 1)
        inbox.receive(envelope)
        precondition(inbox.pendingCount == 1, "duplicate failed ciphertext must not fill buffer")
        ready = true
        inbox.retryPending()
        precondition(deliveries == 1 && receipts == 1 && inbox.pendingCount == 0)
        inbox.receive(envelope)
        precondition(deliveries == 1 && receipts == 2, "lost acceptance receipt must not redeliver")
        ready = false
        let bounded = DeliveryInbox(maxCount: 2, maxBytes: 4, lifetime: 1)
        bounded.deliver = { _ in throw TestError.missingKey }
        var failures = 0
        bounded.onFailure = { message in if !message.contains("waiting") { failures += 1 } }
        bounded.receive(envelope, now: Date(timeIntervalSince1970: 0))
        bounded.receive(NotificationEnvelope(sessionID: "s", data: Data([4,5,6])), now: Date(timeIntervalSince1970: 0))
        precondition(bounded.pendingCount == 1 && failures == 1, "byte budget must bound buffering")
        bounded.expire(now: Date(timeIntervalSince1970: 2))
        precondition(bounded.pendingCount == 0 && failures == 2, "expired ciphertext must release memory and report failure")
        print("PASS: acceptance-only success, lost/wrong receipts, bounded retries, invalidation, delayed keys, deduplication, byte limits, expiration")
    }
    enum TestError: Error { case missingKey }
}
SWIFT
xcrun swiftc -parse-as-library "$ROOT/shared/DeliveryReceipt.swift" "$ROOT/macos/NotifBridge/DeliveryInbox.swift" "$WORK/Test.swift" -o "$WORK/test"
"$WORK/test"
