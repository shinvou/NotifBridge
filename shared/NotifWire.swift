import Foundation

/// Cross-platform wire format for an iPhone → ESP32 → Mac notification frame.
/// `kind=0x02` denotes the rich format including subtitle, attributes, actions,
/// icons (source + context) and attachments. Older `kind=0x01` frames are not
/// produced anymore but the Mac decoder still tolerates them.
///
/// All multi-byte lengths are big-endian. String lengths are byte counts of
/// UTF-8. File / attachment data are raw bytes with a 4-byte length prefix.
enum NotifWire {
    static let kindRichV2: UInt8 = 0x02

    /// Reverse-channel command kinds (Mac → ESP32 → iPhone).
    static let cmdRemove: UInt8 = 0x10
    static let cmdRespond: UInt8 = 0x11

    /// `Attributes` bitmask layout.
    enum Attr: UInt8 {
        case critical      = 0x01
        case timeSensitive = 0x02
        case priority      = 0x04
    }

    /// `Action.ActionType` discriminator.
    enum ActionKind: UInt8 {
        case background = 0
        case textInput  = 1
        case dismiss    = 2
    }
}

extension NotifWire {
    static let maxFrameBytes = 4 * 1024 * 1024
    static let maxEnvelopeBytes = 8 * 1024 * 1024

    struct Identity: Codable, Hashable, Sendable {
        var sourceIdentifier: String
        var notificationIdentifier: String
        var key: String { "\(sourceIdentifier.utf8.count):\(sourceIdentifier)\(notificationIdentifier)" }
    }

    struct Notification: Identifiable, Codable, Equatable, Sendable {
        var title: String = ""
        var subtitle: String = ""
        var body: String = ""
        var sourceName: String = ""
        var sourceIdentifier: String = ""
        var notificationIdentifier: String = ""
        var threadIdentifier: String = ""
        var hasSound: Bool = false
        var attributes: Attributes = []
        var actions: [Action] = []
        var sourceIcon: Data = Data()
        var contextIcon: Data = Data()
        var attachments: [Attachment] = []
        var receivedAt: Date = .now
        var transportSessionID: String?
        var deliveryDate: Date = .now
        var displayDate: Date? = .now
        var displayDateIsAllDay = false
        var summary = ""
        var richBody: Data?
        var shouldAlert = true
        var isSuppressedByFocus = false
        var ignoreSilentMode = false
        var alertKind: AlertKind = .notification
        var isCleared = false
        var id: String { identity.key }
        var identity: Identity { .init(sourceIdentifier: sourceIdentifier, notificationIdentifier: notificationIdentifier) }
        var groupID: String { "\(sourceIdentifier.utf8.count):\(sourceIdentifier)\(threadIdentifier.isEmpty ? "notification:" + id : "thread:" + threadIdentifier)" }
        var needsPersistentBanner: Bool { alertKind != .notification || attributes.contains(.critical) }

        enum AlertKind: String, Codable, Sendable { case notification, incomingCall, alarm, timer }
        struct Attributes: OptionSet, Codable, Equatable, Sendable {
            let rawValue: UInt8
            static let critical = Self(rawValue: 1)
            static let timeSensitive = Self(rawValue: 2)
            static let priority = Self(rawValue: 4)
        }
        struct Action: Identifiable, Codable, Equatable, Sendable {
            var id: String
            var title: String
            var type: ActionType
        }
        enum ActionType: Codable, Equatable, Sendable {
            case background, textInput(placeholder: String), dismiss, unknown(UInt8)
        }
        struct Attachment: Identifiable, Codable, Equatable, Sendable {
            var id = UUID()
            var uti: String
            var data: Data
            var unavailableReason: String?
        }
    }

    struct Command: Codable, Equatable, Sendable {
        var version = 3
        var id = UUID()
        var kind: Kind
        var identity: Identity
        var actionIdentifier: String?
        var userText: String?
        var replyTo: UUID?
        var didAlert: Bool?
        enum Kind: String, Codable, Sendable { case clear, respond, displayed }
    }
    struct CommandResult: Codable, Equatable, Sendable {
        var commandID: UUID
        var success: Bool
        var message: String
    }
    struct Event: Codable, Equatable, Sendable {
        var version = 3
        var id = UUID()
        var kind: Kind
        var notification: Notification?
        var identity: Identity?
        var result: CommandResult?
        var sentAt: Date = .now
        enum Kind: String, Codable, Sendable { case add, update, remove, removeAll, commandResult }
    }
    enum WireError: Error { case invalidMessage, tooLarge }
    static func encodeEvent(_ event: Event) throws -> Data {
        let data = try JSONEncoder().encode(event)
        guard data.count <= maxFrameBytes else { throw WireError.tooLarge }
        return data
    }
    static func decodeEvent(_ data: Data) throws -> Event {
        guard data.count <= maxFrameBytes else { throw WireError.tooLarge }
        let event = try JSONDecoder().decode(Event.self, from: data)
        guard event.version == 3 else { throw WireError.invalidMessage }
        switch event.kind {
        case .add, .update:
            guard let n = event.notification, !n.sourceIdentifier.isEmpty,
                  !n.notificationIdentifier.isEmpty, n.actions.count <= 64,
                  n.attachments.count <= 16 else { throw WireError.invalidMessage }
        case .remove:
            guard let id = event.identity, !id.sourceIdentifier.isEmpty,
                  !id.notificationIdentifier.isEmpty else { throw WireError.invalidMessage }
        case .commandResult:
            guard event.result != nil else { throw WireError.invalidMessage }
        case .removeAll: break
        }
        return event
    }

    /// A bounded, persistent active/history store. Source IDs remain intact; revisions
    /// prevent delayed BLE deliveries from undoing a later update or removal.
    struct Ledger: Codable, Sendable {
        var notifications: [Notification] = []
        private var revisions: [String: Date] = [:]
        private var clearedAt: Date?
        struct Change {
            var notification: Notification?
            var shouldAlert = false
            var removedIDs: [String] = []
        }
        mutating func apply(_ event: Event, alertQuietNotifications: Bool = false) -> Change {
            switch event.kind {
            case .add, .update:
                guard var n = event.notification,
                      event.sentAt > (clearedAt ?? .distantPast),
                      event.sentAt > (revisions[n.id] ?? .distantPast) else { return Change() }
                let existing = notifications.firstIndex { $0.id == n.id }
                if let existing {
                    n.receivedAt = notifications[existing].receivedAt
                    if event.kind == .update {
                        n.alertKind = notifications[existing].alertKind
                        n.hasSound = notifications[existing].hasSound
                        n.ignoreSilentMode = notifications[existing].ignoreSilentMode
                        n.shouldAlert = notifications[existing].shouldAlert
                        n.isSuppressedByFocus = notifications[existing].isSuppressedByFocus
                    }
                }
                n.isCleared = false
                if let existing { notifications[existing] = n }
                else { notifications.insert(n, at: 0) }
                revisions[n.id] = event.sentAt
                trim()
                // Explicit Mac preference also covers previously unseen messages
                // recovered after an outage. Existing IDs still cannot re-alert.
                let quietAlert = alertQuietNotifications
                return Change(notification: n, shouldAlert: event.kind == .add && existing == nil
                    && (quietAlert || (n.shouldAlert && !n.isSuppressedByFocus)))
            case .remove:
                guard let id = event.identity?.key,
                      event.sentAt > (revisions[id] ?? .distantPast) else { return Change() }
                revisions[id] = event.sentAt
                if let i = notifications.firstIndex(where: { $0.id == id }) { notifications[i].isCleared = true }
                trim()
                return Change(removedIDs: [id])
            case .removeAll:
                guard event.sentAt > (clearedAt ?? .distantPast) else { return Change() }
                clearedAt = event.sentAt
                let ids = notifications.filter { (revisions[$0.id] ?? .distantPast) <= event.sentAt }.map(\.id)
                for i in notifications.indices where ids.contains(notifications[i].id) { notifications[i].isCleared = true }
                return Change(removedIDs: ids)
            case .commandResult: return Change()
            }
        }
        private mutating func trim() {
            // Retain the newest iPhone notifications even when replay or retries
            // deliver older items later. Break timestamp ties deterministically.
            notifications.sort {
                $0.deliveryDate == $1.deliveryDate ? $0.id < $1.id : $0.deliveryDate > $1.deliveryDate
            }
            // Include media in the byte budget; do not accumulate unbounded image history.
            var bytes = 0
            notifications = Array(notifications.prefix(100).prefix { n in
                bytes += n.sourceIcon.count + n.contextIcon.count + (n.richBody?.count ?? 0)
                    + n.attachments.reduce(0) { $0 + $1.data.count } + n.body.utf8.count + n.title.utf8.count + n.subtitle.utf8.count
                    + n.summary.utf8.count + n.sourceName.utf8.count + n.sourceIdentifier.utf8.count
                    + n.notificationIdentifier.utf8.count + n.threadIdentifier.utf8.count
                    + n.actions.reduce(0) { $0 + $1.id.utf8.count + $1.title.utf8.count }
                return bytes <= 8 * 1024 * 1024
            })
            if revisions.count > 200 { revisions = Dictionary(uniqueKeysWithValues: revisions.sorted { $0.value > $1.value }.prefix(200).map { ($0.key, $0.value) }) }
        }
    }
}
