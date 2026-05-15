import AccessoryTransportExtension
import ExtensionFoundation
import Foundation

@main
struct TransportApp: AccessoryTransportAppExtension {
    init() {
        print("[TX-EXT] TransportApp init")
        NSLog("[TX-EXT] TransportApp init")
    }

    @AppExtensionPoint.Bind
    var extensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier("com.apple.accessory-transport-extension")
    }

    func accept(
        sessionRequest req: AccessoryTransportSession.Request
    ) -> AccessoryTransportSession.Request.Decision {
        print("[TX-EXT] accept sessionRequest session=\(req.session)")
        NSLog("[TX-EXT] accept sessionRequest")
        return req.accept { TransportEventHandler(session: req.session) }
    }
}
