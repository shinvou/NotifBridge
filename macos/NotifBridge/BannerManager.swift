import AppKit
import UserNotifications
import Intents
import CryptoKit
import os

/// Native macOS presentation. The history UI continues to own command status.
@MainActor
final class BannerManager: NSObject, UNUserNotificationCenterDelegate {
    enum BannerCommand {
        case dismissLocally(NotifFrame), clearOnIPhone(NotifFrame), retry(NotifFrame)
        case actionInvoked(NotifFrame, NotifFrame.Action, userText: String?)
    }
    static let clearAction = "notifbridge.clear-on-iphone"
    static let openHistory = Notification.Name("NotifBridgeOpenHistory")
    var onCommand: ((BannerCommand) -> Void)?
    var onError: ((String) -> Void)?
    var resolveNotification: ((String) -> NotifFrame?)?
    var soundEnabled = true
    private let center = UNUserNotificationCenter.current()
    private var categories: [String: UNNotificationCategory] = [:]
    private var versions: [String: UUID] = [:]
    private var submissionTask: Task<Void, Never>?
    private var presentations: [String: (Bool) -> Void] = [:]
    private let log = Logger(subsystem: "com.shinvou.NotifBridge.Mac", category: "native-notifications")

    override init() {
        super.init()
        center.delegate = self
    }

    static func actionID(_ action: NotifFrame.Action) -> String {
        "notifbridge.action." + Data(action.id.utf8).base64EncodedString()
    }
    static func category(for frame: NotifFrame) -> UNNotificationCategory {
        var actions: [UNNotificationAction] = [UNNotificationAction(
            identifier: clearAction, title: "Clear on iPhone", options: [])]
        if frame.transportSessionID == nil { actions = [] }
        // Keep reply among the first two actions visible in compact banners.
        let supported = (frame.transportSessionID == nil ? [] : frame.actions).filter { if case .unknown = $0.type { return false }; return true }
        let ordered = supported.filter { if case .textInput = $0.type { return true }; return false }
            + supported.filter { if case .textInput = $0.type { return false }; return true }
        var seen: Set<String> = []
        for action in ordered where seen.insert(action.id).inserted {
            guard actions.count < 4 else { break }
            let title = action.title.isEmpty ? "Action" : action.title
            if case .textInput(let placeholder) = action.type {
                actions.append(UNTextInputNotificationAction(identifier: actionID(action), title: title,
                    options: [], textInputButtonTitle: "Send", textInputPlaceholder: placeholder))
            } else {
                actions.append(UNNotificationAction(identifier: actionID(action), title: title, options: []))
            }
        }
        let signature = actions.map { "\($0.identifier):\($0.title):\(($0 as? UNTextInputNotificationAction)?.textInputPlaceholder ?? "")" }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(signature.utf8)).map { String(format: "%02x", $0) }.joined()
        return UNNotificationCategory(identifier: "notifbridge." + digest, actions: actions,
            intentIdentifiers: [], options: [.customDismissAction])
    }
    static func command(for actionID: String, text: String?, frame: NotifFrame) -> BannerCommand? {
        if actionID == UNNotificationDismissActionIdentifier { return .dismissLocally(frame) }
        guard frame.transportSessionID != nil else { return nil }
        if actionID == clearAction { return .clearOnIPhone(frame) }
        guard let action = frame.actions.first(where: { Self.actionID($0) == actionID }) else { return nil }
        if case .unknown = action.type { return nil }
        if case .textInput = action.type {
            guard let text else { return nil }
            return .actionInvoked(frame, action, userText: text)
        }
        return .actionInvoked(frame, action, userText: nil)
    }

    func present(_ frame: NotifFrame, status: ReceiverModel.ActionStatus, completion: @escaping (Bool) -> Void = { _ in }) {
        let token = UUID()
        versions[frame.id] = token
        presentations.removeValue(forKey: frame.id)?(false)
        presentations[frame.id] = completion
        let previousSubmission = submissionTask
        submissionTask = Task {
            await previousSubmission?.value
            guard versions[frame.id] == token else { return }
            do {
                let authorized = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                guard versions[frame.id] == token else { return }
                guard authorized else {
                    onError?("Mac notifications are disabled. Enable NotifBridge in System Settings → Notifications.")
                    finishPresentation(frame.id, alerted: false)
                    return
                }
                let category = Self.category(for: frame)
                categories[category.identifier] = category
                // Include categories belonging to notifications still in Notification Center,
                // including those posted before the app restarted.
                let existing = await center.notificationCategories()
                guard versions[frame.id] == token else { return }
                center.setNotificationCategories(existing.union(Set(categories.values)))
                let content = await self.content(for: frame)
                guard versions[frame.id] == token else { return }
                try await center.add(UNNotificationRequest(identifier: frame.id, content: content, trigger: nil))
                if versions[frame.id] != token {
                    if versions[frame.id] == nil { center.removeDeliveredNotifications(withIdentifiers: [frame.id]) }
                    return
                }
                log.notice("native notification submitted source=\(frame.sourceIdentifier, privacy: .public)")
                // Only willPresent proves that we requested an on-screen alert.
                // Background submission alone cannot prove macOS displayed a banner.
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    if versions[frame.id] == token {
                        let delivered = await center.deliveredNotifications().contains { $0.request.identifier == frame.id }
                        log.notice("native notification retained=\(delivered, privacy: .public) source=\(frame.sourceIdentifier, privacy: .public)")
                        finishPresentation(frame.id, alerted: false)
                    }
                }
            } catch {
                guard versions[frame.id] == token else { return }
                onError?("Could not post a Mac notification: \(error.localizedDescription)")
                finishPresentation(frame.id, alerted: false)
            }
        }
    }
    static func communicationIntent(for frame: NotifFrame) -> INSendMessageIntent? {
        guard !frame.sourceIcon.isEmpty, NSImage(data: frame.sourceIcon) != nil else { return nil }
        let name = frame.sourceName.isEmpty ? frame.title : "\(frame.sourceName): \(frame.title)"
        let sender = INPerson(personHandle: INPersonHandle(value: frame.sourceIdentifier, type: .unknown),
            nameComponents: nil, displayName: name, image: INImage(imageData: frame.sourceIcon),
            contactIdentifier: nil, customIdentifier: frame.sourceIdentifier)
        return INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText,
            content: frame.body, speakableGroupName: nil, conversationIdentifier: frame.groupID,
            serviceName: frame.sourceName, sender: sender, attachments: nil)
    }

    private func content(for frame: NotifFrame) async -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = frame.sourceName.isEmpty ? frame.title : "\(frame.sourceName): \(frame.title)"
        content.subtitle = frame.subtitle
        content.body = frame.body
        content.threadIdentifier = frame.groupID
        content.categoryIdentifier = Self.category(for: frame).identifier
        content.userInfo = ["notificationID": frame.id]
        if soundEnabled { content.sound = .default }
        guard let intent = Self.communicationIntent(for: frame) else { return content }
        do {
            let interaction = INInteraction(intent: intent, response: nil)
            interaction.direction = .incoming
            try await interaction.donate()
            // Return Apple's decorated content unchanged to preserve its avatar metadata.
            let decorated = try content.updating(from: intent)
            log.notice("Source icon applied source=\(frame.sourceIdentifier, privacy: .public)")
            return decorated
        } catch {
            log.error("Source icon decoration failed; using standard notification: \(error.localizedDescription, privacy: .public)")
            return content
        }
    }
    private func finishPresentation(_ id: String, alerted: Bool) {
        presentations.removeValue(forKey: id)?(alerted)
    }
    func update(_ frame: NotifFrame, status: ReceiverModel.ActionStatus) {
        // History owns live content/status. Reposting here would re-alert on every
        // update or resurrect a notification the user dismissed with X.
    }
    func dismiss(id: String) {
        versions.removeValue(forKey: id)
        finishPresentation(id, alerted: false)
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }
    func dismissAll() {
        for id in Array(versions.keys) { dismiss(id: id) }
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let id = notification.request.identifier
        let listOnly = notification.request.content.userInfo["listOnly"] as? Bool == true
        completionHandler(listOnly ? [.list] : [.banner, .list, .sound])
        Task { @MainActor in self.finishPresentation(id, alerted: !listOnly) }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["notificationID"] as? String
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        completionHandler()
        Task { @MainActor in
            if action == UNNotificationDefaultActionIdentifier {
                NotificationCenter.default.post(name: Self.openHistory, object: nil)
                NSApp.activate()
                return
            }
            guard let id, let frame = self.resolveNotification?(id), !frame.isCleared else { return }
            guard let command = Self.command(for: action, text: text, frame: frame) else { return }
            // Keep the native notification dismissed while history tracks the
            // phone's confirmation or failure. Also cancel in-flight presentation.
            if action == Self.clearAction { self.dismiss(id: id) }
            self.onCommand?(command)
        }
    }
}
