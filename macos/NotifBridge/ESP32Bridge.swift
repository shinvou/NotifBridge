import Foundation
import CryptoKit
@preconcurrency import CoreBluetooth
import os

private let log = Logger(subsystem: "com.shinvou.NotifBridge.Mac", category: "esp32-bridge")
private let defaultsKey = "com.shinvou.NotifBridge.Mac.esp32PeripheralID"

/// Mac is BLE central. Connects to the ESP32 bridge, subscribes to the two NOTIFY
/// characteristics, reassembles the sentinel-bracketed chunk stream coming through
/// from the iPhone, then hands key/notif payloads to the existing HPKE pipeline.
///
/// Bond lives in macOS `bluetoothd` keyed to the ESP32's stable BLE identity — like
/// AirPods, it survives app quit and reboots. We only need to remember the peripheral
/// UUID across launches to skip rescanning.
@MainActor
final class ESP32Bridge: NSObject {
    typealias StateHandler = (_ statusLine: String, _ ready: Bool) -> Void
    typealias KeyInfoHandler = (_ info: String) -> Void

    var onEvent: ((NotifWire.Event, String) -> Void)?
    var onError: ((String) -> Void)?
    var onState: StateHandler?
    var onKeyInfo: KeyInfoHandler?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var keyNotifyChar: CBCharacteristic?
    private var notifNotifyChar: CBCharacteristic?
    private var reverseWriteChar: CBCharacteristic?
    private var connectFallbackTask: Task<Void, Never>?
    private var didConnect = false
    private var receiverReadyTask: Task<Void, Never>?

    private let hpke = HPKEDecryptor()
    private var hpkeReady = false
    private let inbox = DeliveryInbox()
    private var expirationTask: Task<Void, Never>?

    private var keyBuffer = Data()
    private var keyAssembling = false
    private var notifBuffer = Data()
    private var notifAssembling = false

    private let startToken = Data("--START--".utf8)
    private let endToken = Data("--END--".utf8)

    func start() {
        inbox.deliver = { [weak self] env in
            guard let self, self.onEvent != nil else { throw SendError.disconnected }
            try self.decryptAndDeliver(env)
        }
        inbox.acknowledge = { [weak self] id in
            guard let self else { return }
            do { try self.writeReverse(JSONEncoder().encode(DeliveryReceipt(id: id))) }
            catch { log.error("acceptance receipt failed: \(error.localizedDescription, privacy: .public)") }
        }
        inbox.onFailure = { [weak self] message in
            log.error("delivery deferred/failed: \(message, privacy: .public)")
            self?.onError?(message)
        }
        expirationTask?.cancel()
        expirationTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                self?.inbox.expire()
            }
        }
        NSLog("[NB] ESP32Bridge.start() — creating CBCentralManager")
        central = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionShowPowerAlertKey: true
        ])
        NSLog("[NB] CBCentralManager created — initial state=%d", central.state.rawValue)
        if let info = hpke.restoreFromKeychain() {
            hpkeReady = true
            NSLog("[NB] HPKE keys restored from Keychain: %@", info)
            onKeyInfo?(info)
        }
    }

    private func updateState(_ line: String, ready: Bool) {
        onState?(line, ready)
    }

    private func savedPeripheralID() -> UUID? {
        guard let s = UserDefaults.standard.string(forKey: defaultsKey) else { return nil }
        return UUID(uuidString: s)
    }

    private func storePeripheralID(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: defaultsKey)
        log.notice("stored ESP32 peripheral id \(id.uuidString, privacy: .public)")
    }

    private func attemptReconnectOrScan() {
        NSLog("[NB] attemptReconnectOrScan central.state=%d", central.state.rawValue)
        guard central.state == .poweredOn else { return }
        if let saved = savedPeripheralID(),
           let p = central.retrievePeripherals(withIdentifiers: [saved]).first
        {
            NSLog("[NB]   retrieved bonded %@ state=%d", saved.uuidString, p.state.rawValue)
            peripheral = p
            p.delegate = self
            updateState("reconnecting to ESP32 \(saved.uuidString.prefix(8))…", ready: false)
            central.connect(p, options: nil)
            scheduleConnectFallback()
            return
        }
        startScan()
    }

    private func startScan() {
        NSLog("[NB]   scanning for service %@", DemoGATT.service.uuidString)
        updateState("scanning for ESP32 \(DemoGATT.advertisedNameSubstring)…", ready: false)
        central.scanForPeripherals(withServices: [DemoGATT.service], options: nil)
    }

    /// If `central.connect(...)` doesn't fire `didConnect` within 8s, drop the saved
    /// identifier and fall back to a service-UUID scan. Prevents being stuck on a
    /// phantom peripheral in macOS's known-devices cache.
    private func scheduleConnectFallback() {
        connectFallbackTask?.cancel()
        didConnect = false
        connectFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !self.didConnect else { return }
            NSLog("[NB]   connect timeout — clearing saved id, scanning")
            if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
            self.peripheral = nil
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            self.startScan()
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension ESP32Bridge: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        NSLog("[NB] centralManagerDidUpdateState state=%d", central.state.rawValue)
        Task { @MainActor in
            NSLog("[NB]   in MainActor task, state=%d", central.state.rawValue)
            switch central.state {
            case .poweredOn:
                NSLog("[NB]   poweredOn → attemptReconnectOrScan")
                log.notice("CB powered on — attempting reconnect/scan")
                attemptReconnectOrScan()
            case .poweredOff:    updateState("Bluetooth off", ready: false)
            case .unauthorized:  updateState("Bluetooth not authorized", ready: false)
            case .unsupported:   updateState("Bluetooth not supported", ready: false)
            case .resetting:     updateState("Bluetooth resetting…", ready: false)
            case .unknown:       updateState("Bluetooth state unknown", ready: false)
            @unknown default:    updateState("Bluetooth state \(central.state.rawValue)", ready: false)
            }
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager,
                                    didDiscover p: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? "?"
        NSLog("[NB] didDiscover %@ id=%@ rssi=%d", name, p.identifier.uuidString, rssi.intValue)
        log.notice("didDiscover \(name, privacy: .public) id=\(p.identifier.uuidString, privacy: .public) rssi=\(rssi.intValue)")
        Task { @MainActor in
            guard peripheral == nil else { return }
            peripheral = p
            p.delegate = self
            c.stopScan()
            updateState("connecting to ESP32 (\(name))…", ready: false)
            c.connect(p, options: nil)
            scheduleConnectFallback()
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        NSLog("[NB] didConnect")
        log.notice("didConnect — discoverServices")
        Task { @MainActor in
            didConnect = true
            connectFallbackTask?.cancel()
            storePeripheralID(p.identifier)
            updateState("connected, discovering services…", ready: false)
            p.discoverServices([DemoGATT.service])
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: (any Error)?) {
        log.error("didFailToConnect err=\(error?.localizedDescription ?? "nil", privacy: .public)")
        Task { @MainActor in
            updateState("connect failed: \(error?.localizedDescription ?? "?") — retrying", ready: false)
            c.connect(p, options: nil)
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: (any Error)?) {
        let domain = (error as NSError?)?.domain ?? ""
        let code = (error as NSError?)?.code ?? 0
        NSLog("[NB] didDisconnect err=%@ domain=%@ code=%d", error?.localizedDescription ?? "nil", domain, code)
        log.notice("didDisconnect err=\(error?.localizedDescription ?? "nil", privacy: .public) — reconnecting")
        Task { @MainActor in
            receiverReadyTask?.cancel()
            receiverReadyTask = nil
            updateState("ESP32 disconnected — reconnecting…", ready: false)
            keyNotifyChar = nil
            notifNotifyChar = nil
            c.connect(p, options: nil)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension ESP32Bridge: CBPeripheralDelegate {
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: (any Error)?) {
        NSLog("[NB] didDiscoverServices err=%@ count=%d", error?.localizedDescription ?? "nil", p.services?.count ?? -1)
        if let error { log.error("didDiscoverServices err=\(error.localizedDescription, privacy: .public)"); return }
        guard let svc = p.services?.first(where: { $0.uuid == DemoGATT.service }) else {
            NSLog("[NB]   service %@ NOT in discovered list", DemoGATT.service.uuidString)
            log.error("service \(DemoGATT.service.uuidString, privacy: .public) not found")
            return
        }
        p.discoverCharacteristics(
            [DemoGATT.keySharingNotify, DemoGATT.notificationNotify, DemoGATT.reverseWrite],
            for: svc
        )
    }

    nonisolated func peripheral(_ p: CBPeripheral,
                                didDiscoverCharacteristicsFor s: CBService,
                                error: (any Error)?) {
        NSLog("[NB] didDiscoverCharacteristics count=%d err=%@", s.characteristics?.count ?? -1, error?.localizedDescription ?? "nil")
        if let error { log.error("didDiscoverCharacteristics err=\(error.localizedDescription, privacy: .public)"); return }
        Task { @MainActor in
            for ch in s.characteristics ?? [] {
                NSLog("[NB]   char %@ props=0x%x", ch.uuid.uuidString, ch.properties.rawValue)
                switch ch.uuid {
                case DemoGATT.keySharingNotify:
                    keyNotifyChar = ch
                    p.setNotifyValue(true, for: ch)
                case DemoGATT.notificationNotify:
                    notifNotifyChar = ch
                    p.setNotifyValue(true, for: ch)
                case DemoGATT.reverseWrite:
                    reverseWriteChar = ch
                default: break
                }
            }
            announceReceiverReadiness()

        }
    }

    nonisolated func peripheral(_ p: CBPeripheral,
                                didUpdateNotificationStateFor ch: CBCharacteristic,
                                error: (any Error)?) {
        NSLog("[NB] didUpdateNotificationState %@ notifying=%d err=%@", ch.uuid.uuidString, ch.isNotifying ? 1 : 0, error?.localizedDescription ?? "nil")
        log.notice("didUpdateNotificationState \(ch.uuid.uuidString, privacy: .public) notifying=\(ch.isNotifying, privacy: .public) err=\(error?.localizedDescription ?? "nil", privacy: .public)")
        Task { @MainActor in
            guard error == nil, p === peripheral else { return }
            announceReceiverReadiness()
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral,
                                didUpdateValueFor ch: CBCharacteristic,
                                error: (any Error)?) {
        if let error { log.error("didUpdateValue err=\(error.localizedDescription, privacy: .public)"); return }
        guard let data = ch.value else { return }
        NSLog("[NB] didUpdateValue %@ %dB", ch.uuid.uuidString, data.count)
        let isKeys = (ch.uuid == DemoGATT.keySharingNotify)
        Task { @MainActor in handleChunk(data, isKeys: isKeys) }
    }
}

// MARK: - chunk reassembly + decrypt

extension ESP32Bridge {
    private func handleChunk(_ data: Data, isKeys: Bool) {
        if !isKeys { receiverReadyTask?.cancel() }

        if data == startToken {
            if isKeys { keyBuffer = .init(); keyAssembling = true }
            else      { notifBuffer = .init(); notifAssembling = true }
            return
        }
        if data == endToken {
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
        if isKeys, keyAssembling {
            if keyBuffer.count + data.count > NotifWire.maxEnvelopeBytes { keyAssembling = false; keyBuffer.removeAll() }
            else { keyBuffer.append(data) }
        }
        if !isKeys, notifAssembling {
            if notifBuffer.count + data.count > NotifWire.maxEnvelopeBytes { notifAssembling = false; notifBuffer.removeAll() }
            else { notifBuffer.append(data) }
        }
    }

    private func processKeys(_ data: Data) {
        NSLog("[NB] processKeys %dB", data.count)
        do {
            if let packet = try? JSONDecoder().decode(KeyExchangePacket.self, from: data) {
                try hpke.acceptKeyPacket(packet)
                log.notice("key phase persisted: \(packet.phase.rawValue, privacy: .public)")
                try writeReverse(JSONEncoder().encode(DeliveryReceipt(id: packet.receiptID)))
                if packet.phase == .activate {
                    hpkeReady = true
                    onKeyInfo?("Encryption keys installed")
                    inbox.retryPending()
                }
                return
            }
            let evt = try JSONDecoder().decode(ShareKeyEvent.self, from: data)
            NSLog("[NB]   decoded ShareKeyEvent cipher=%@ id=%@", evt.ciphersuite, evt.identifier)
            try hpke.installKeys(
                privateKeySeed: evt.privateKeySeed,
                publicKey: evt.publicKey,
                encapsulatedKey: evt.encapsulatedKey,
                identifier: evt.identifier,
                ciphersuite: evt.ciphersuite,
                version: evt.version
            )
            hpkeReady = true
            let info = "cipher=\(evt.ciphersuite) v=\(evt.version) id=\(evt.identifier.prefix(8)) priv=\(evt.privateKeySeed.count)B"
            log.notice("keys installed: \(info, privacy: .public)")
            onKeyInfo?(info)

            if let id = evt.receiptID {
                try writeReverse(JSONEncoder().encode(DeliveryReceipt(id: id)))
            }
            inbox.retryPending()
        } catch {
            log.error("key install failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func processNotification(_ data: Data) {
        NSLog("[NB] processNotification %dB", data.count)
        do {
            let env = try JSONDecoder().decode(NotificationEnvelope.self, from: data)
            NSLog("[NB]   envelope sess=%@ cipher=%dB", env.sessionID, env.data.count)
            inbox.receive(env)
        } catch {
            NSLog("[NB]   envelope decode FAILED: %@", error.localizedDescription)
            // Dump head and tail so we can tell apart {truncated JSON, garbled
            // bytes, two payloads concatenated, etc.}.
            let head = data.prefix(120)
            let tail = data.suffix(80)
            let headAscii = String(decoding: head, as: UTF8.self).replacingOccurrences(of: "\n", with: "\\n")
            let tailAscii = String(decoding: tail, as: UTF8.self).replacingOccurrences(of: "\n", with: "\\n")
            let headHex = head.prefix(16).map { String(format: "%02x", $0) }.joined()
            let tailHex = tail.suffix(16).map { String(format: "%02x", $0) }.joined()
            NSLog("[NB]   head ascii: %@", headAscii)
            NSLog("[NB]   head hex:   %@", headHex)
            NSLog("[NB]   tail ascii: %@", tailAscii)
            NSLog("[NB]   tail hex:   %@", tailHex)
        }
    }

    private func decryptAndDeliver(_ env: NotificationEnvelope) throws {
        let plaintext: Data
        do { plaintext = try hpke.decrypt(env.data, sessionID: env.sessionID) }
        catch {
            log.error("decrypt failed bytes=\(env.data.count, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
        let event: NotifWire.Event
        if plaintext.first == NotifWire.kindRichV2, let frame = NotifFrame.decode(plaintext) {
            event = .init(kind: .add, notification: frame)
        } else {
            event = try NotifWire.decodeEvent(plaintext)
        }
        log.notice("event accepted kind=\(event.kind.rawValue, privacy: .public) bytes=\(plaintext.count, privacy: .public)")
        onEvent?(event, env.sessionID)
    }

    enum SendError: LocalizedError {
        case noSession, disconnected
        var errorDescription: String? {
            switch self {
            case .noSession: "This notification has no iPhone session."
            case .disconnected: "The bridge is disconnected. Reconnect before trying again."
            }
        }
    }
    func sendReverseCommand(_ payload: Data, sessionID: String?) throws {
        guard let sessionID else { throw SendError.noSession }
        let ciphertext = try hpke.encryptReverse(payload, sessionID: sessionID)
        let envelope = try JSONEncoder().encode(NotificationEnvelope(sessionID: sessionID, data: ciphertext))
        try writeReverse(envelope)
        log.notice("reverse command transmitted (\(payload.count, privacy: .public) bytes)")
    }

    private func announceReceiverReadiness() {
        guard receiverReadyTask == nil, keyNotifyChar?.isNotifying == true,
              notifNotifyChar?.isNotifying == true, reverseWriteChar != nil else { return }
        updateState("subscribed — waiting for iPhone via ESP32", ready: true)
        receiverReadyTask = Task { @MainActor [weak self] in
            // Retry briefly if the phone has not subscribed yet. Stop as soon as
            // a notification chunk arrives, so long transfers are not restarted.
            for _ in 0..<6 {
                guard !Task.isCancelled, let self else { return }
                do { try self.writeReverse(Data("NB-RECEIVER-READY-1".utf8)) }
                catch { log.error("receiver ready signal failed: \(error.localizedDescription, privacy: .public)") }
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
    }

    private func writeReverse(_ envelope: Data) throws {
        guard let p = peripheral, let ch = reverseWriteChar, p.state == .connected else { throw SendError.disconnected }
        let chunkSize = max(1, p.maximumWriteValueLength(for: .withResponse) - 3)
        p.writeValue(startToken, for: ch, type: .withResponse)
        for offset in stride(from: 0, to: envelope.count, by: chunkSize) {
            p.writeValue(envelope.subdata(in: offset..<min(offset + chunkSize, envelope.count)), for: ch, type: .withResponse)
        }
        p.writeValue(endToken, for: ch, type: .withResponse)
    }

}

// CBPeripheralDelegate for the reverseWrite char ack.
extension ESP32Bridge {
    nonisolated func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: (any Error)?) {
        if let error {
            Task { @MainActor [weak self] in self?.onError?("Bluetooth write failed: \(error.localizedDescription)") }
        } else {
            NSLog("[NB] didWriteValueFor %@ OK", ch.uuid.uuidString)
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
    var receiptID: UUID? = nil
}
