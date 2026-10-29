import Foundation
import UserNotifications
import UsageTrackerCore

enum NotificationService {
    static func requestPermission() async -> Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    static func send(alert: AppAlert) {
        guard Bundle.main.bundleIdentifier != nil else {
            fallback(title: alert.title, body: alert.message)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.message
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: alert.id.uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if error != nil {
                fallback(title: alert.title, body: alert.message)
            }
        }
    }

    private static func fallback(title: String, body: String) {
        let script = "display notification \"\(escape(body))\" with title \"\(escape(title))\""
        _ = try? ProcessRunner.run("/usr/bin/osascript", ["-e", script])
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
