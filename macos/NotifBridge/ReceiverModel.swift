import Foundation
import Observation
import AppKit
import os

private let modelLog = Logger(subsystem: "com.shinvou.NotifBridge.Mac", category: "receiver-model")

@Observable @MainActor
final class ReceiverModel {
    @Observable @MainActor final class ActionStatus {
        enum Phase { case idle, pending, succeeded, failed }
        var phase: Phase = .idle
        var message = ""
        var requestID: UUID?
        var attemptID: UUID?
        var retryMayRepeat = false
        var isEditing = false
        var protectsBanner: Bool { phase == .pending || phase == .failed || isEditing }
    }
    var bluetoothReady = false
    var statusLine = "starting…"
    var hpkeReady = false
    var keyInfo = ""
    var lastError: String?
    private var lastBridgeError: String?
    var ledger = NotifWire.Ledger()
    var showQuietNotifications = UserDefaults.standard.object(forKey: "showQuietNotifications") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showQuietNotifications, forKey: "showQuietNotifications") }
    }
    var soundEnabled = UserDefaults.standard.object(forKey: "notificationSounds") as? Bool ?? true {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: "notificationSounds") }
    }
    var mutedApps = Set(UserDefaults.standard.stringArray(forKey: "mutedNotificationApps") ?? []) {
        didSet { UserDefaults.standard.set(Array(mutedApps), forKey: "mutedNotificationApps") }
    }
    var received: [NotifFrame] { ledger.notifications }
    private var statuses: [String: ActionStatus] = [:]
    private struct Request {
        var command: NotifWire.Command
        var notification: NotifFrame
    }
    private var requests: [UUID: Request] = [:]
    private var lastRequests: [String: Request] = [:]
    private var testedNotifications: Set<String> = []
    private var displayReceipts: [UUID: Bool] = [:]
    private var saveTask: Task<Void, Never>?
    private let bridge = ESP32Bridge()
    private let banners = BannerManager()
    private static let historyKey = "notificationHistoryV3"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.historyKey),
           let saved = try? JSONDecoder().decode(NotifWire.Ledger.self, from: data) { ledger = saved }
        for item in received { statuses[item.id] = ActionStatus() }
        bridge.onState = { [weak self] line, ready in self?.statusLine = line; self?.bluetoothReady = ready }
        bridge.onKeyInfo = { [weak self] info in self?.keyInfo = info; self?.hpkeReady = !info.isEmpty }
        bridge.onEvent = { [weak self] event, session in self?.receive(event, sessionID: session) }
        bridge.onError = { [weak self] error in
            self?.lastBridgeError = error
            self?.lastError = error
        }
        banners.resolveNotification = { [weak self] id in self?.received.first { $0.id == id } }
        banners.onError = { [weak self] error in self?.lastError = error }
        banners.onCommand = { [weak self] command in self?.handle(command) }
        bridge.start()
    }
    func status(for notification: NotifFrame) -> ActionStatus { statuses[notification.id] ?? ActionStatus() }
    func toggleMute(_ source: String) {
        if mutedApps.contains(source) { mutedApps.remove(source) } else { mutedApps.insert(source) }
    }
    func eraseLocalHistory() {
        banners.dismissAll()
        ledger = .init()
        statuses.removeAll()
        lastRequests.removeAll()
        requests.removeAll()
        saveTask?.cancel()
        UserDefaults.standard.removeObject(forKey: Self.historyKey)
    }
    private func saveHistory() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self else { return }
            do { UserDefaults.standard.set(try JSONEncoder().encode(ledger), forKey: Self.historyKey) }
            catch { lastError = "Could not save notification history: \(error.localizedDescription)" }
        }
    }
    private func receive(_ incoming: NotifWire.Event, sessionID: String) {
        if let lastBridgeError, lastError == lastBridgeError { lastError = nil }
        lastBridgeError = nil
        var event = incoming
        event.notification?.transportSessionID = sessionID
        if let result = event.result, event.kind == .commandResult { finish(result, sentAt: event.sentAt); return }
        let change = ledger.apply(event, alertQuietNotifications: showQuietNotifications)
        for id in change.removedIDs { banners.dismiss(id: id) }
        if let frame = change.notification {
            if statuses[frame.id] == nil { statuses[frame.id] = ActionStatus() }
            let allowed = change.shouldAlert && !mutedApps.contains(frame.sourceIdentifier)
            if allowed {
                banners.soundEnabled = soundEnabled
                banners.present(frame, status: status(for: frame)) { [weak self] displayed in
                    guard let self, received.contains(where: { $0.id == frame.id && !$0.isCleared }) else { return }
                    if event.kind == .add { acknowledgeDisplay(event, frame: frame, alerted: displayed) }
                }
            } else {
                banners.update(frame, status: status(for: frame))
                if event.kind == .add { acknowledgeDisplay(event, frame: frame, alerted: false) }
            }
            runClearTestIfRequested(frame)
        } else if event.kind == .add, let frame = event.notification {
            acknowledgeDisplay(event, frame: frame, alerted: displayReceipts[event.id] ?? false)
        }
        let retainedIDs = Set(received.map(\.id))
        statuses = statuses.filter { retainedIDs.contains($0.key) }
        lastRequests = lastRequests.filter { retainedIDs.contains($0.key) }
        requests = requests.filter { retainedIDs.contains($0.value.notification.id) }
        saveHistory()
    }
    private func acknowledgeDisplay(_ event: NotifWire.Event, frame: NotifFrame, alerted: Bool) {
        displayReceipts[event.id] = alerted
        if displayReceipts.count > 128 { displayReceipts.removeAll(keepingCapacity: true); displayReceipts[event.id] = alerted }
        let command = NotifWire.Command(kind: .displayed, identity: frame.identity, replyTo: event.id, didAlert: alerted)
        do { try bridge.sendReverseCommand(JSONEncoder().encode(command), sessionID: frame.transportSessionID) }
        catch { lastError = "Could not confirm notification receipt: \(error.localizedDescription)" }
    }
    func handle(_ command: BannerManager.BannerCommand) {
        switch command {
        case .dismissLocally(let frame): banners.dismiss(id: frame.id)
        case .clearOnIPhone(let frame): submit(.init(kind: .clear, identity: frame.identity), for: frame)
        case .actionInvoked(let frame, let action, let text):
            if case .unknown = action.type { return }
            submit(.init(kind: .respond, identity: frame.identity, actionIdentifier: action.id, userText: text), for: frame)
        case .retry(let frame):
            guard let request = lastRequests[frame.id] else { return }
            submit(request.command, for: request.notification)
        }
    }
    private func submit(_ command: NotifWire.Command, for frame: NotifFrame) {
        if statuses[frame.id] == nil { statuses[frame.id] = ActionStatus() }
        let status = status(for: frame)
        guard status.phase != .pending else { return }
        let request = Request(command: command, notification: frame)
        lastRequests[frame.id] = request
        requests[command.id] = request
        let attemptID = UUID()
        status.attemptID = attemptID
        status.requestID = command.id
        status.phase = .pending
        status.retryMayRepeat = false
        status.message = command.kind == .clear ? "Clearing on iPhone…" : "Sending to iPhone…"
        do { try bridge.sendReverseCommand(JSONEncoder().encode(command), sessionID: frame.transportSessionID) }
        catch {
            status.phase = .failed
            status.message = error.localizedDescription
            lastError = status.message
            return
        }
        Task { [weak self, weak status] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, let status, status.requestID == command.id, status.attemptID == attemptID, status.phase == .pending else { return }
            status.phase = .failed
            status.retryMayRepeat = command.kind == .respond
            status.message = "No confirmation from iPhone. Check the phone before retrying."
            self.lastError = status.message
        }
    }
    private func finish(_ result: NotifWire.CommandResult, sentAt: Date) {
        guard let request = requests.removeValue(forKey: result.commandID),
              let status = statuses[request.notification.id], status.requestID == result.commandID else { return }
        if lastError == status.message { lastError = nil }
        status.phase = result.success ? .succeeded : .failed
        status.retryMayRepeat = false
        status.message = result.message
        modelLog.notice("command result success=\(result.success, privacy: .public)")
        if request.command.kind == .clear,
           request.notification.sourceIdentifier == "com.shinvou.NotifBridge",
           ProcessInfo.processInfo.arguments.contains("--clear-test-notif-body=\(request.notification.body)") {
            modelLog.notice("TEST-E2E clear result success=\(result.success, privacy: .public)")
        }
        if result.success {
            lastRequests.removeValue(forKey: request.notification.id)
            if request.command.kind == .clear {
                _ = ledger.apply(.init(kind: .remove, identity: request.command.identity, sentAt: sentAt))
                saveHistory()
            }
            banners.dismiss(id: request.notification.id)
        } else {
            lastError = result.message
            // The phone caches command results. A confirmed failure can safely start a new request.
            var retry = request
            retry.command.id = UUID()
            lastRequests[request.notification.id] = retry
        }
    }
    private func runClearTestIfRequested(_ frame: NotifFrame) {
        let arguments = ProcessInfo.processInfo.arguments
        let prefix = arguments.contains { $0.hasPrefix("--clear-test-notif-body=") }
            ? "--clear-test-notif-body=" : "--test-notif-body="
        let body = arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        guard frame.sourceIdentifier == "com.shinvou.NotifBridge", frame.body == body,
              testedNotifications.insert(frame.id).inserted else { return }
        modelLog.notice("TEST-E2E received matching test notification")
        guard prefix == "--clear-test-notif-body=" else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.handle(.clearOnIPhone(frame))
        }
    }
    func presentTestBanner() {
        let frame = NotifFrame(title: "Test banner", subtitle: "Local preview", body: "A preview of the notification display. This is not an iPhone notification.",
            sourceName: "NotifBridge", sourceIdentifier: "com.shinvou.NotifBridge.Mac",
            notificationIdentifier: UUID().uuidString, attributes: [.timeSensitive])
        _ = ledger.apply(.init(kind: .add, notification: frame))
        statuses[frame.id] = ActionStatus()
        banners.present(frame, status: status(for: frame))
        saveHistory()
    }
}
