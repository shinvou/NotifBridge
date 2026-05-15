import CoreBluetooth

/// Shared protocol constants between the iPhone app/extensions and the Mac receiver.
/// Generated UUIDs — replace if you change the service identity in your accessory firmware.
enum DemoGATT {
    /// Primary GATT service the Mac receiver advertises and the iPhone discovers via ASK.
    nonisolated(unsafe) static let service = CBUUID(string: "D5E12B7A-7D8E-4F12-9B5C-3F0A1E6D8C44")

    /// Write by iPhone Security ext: chunked ShareKeyEvent JSON (keyMaterial + privKey + pubKey).
    /// Bracketed by `--START--` and `--END--` ASCII sentinels.
    nonisolated(unsafe) static let keySharing = CBUUID(string: "D5E12B7A-7D8E-4F12-9B5C-3F0A1E6D8C46")

    /// Write by iPhone Transport ext: encrypted notification message bytes (AES-GCM via HPKE-derived secret).
    /// Bracketed by `--START--` and `--END--` ASCII sentinels.
    nonisolated(unsafe) static let notification = CBUUID(string: "D5E12B7A-7D8E-4F12-9B5C-3F0A1E6D8C47")

    /// Substring used by the Mac receiver when advertising local name.
    static let advertisedNameSubstring = "NotifBdg"
}
