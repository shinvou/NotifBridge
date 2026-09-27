import AccessoryTransportExtension
import ExtensionFoundation
import Foundation
import os

private let secMainLog = Logger(subsystem: "com.shinvou.NotifBridge", category: "sec-ext-main")

@main
struct TransportSecurity: AccessoryTransportSecurity {
    init() {
        secMainLog.notice("TransportSecurity init pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public)")
    }

    @AppExtensionPoint.Bind
    static var boundExtensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier("com.apple.accessory-transport-security")
    }

    func accept(
        sessionRequest req: AccessorySecuritySession.Request
    ) -> AccessorySecuritySession.Request.Decision {
        secMainLog.notice("accept sessionRequest")
        return req.accept { SecurityEventHandler(session: req.session) }
    }
}
