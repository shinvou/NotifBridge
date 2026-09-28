#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
python3 - "$ROOT" "$WORK" <<'PY'
from pathlib import Path
import sys
root,work=map(Path,sys.argv[1:])
s=(root/'macos/NotifBridge/ESP32Bridge.swift').read_text()
a=s.index('    private func announceReceiverReadiness()');b=s.index('\n    private func writeReverse',a)
method=s[a:b]
(work/'Test.swift').write_text('''import Foundation
import os
private let log = Logger(subsystem: "test", category: "ready")
final class Characteristic { var isNotifying = false }
@MainActor final class Harness {
    var keyNotifyChar: Characteristic? = Characteristic()
    var notifNotifyChar: Characteristic? = Characteristic()
    var reverseWriteChar: Characteristic? = Characteristic()
    var receiverReadyTask: Task<Void, Never>?
    var writes: [Data] = []
    var ready = false
    func updateState(_ text: String, ready: Bool) { self.ready = ready }
    func writeReverse(_ data: Data) throws { writes.append(data) }
    func changed() { announceReceiverReadiness() }
''' + method + '''
}
@main struct Test {
    @MainActor static func main() async throws {
        let h = Harness()
        h.changed()
        precondition(!h.ready && h.receiverReadyTask == nil)
        h.keyNotifyChar?.isNotifying = true
        h.changed()
        precondition(!h.ready && h.receiverReadyTask == nil, "both subscriptions must be acknowledged")
        h.notifNotifyChar?.isNotifying = true
        h.changed()
        let deadline = Date().addingTimeInterval(5)
        while h.writes.isEmpty {
            precondition(Date() < deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(h.ready && h.writes == [Data("NB-RECEIVER-READY-1".utf8)])
        let first = h.receiverReadyTask
        h.changed()
        precondition(h.writes.count == 1, "duplicate callbacks must not send concurrent readiness loops")
        h.receiverReadyTask?.cancel()
        await first?.value
        h.ready = false // reconnect temporarily reports discovering services
        h.changed()
        precondition(h.ready, "confirmed subscriptions must restore status even with an existing cancelled readiness task")
        precondition(h.writes.count == 1, "status refresh must not start another readiness loop")
        print("PASS: confirmed subscriptions gate readiness; paired-link wake signal is sent once and is cancellable")
    }
}
''')
PY
xcrun swiftc -swift-version 6 -parse-as-library "$WORK/Test.swift" -o "$WORK/test"
"$WORK/test"
