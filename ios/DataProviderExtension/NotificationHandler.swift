import Foundation
@preconcurrency import AccessoryNotifications
import AccessoryTransportExtension
import UniformTypeIdentifiers
import UIKit
import os

private let dpLog = Logger(subsystem: "com.shinvou.NotifBridge", category: "dp-ext")

final class NotificationHandler: NotificationsForwarding.AccessoryNotificationsHandler {
    private let state = OSAllocatedUnfairLock<State>(initialState: .init())
    private struct State {
        var session: NotificationsForwarding.Session?
        var receipts: [UUID: CheckedContinuation<Bool, Never>] = [:]
        var executing: Set<UUID> = []
        var results: [UUID: NotifWire.CommandResult] = [:]
        var resultOrder: [UUID] = []
    }
    private enum Failure: Error { case sessionUnavailable }

    func didActivate(for session: NotificationsForwarding.Session) {
        state.withLock { $0.session = session }
        dpLog.notice("DataProvider activated")
    }
    func didInvalidate() {
        let waiters = state.withLock { state in
            state.session = nil
            let waiters = Array(state.receipts.values)
            state.receipts.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume(returning: false) }
    }

    func addNotification(_ notification: AccessoryNotification, alertingContext ctx: AlertingContext) async throws -> Bool {
        dpLog.notice("addNotification entered source=\(notification.identifier.sourceIdentifier, privacy: .public)")
        let timestamp = Date.now
        let frame = await curate(notification, context: ctx)
        dpLog.notice("addNotification curation complete")
        let event = NotifWire.Event(kind: .add, notification: frame, sentAt: timestamp)
        // The Boolean means the Mac actually alerted, not merely that BLE accepted bytes.
        return await withCheckedContinuation { continuation in
            state.withLock { $0.receipts[event.id] = continuation }
            Task {
                do { try await send(event) }
                catch {
                    dpLog.error("notification transport failed: \(error.localizedDescription, privacy: .public)")
                    resolveReceipt(event.id, alerted: false)
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(60))
                resolveReceipt(event.id, alerted: false)
            }
        }
    }
    func updateNotification(_ notification: AccessoryNotification) {
        let timestamp = Date.now
        Task {
            let frame = await curate(notification, context: nil)
            await sendLogged(.init(kind: .update, notification: frame, sentAt: timestamp))
        }
    }
    func removeNotification(identifier: AccessoryNotification.Identifier) {
        let event = NotifWire.Event(kind: .remove, identity: .init(
            sourceIdentifier: identifier.sourceIdentifier,
            notificationIdentifier: identifier.notificationIdentifier))
        Task { await sendLogged(event) }
    }
    func removeAllNotifications() {
        let event = NotifWire.Event(kind: .removeAll)
        Task { await sendLogged(event) }
    }
    func messageHandler(_ message: TransportMessage) {
        guard message.data.count <= NotifWire.maxFrameBytes,
              let command = try? JSONDecoder().decode(NotifWire.Command.self, from: message.data),
              command.version == 3, !command.identity.sourceIdentifier.isEmpty,
              !command.identity.notificationIdentifier.isEmpty else {
            dpLog.error("Rejected invalid reverse command")
            return
        }
        if command.kind == .displayed {
            if let eventID = command.replyTo, let alerted = command.didAlert { resolveReceipt(eventID, alerted: alerted) }
            return
        }
        let cached = state.withLock { $0.results[command.id] }
        if let cached {
            Task { await sendLogged(.init(kind: .commandResult, result: cached)) }
            return
        }
        guard state.withLock({ $0.executing.insert(command.id).inserted }) else { return }
        Task {
            let result: NotifWire.CommandResult
            do {
                guard let session = state.withLock(\.session) else { throw Failure.sessionUnavailable }
                switch command.kind {
                case .clear:
                    try await session.removeNotifications(identifiers: [.init(
                        notificationIdentifier: command.identity.notificationIdentifier,
                        sourceIdentifier: command.identity.sourceIdentifier)])
                    dpLog.notice("session.removeNotifications OK")
                case .respond:
                    guard let action = command.actionIdentifier, !action.isEmpty else { throw NotifWire.WireError.invalidMessage }
                    try await session.sendResponse(.init(sourceIdentifier: command.identity.sourceIdentifier,
                        notificationIdentifier: command.identity.notificationIdentifier,
                        actionIdentifier: action, userText: command.userText))
                    dpLog.notice("session.sendResponse OK")
                case .displayed: return
                }
                result = .init(commandID: command.id, success: true,
                    message: command.kind == .clear ? "Cleared on iPhone" : "Response accepted by iPhone")
            } catch {
                dpLog.error("notification command failed: \(error.localizedDescription, privacy: .public)")
                result = .init(commandID: command.id, success: false, message: error.localizedDescription)
            }
            state.withLock { state in
                state.executing.remove(command.id)
                state.results[command.id] = result
                state.resultOrder.append(command.id)
                if state.resultOrder.count > 128 { state.results.removeValue(forKey: state.resultOrder.removeFirst()) }
            }
            await sendLogged(.init(kind: .commandResult, result: result))
        }
    }

    private func resolveReceipt(_ id: UUID, alerted: Bool) {
        state.withLock { $0.receipts.removeValue(forKey: id) }?.resume(returning: alerted)
    }
    private func send(_ event: NotifWire.Event) async throws {
        guard let session = state.withLock(\.session) else { throw Failure.sessionUnavailable }
        let data = try NotifWire.encodeEvent(event)
        dpLog.notice("sending event kind=\(event.kind.rawValue, privacy: .public) bytes=\(data.count, privacy: .public)")
        try await session.send(message: AccessoryMessage {
            AccessoryMessage.Payload(transport: .bluetooth, data: data)
        })
        dpLog.notice("event send completed")
    }
    private func sendLogged(_ event: NotifWire.Event) async {
        do { try await send(event) }
        catch { dpLog.error("event send failed: \(error.localizedDescription, privacy: .public)") }
    }

    private func curate(_ n: AccessoryNotification, context: AlertingContext?) async -> NotifWire.Notification {
        var frame = NotifWire.Notification(title: n.title ?? "", subtitle: n.subtitle ?? "",
            body: n.body?.string ?? "", sourceName: n.sourceName,
            sourceIdentifier: n.identifier.sourceIdentifier, notificationIdentifier: n.identifier.notificationIdentifier,
            threadIdentifier: n.threadIdentifier ?? "")
        dpLog.notice("curation: text copied")
        frame.deliveryDate = n.deliveryDate
        switch n.displayDate {
        case .deliveryDate: frame.displayDate = n.deliveryDate
        case .contentDate(let date): frame.displayDate = date
        case .allDayDate(let date): frame.displayDate = date; frame.displayDateIsAllDay = true
        case .hideDate: frame.displayDate = nil
        @unknown default: frame.displayDate = n.deliveryDate
        }
        frame.summary = n.summary?.string ?? ""
        dpLog.notice("curation: serializing rich body")
        if let body = n.body, let rich = try? body.data(from: NSRange(location: 0, length: body.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]), rich.count <= 512 * 1024 {
            frame.richBody = rich
        }
        dpLog.notice("curation: rich body ready")
        frame.shouldAlert = context?.shouldAlert ?? false
        frame.isSuppressedByFocus = context?.isSuppressedByFocus ?? false
        frame.hasSound = context?.sound != nil
        frame.ignoreSilentMode = context?.sound?.shouldIgnoreSilentMode ?? false
        switch context?.kind {
        case .incomingCall: frame.alertKind = .incomingCall
        case .alarm: frame.alertKind = .alarm
        case .timer: frame.alertKind = .timer
        default: frame.alertKind = .notification
        }
        if n.attributes.contains(.critical) { frame.attributes.insert(.critical) }
        if n.attributes.contains(.timeSensitive) { frame.attributes.insert(.timeSensitive) }
        if n.attributes.contains(.priority) { frame.attributes.insert(.priority) }
        frame.actions = n.actions.prefix(64).map { action in
            let type: NotifWire.Notification.ActionType
            switch action.type {
            case .background: type = .background
            case .dismiss: type = .dismiss
            case .textInput(let placeholder): type = .textInput(placeholder: placeholder)
            @unknown default: type = .unknown(255)
            }
            return .init(id: action.identifier, title: action.title ?? "", type: type)
        }
        dpLog.notice("curation: loading artwork")
        async let sourceIcon = readFile(n.sourceIcon)
        async let contextIcon = readFile(n.contextIcon)
        let media = await withTaskGroup(of: (Int, String, Data).self) { group in
            for (index, attachment) in n.attachments.prefix(16).enumerated() {
                group.addTask { (index, attachment.type.identifier, await self.readFile(attachment)) }
            }
            var results: [(Int, String, Data)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }
        }
        frame.sourceIcon = iconData(await sourceIcon)
        frame.contextIcon = iconData(await contextIcon)
        var remaining = 1024 * 1024
        for (_, uti, bytes) in media {
            guard !bytes.isEmpty, bytes.count <= remaining else {
                frame.attachments.append(.init(uti: uti, data: Data(),
                    unavailableReason: "Attachment unavailable or exceeds the Bluetooth transfer limit. Open it on iPhone."))
                continue
            }
            remaining -= bytes.count
            frame.attachments.append(.init(uti: uti, data: bytes))
        }
        dpLog.notice("curation: artwork ready")
        return frame
    }

    // Mac banners display icons at 30 points. Bound them to Retina resolution
    // instead of sending full-size app artwork with every notification.
    private func iconData(_ data: Data) -> Data {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return data }
        let ratio = min(1, 64 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        let encoded = resized.pngData() ?? data
        return encoded.count < data.count ? encoded : data
    }

    /// Race without a task-group scope that waits forever for a stalled File.url.
    private func readFile(_ file: AccessoryNotification.File?) async -> Data {
        guard let file else { return Data() }
        return await withCheckedContinuation { continuation in
            let gate = FileResult(continuation)
            Task {
                do {
                    let url = try await file.url
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                    guard size <= 256 * 1024 else { gate.finish(Data()); return }
                    gate.finish(try Data(contentsOf: url))
                } catch { gate.finish(Data()) }
            }
            Task {
                try? await Task.sleep(for: .seconds(2))
                gate.finish(Data())
            }
        }
    }
    private final class FileResult: @unchecked Sendable {
        private let continuation: OSAllocatedUnfairLock<CheckedContinuation<Data, Never>?>
        init(_ continuation: CheckedContinuation<Data, Never>) { self.continuation = .init(initialState: continuation) }
        func finish(_ data: Data) {
            let next = continuation.withLock { value in let result = value; value = nil; return result }
            next?.resume(returning: data)
        }
    }
}
