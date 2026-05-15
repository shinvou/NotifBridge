import Foundation
import AccessoryNotifications
import AccessoryTransportExtension
import os

private let dpLog = Logger(subsystem: "com.shinvou.NotifBridge", category: "dp-ext")
private func L(_ msg: String) {
    dpLog.notice("\(msg, privacy: .public)")
}

final class NotificationHandler: NotificationsForwarding.AccessoryNotificationsHandler {
    private let state = OSAllocatedUnfairLock<State>(initialState: .init())
    private struct State { var session: NotificationsForwarding.Session? }

    init() {
        L("NotificationHandler init")
    }

    func didActivate(for session: NotificationsForwarding.Session) {
        L("didActivate session=\(String(describing: session))")
        state.withLock { $0.session = session }
    }

    func didInvalidate() {
        L("didInvalidate")
        state.withLock { $0.session = nil }
    }

    func addNotification(
        _ notification: AccessoryNotification,
        alertingContext ctx: AlertingContext
    ) async throws -> Bool {
        L("addNotification id=\(notification.identifier.notificationIdentifier) src=\(notification.identifier.sourceIdentifier) name=\(notification.sourceName) shouldAlert=\(ctx.shouldAlert) kind=\(ctx.kind)")

        // session.send is the only path that triggers TransportApp.messageReceived.
        // Returning true alone does NOT cause the framework to forward.
        if let session = state.withLock(\.session) {
            let payload = encode(notification, ctx: ctx)
            let message = AccessoryMessage {
                AccessoryMessage.Payload(transport: .bluetooth, data: payload)
            }
            try await session.send(message: message)
            L("  session.send \(payload.count) bytes OK")
        } else {
            L("  ERROR: session nil — notification dropped")
        }
        return true
    }

    func updateNotification(_ n: AccessoryNotification) {
        L("updateNotification id=\(n.identifier.notificationIdentifier)")
        Task { [data = encode(n, ctx: nil)] in try? await sendFrame(data) }
    }

    func removeNotification(identifier: AccessoryNotification.Identifier) {
        L("removeNotification id=\(identifier.notificationIdentifier)")
        var d = Data([0x03])
        d.append(idBytes(identifier))
        Task { [data = d] in try? await sendFrame(data) }
    }

    func removeAllNotifications() {
        L("removeAllNotifications")
        Task { try? await sendFrame(Data([0x04])) }
    }

    func messageHandler(_ message: TransportMessage) {
        L("messageHandler inbound \(message.data.count) bytes session=\(message.sessionID)")
    }

    // [kind:1][titleLen:2][title][bodyLen:2][body][srcLen:1][source][idLen:1][id][hasSound:1]

    private func encode(_ n: AccessoryNotification, ctx: AlertingContext?) -> Data {
        var d = Data()
        d.append(0x01)
        appendLP16(&d, n.title ?? "")
        appendLP16(&d, n.body?.string ?? "")
        appendLP8(&d, n.sourceName)
        let id = idBytes(n.identifier)
        appendLP8(&d, String(decoding: id, as: UTF8.self))
        d.append(ctx?.sound == nil ? 0x00 : 0x01)
        return d
    }

    private func sendFrame(_ data: Data) async throws {
        let msg = AccessoryMessage {
            AccessoryMessage.Payload(transport: .bluetooth, data: data)
        }
        try await state.withLock(\.session)?.send(message: msg)
    }

    private func appendLP16(_ d: inout Data, _ s: String) {
        let bytes = Array(s.utf8.prefix(0xFFFF))
        var len = UInt16(bytes.count).bigEndian
        withUnsafeBytes(of: &len) { d.append(contentsOf: $0) }
        d.append(contentsOf: bytes)
    }

    private func appendLP8(_ d: inout Data, _ s: String) {
        let bytes = Array(s.utf8.prefix(0xFF))
        d.append(UInt8(bytes.count))
        d.append(contentsOf: bytes)
    }

    private func idBytes(_ id: AccessoryNotification.Identifier) -> Data {
        let joined = "\(id.sourceIdentifier)|\(id.notificationIdentifier)"
        return Data(joined.utf8.prefix(32))
    }
}
