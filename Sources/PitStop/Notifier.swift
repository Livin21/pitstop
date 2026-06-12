import Foundation
import UserNotifications

/// Posts user notifications when running as a proper .app bundle; no-ops when
/// running as a bare binary (UNUserNotificationCenter requires a bundle).
final class Notifier {
    static let shared = Notifier()

    private var authRequested = false
    private var available: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    func post(title: String, body: String) {
        guard available else {
            NSLog("PitStop: %@ — %@", title, body)
            return
        }
        let center = UNUserNotificationCenter.current()
        let send = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content, trigger: nil)
            center.add(request)
        }
        if authRequested {
            send()
        } else {
            authRequested = true
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                if granted { send() }
            }
        }
    }
}
