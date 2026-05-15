import AccessoryNotifications
import AccessoryTransportExtension
import ExtensionFoundation
import Foundation

@main
struct DataProvider: AccessoryDataProvider {
    init() {
        print("[DP-EXT] DataProvider init (notif-only, instance extensionPoint)")
        NSLog("[DP-EXT] DataProvider init (notif-only, instance extensionPoint)")
    }

    @AppExtensionPoint.Bind
    var extensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier("com.apple.accessory-data-provider")
        AppExtensionPoint.Capabilities {
            NotificationsForwarding {
                print("[DP-EXT] NotificationHandler factory CALLED")
                NSLog("[DP-EXT] NotificationHandler factory CALLED")
                return NotificationHandler()
            }
        }
    }
}
