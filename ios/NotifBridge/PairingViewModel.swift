import Foundation
import SwiftUI
import AccessorySetupKit
import AccessoryNotifications
import AccessoryTransportExtension
import CoreBluetooth

private func L(_ msg: String) {
    let ts = Date().formatted(.dateTime.hour().minute().second())
    print("[\(ts)] [VM] \(msg)")
    NSLog("[VM] %@", msg)
}

@Observable
@MainActor
final class PairingViewModel {
    // Eagerly activate ASAccessorySession on init so the accessory connects
    // at launch. Auto-refresh of forwardingStatus on session events is
    // deliberately NOT done (would add another DADeviceChanged wave that
    // racing with the NotificationsForwarding XPC dispatch correlated with
    // `DAExtensionEvent init bad type: 42` decode failures). `refreshStatus`
    // only runs on explicit user action now.
    private let session = ASAccessorySession()

    var accessory: ASAccessory?
    var accessoryName: String? { accessory?.displayName }
    var decision: ForwardingDecision?
    var lastError: String?

    init() {
        L("init — activating ASAccessorySession (no auto-status-refresh)")
        session.activate(on: DispatchQueue.main) { [weak self] event in
            L("session event raw — \(event.eventType.rawValue)")
            Task { @MainActor in self?.handle(event) }
        }
        L("session activate dispatched; existing accessories=\(session.accessories.count)")
        for (i, a) in session.accessories.enumerated() {
            L("  [\(i)] displayName=\(a.displayName) bt=\(a.bluetoothIdentifier?.uuidString ?? "nil") state=\(a.state.rawValue)")
        }
    }

    private func handle(_ event: ASAccessoryEvent) {
        L("handle event=\(event.eventType.rawValue) accessory=\(event.accessory?.displayName ?? "nil")")
        switch event.eventType {
        case .activated:
            L("  .activated — accessories.count=\(session.accessories.count)")
            // No auto-refresh: just record. refreshStatus only on explicit
            // user action or after requestForwarding completes.
            setAccessory(session.accessories.first)
        case .accessoryAdded, .accessoryChanged:
            setAccessory(event.accessory ?? session.accessories.first)
            L("  .added/changed → accessory=\(accessory?.displayName ?? "nil")")
        case .accessoryRemoved:
            L("  .removed")
            if accessory?.bluetoothIdentifier == event.accessory?.bluetoothIdentifier {
                accessory = nil
                decision = nil
            }
        case .pickerDidPresent:
            L("  .pickerDidPresent")
        case .pickerDidDismiss:
            L("  .pickerDidDismiss")
        case .pickerSetupBridging:
            L("  .pickerSetupBridging")
        case .pickerSetupFailed:
            L("  .pickerSetupFailed")
        case .pickerSetupPairing:
            L("  .pickerSetupPairing")
        case .pickerSetupRename:
            L("  .pickerSetupRename")
        case .invalidated:
            L("  .invalidated")
        default:
            L("  (unhandled raw=\(event.eventType.rawValue))")
        }
    }

    private func setAccessory(_ newAccessory: ASAccessory?) {
        let oldIdentifier = accessory?.bluetoothIdentifier
        accessory = newAccessory
        if let acc = newAccessory, oldIdentifier != acc.bluetoothIdentifier {
            decision = nil
        } else if newAccessory == nil {
            decision = nil
        }
    }

    func pair() async {
        L("pair() called")
        lastError = nil
        let descriptor = ASDiscoveryDescriptor()
        descriptor.bluetoothServiceUUID = DemoGATT.service
        descriptor.bluetoothNameSubstring = DemoGATT.advertisedNameSubstring
        descriptor.supportedOptions = [.bluetoothPairingLE]
        L("descriptor: serviceUUID=\(DemoGATT.service.uuidString) nameSubstring=\(DemoGATT.advertisedNameSubstring) options=bluetoothPairingLE")

        let item = ASPickerDisplayItem(
            name: "NotifBridge Mac",   // display label only; BLE filter uses DemoGATT.advertisedNameSubstring
            productImage: UIImage(systemName: "macbook") ?? UIImage(),
            descriptor: descriptor
        )
        do {
            L("showPicker(for: [item]) awaiting…")
            try await session.showPicker(for: [item])
            L("showPicker returned cleanly")
        } catch {
            L("showPicker error: \(error.localizedDescription) [\((error as NSError).domain) \((error as NSError).code)]")
            lastError = "Pair: \(error.localizedDescription)"
        }
    }

    func requestForwarding() async {
        L("requestForwarding() called accessory=\(accessory?.displayName ?? "nil")")
        if accessory == nil, let cached = session.accessories.first {
            accessory = cached
            L("  seeded accessory from cache → \(cached.displayName)")
        }
        guard let accessory else {
            L("  no accessory; aborting")
            return
        }
        lastError = nil
        do {
            L("  invoking AccessoryNotificationCenter().requestForwarding(for:)")
            let d = try await AccessoryNotificationCenter().requestForwarding(for: accessory)
            decision = d
            L("  decision=\(d)")
        } catch {
            L("  ERROR: \(error.localizedDescription) [\((error as NSError).domain) \((error as NSError).code)]")
            lastError = "Request: \(error.localizedDescription)"
        }
    }

    func refreshStatus(reason: String = "manual") async {
        L("refreshStatus() called reason=\(reason)")
        guard let accessory else { return }
        lastError = nil
        do {
            let d = try await AccessoryNotificationCenter().forwardingStatus(for: accessory)
            decision = d
            L("  status=\(d)")
        } catch {
            L("  ERROR: \(error.localizedDescription) [\((error as NSError).domain) \((error as NSError).code)]")
            lastError = "Status: \(error.localizedDescription)"
        }
    }

    func diagnose() async {
        L("=== DIAG ===")
        L("NotificationsForwarding.featureID = \"\(NotificationsForwarding.featureID)\"")
        // LiveActivityForwarding probing intentionally removed: calling
        // LiveActivityForwarding.authorization(forAccessory:) triggers a
        // DADeviceEvent loop with CapFl 0x8 that races with the
        // NotificationsForwarding XPC dispatch and may correlate with the
        // `DAExtensionEvent init bad type: 42` decode failure we're chasing.
        guard let accessory else {
            L("no accessory bonded")
            return
        }
        do {
            let notifStatus = try await AccessoryNotificationCenter().forwardingStatus(for: accessory)
            L("AccessoryNotificationCenter.forwardingStatus = \(notifStatus)")
        } catch {
            L("notif status error: \(error.localizedDescription)")
        }
        L("=== END DIAG ===")
    }

    func openSettings() async {
        L("openSettings() called")
        guard let accessory else { return }
        lastError = nil
        do {
            let d = try await AccessoryNotificationCenter().presentSettings(for: accessory)
            decision = d
            L("  settings returned=\(d)")
        } catch {
            L("  ERROR: \(error.localizedDescription) [\((error as NSError).domain) \((error as NSError).code)]")
            lastError = "Settings: \(error.localizedDescription)"
        }
    }
}
