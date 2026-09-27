#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
python3 - "$ROOT" "$WORK/Writer.swift" <<'PY'
import sys
s=open(sys.argv[1]+'/ios/AccessoryBLEWriter.swift').read()
def block(prefix):
 a=s.index(prefix); b=s.index('{',a);depth=1;i=b+1
 while depth:
  depth+=(s[i]=='{')-(s[i]=='}');i+=1
 return s[a:i]
methods='\n'.join(block(p) for p in ['    private struct PendingWrite','    func write(','    private func drainPending(','    private func advanceIfAcknowledged('])
pre='''import Foundation
import os
typealias CBUUID = String
extension String { var uuidString: String { self } }
final class CBCharacteristic { var isNotifying = true }
final class CBPeripheral { enum State: Int { case connected }; enum Write { case withResponse }; var state = State.connected
func maximumWriteValueLength(for: Write) -> Int { 512 }
}
final class Harness: @unchecked Sendable {
let log = Logger(subsystem: "test.order", category: "writer")
var peripheral: CBPeripheral? = CBPeripheral()
var characteristics = ["notify": CBCharacteristic(), "reverse": CBCharacteristic()]
let reverseUUID: String? = "reverse"
let relayReceipts = true
var stopped = false
private var pendingWrites: [PendingWrite] = []
private var activeWrite: PendingWrite?
var chunks: [Data] = []
var chunkIndex = 0
var chunkReceipt = Data()
var attAcknowledged = true, relayAcknowledged = true
var progressGeneration: UInt64 = 0
func watchForStall(_ id: UUID, timeout: TimeInterval) {}
func sendCurrentChunk(_ p: CBPeripheral, _ ch: CBCharacteristic) {}
enum BLEError: Error { case notConnected, missingCharacteristic }
var activeByte: UInt8? { activeWrite?.data.first }
var waitingBytes: [UInt8] { pendingWrites.map { $0.data.first! } }
func advance() { advanceIfAcknowledged(peripheral!, characteristics["notify"]!) }
func finish() { while activeWrite != nil { advance() } }
'''
open(sys.argv[2],'w').write(pre+methods+'\n}\n')
PY
cat > "$WORK/Test.swift" <<'SWIFT'
import Foundation
@main struct Tests {
    @MainActor static func main() async throws {
        let writer = Harness()
        let first = Task { try await writer.write(Data(repeating: 1, count: 2048), to: "notify") }
        try await Task.sleep(for: .milliseconds(20))
        let second = Task { try await writer.write(Data(repeating: 2, count: 2048), to: "notify") }
        try await Task.sleep(for: .milliseconds(20))
        let third = Task { try await writer.write(Data(repeating: 3, count: 2048), to: "notify") }
        try await Task.sleep(for: .milliseconds(20))
        precondition(writer.waitingBytes == [2,3], "ordinary backlog must be FIFO")
        writer.advance()
        precondition(writer.activeByte == 1, "new ordinary notification must not interrupt active transfer")
        let control = Task { try await writer.write(Data(repeating: 4, count: 80), to: "notify") }
        try await Task.sleep(for: .milliseconds(20))
        writer.advance()
        precondition(writer.activeByte == 4, "control must still preempt rich notifications")
        while writer.activeByte == 4 { writer.advance() }
        precondition(writer.activeByte == 1 && writer.waitingBytes == [2,3], "interrupted oldest frame must resume before newer frames")
        writer.finish()
        _ = try await (first.value, second.value, third.value, control.value)
        var ledger = NotifWire.Ledger()
        for i in stride(from: 101, through: 0, by: -1) {
            let n = NotifWire.Notification(sourceIdentifier: "test", notificationIdentifier: "\(i)", deliveryDate: Date(timeIntervalSince1970: Double(i)))
            _ = ledger.apply(.init(kind: .add, notification: n))
        }
        precondition(ledger.notifications.count == 100)
        precondition(ledger.notifications.first?.notificationIdentifier == "101", "delayed old arrivals must not evict newer history")
        precondition(ledger.notifications.last?.notificationIdentifier == "2")
        print("PASS: FIFO enqueue, no ordinary preemption, control priority, interrupted-frame resume, chronological history retention")
    }
}
SWIFT
xcrun swiftc -parse-as-library "$WORK/Writer.swift" "$ROOT/shared/NotifWire.swift" "$WORK/Test.swift" -o "$WORK/test"
"$WORK/test"
