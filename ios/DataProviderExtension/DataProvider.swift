import AccessoryNotifications
import AccessoryTransportExtension
import ExtensionFoundation
import Foundation

@main
struct DataProvider: AccessoryDataProvider {
    init() {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let pid = ProcessInfo.processInfo.processIdentifier
        print("[DP-EXT] DataProvider init @ \(stamp) pid=\(pid)")
        NSLog("[DP-EXT] DataProvider init @ %@ pid=%d", stamp, pid)
    }

    @AppExtensionPoint.Bind
    var extensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier("com.apple.accessory-data-provider")
        AppExtensionPoint.Capabilities {
            NotificationsForwarding {
                let stamp = ISO8601DateFormatter().string(from: Date())
                print("[DP-EXT] NotificationHandler factory CALLED @ \(stamp)")
                NSLog("[DP-EXT] NotificationHandler factory CALLED @ %@", stamp)
                return NotificationHandler()
            }
        }
    }
}
