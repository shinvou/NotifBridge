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

    var statusText: String = "starting"

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func start() {
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
            bondedID = nil
            if let p = peripheral { central.cancelPeripheralConnection(p) }
            peripheral = nil
        default: break
        }
        updateStatus()
    }

    private func attemptConnect() {
        guard central.state == .poweredOn, let id = bondedID else { return }
        if let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            peripheral = p
            p.delegate = self
            monitorLog.notice("retrieved peripheral state=\(p.state.rawValue, privacy: .public) — connecting")
            central.connect(p, options: nil)
        } else {
            monitorLog.error("peripheral \(id.uuidString, privacy: .public) not in retrievePeripherals")
        }
        updateStatus()
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

extension HostBLEMonitor: CBCentralManagerDelegate, CBPeripheralDelegate {
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
            self.updateStatus()
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: (any Error)?) {
        Task { @MainActor in
            monitorLog.notice("didDisconnect err=\(error?.localizedDescription ?? "nil", privacy: .public) — reconnecting")
            c.connect(p, options: nil)
            self.updateStatus()
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: (any Error)?) {
        Task { @MainActor in
            monitorLog.error("didFailToConnect err=\(error?.localizedDescription ?? "nil", privacy: .public)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.attemptConnect()
            }
            self.updateStatus()
        }
    }
}
