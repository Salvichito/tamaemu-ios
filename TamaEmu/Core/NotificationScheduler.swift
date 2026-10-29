import UserNotifications

/// iOS suppresses a local notification's banner/sound by default while
/// the app that scheduled it is in the foreground — exactly when the
/// player would actually be looking at the screen. Without opting in via
/// this delegate, a "calling for attention" notification fired while
/// playing is silently swallowed: delivered to the notification center,
/// never actually shown.
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}

/// Fires a local notification when the Tamagotchi needs attention.
/// Authorization is requested once, the first time the user actually has
/// something running (right after importing firmware) rather than at
/// cold launch before they've done anything.
enum NotificationScheduler {
    private static let foregroundPresenter = ForegroundPresenter()

    /// Must run before any notification could possibly be fired while
    /// the app is in the foreground — call once, as early as possible.
    static func configure() {
        UNUserNotificationCenter.current().delegate = foregroundPresenter
    }

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
