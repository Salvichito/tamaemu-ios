import UserNotifications

/// Fires a local notification when the Tamagotchi needs attention.
/// Authorization is requested once, the first time the user actually has
/// something running (right after importing firmware) rather than at
/// cold launch before they've done anything.
enum NotificationScheduler {
    static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    static func fireCallingNotification(deviceTitle: String) {
        let content = UNMutableNotificationContent()
        content.title = "Your Tama is calling"
        content.body = "\(deviceTitle) needs your attention."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "tama-calling-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
