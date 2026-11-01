import UserNotifications

/// A deliberately dumb fallback for NotificationScheduler.fireCallingNotification:
/// that one only fires when the emulator core actually detects a call, but
/// detecting that requires running the CPU forward (EmulatorEngine's
/// checkCallDetection), which in the background only happens whenever iOS
/// opportunistically grants a BGAppRefreshTask — no guaranteed cadence, and
/// for an app that isn't opened often, effectively never (see
/// BackgroundRefresh's own comment). This scheduler knows nothing about
/// game state at all — it just reminds the player to check in if they
/// haven't opened the app in a while. The tradeoff is the opposite one: a
/// time-interval trigger is delivered reliably by iOS on its own, with no
/// background execution needed, but it's a guess, not a signal.
enum ReminderNotificationScheduler {
    private static let identifier = "tama-reminder"

    /// Call when the app leaves the foreground. No-ops if the setting is
    /// off; replaces any already-pending reminder (same identifier) rather
    /// than stacking one per background transition.
    static func scheduleIfEnabled() {
        guard AppSettings.reminderNotificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Check on your Tama"
        content.body = "It's been a while since you last opened TamaEmu."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: AppSettings.reminderIntervalHours * 3600,
            repeats: false
        )
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    /// Call whenever the player is back in the app — either by opening it,
    /// or because a real call-detected notification already gave them a
    /// (more useful) heads-up — so the dumb reminder doesn't also fire on
    /// top of that.
    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}
