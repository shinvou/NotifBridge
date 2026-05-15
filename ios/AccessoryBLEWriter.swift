import Foundation
@preconcurrency import CoreBluetooth
import AccessorySetupKit
import os

/// Per-extension BLE writer: connects to the paired Mac peripheral via ASAccessorySession +
/// CBCentralManager, writes a buffer in chunks framed by `--START--` / `--END--` sentinels.
///
/// Each extension instantiates one writer. Apple's design is that AccessoryTransport
/// extensions do their own BLE I/O (CoreBluetooth is allowed in this sandbox profile
/// provided `NSAccessorySetupBluetoothServices` is in Info.plist + the split entitlements
/// are signed in). The host app does NOT proxy writes anymore.
///
/// Concurrency model: callers `await write(_:to:)`. The writer transparently activates
/// ASK, retrieves the paired peripheral, connects, discovers chars, then performs the
/// chunked write. State is kept across calls so subsequent writes reuse the connection.
final class AccessoryBLEWriter: NSObject, @unchecked Sendable {
    private let log: Logger
    private let serviceUUID: CBUUID
    private var central: CBCentralManager!
    private let askSession = ASAccessorySession()

    private var peripheral: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]

    private var bondedID: UUID?
    private var pendingWrites: [PendingWrite] = []
    private var awaitingReady: [(Bool) -> Void] = []

    private struct PendingWrite {
        let data: Data
        let target: CBUUID
        let completion: (Result<Void, any Error>) -> Void
    }

    init(category: String, serviceUUID: CBUUID) {
        self.log = Logger(subsystem: "com.shinvou.NotifBridge", category: category)
        self.serviceUUID = serviceUUID
        super.init()
        log.notice("init — activating ASK + CBCentralManager(DeviceAccessForMedia)")
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionDeviceAccessForMedia: true]
        )
        askSession.activate(on: .main) { [weak self] event in
            self?.handleASK(event)
        }
    }

    /// Write a buffer to a characteristic, chunked + framed. Throws if the connection
    /// fails or the write times out. Re-uses a live connection across calls.
    func write(_ data: Data, to target: CBUUID, timeout: TimeInterval = 8) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            DispatchQueue.main.async { [self] in
                pendingWrites.append(PendingWrite(data: data, target: target) { result in
                    cont.resume(with: result)
                })
                drainPending()
            }
        }
    }

    private func drainPending() {
        guard let p = peripheral, p.state == .connected, !characteristics.isEmpty else {
            log.notice("drainPending: not ready — \(self.pendingWrites.count, privacy: .public) queued")
            return
        }
        let mtu = max(20, p.maximumWriteValueLength(for: .withResponse))
        log.notice("drainPending: ready, mtu=\(mtu, privacy: .public) writing \(self.pendingWrites.count, privacy: .public) item(s)")
        let items = pendingWrites
        pendingWrites.removeAll()
        for item in items {
            guard let ch = characteristics[item.target] else {
                log.error("missing char \(item.target.uuidString, privacy: .public) — failing item")
                item.completion(.failure(BLEError.missingCharacteristic))
                continue
            }
            do {
                try writeChunked(item.data, to: ch, on: p, mtu: mtu)
                item.completion(.success(()))
            } catch {
                item.completion(.failure(error))
            }
        }
    }

    private func writeChunked(_ data: Data, to ch: CBCharacteristic, on p: CBPeripheral, mtu: Int) throws {
        let start = Data("--START--".utf8)
        let end = Data("--END--".utf8)
        p.writeValue(start, for: ch, type: .withResponse)
        var i = 0
        while i < data.count {
            let to = min(i + mtu - 3, data.count)  // -3 for ATT overhead
            p.writeValue(data.subdata(in: i..<to), for: ch, type: .withResponse)
            i = to
        }
        p.writeValue(end, for: ch, type: .withResponse)
        log.notice("wrote \(data.count, privacy: .public)B to \(ch.uuid.uuidString, privacy: .public)")
    }

    private func handleASK(_ event: ASAccessoryEvent) {
        switch event.eventType {
        case .activated, .accessoryAdded, .accessoryChanged:
            if let id = askSession.accessories.first?.bluetoothIdentifier {
                if id != bondedID {
                    log.notice("ASK bonded: \(id.uuidString, privacy: .public)")
                    bondedID = id
                    attemptConnect()
                }
            }
        case .accessoryRemoved:
            log.notice("ASK accessory removed")
            bondedID = nil
            peripheral = nil
            characteristics.removeAll()
        default: break
        }
    }

    private func attemptConnect() {
        guard central.state == .poweredOn, let id = bondedID else { return }
        if let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            peripheral = p
            p.delegate = self
            log.notice("retrieved peripheral state=\(p.state.rawValue, privacy: .public) — connecting")
            if p.state == .connected {
                p.discoverServices([serviceUUID])
            } else {
                central.connect(p, options: nil)
            }
        } else {
            log.error("peripheral \(id.uuidString, privacy: .public) not in retrievePeripherals")
        }
    }

    enum BLEError: Error {
        case missingCharacteristic
        case notConnected
        case timeout
    }
}

extension AccessoryBLEWriter: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log.notice("central state=\(central.state.rawValue, privacy: .public)")
        if central.state == .poweredOn { attemptConnect() }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        log.notice("didConnect — discoverServices")
        p.discoverServices([serviceUUID])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: (any Error)?) {
        log.error("didFailToConnect err=\(error?.localizedDescription ?? "nil", privacy: .public)")
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: (any Error)?) {
        log.notice("didDisconnect err=\(error?.localizedDescription ?? "nil", privacy: .public) — reconnecting")
        characteristics.removeAll()
        c.connect(p, options: nil)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard let s = p.services?.first(where: { $0.uuid == serviceUUID }) else {
            log.error("service \(self.serviceUUID.uuidString, privacy: .public) not found")
            return
        }
        log.notice("discovered service; discovering characteristics")
        p.discoverCharacteristics(nil, for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: (any Error)?) {
        for ch in s.characteristics ?? [] {
            characteristics[ch.uuid] = ch
            log.notice("ch \(ch.uuid.uuidString, privacy: .public) props=\(ch.properties.rawValue, privacy: .public)")
        }
        drainPending()
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: (any Error)?) {
        if let error {
            log.error("write to \(ch.uuid.uuidString, privacy: .public) FAILED: \(error.localizedDescription, privacy: .public)")
        }
    }
}
