import AppKit
import UserNotifications

/// macOS notifications; clicking one focuses its session. Needs the .app bundle.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    var onSelect: ((Int64) -> Void)?
    private var enabled: Bool { Bundle.main.bundleIdentifier != nil && ProcessInfo.processInfo.environment["FENRIR_NO_NOTIFY"] == nil }

    func setup() {
        guard enabled else { return }
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String, sessionID: Int64) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["session": sessionID]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo["session"] as? NSNumber)?.int64Value
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let id { self.onSelect?(id) }
            done()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}
