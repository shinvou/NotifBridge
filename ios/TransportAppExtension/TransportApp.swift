import AccessoryTransportExtension
import ExtensionFoundation
import Foundation
import os

private let txAppLog = Logger(subsystem: "com.shinvou.NotifBridge", category: "tx-ext-main")

@main
struct TransportApp: AccessoryTransportAppExtension {
    init() {
        txAppLog.notice("TransportApp init pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public)")
    }

    @AppExtensionPoint.Bind
    static var boundExtensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier("com.apple.accessory-transport-extension")
    }

    func accept(
        sessionRequest req: AccessoryTransportSession.Request
    ) -> AccessoryTransportSession.Request.Decision {
        let restoreID = req.session.transportStateRestoreIdentifier ?? "nil"
        let transport = String(describing: req.session.transport)
        txAppLog.notice("accept sessionRequest restoreID=\(restoreID, privacy: .public) transport=\(transport, privacy: .public)")
        return req.accept {
            txAppLog.notice("sessionRequestHandler factory called — creating TransportEventHandler")
            return TransportEventHandler(session: req.session)
        }
    }
}
