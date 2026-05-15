import Foundation
import CoreBluetooth
import os

/// Hosts the GATT service the iPhone AccessoryTransport extensions write to.
///
/// Two writeable characteristics, both chunked with `--START--`/`--END--` ASCII sentinels:
///   - `keySharing`     — one-time per session: ShareKeyEvent JSON with priv/pub key + encapsulatedKey
///   - `notification`   — per notif: NotificationEnvelope JSON wrapping AES-GCM ciphertext
final class PeripheralManager: NSObject, @unchecked Sendable {
    typealias KeysHandler = @Sendable (ShareKeyEvent) -> Void
    typealias NotifHandler = @Sendable (NotificationEnvelope) -> Void
    typealias StateHandler = @Sendable (String, Bool) -> Void

    private let log = Logger(subsystem: "com.shinvou.NotifBridge.Mac", category: "peripheral")
    private let onStateChange: StateHandler
    private let onKeys: KeysHandler
    private let onNotification: NotifHandler

    private var peripheral: CBPeripheralManager!
    private var keySharingChar: CBMutableCharacteristic!
    private var notificationChar: CBMutableCharacteristic!

    private var keyBuffer = Data()
    private var keyAssembling = false
    private var notifBuffer = Data()
    private var notifAssembling = false

    init(onStateChange: @escaping StateHandler,
         onKeys: @escaping KeysHandler,
         onNotification: @escaping NotifHandler)
    {
        self.onStateChange = onStateChange
        self.onKeys = onKeys
        self.onNotification = onNotification
        super.init()
        peripheral = CBPeripheralManager(delegate: self, queue: nil)
    }
}

extension PeripheralManager: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            log.info("BT on; configuring service")
            buildAndAdvertise()
        case .poweredOff:   onStateChange("Bluetooth off", false)
        case .unauthorized: onStateChange("Bluetooth not authorized — enable in System Settings", false)
        case .unsupported:  onStateChange("Bluetooth not supported on this Mac", false)
        case .resetting:    onStateChange("Bluetooth resetting…", false)
        case .unknown:      onStateChange("Bluetooth state unknown", false)
        @unknown default:   onStateChange("Bluetooth state \(peripheral.state.rawValue)", false)
        }
    }

    private func buildAndAdvertise() {
        keySharingChar = CBMutableCharacteristic(
            type: DemoGATT.keySharing,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        notificationChar = CBMutableCharacteristic(
            type: DemoGATT.notification,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )

        let service = CBMutableService(type: DemoGATT.service, primary: true)
        service.characteristics = [keySharingChar, notificationChar]
        peripheral.add(service)

        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [DemoGATT.service],
            CBAdvertisementDataLocalNameKey: DemoGATT.advertisedNameSubstring
        ])
        onStateChange("advertising as \(DemoGATT.advertisedNameSubstring)", true)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveWrite requests: [CBATTRequest]) {
        log.notice("didReceiveWrite count=\(requests.count, privacy: .public)")
        for (i, req) in requests.enumerated() {
            let uuid = req.characteristic.uuid.uuidString
            let bytes = req.value?.count ?? 0
            let hex = req.value?.prefix(32).map { String(format: "%02x", $0) }.joined() ?? ""
            log.notice("  [\(i, privacy: .public)] uuid=\(uuid, privacy: .public) offset=\(req.offset, privacy: .public) \(bytes, privacy: .public)B hex=\(hex, privacy: .public)\(bytes > 32 ? "…" : "", privacy: .public)")
            guard let val = req.value else {
                peripheral.respond(to: req, withResult: .success)
                continue
            }
            switch req.characteristic.uuid {
            case DemoGATT.keySharing:
                handleChunk(val, isKeys: true)
            case DemoGATT.notification:
                handleChunk(val, isKeys: false)
            default:
                log.error("unexpected write to \(req.characteristic.uuid.uuidString, privacy: .public)")
            }
            peripheral.respond(to: req, withResult: .success)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveRead req: CBATTRequest) {
        log.notice("didReceiveRead uuid=\(req.characteristic.uuid.uuidString, privacy: .public) offset=\(req.offset, privacy: .public)")
        peripheral.respond(to: req, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral, didSubscribeTo c: CBCharacteristic) {
        log.notice("didSubscribeTo uuid=\(c.uuid.uuidString, privacy: .public) centralMTU=\(central.maximumUpdateValueLength, privacy: .public)")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral, didUnsubscribeFrom c: CBCharacteristic) {
        log.notice("didUnsubscribeFrom uuid=\(c.uuid.uuidString, privacy: .public)")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didAdd service: CBService, error: (any Error)?) {
        log.notice("didAdd service=\(service.uuid.uuidString, privacy: .public) err=\(error?.localizedDescription ?? "nil", privacy: .public)")
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: (any Error)?) {
        log.notice("didStartAdvertising err=\(error?.localizedDescription ?? "nil", privacy: .public)")
    }

    private func handleChunk(_ data: Data, isKeys: Bool) {
        let start = Data("--START--".utf8)
        let end = Data("--END--".utf8)
        if data == start {
            if isKeys { keyBuffer = .init(); keyAssembling = true }
            else { notifBuffer = .init(); notifAssembling = true }
            return
        }
        if data == end {
            if isKeys, keyAssembling {
                let buf = keyBuffer
                keyBuffer = .init()
                keyAssembling = false
                processKeys(buf)
            } else if !isKeys, notifAssembling {
                let buf = notifBuffer
                notifBuffer = .init()
                notifAssembling = false
                processNotification(buf)
            }
            return
        }
        if isKeys, keyAssembling { keyBuffer.append(data) }
        if !isKeys, notifAssembling { notifBuffer.append(data) }
    }

    private func processKeys(_ data: Data) {
        do {
            let evt = try JSONDecoder().decode(ShareKeyEvent.self, from: data)
            log.info("keySharing reassembled \(data.count) bytes → ShareKeyEvent")
            onKeys(evt)
        } catch {
            log.error("keySharing decode failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func processNotification(_ data: Data) {
        do {
            let envelope = try JSONDecoder().decode(NotificationEnvelope.self, from: data)
            log.info("notification reassembled \(data.count) bytes → NotificationEnvelope")
            onNotification(envelope)
        } catch {
            log.error("notification decode failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

struct ShareKeyEvent: Codable {
    let identifier: String
    let ciphersuite: String
    let version: String
    let encapsulatedKey: Data
    let publicKey: Data
    let privateKeySeed: Data
}

struct NotificationEnvelope: Codable {
    let sessionID: String
    let data: Data
}
