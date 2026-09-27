import Foundation
@preconcurrency import CoreBluetooth
import AccessorySetupKit
import os

/// Per-extension BLE writer: connects to the paired ESP32 peripheral via ASAccessorySession +
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

    private let reverseUUID: CBUUID?
    private let relayReceipts: Bool
    var onMessage: ((Data) -> Void)?
    private var reverseBuffer = Data()
    private var assemblingReverse = false
    private var stopped = false

    private var bondedID: UUID?
    private var pendingWrites: [PendingWrite] = []
    private var activeWrite: PendingWrite?
    private var chunks: [Data] = []
    private var chunkIndex = 0
    private var progressGeneration: UInt64 = 0
    private var chunkReceipt = Data()
    private var attAcknowledged = false
    private var relayAcknowledged = false
    private var restartAfterATT = false

    private struct PendingWrite {
        let id = UUID()
        let data: Data
        let target: CBUUID
        let timeout: TimeInterval
        var retriesRemaining = 2
        let completion: (Result<Void, any Error>) -> Void
    }

    init(category: String, serviceUUID: CBUUID, reverseUUID: CBUUID? = nil, restoreIdentifier: String? = nil, relayReceipts: Bool = true) {
        self.log = Logger(subsystem: "com.shinvou.NotifBridge", category: category)
        self.serviceUUID = serviceUUID
        self.reverseUUID = reverseUUID
        self.relayReceipts = reverseUUID != nil && relayReceipts
        super.init()
        log.notice("init — activating ASK + CBCentralManager(DeviceAccessForMedia)")
        var options: [String: Any] = [CBCentralManagerOptionDeviceAccessForMedia: true]
        if let restoreIdentifier { options[CBCentralManagerOptionRestoreIdentifierKey] = restoreIdentifier }
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: options
        )
        askSession.activate(on: .main) { [weak self] event in
            self?.handleASK(event)
        }
    }

    /// Write a buffer to a characteristic, chunked + framed. Throws if the connection
    /// fails or the write times out. Re-uses a live connection across calls.
    func write(_ data: Data, to target: CBUUID, timeout: TimeInterval = 16) async throws {
        log.notice("write() ENTER \(data.count, privacy: .public)B to=\(target.uuidString, privacy: .public)")
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            DispatchQueue.main.async { [self] in
                guard !stopped else { cont.resume(throwing: BLEError.notConnected); return }
                self.log.notice("write() queued — pendingWrites.count=\(self.pendingWrites.count + 1, privacy: .public) peripheral=\(self.peripheral?.state.rawValue ?? -1, privacy: .public) chars=\(self.characteristics.count, privacy: .public)")
                let item = PendingWrite(data: data, target: target, timeout: timeout) { result in cont.resume(with: result) }
                // Preserve FIFO for ordinary notifications. Small control
                // frames retain priority when selecting the next write.
                pendingWrites.append(item)
                watchForStall(item.id, timeout: timeout)
                drainPending()
            }
        }
        log.notice("write() EXIT \(data.count, privacy: .public)B to=\(target.uuidString, privacy: .public)")
    }

    // Bound inactivity, not total transfer time: the ESP32 relays a rich frame
    // over many acknowledged indications. Queued frames share that progress.
    private func watchForStall(_ id: UUID, timeout: TimeInterval) {
        let generation = progressGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self,
                  activeWrite?.id == id || pendingWrites.contains(where: { $0.id == id }) else { return }
            if progressGeneration != generation || (activeWrite != nil && activeWrite?.id != id) {
                watchForStall(id, timeout: timeout)
            } else if activeWrite?.id == id {
                // Prevent a late ATT callback from acknowledging the next frame.
                failActive(BLEError.timeout, retry: true)
                if let peripheral { central.cancelPeripheralConnection(peripheral) }
            } else if let index = pendingWrites.firstIndex(where: { $0.id == id }) {
                pendingWrites.remove(at: index).completion(.failure(BLEError.timeout))
            }
        }
    }

    private func drainPending() {
        guard activeWrite == nil, !pendingWrites.isEmpty,
              let p = peripheral, p.state == .connected, !characteristics.isEmpty else { return }
        if let reverseUUID, characteristics[reverseUUID]?.isNotifying != true { return }
        let next = reverseUUID == nil ? 0 : (pendingWrites.firstIndex { $0.data.count <= 1024 } ?? 0)
        let item = pendingWrites.remove(at: next)
        guard let ch = characteristics[item.target] else {
            item.completion(.failure(BLEError.missingCharacteristic))
            drainPending()
            return
        }
        activeWrite = item
        restartAfterATT = false
        let maximum = p.maximumWriteValueLength(for: .withResponse)
        // One receipt should cover one relay indication, not a long write that
        // becomes several separately acknowledged packets on the Mac link.
        let size = !relayReceipts ? max(1, maximum) : max(1, min(200, maximum - 20))
        chunks = [Data("--START--".utf8)]
        for offset in stride(from: 0, to: item.data.count, by: size) {
            chunks.append(item.data.subdata(in: offset..<min(offset + size, item.data.count)))
        }
        chunks.append(Data("--END--".utf8))
        chunkIndex = 0
        sendCurrentChunk(p, ch)
    }

    private func receiverBecameReady() {
        guard !stopped else { return }
        guard activeWrite != nil else { drainPending(); return }
        // A new receiver has no partial frame. Restart at START, but never issue
        // another ATT write while the preceding one is outstanding.
        restartAfterATT = true
        if attAcknowledged, let p = peripheral, let item = activeWrite,
           let ch = characteristics[item.target] { restartForReceiver(p, ch) }
    }

    private func restartForReceiver(_ p: CBPeripheral, _ ch: CBCharacteristic) {
        restartAfterATT = false
        progressGeneration &+= 1
        chunkIndex = 0
        log.notice("receiver ready — restarting pending frame")
        sendCurrentChunk(p, ch)
    }

    private func sendCurrentChunk(_ p: CBPeripheral, _ ch: CBCharacteristic) {
        attAcknowledged = false
        relayAcknowledged = !relayReceipts
        var data = chunks[chunkIndex]
        if relayReceipts {
            var id = UUID().uuid
            let bytes = withUnsafeBytes(of: &id) { Data($0) }
            chunkReceipt = Data("NBA1".utf8) + bytes
            data = Data("NBW1".utf8) + bytes + data
        }
        p.writeValue(data, for: ch, type: .withResponse)
    }

    private func advanceIfAcknowledged(_ p: CBPeripheral, _ ch: CBCharacteristic) {
        guard attAcknowledged, relayAcknowledged, let item = activeWrite else { return }
        progressGeneration &+= 1
        chunkIndex += 1
        if chunkIndex < chunks.count {
            if reverseUUID != nil, item.data.count > 1024,
               pendingWrites.contains(where: { $0.data.count <= 1024 }) {
                // Only small control results interrupt rich frames. Resume the
                // interrupted frame before other ordinary notifications.
                pendingWrites.insert(item, at: 0)
                activeWrite = nil
                chunks.removeAll()
                chunkReceipt.removeAll()
                drainPending()
            } else { sendCurrentChunk(p, ch) }
        }
        else {
            activeWrite = nil
            chunks.removeAll()
            chunkReceipt.removeAll()
            item.completion(.success(()))
            drainPending()
        }
    }

    private func failActive(_ error: any Error, retry: Bool = false) {
        let item = activeWrite
        activeWrite = nil
        chunks.removeAll()
        chunkIndex = 0
        characteristics.removeAll()
        reverseBuffer.removeAll()
        assemblingReverse = false
        chunkReceipt.removeAll()
        if var item, retry, item.retriesRemaining > 0, !stopped {
            item.retriesRemaining -= 1
            progressGeneration &+= 1
            pendingWrites.insert(item, at: 0)
            watchForStall(item.id, timeout: item.timeout)
            log.notice("retrying interrupted frame; retries left=\(item.retriesRemaining, privacy: .public)")
        } else {
            item?.completion(.failure(error))
        }
    }

    func stop() {
        stopped = true
        onMessage = nil
        failActive(BLEError.notConnected)
        let waiting = pendingWrites
        pendingWrites.removeAll()
        waiting.forEach { $0.completion(.failure(BLEError.notConnected)) }
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        askSession.invalidate()
    }

    private func handleASK(_ event: ASAccessoryEvent) {
        log.notice("ASK event raw=\(event.eventType.rawValue, privacy: .public) accessories.count=\(self.askSession.accessories.count, privacy: .public)")
        switch event.eventType {
        case .activated, .accessoryAdded, .accessoryChanged:
            if let id = askSession.accessories.first?.bluetoothIdentifier {
                if id != bondedID {
                    log.notice("ASK bonded: \(id.uuidString, privacy: .public)")
                    bondedID = id
                    attemptConnect()
                } else if peripheral?.state != .connected {
                    // Same bondedID but not yet connected — retry. Fixes a deadlock
                    // where the first ASK event fired before CB was poweredOn (so
                    // attemptConnect bailed) and subsequent ASK events all hit the
                    // "same bondedID" branch, leaving no retry path.
                    log.notice("ASK same bondedID but peripheral.state=\(self.peripheral?.state.rawValue ?? -1, privacy: .public) — retrying connect")
                    attemptConnect()
                } else {
                    log.notice("ASK same bondedID, already connected — no-op")
                }
            }
        case .accessoryRemoved:
            log.notice("ASK accessory removed")
            bondedID = nil
            failActive(BLEError.notConnected)
            if let peripheral { central.cancelPeripheralConnection(peripheral) }
            peripheral = nil
            characteristics.removeAll()
        default:
            log.notice("ASK unhandled event raw=\(event.eventType.rawValue, privacy: .public)")
        }
    }

    private func attemptConnect() {
        log.notice("attemptConnect: central.state=\(self.central.state.rawValue, privacy: .public) bondedID=\(self.bondedID?.uuidString ?? "nil", privacy: .public)")
        guard !stopped, central.state == .poweredOn else {
            log.notice("  central not poweredOn — bail")
            return
        }
        guard let id = bondedID else {
            log.notice("  no bondedID — bail")
            return
        }
        let retrieved = central.retrievePeripherals(withIdentifiers: [id])
        log.notice("  retrievePeripherals returned \(retrieved.count, privacy: .public) item(s)")
        if let p = retrieved.first {
            peripheral = p
            p.delegate = self
            log.notice("  peripheral state=\(p.state.rawValue, privacy: .public) name=\(p.name ?? "nil", privacy: .public)")
            if p.state == .connected {
                log.notice("  already connected → discoverServices")
                p.discoverServices([serviceUUID])
            } else {
                log.notice("  calling central.connect")
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
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let p = restored.first else { return }
        peripheral = p
        bondedID = p.identifier
        p.delegate = self
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: (any Error)?) {
        log.notice("didUpdateNotificationState \(ch.uuid.uuidString, privacy: .public) notifying=\(ch.isNotifying, privacy: .public) err=\(error?.localizedDescription ?? "nil", privacy: .public)")
        if error == nil { drainPending() }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: (any Error)?) {
        guard !stopped, p === peripheral, ch.uuid == reverseUUID, error == nil, let data = ch.value else { return }
        if data.count == 20, data.starts(with: Data("NBA1".utf8)) {
            if data == chunkReceipt, let item = activeWrite, let target = characteristics[item.target] {
                relayAcknowledged = true
                advanceIfAcknowledged(p, target)
            }
            return // Stale receipts must never become reverse-message content.
        }
        if data == Data("--START--".utf8) {
            reverseBuffer.removeAll()
            assemblingReverse = true
        } else if data == Data("--END--".utf8) {
            guard assemblingReverse else { return }
            let message = reverseBuffer
            reverseBuffer.removeAll()
            assemblingReverse = false
            if message == Data("NB-RECEIVER-READY-1".utf8) { receiverBecameReady() }
            else if !message.isEmpty { onMessage?(message) }
        } else if assemblingReverse {
            guard reverseBuffer.count + data.count <= NotifWire.maxEnvelopeBytes else {
                reverseBuffer.removeAll()
                assemblingReverse = false
                return
            }
            reverseBuffer.append(data)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log.notice("centralManagerDidUpdateState state=\(central.state.rawValue, privacy: .public) (5=poweredOn,4=poweredOff,0=unknown)")
        if central.state == .poweredOn { attemptConnect() }
        else { failActive(BLEError.notConnected) }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        log.notice("didConnect peripheral name=\(p.name ?? "nil", privacy: .public) state=\(p.state.rawValue, privacy: .public) — discoverServices")
        p.discoverServices([serviceUUID])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: (any Error)?) {
        log.error("didFailToConnect err=\(error?.localizedDescription ?? "nil", privacy: .public) — retrying connect")
        if !stopped { c.connect(p, options: nil) }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: (any Error)?) {
        let errCode = (error as NSError?)?.code ?? -1
        log.notice("didDisconnect err=\(error?.localizedDescription ?? "nil", privacy: .public) code=\(errCode, privacy: .public) — reconnecting")
        failActive(error ?? BLEError.notConnected, retry: true)
        if !stopped, bondedID != nil { c.connect(p, options: nil) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: (any Error)?) {
        log.notice("didDiscoverServices err=\(error?.localizedDescription ?? "nil", privacy: .public) count=\(p.services?.count ?? 0, privacy: .public)")
        guard let s = p.services?.first(where: { $0.uuid == serviceUUID }) else {
            log.error("service \(self.serviceUUID.uuidString, privacy: .public) not found in discovered")
            return
        }
        log.notice("discovered target service; discovering characteristics")
        p.discoverCharacteristics(nil, for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: (any Error)?) {
        log.notice("didDiscoverCharacteristics err=\(error?.localizedDescription ?? "nil", privacy: .public) count=\(s.characteristics?.count ?? 0, privacy: .public)")
        for ch in s.characteristics ?? [] {
            characteristics[ch.uuid] = ch
            log.notice("  ch \(ch.uuid.uuidString, privacy: .public) props=0x\(String(ch.properties.rawValue, radix: 16), privacy: .public)")
        }
        if let reverseUUID, let ch = characteristics[reverseUUID] {
            p.setNotifyValue(true, for: ch)
        }
        log.notice("now have \(self.characteristics.count, privacy: .public) chars; draining pendingWrites=\(self.pendingWrites.count, privacy: .public)")
        drainPending()
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: (any Error)?) {
        guard p === peripheral, let item = activeWrite, item.target == ch.uuid, characteristics[item.target] === ch else { return }
        if let error {
            failActive(error)
            central.cancelPeripheralConnection(p)
            return
        }
        if chunkIndex == 0 || chunkIndex == chunks.count - 1 {
            log.notice("ATT acknowledgment chunk=\(self.chunkIndex, privacy: .public) of \(self.chunks.count, privacy: .public)")
        }
        attAcknowledged = true
        if restartAfterATT { restartForReceiver(p, ch) }
        else { advanceIfAcknowledged(p, ch) }
    }
}
