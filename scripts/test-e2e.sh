#!/usr/bin/env bash
# End-to-end test for the ESP32 BLE bridge.
#
#   iPhone (--send-test-notif=BODY) ──ASK/BLE──▶ ESP32 ──BLE NOTIFY──▶ Mac
#
# Steps:
#   1. Ensure Mac app is running (the central subscribes on launch).
#   2. Fire a test notification on the iPhone via `devicectl process launch`.
#   3. Tail the Mac `log` predicate for a marker emitted only for the synthetic BODY.
#
# Pre-reqs: iPhone already paired with the ESP32 (via ASK picker, once);
#           Mac already paired with the ESP32 (one-tap on first connect, once);
#           ESP32 powered + flashed with this repo's firmware.

set -eo pipefail

# Offline lifecycle and wire-contract regression (no paired devices needed).
if [[ "${1:-}" == "--features" ]]; then
    ROOT="$(cd "$(dirname "$0")/.." && pwd)"
    TEST_BIN="$ROOT/macos/Build/notification-features-test"
    python3 - "$ROOT" <<'PYCONFIG'
import pathlib, plistlib, sys
root = pathlib.Path(sys.argv[1])
for relative in ["ios/NotifBridge/Info.plist", "ios/TransportAppExtension/Info.plist"]:
    with (root / relative).open("rb") as handle:
        info = plistlib.load(handle)
    assert "bluetooth-central" in info.get("UIBackgroundModes", []), f"{relative}: Bluetooth restoration requires bluetooth-central background mode"
print("PASS: Bluetooth restoration background declarations")
PYCONFIG
    {
        cat "$ROOT/shared/NotifWire.swift"
        cat <<'SWIFT'
@main struct FeatureRegression {
    static func main() throws {
        var ledger = NotifWire.Ledger()
        let oldDate = Date(timeIntervalSince1970: 100)
        var n = NotifWire.Notification(title: "First", body: "body", sourceName: "Example",
            sourceIdentifier: "com.example", notificationIdentifier: String(repeating: "通知", count: 200),
            threadIdentifier: "conversation", receivedAt: oldDate)
        n.deliveryDate = oldDate
        n.displayDate = oldDate
        n.summary = "Summary"
        n.richBody = Data([1,2,3])
        n.attachments = [.init(uti: "public.png", data: Data([4,5,6]))]
        let add = NotifWire.Event(kind: .add, notification: n, sentAt: oldDate)
        let roundTrip = try NotifWire.decodeEvent(NotifWire.encodeEvent(add))
        precondition(roundTrip == add, "rich metadata, full Unicode IDs and dates must round-trip")
        precondition(ledger.apply(add).shouldAlert)
        precondition(!ledger.apply(add).shouldAlert, "duplicates must not re-alert")
        precondition(ledger.notifications.count == 1)
        n.body = "updated"
        let update = NotifWire.Event(kind: .update, notification: n, sentAt: oldDate.addingTimeInterval(1))
        precondition(!ledger.apply(update).shouldAlert)
        precondition(ledger.notifications.count == 1 && ledger.notifications[0].body == "updated")
        let remove = NotifWire.Event(kind: .remove, identity: n.identity, sentAt: oldDate.addingTimeInterval(2))
        _ = ledger.apply(remove)
        precondition(ledger.notifications[0].isCleared)
        _ = ledger.apply(add)
        precondition(ledger.notifications[0].isCleared, "stale adds must not resurrect a removal")
        var silent = n
        silent.notificationIdentifier = "silent"
        silent.shouldAlert = false
        silent.isSuppressedByFocus = true
        precondition(!ledger.apply(.init(kind: .add, notification: silent)).shouldAlert)
        var focused = n
        focused.notificationIdentifier = "focus"
        focused.shouldAlert = true
        focused.isSuppressedByFocus = true
        precondition(!ledger.apply(.init(kind: .add, notification: focused)).shouldAlert)
        var quiet = n
        quiet.notificationIdentifier = "quiet-fresh"
        quiet.shouldAlert = false
        quiet.deliveryDate = Date()
        precondition(ledger.apply(.init(kind: .add, notification: quiet), alertQuietNotifications: true).shouldAlert,
                     "explicit Mac preference shows a fresh quiet notification")
        precondition(!ledger.apply(.init(kind: .add, notification: quiet), alertQuietNotifications: true).shouldAlert,
                     "quiet notifications must not alert twice")
        quiet.notificationIdentifier = "quiet-old"
        quiet.deliveryDate = Date().addingTimeInterval(-301)
        precondition(ledger.apply(.init(kind: .add, notification: quiet), alertQuietNotifications: true).shouldAlert,
                     "newly recovered quiet notifications must alert when explicitly enabled")
        quiet.notificationIdentifier = "quiet-focus"
        quiet.deliveryDate = Date()
        quiet.isSuppressedByFocus = true
        precondition(ledger.apply(.init(kind: .add, notification: quiet), alertQuietNotifications: true).shouldAlert,
                     "Mac override must ignore iPhone Focus")
        let clear = NotifWire.Event(kind: .removeAll)
        _ = ledger.apply(clear)
        precondition(ledger.notifications.allSatisfy(\.isCleared))
        _ = ledger.apply(update)
        precondition(ledger.notifications.allSatisfy(\.isCleared))
        let persisted = try JSONEncoder().encode(ledger)
        let restored = try JSONDecoder().decode(NotifWire.Ledger.self, from: persisted)
        precondition(restored.notifications == ledger.notifications)
        let command = NotifWire.Command(kind: .respond, identity: n.identity,
            actionIdentifier: "reply", userText: "Hello 🌍")
        let decodedCommand = try JSONDecoder().decode(NotifWire.Command.self, from: JSONEncoder().encode(command))
        precondition(decodedCommand == command)
        for bad in [Data(), Data("{}".utf8), try JSONEncoder().encode(NotifWire.Event(version: 999, kind: .add, notification: n)),
                    try JSONEncoder().encode(NotifWire.Event(kind: .remove))] {
            do { _ = try NotifWire.decodeEvent(bad); fatalError("malformed events must fail") } catch {}
        }
        var crowded = NotifWire.Ledger()
        for i in 0..<150 {
            var item = n; item.notificationIdentifier = "item-\(i)"
            _ = crowded.apply(.init(kind: .add, notification: item))
        }
        precondition(crowded.notifications.count <= 100, "history must be bounded")
        print("PASS: rich wire round-trip, stable identity, dedup, update, full-ID remove, Focus, clear-all, stale-event protection, persistence, command payloads, malformed input and bounded history")
    }
}
SWIFT
    } | xcrun swiftc -parse-as-library -o "$TEST_BIN" -
    "$TEST_BIN"
    exit 0
fi

# Exercise the production receiver with deterministic transport and presentation doubles.
if [[ "${1:-}" == "--receiver" ]]; then
    ROOT="$(cd "$(dirname "$0")/.." && pwd)"
    TEST_BIN="$ROOT/macos/Build/receiver-regression"
    {
        cat "$ROOT/shared/NotifWire.swift" "$ROOT/macos/NotifBridge/ReceiverModel.swift"
        cat <<'SWIFT'
typealias NotifFrame = NotifWire.Notification
@MainActor final class ESP32Bridge {
    static var instance: ESP32Bridge!
    var onState: ((String, Bool) -> Void)?
    var onKeyInfo: ((String) -> Void)?
    var onEvent: ((NotifWire.Event, String) -> Void)?
    var onError: ((String) -> Void)?
    var sent: [NotifWire.Command] = []
    var fail = false
    init() { Self.instance = self }
    func start() {}
    func sendReverseCommand(_ data: Data, sessionID: String?) throws {
        if fail { throw NSError(domain: "Disconnected", code: 1) }
        sent.append(try JSONDecoder().decode(NotifWire.Command.self, from: data))
    }
}
@MainActor final class BannerManager {
    enum BannerCommand {
        case dismissLocally(NotifFrame), clearOnIPhone(NotifFrame), retry(NotifFrame)
        case actionInvoked(NotifFrame, NotifFrame.Action, userText: String?)
    }
    static var instance: BannerManager!
    var onCommand: ((BannerCommand) -> Void)?
    var onError: ((String) -> Void)?
    var resolveNotification: ((String) -> NotifFrame?)?
    var soundEnabled = true
    var presented = 0
    var dismissed: [String] = []
    init() { Self.instance = self }
    func present(_ frame: NotifFrame, status: ReceiverModel.ActionStatus, completion: (Bool) -> Void = { _ in }) { presented += 1; completion(true) }
    func update(_ frame: NotifFrame, status: ReceiverModel.ActionStatus) {}
    func dismiss(id: String) { dismissed.append(id) }
    func dismissAll() {}
}
@main struct ReceiverRegression {
    @MainActor static func main() async throws {
        let model = ReceiverModel()
        model.eraseLocalHistory()
        model.mutedApps = []
        let bridge = ESP32Bridge.instance!
        let banners = BannerManager.instance!
        let session = UUID().uuidString
        var n = NotifFrame(title: "Test", body: "test", sourceName: "Tests", sourceIdentifier: "test.app", notificationIdentifier: "one")
        let event = NotifWire.Event(kind: .add, notification: n)
        bridge.onError?("Notification authentication failed")
        precondition(model.lastError != nil)
        bridge.onEvent?(event, session)
        precondition(model.lastError == nil, "successful receipt must clear a stale transport error")
        bridge.onError?("Notification authentication failed")
        model.lastError = "Could not save notification history"
        bridge.onEvent?(event, session)
        precondition(model.lastError == "Could not save notification history", "transport recovery must preserve unrelated failures")
        model.lastError = nil
        precondition(model.received.count == 1 && banners.presented == 1)
        precondition(bridge.sent.last?.kind == .displayed && bridge.sent.last?.didAlert == true)
        bridge.onEvent?(event, session)
        precondition(banners.presented == 1, "duplicate delivery must not re-alert")
        n = model.received[0]
        let commandsBeforeDismiss = bridge.sent.count
        model.handle(.dismissLocally(n))
        precondition(bridge.sent.count == commandsBeforeDismiss && !model.received[0].isCleared,
                     "X dismisses locally without an iPhone command")
        banners.dismissed.removeAll()
        model.handle(.clearOnIPhone(n))
        let clear = bridge.sent.last!
        precondition(clear.kind == .clear && model.status(for: n).phase == .pending)
        precondition(!model.received[0].isCleared && banners.dismissed.isEmpty, "no optimistic clear")
        bridge.onEvent?(.init(kind: .commandResult, result: .init(commandID: clear.id, success: false, message: "Try again")), session)
        precondition(model.status(for: n).phase == .failed && !model.received[0].isCleared)
        model.handle(.retry(n))
        precondition(bridge.sent.last?.id != clear.id, "a confirmed failure needs a new request, not a cached failure")
        let retry = bridge.sent.last!
        bridge.onEvent?(.init(kind: .commandResult, result: .init(commandID: retry.id, success: true, message: "Cleared")), session)
        precondition(model.received[0].isCleared && model.status(for: n).phase == .succeeded)
        precondition(banners.dismissed == [n.id])
        n.notificationIdentifier = "reply"
        bridge.onEvent?(.init(kind: .add, notification: n), session)
        n = model.received.first { $0.notificationIdentifier == "reply" }!
        let action = NotifFrame.Action(id: "reply-action", title: "Reply", type: .textInput(placeholder: "Reply"))
        model.handle(.actionInvoked(n, action, userText: "Hello 🌍"))
        let response = bridge.sent.last!
        precondition(response.kind == .respond && response.userText == "Hello 🌍" && response.actionIdentifier == action.id)
        bridge.onEvent?(.init(kind: .commandResult, result: .init(commandID: response.id, success: true, message: "Accepted")), session)
        precondition(!model.received.first { $0.id == n.id }!.isCleared, "reply acceptance does not imply removal")
        n.notificationIdentifier = "offline"
        bridge.onEvent?(.init(kind: .add, notification: n), session)
        n = model.received.first { $0.notificationIdentifier == "offline" }!
        bridge.fail = true
        model.handle(.clearOnIPhone(n))
        precondition(model.status(for: n).phase == .failed)
        precondition(!model.received.first { $0.id == n.id }!.isCleared)
        bridge.fail = false
        model.handle(.retry(n))
        precondition(model.status(for: n).phase == .pending)
        n.notificationIdentifier = "uncertain-reply"
        bridge.onEvent?(.init(kind: .add, notification: n), session)
        n = model.received.first { $0.notificationIdentifier == "uncertain-reply" }!
        model.handle(.actionInvoked(n, action, userText: "Uncertain"))
        let uncertainID = bridge.sent.last!.id
        try await Task.sleep(for: .milliseconds(15_100))
        precondition(model.status(for: n).phase == .failed && model.status(for: n).retryMayRepeat)
        model.handle(.retry(n))
        precondition(bridge.sent.last?.id == uncertainID, "uncertain retries must retain the deduplication ID")
        bridge.onEvent?(.init(kind: .commandResult, result: .init(commandID: uncertainID, success: true, message: "Accepted")), session)
        model.toggleMute("muted.app")
        var silent = n; silent.sourceIdentifier = "muted.app"
        let before = banners.presented
        bridge.onEvent?(.init(kind: .add, notification: silent), session)
        precondition(banners.presented == before && bridge.sent.last?.didAlert == false)
        model.showQuietNotifications = true
        var quiet = n
        quiet.sourceIdentifier = "quiet.app"
        quiet.notificationIdentifier = "fresh-quiet"
        quiet.shouldAlert = false
        quiet.deliveryDate = Date()
        quiet.isSuppressedByFocus = true
        bridge.onEvent?(.init(kind: .add, notification: quiet), session)
        precondition(banners.presented == before + 1 && bridge.sent.last?.didAlert == true,
                     "quiet Mac banner reports actual presentation to iPhone")
        quiet.sourceIdentifier = "muted.app"
        bridge.onEvent?(.init(kind: .add, notification: quiet), session)
        precondition(banners.presented == before + 1 && bridge.sent.last?.didAlert == false)
        model.showQuietNotifications = false
        try await Task.sleep(for: .milliseconds(500))
        let restored = ReceiverModel()
        precondition(restored.received == model.received, "history survives restart")
        restored.eraseLocalHistory()
        model.eraseLocalHistory()
        print("PASS: display receipts, duplicate delivery, confirmed clears, reply payloads, failures, retries, timeout, per-app mute and persisted history")
    }
}
SWIFT
    } | xcrun swiftc -parse-as-library -target arm64-apple-macos26.0 -o "$TEST_BIN" -
    "$TEST_BIN"
    exit 0
fi

# Run the production BLE writer against an explicitly stepped ATT transport.
if [[ "${1:-}" == "--ble-writer" ]]; then
    ROOT="$(cd "$(dirname "$0")/.." && pwd)"
    TEST_BIN="$ROOT/macos/Build/ble-writer-regression"
    {
        sed '/import CoreBluetooth/d; /import AccessorySetupKit/d' "$ROOT/ios/AccessoryBLEWriter.swift"
        cat <<'SWIFT'
struct CBUUID: Hashable { let uuidString: String; init(string: String) { uuidString = string } }
enum NotifWire { static let maxEnvelopeBytes = 8 * 1024 * 1024 }
let CBCentralManagerOptionRestoreIdentifierKey = "restore"
let CBCentralManagerRestoredStatePeripheralsKey = "peripherals"
let CBCentralManagerOptionDeviceAccessForMedia = "access"
protocol CBCentralManagerDelegate: AnyObject {}
protocol CBPeripheralDelegate: AnyObject {}
enum CBManagerState: Int { case unknown = 0, poweredOff = 4, poweredOn = 5 }
enum CBPeripheralState: Int { case disconnected, connecting, connected }
struct CBCharacteristicProperties { let rawValue = 8 }
final class CBCharacteristic { let uuid: CBUUID; var value: Data?; var isNotifying = false; let properties = CBCharacteristicProperties(); init(_ id: CBUUID) { uuid = id } }
final class CBService { let uuid: CBUUID; var characteristics: [CBCharacteristic]?; init(_ id: CBUUID, _ char: CBUUID) { uuid = id; characteristics = [CBCharacteristic(char)] } }
final class CBPeripheral {
    enum WriteType { case withResponse }
    let identifier = UUID()
    func setNotifyValue(_ value: Bool, for ch: CBCharacteristic) { ch.isNotifying = value }
    var state: CBPeripheralState = .connected
    var name: String? = "Test"
    var delegate: (any CBPeripheralDelegate)?
    var services: [CBService]?
    var writes: [Data] = []
    var maximumWriteLength = 20
    func maximumWriteValueLength(for type: WriteType) -> Int { maximumWriteLength }
    func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: WriteType) { writes.append(data) }
    func discoverServices(_ ids: [CBUUID]) { (delegate as? AccessoryBLEWriter)?.peripheral(self, didDiscoverServices: nil) }
    func discoverCharacteristics(_ ids: [CBUUID]?, for service: CBService) { (delegate as? AccessoryBLEWriter)?.peripheral(self, didDiscoverCharacteristicsFor: service, error: nil) }
}
final class CBCentralManager {
    static let phone = CBPeripheral()
    var state: CBManagerState = .poweredOn
    var delegate: (any CBCentralManagerDelegate)?
    init(delegate: any CBCentralManagerDelegate, queue: DispatchQueue, options: [String: Any]) { self.delegate = delegate }
    func retrievePeripherals(withIdentifiers ids: [UUID]) -> [CBPeripheral] { [Self.phone] }
    func connect(_ p: CBPeripheral, options: [String: String]?) {}
    func cancelPeripheralConnection(_ p: CBPeripheral) { p.state = .disconnected }
}
struct ASAccessoryEvent { enum EventType: Int { case activated, accessoryAdded, accessoryChanged, accessoryRemoved, other }; let eventType: EventType }
struct ASAccessory { let bluetoothIdentifier: UUID? = UUID() }
final class ASAccessorySession {
    func invalidate() {}
    let accessories = [ASAccessory()]
    func activate(on queue: DispatchQueue, _ handler: @escaping (ASAccessoryEvent) -> Void) { queue.async { handler(.init(eventType: .activated)) } }
}
@main struct BLEWriterRegression {
    @MainActor static func main() async throws {
        func waitForWrite(after count: Int) async throws {
            let deadline = Date().addingTimeInterval(5)
            while phone.writes.count <= count {
                guard Date() < deadline else { fatalError("test transport did not receive a write") }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let service = CBUUID(string: "service"), target = CBUUID(string: "target")
        let phone = CBCentralManager.phone
        phone.services = [CBService(service, target)]
        let characteristic = phone.services![0].characteristics![0]
        let writer = AccessoryBLEWriter(category: "test", serviceUUID: service)
        var completed = false
        let taskStartCount = phone.writes.count
        let task = Task { try await writer.write(Data(repeating: 7, count: 25), to: target); completed = true }
        try await waitForWrite(after: taskStartCount)
        precondition(phone.writes == [Data("--START--".utf8)] && !completed, "wait for each ATT acknowledgment")
        for expectedCount in 2...4 {
            writer.peripheral(phone, didWriteValueFor: characteristic, error: nil)
            precondition(phone.writes.count == expectedCount && !completed)
        }
        writer.peripheral(phone, didWriteValueFor: characteristic, error: nil)
        try await task.value
        precondition(completed && phone.writes.last == Data("--END--".utf8))
        // A healthy slow frame and the frame queued behind it must outlive the
        // inactivity timeout as long as ATT acknowledgments keep arriving.
        let slowStartCount = phone.writes.count
        let slow = Task { try await writer.write(Data(repeating: 3, count: 100), to: target, timeout: 1.0) }
        try await waitForWrite(after: slowStartCount)
        let queued = Task { try await writer.write(Data([2]), to: target, timeout: 1.0) }
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(200))
            writer.peripheral(phone, didWriteValueFor: characteristic, error: nil)
        }
        try await slow.value
        try await queued.value
        let interruptedStartCount = phone.writes.count
        let interrupted = Task { try await writer.write(Data([8]), to: target) }
        try await waitForWrite(after: interruptedStartCount)
        let reconnect = CBCentralManager(delegate: writer, queue: .main, options: [:])
        phone.state = .disconnected
        writer.centralManager(reconnect, didDisconnectPeripheral: phone, error: nil)
        phone.state = .connected
        writer.centralManager(reconnect, didConnect: phone)
        for _ in 0..<3 { writer.peripheral(phone, didWriteValueFor: characteristic, error: nil) }
        try await interrupted.value
        let failureStartCount = phone.writes.count
        let failure = Task { try await writer.write(Data([1]), to: target) }
        try await waitForWrite(after: failureStartCount)
        writer.peripheral(phone, didWriteValueFor: characteristic, error: NSError(domain: "ATT", code: 9))
        do { try await failure.value; fatalError("ATT errors must fail the caller") } catch {}
        do { try await writer.write(Data([1]), to: target, timeout: 0.05); fatalError("offline writes must time out") } catch {}
        phone.state = .connected
        let stalled = AccessoryBLEWriter(category: "stalled-test", serviceUUID: service)
        do { try await stalled.write(Data([1]), to: target, timeout: 0.05); fatalError("active writes must time out") } catch {}
        let countAfterTimeout = phone.writes.count
        stalled.peripheral(phone, didWriteValueFor: characteristic, error: nil)
        precondition(phone.writes.count == countAfterTimeout && phone.state == .disconnected, "late acknowledgments must not resume timed-out frames")
        phone.state = .connected
        phone.maximumWriteLength = 128
        let reverse = AccessoryBLEWriter(category: "reverse-test", serviceUUID: service, reverseUUID: target, restoreIdentifier: "test")
        var received: [Data] = []
        reverse.onMessage = { received.append($0) }
        try await Task.sleep(for: .milliseconds(30))
        precondition(characteristic.isNotifying)
        for part in ["orphan", "--START--", "NBA10123456789abcdef", "reply", "--END--", "--END--"] {
            characteristic.value = Data(part.utf8)
            reverse.peripheral(phone, didUpdateValueFor: characteristic, error: nil)
        }
        precondition(received == [Data("reply".utf8)], "assemble exactly one reverse frame on the authorized central")
        let pacedStartCount = phone.writes.count
        let paced = Task { try await reverse.write(Data([7]), to: target, timeout: 5.0) }
        try await waitForWrite(after: pacedStartCount)
        let firstPacketCount = phone.writes.count
        let firstReceipt = Data("NBA1".utf8) + phone.writes.last!.dropFirst(4).prefix(16)
        reverse.peripheral(phone, didWriteValueFor: characteristic, error: nil)
        precondition(phone.writes.count == firstPacketCount, "ATT ack must not outrun the relay")
        characteristic.value = Data("NBA1wrong-or-old-uuid".utf8)
        reverse.peripheral(phone, didUpdateValueFor: characteristic, error: nil)
        precondition(phone.writes.count == firstPacketCount, "reject unrelated relay receipts")
        characteristic.value = firstReceipt
        reverse.peripheral(phone, didUpdateValueFor: characteristic, error: nil)
        precondition(phone.writes.count == firstPacketCount + 1)
        // The relay receipt may also arrive before the ATT callback.
        characteristic.value = Data("NBA1".utf8) + phone.writes.last!.dropFirst(4).prefix(16)
        reverse.peripheral(phone, didUpdateValueFor: characteristic, error: nil)
        precondition(phone.writes.count == firstPacketCount + 1)
        reverse.peripheral(phone, didWriteValueFor: characteristic, error: nil)
        precondition(phone.writes.count == firstPacketCount + 2)
        characteristic.value = Data("NBA1".utf8) + phone.writes.last!.dropFirst(4).prefix(16)
        reverse.peripheral(phone, didUpdateValueFor: characteristic, error: nil)
        reverse.peripheral(phone, didWriteValueFor: characteristic, error: nil)
        try await paced.value
        func acknowledgePacket() {
            characteristic.value = Data("NBA1".utf8) + phone.writes.last!.dropFirst(4).prefix(16)
            reverse.peripheral(phone, didUpdateValueFor: characteristic, error: nil)
            reverse.peripheral(phone, didWriteValueFor: characteristic, error: nil)
        }
        let artworkStartCount = phone.writes.count
        let artwork = Task { try await reverse.write(Data(repeating: 4, count: 2048), to: target) }
        try await waitForWrite(after: artworkStartCount)
        acknowledgePacket() // START accepted; first media chunk is now in flight.
        let urgent = Task { try await reverse.write(Data([9]), to: target) }
        try await Task.sleep(for: .milliseconds(20))
        acknowledgePacket()
        precondition(phone.writes.last!.dropFirst(20) == Data("--START--".utf8), "urgent result interrupts media only at a confirmed chunk boundary")
        for _ in 0..<3 { acknowledgePacket() }
        try await urgent.value
        precondition(phone.writes.last!.dropFirst(20) == Data("--START--".utf8), "interrupted media restarts with a clean frame")
        for _ in 0..<21 { acknowledgePacket() }
        try await artwork.value
        let recoveryStart = phone.writes.count
        let recovery = Task { try await reverse.write(Data(repeating: 6, count: 1500), to: target) }
        try await waitForWrite(after: recoveryStart)
        acknowledgePacket() // START confirmed; data packet in flight.
        let staleReceipt = Data("NBA1".utf8) + phone.writes.last!.dropFirst(4).prefix(16)
        let beforeReady = phone.writes.count
        for part in ["--START--", "NB-RECEIVER-READY-1", "--END--"] {
            characteristic.value = Data(part.utf8)
            reverse.peripheral(phone, didUpdateValueFor: characteristic, error: nil)
        }
        precondition(phone.writes.count == beforeReady, "recovery must wait for outstanding ATT completion")
        reverse.peripheral(phone, didWriteValueFor: characteristic, error: nil)
        precondition(phone.writes.last!.dropFirst(20) == Data("--START--".utf8), "receiver readiness must restart the whole interrupted frame")
        let restartedCount = phone.writes.count
        characteristic.value = staleReceipt
        reverse.peripheral(phone, didUpdateValueFor: characteristic, error: nil)
        precondition(phone.writes.count == restartedCount, "old relay receipt must not advance restarted frame")
        for _ in 0..<16 { acknowledgePacket() }
        try await recovery.value
        precondition(received == [Data("reply".utf8)], "readiness control must not reach application command parser")
        phone.maximumWriteLength = 512
        let largeStart = phone.writes.count
        let largeStartCount = phone.writes.count
        let large = Task { try await reverse.write(Data(repeating: 5, count: 1000), to: target) }
        try await waitForWrite(after: largeStartCount)
        acknowledgePacket()
        precondition(phone.writes.last!.count <= 220, "a flow-controlled payload must fit one 200-byte relay indication")
        for _ in 0..<6 { acknowledgePacket() }
        try await large.value
        let payload = phone.writes.dropFirst(largeStart + 1).dropLast().reduce(into: Data()) { $0.append($1.dropFirst(20)) }
        precondition(payload == Data(repeating: 5, count: 1000), "single-indication chunks preserve every payload byte")
        let historyStartCount = phone.writes.count
        let history = Task { try await reverse.write(Data(repeating: 6, count: 8000), to: target) }
        try await waitForWrite(after: historyStartCount)
        acknowledgePacket()
        let fresh = Task { try await reverse.write(Data(repeating: 9, count: 2000), to: target) }
        try await Task.sleep(for: .milliseconds(20))
        acknowledgePacket()
        precondition(phone.writes.last!.dropFirst(20) == Data(repeating: 6, count: 200), "ordinary notifications must not interrupt earlier transfers")
        for _ in 0..<40 { acknowledgePacket() }
        try await history.value
        precondition(phone.writes.last!.dropFirst(20) == Data("--START--".utf8), "next notification starts after the earlier END is acknowledged")
        acknowledgePacket()
        precondition(phone.writes.last!.dropFirst(20) == Data(repeating: 9, count: 200))
        for _ in 0..<11 { acknowledgePacket() }
        try await fresh.value
        reverse.stop()
        characteristic.value = Data("--START--".utf8)
        reverse.peripheral(phone, didUpdateValueFor: characteristic, error: nil)
        precondition(phone.state == .disconnected)
        print("PASS: per-chunk acknowledgment, completion after END acknowledgment, ATT failure, offline/active timeout, late acknowledgment, slow queued transfers and reverse assembly")
    }
}
SWIFT
    } | xcrun swiftc -parse-as-library -o "$TEST_BIN" -
    "$TEST_BIN"
    exit 0
fi

# Offline crypto regression; uses ephemeral keys and a no-op Keychain stub.
if [[ "${1:-}" == "--reverse-crypto" ]]; then
    ROOT="$(cd "$(dirname "$0")/.." && pwd)"
    TEST_BIN="$ROOT/macos/Build/reverse-crypto-test"
    {
        cat "$ROOT/shared/KeyExchangePacket.swift" "$ROOT/macos/NotifBridge/HPKEDecryptor.swift"
        cat <<'SWIFT'
private enum KeychainStore {
    static func load<T: Decodable>(_ type: T.Type, account: String) -> T? { nil }
    static func save<T: Encodable>(_ value: T, account: String) throws {}
    static func delete(account: String) {}
}
@main struct ReverseCryptoRegression {
    static func main() throws {
        let privateKey = try XWingMLKEM768X25519.PrivateKey()
        let info = "XWing-Version1-regression"
        let sender = try HPKE.Sender(recipientKey: privateKey.publicKey,
            ciphersuite: .XWingMLKEM768X25519_SHA256_AES_GCM_256,
            info: Data(info.utf8))
        let codec = HPKEDecryptor()
        try codec.installKeys(privateKeySeed: privateKey.seedRepresentation,
            publicKey: privateKey.publicKey.rawRepresentation,
            encapsulatedKey: sender.encapsulatedKey, identifier: "regression",
            ciphersuite: "XWing", version: "Version1")
        let sessionID = UUID().uuidString
        let command = Data([0x10, 3]) + Data("app".utf8) + Data([2]) + Data("id".utf8)
        let encrypted = try codec.encryptReverse(command, sessionID: sessionID)
        let key = SymmetricKey(data: try sender.exportSecret(
            context: Data("\(info)-AccessoryToHost-\(sessionID)".utf8), outputByteCount: 32))
        let decoded = try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: key)
        precondition(decoded == command, "reverse command must round-trip through system-side key")
        let another = try codec.encryptReverse(command, sessionID: sessionID)
        precondition(another != encrypted, "each command needs a fresh AES-GCM nonce")
        for context in ["\(info)-HostToAccessory-\(sessionID)", "\(info)-AccessoryToHost-\(UUID().uuidString)"] {
            let wrongKey = SymmetricKey(data: try sender.exportSecret(context: Data(context.utf8), outputByteCount: 32))
            do {
                _ = try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: wrongKey)
                fatalError("wrong direction/session must not authenticate")
            } catch {}
        }
        var tampered = encrypted
        tampered[tampered.count - 1] ^= 1
        do {
            _ = try AES.GCM.open(AES.GCM.SealedBox(combined: tampered), using: key)
            fatalError("tampered command must not authenticate")
        } catch {}
        let outboundKey = SymmetricKey(data: try sender.exportSecret(
            context: Data("\(info)-HostToAccessory-\(sessionID)".utf8), outputByteCount: 32))
        let outbound = try AES.GCM.seal(command, using: outboundKey).combined!
        let roundTrip = try codec.decrypt(outbound, sessionID: sessionID)
        precondition(roundTrip == command, "existing inbound decryption must still work")
        print("PASS: reverse round-trip, nonce uniqueness, direction/session isolation, tamper rejection, inbound decryption")
    }
}
SWIFT
    } | xcrun swiftc -parse-as-library -target arm64-apple-macos26.0 -o "$TEST_BIN" -
    "$TEST_BIN"
    exit 0
fi

: "${DEVICE:?Set DEVICE to your paired iPhone identifier from xcrun devicectl list devices}"
BUNDLE="${BUNDLE:-com.shinvou.NotifBridge}"
BODY="${1:-e2e-$(date +%s)-$RANDOM}"
WAIT_SEC="${WAIT_SEC:-130}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-2}"
if [[ "${CLEAR_ON_IPHONE:-0}" == "1" ]]; then WAIT_SEC="${WAIT_SEC:-130}"; fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAC_APP="${MAC_APP:-$ROOT/macos/Build/Products/Debug/NotifBridge.app}"

ensure_mac_receiver() {
    # Always relaunch so we exercise the freshly built binary, not a stale
    # process left over from a previous build (PIDs survive incremental builds
    # because the binary path is the same).
    pkill -f "$MAC_APP/Contents/MacOS/NotifBridge" 2>/dev/null || true
    sleep 1
    if [[ "${CLEAR_ON_IPHONE:-0}" == "1" ]]; then
        open "$MAC_APP" --args "--clear-test-notif-body=$BODY"
    else
        open "$MAC_APP" --args "--test-notif-body=$BODY"
    fi
    local ready_log
    MAC_PID=$(pgrep -f "$MAC_APP/Contents/MacOS/NotifBridge" | head -1)
    for _ in $(seq 1 30); do
        ready_log=$(/usr/bin/log show --last 40s --style compact --predicate "processIdentifier == $MAC_PID AND subsystem == \"com.shinvou.NotifBridge.Mac\"" 2>/dev/null)
        if echo "$ready_log" | grep -q 'D5E12B7A-7D8E-4F12-9B5C-3F0A1E6D8C48 notifying=true' &&
           echo "$ready_log" | grep -q 'D5E12B7A-7D8E-4F12-9B5C-3F0A1E6D8C49 notifying=true'; then
            echo "  NotifBridge (Mac) PID=$MAC_PID subscribed to keys and notifications"
            return 0
        fi
        sleep 1
    done
    echo "FAIL: Mac receiver did not subscribe within 30 seconds"
    return 1
}

run_once() {
    local attempt=$1 start_ts end_ts log
    local -a clear_args=()
    if [[ "${CLEAR_ON_IPHONE:-0}" == "1" ]]; then clear_args=(--verify-test-clear); fi
    start_ts=$(date +%s)

    echo "[2/4] (attempt $attempt) Launching iPhone app body=\"$BODY\"…"
    xcrun devicectl device process launch \
        --device "$DEVICE" \
        --terminate-existing \
        "$BUNDLE" \
        --send-test-notif \
        "--test-notif-body=$BODY" --test-notif-count=1 --test-notif-delay=30 "${clear_args[@]}" > "$ROOT/ios/Build/e2e-launch.log" 2>&1 || { cat "$ROOT/ios/Build/e2e-launch.log"; return 3; }
    head -8 "$ROOT/ios/Build/e2e-launch.log"

    echo "[3/4] Waiting ${WAIT_SEC}s for notif → ESP32 → Mac…"
    sleep "$WAIT_SEC"

    echo "[4/4] Pulling Mac receiver log…"
    end_ts=$(date +%s)
    log=$(/usr/bin/log show --predicate "processIdentifier == $MAC_PID AND subsystem == \"com.shinvou.NotifBridge.Mac\"" --info --last "$((end_ts - start_ts + 10))s")

    echo ""
    echo "=== ESP32-bridge log highlights ==="
    echo "$log" | grep -E 'TEST-E2E|command result' | tail -8 || true

    if echo "$log" | grep -qF "TEST-E2E received matching test notification"; then
        if [[ "${CLEAR_ON_IPHONE:-0}" == "1" ]]; then
            if ! echo "$log" | grep -qF "TEST-E2E clear result success=true"; then
                echo "FAIL: received notification, but no successful iPhone command acknowledgment"
                return 2
            fi
            echo "PASS: round-trip clear acknowledged by iPhone API; verify TEST-CLEAR delivered=0 on iPhone logs"
        else
            echo "PASS: matching synthetic notification decrypted and received"
        fi
        return 0
    fi
    return 2
}

echo "[1/4] Ensuring Mac receiver is running…"
ensure_mac_receiver

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
    set +e
    run_once "$attempt"
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then exit 0; fi
    if [[ $rc -eq 3 ]]; then exit 3; fi
    if [[ $attempt -lt $MAX_ATTEMPTS ]]; then
        echo ""
        echo "❌ no matching receipt on attempt $attempt — retrying…"
        sleep 2
    fi
done

echo ""
echo "❌ FAIL — no matching receipt after $MAX_ATTEMPTS attempts"
exit 1
