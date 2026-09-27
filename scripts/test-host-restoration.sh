#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
{
    sed '/^import SwiftUI$/d; /^@preconcurrency import CoreBluetooth$/d; /^import AccessorySetupKit$/d' "$ROOT/ios/NotifBridge/HostBLEMonitor.swift"
    cat <<'SWIFT'
import Observation
let CBCentralManagerOptionRestoreIdentifierKey = "restoreID"
let CBCentralManagerRestoredStatePeripheralsKey = "peripherals"
protocol CBCentralManagerDelegate {}
protocol CBPeripheralDelegate {}
enum CBManagerState: Int { case poweredOn, poweredOff }
enum CBPeripheralState: Int { case disconnected, connecting, connected, disconnecting }
final class CBPeripheral: @unchecked Sendable {
    let identifier = UUID()
    var state: CBPeripheralState = .connecting
    weak var delegate: AnyObject?
}
final class CBCentralManager: @unchecked Sendable {
    static var latest: CBCentralManager!
    var state: CBManagerState = .poweredOff
    let options: [String: Any]?
    var connections = 0
    var cancellations = 0
    var known: [CBPeripheral] = []
    init(delegate: CBCentralManagerDelegate, queue: DispatchQueue, options: [String: Any]? = nil) {
        self.options = options
        Self.latest = self
    }
    func retrievePeripherals(withIdentifiers ids: [UUID]) -> [CBPeripheral] { known.filter { ids.contains($0.identifier) } }
    func connect(_ p: CBPeripheral, options: [String: Any]?) { connections += 1; p.state = .connecting }
    func cancelPeripheralConnection(_ p: CBPeripheral) { cancellations += 1; p.state = .disconnecting }
}
enum ASAccessoryEventType { case activated, accessoryAdded, accessoryChanged, accessoryRemoved }
struct ASAccessory { let bluetoothIdentifier: UUID? }
struct ASAccessoryEvent: Sendable { let eventType: ASAccessoryEventType }
final class ASAccessorySession {
    static var latest: ASAccessorySession!
    var accessories: [ASAccessory] = []
    var activations = 0
    var handler: ((ASAccessoryEvent) -> Void)?
    init() { Self.latest = self }
    func activate(on queue: DispatchQueue, _ handler: @escaping (ASAccessoryEvent) -> Void) { activations += 1; self.handler = handler }
}
@main struct Regression {
    @MainActor static func settle() async { try? await Task.sleep(for: .milliseconds(30)) }
    @MainActor static func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            precondition(Date() < deadline, "Timed out waiting for reconnect callback")
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
    @MainActor static func main() async {
        let monitor = HostBLEMonitor()
        let central = CBCentralManager.latest!
        guard let restoreID = central.options?[CBCentralManagerOptionRestoreIdentifierKey] as? String, !restoreID.isEmpty else {
            fatalError("Host must opt into restoration so pending connections survive termination")
        }
        let ask = ASAccessorySession.latest!
        precondition(ask.activations == 1, "Background startup must not wait for a view to appear")
        monitor.start()
        precondition(ask.activations == 1, "Repeated view appearances must not reactivate ASK")
        let peripheral = CBPeripheral()
        central.known = [peripheral]
        monitor.centralManager(central, willRestoreState: [CBCentralManagerRestoredStatePeripheralsKey: [peripheral]])
        await settle()
        precondition(peripheral.delegate === monitor)
        central.state = .poweredOn
        monitor.centralManagerDidUpdateState(central)
        await settle()
        precondition(central.cancellations == 1 && central.connections == 0, "Restart a restored pending connection before issuing a fresh connect")
        monitor.centralManagerDidUpdateState(central)
        await settle()
        precondition(central.cancellations == 1, "Cancel the restored attempt only once")
        peripheral.state = .disconnected
        monitor.centralManager(central, didFailToConnect: peripheral, error: nil)
        await waitUntil { central.connections == 1 }
        precondition(central.connections == 1, "Restored peripheral must reconnect without an ASK change")
        peripheral.state = .disconnected
        monitor.centralManager(central, didDisconnectPeripheral: peripheral, error: nil)
        await settle()
        precondition(central.connections == 1, "Disconnect must allow transport teardown before reconnecting")
        await waitUntil { central.connections == 2 }
        precondition(central.connections == 2, "Reconnect after transport teardown without reopening the app")
        peripheral.state = .disconnected
        monitor.centralManager(central, didDisconnectPeripheral: peripheral, error: nil)
        await settle()
        ask.handler?(ASAccessoryEvent(eventType: .accessoryRemoved))
        await settle()
        monitor.centralManager(central, didDisconnectPeripheral: peripheral, error: nil)
        await settle()
        try? await Task.sleep(for: .milliseconds(2100))
        precondition(central.connections == 2, "Removing an accessory must cancel scheduled reconnects")
        let second = HostBLEMonitor()
        precondition(CBCentralManager.latest.options?[CBCentralManagerOptionRestoreIdentifierKey] as? String == restoreID)
        let secondCentral = CBCentralManager.latest!
        let connected = CBPeripheral()
        connected.state = .connected
        secondCentral.known = [connected]
        secondCentral.state = .poweredOn
        second.centralManager(secondCentral, willRestoreState: [CBCentralManagerRestoredStatePeripheralsKey: [connected]])
        precondition(secondCentral.cancellations == 0 && secondCentral.connections == 0, "Do not disrupt a restored live connection")
        print("PASS: stable restoration ID, background startup, restored pending/disconnected peripheral, accessory removal")
    }
}
SWIFT
} > "$WORK/Test.swift"
xcrun swiftc -parse-as-library "$WORK/Test.swift" -o "$WORK/test"
"$WORK/test"
