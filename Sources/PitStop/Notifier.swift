import Foundation
import UserNotifications

/// Posts user notifications when running as a proper .app bundle; no-ops when
/// running as a bare binary (UNUserNotificationCenter requires a bundle).
@MainActor
final class Notifier {
    static let shared = Notifier()

    private enum AuthState { case unknown, requesting, granted, denied }
    private var authState: AuthState = .unknown
    /// Notifications that arrived while the authorization request was in
    /// flight — flushed (or dropped) once the user answers.
    private var pending: [UNNotificationRequest] = []

    private var available: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    func post(title: String, body: String) {
        guard available else {
            NSLog("PitStop: %@ — %@", title, body)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        switch authState {
        case .granted:
            UNUserNotificationCenter.current().add(request)
        case .denied:
            break
        case .requesting:
            pending.append(request)
        case .unknown:
            authState = .requesting
            pending.append(request)
            UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    Task { @MainActor in
                        self.authState = granted ? .granted : .denied
                        if granted {
                            for request in self.pending {
                                try? await UNUserNotificationCenter.current().add(request)
                            }
                        }
                        self.pending.removeAll()
                    }
                }
        }
    }
}
