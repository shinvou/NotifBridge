import CoreBluetooth

/// Shared protocol constants. ESP32 bridges iPhone ↔ Mac:
///   iPhone (central, ASK) ──WRITE──▶ ESP32 (peripheral) ──NOTIFY──▶ Mac (central)
/// ESP32 firmware mirrors these UUIDs in esp32/include/demo_gatt.h.
enum DemoGATT {
    nonisolated(unsafe) static let service = CBUUID(string: "D5E12B7A-7D8E-4F12-9B5C-3F0A1E6D8C44")

    /// iPhone → ESP32: chunked ShareKeyEvent JSON, sentinel-bracketed.
    nonisolated(unsafe) static let keySharing = CBUUID(string: "D5E12B7A-7D8E-4F12-9B5C-3F0A1E6D8C46")
    /// iPhone → ESP32: chunked NotificationEnvelope JSON, sentinel-bracketed.
    nonisolated(unsafe) static let notification = CBUUID(string: "D5E12B7A-7D8E-4F12-9B5C-3F0A1E6D8C47")

    /// ESP32 → Mac: chunks re-emitted from iPhone keys writes.
    nonisolated(unsafe) static let keySharingNotify = CBUUID(string: "D5E12B7A-7D8E-4F12-9B5C-3F0A1E6D8C48")
    /// ESP32 → Mac: chunks re-emitted from iPhone notif writes.
    nonisolated(unsafe) static let notificationNotify = CBUUID(string: "D5E12B7A-7D8E-4F12-9B5C-3F0A1E6D8C49")

    /// Mac → ESP32: reverse-channel command writes (chunked + sentinels).
    nonisolated(unsafe) static let reverseWrite = CBUUID(string: "D5E12B7A-7D8E-4F12-9B5C-3F0A1E6D8C4A")
    /// ESP32 → iPhone: reverse-channel notify chunks (iPhone extension subscribes).
    nonisolated(unsafe) static let reverseNotify = CBUUID(string: "D5E12B7A-7D8E-4F12-9B5C-3F0A1E6D8C4B")

    static let advertisedNameSubstring = "NotifBdg"
}
