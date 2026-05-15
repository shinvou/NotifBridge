import AccessoryTransportExtension
import ExtensionFoundation
import Foundation

@main
struct TransportSecurity: AccessoryTransportSecurity {
    init() {
        print("[SEC-EXT] TransportSecurity init")
        NSLog("[SEC-EXT] TransportSecurity init")
    }

    @AppExtensionPoint.Bind
    var extensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier("com.apple.accessory-transport-security")
    }

    func accept(
        sessionRequest req: AccessorySecuritySession.Request
    ) -> AccessorySecuritySession.Request.Decision {
        print("[SEC-EXT] accept sessionRequest session=\(req.session)")
        NSLog("[SEC-EXT] accept sessionRequest")
        return req.accept { SecurityEventHandler(session: req.session) }
    }
}
