import Foundation
import SwiftUI
@preconcurrency import CoreBluetooth
import AccessorySetupKit
import os

private let monitorLog = Logger(subsystem: "com.shinvou.NotifBridge", category: "host-ble")

/// Slim host-side connection monitor for the bonded Mac accessory.
///
/// The actual data path runs inside the AccessoryTransport extensions
/// (`AccessoryBLEWriter`), not here. This monitor exists so the iPhone app UI
/// can show whether the bonded peripheral is reachable, and to keep a warm
/// CoreBluetooth connection at launch so the user sees immediate feedback that
/// pairing still works. It does **not** do IPC, queue writes, or forward
/// notifications.
@MainActor
@Observable
final class HostBLEMonitor: NSObject {
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var bondedID: UUID?
    private let askSession = ASAccessorySession()
    private var started = false
    private var restartRestoredConnection = false
    private var reconnectTask: Task<Void, Never>?

    var statusText: String = "starting"

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "com.shinvou.NotifBridge.host-ble"
        ])
        // Bluetooth restoration can launch the app without showing a view.
        start()
    }

    func start() {
        guard !started else { return }
        started = true
        monitorLog.notice("start — activating ASAccessorySession")
        askSession.activate(on: .main) { [weak self] event in
            Task { @MainActor in self?.handleASEvent(event) }
        }
    }

    private func handleASEvent(_ event: ASAccessoryEvent) {
        switch event.eventType {
        case .activated, .accessoryAdded, .accessoryChanged:
            if let id = askSession.accessories.first?.bluetoothIdentifier, id != bondedID {
                monitorLog.notice("ASK bonded: \(id.uuidString, privacy: .public)")
                bondedID = id
                attemptConnect()
            }
        case .accessoryRemoved:
            monitorLog.notice("ASK accessory removed")
            reconnectTask?.cancel()
            reconnectTask = nil
            bondedID = nil
            if let p = peripheral { central.cancelPeripheralConnection(p) }
            peripheral = nil
        default: break
        }
        updateStatus()
    }

    private func attemptConnect() {
        guard reconnectTask == nil, central.state == .poweredOn, let id = bondedID else { return }
        if let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            peripheral = p
            p.delegate = self
            if restartRestoredConnection {
                restartRestoredConnection = false
                if p.state == .connecting {
                    // A persisted request can outlive its controller connection.
                    // Cancel once, then reconnect from the cancellation callback.
                    monitorLog.notice("restarting restored pending connection")
                    central.cancelPeripheralConnection(p)
                    updateStatus()
                    return
                }
            }
            monitorLog.notice("retrieved peripheral state=\(p.state.rawValue, privacy: .public) — connecting")
            if p.state == .disconnected { central.connect(p, options: nil) }
        } else {
            monitorLog.error("peripheral \(id.uuidString, privacy: .public) not in retrievePeripherals")
        }
        updateStatus()
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil, bondedID != nil else { return }
        // DeviceAccess tears down the transport asynchronously on disconnect.
        // An immediate connect can race that teardown and be cancelled with it.
        reconnectTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            guard let self else { return }
            self.reconnectTask = nil
            monitorLog.notice("retrying connection after transport teardown")
            self.attemptConnect()
        }
    }

    private func updateStatus() {
        if let p = peripheral {
            switch p.state {
            case .connected: statusText = "connected to bonded Mac"
            case .connecting: statusText = "connecting…"
            case .disconnecting: statusText = "disconnecting"
            case .disconnected: statusText = "disconnected"
            @unknown default: statusText = "unknown"
            }
        } else if bondedID != nil {
            statusText = "no peripheral handle"
        } else {
            statusText = "no bonded accessory"
        }
    }
}

extension HostBLEMonitor: @preconcurrency CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // The central's delegate queue is .main; restore before later callbacks.
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        guard let p = restored.first else { return }
        self.peripheral = p
        self.bondedID = p.identifier
        self.restartRestoredConnection = p.state == .connecting
        p.delegate = self
        monitorLog.notice("restored host peripheral state=\(p.state.rawValue, privacy: .public)")
        self.attemptConnect()
        self.updateStatus()
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            monitorLog.notice("central state=\(central.state.rawValue, privacy: .public)")
            if central.state == .poweredOn { self.attemptConnect() }
            self.updateStatus()
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        Task { @MainActor in
            monitorLog.notice("didConnect")
            self.reconnectTask?.cancel()
            self.reconnectTask = nil
            self.updateStatus()
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: (any Error)?) {
        Task { @MainActor in
            guard self.bondedID == p.identifier else { return }
            monitorLog.notice("didDisconnect err=\(error?.localizedDescription ?? "nil", privacy: .public) — reconnecting")
            self.scheduleReconnect()
            self.updateStatus()
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: (any Error)?) {
        Task { @MainActor in
            guard self.bondedID == p.identifier else { return }
            monitorLog.error("didFailToConnect err=\(error?.localizedDescription ?? "nil", privacy: .public)")
            self.scheduleReconnect()
            self.updateStatus()
        }
    }
}
