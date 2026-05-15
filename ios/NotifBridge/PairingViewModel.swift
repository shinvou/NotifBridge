import Foundation
import SwiftUI
import AccessorySetupKit
import AccessoryNotifications
import AccessoryLiveActivities
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
    private let session = ASAccessorySession()

    var accessory: ASAccessory?
    var accessoryName: String? { accessory?.displayName }
    var decision: ForwardingDecision?
    var lastError: String?

    init() {
        L("init — activating ASAccessorySession")
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
            setAccessoryAndRefreshStatus(session.accessories.first, reason: "activated")
            L("  → accessory=\(accessory?.displayName ?? "nil")")
        case .accessoryAdded, .accessoryChanged:
            setAccessoryAndRefreshStatus(event.accessory ?? session.accessories.first, reason: "added/changed")
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

    private func setAccessoryAndRefreshStatus(_ newAccessory: ASAccessory?, reason: String) {
        let oldIdentifier = accessory?.bluetoothIdentifier
        accessory = newAccessory

        guard let accessory else {
            decision = nil
            return
        }

        if oldIdentifier != accessory.bluetoothIdentifier {
            decision = nil
        }

        Task { [weak self] in
            await self?.refreshStatus(reason: "session \(reason)")
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
        L("LiveActivityForwarding.featureID  = \"\(LiveActivityForwarding.featureID)\"")
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
        do {
            let laAuth = try await LiveActivityForwarding.authorization(forAccessory: accessory)
            L("LiveActivityForwarding.authorization = \(laAuth)")
        } catch {
            L("LA auth error: \(error.localizedDescription) [\((error as NSError).domain) \((error as NSError).code)]")
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
