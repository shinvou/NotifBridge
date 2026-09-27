import Foundation
import ServiceManagement
import os

/// Toggles the main-app launch-at-login registration via `SMAppService`.
///
/// `SMAppService.mainApp` registers the running .app bundle as a login item.
/// Status `.enabled` means it'll launch at next login. `.requiresApproval` means
/// macOS is gating in Settings → General → Login Items — user must approve.
/// State is per-bundle, so dev builds and Release builds register independently.
@MainActor
@Observable
final class LaunchAtLogin {
    private let log = Logger(subsystem: "com.shinvou.NotifBridge.Mac", category: "launch-at-login")
    private let service = SMAppService.mainApp

    var status: SMAppService.Status { service.status }

    var isEnabled: Bool {
        service.status == .enabled
    }

    var statusDescription: String {
        switch service.status {
        case .notRegistered:    "not enabled"
        case .enabled:          "launches at login"
        case .requiresApproval: "approval needed in Settings → General → Login Items"
        case .notFound:         "app bundle not found (run from /Applications)"
        @unknown default:       "unknown (\(service.status.rawValue))"
        }
    }

    func setEnabled(_ on: Bool) {
        do {
            if on {
                try service.register()
                log.notice("registered — status=\(self.statusDescription, privacy: .public)")
            } else {
                try service.unregister()
                log.notice("unregistered — status=\(self.statusDescription, privacy: .public)")
            }
        } catch {
            log.error("toggle failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
