import TamaCore
import UIKit
import UserNotifications

/// Which Tama a tapped notification was about, waiting for the gallery
/// to pick it up and scroll there. Set by the delegate below; on a cold
/// launch the tap arrives before the gallery exists, so it waits here.
@MainActor
@Observable
final class NotificationRouter {
    static let shared = NotificationRouter()
    var pendingDeviceID: TamaDevice.ID?

    /// Hands back the waiting device (once) and clears it.
    func take() -> TamaDevice.ID? {
        defer { pendingDeviceID = nil }
        return pendingDeviceID
    }
}

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

    /// The player tapped a notification: open on the Tama it was about.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let deviceID = response.notification.request.content.userInfo[NotificationScheduler.deviceIDKey] as? String
        DispatchQueue.main.async {
            if let deviceID { NotificationRouter.shared.pendingDeviceID = deviceID }
            completionHandler()
        }
    }
}

/// Fires a local notification when the Tamagotchi needs attention.
/// Authorization is requested once, the first time the user actually has
/// something running (right after importing firmware) rather than at
/// cold launch before they've done anything.
enum NotificationScheduler {
    private static let foregroundPresenter = ForegroundPresenter()
    /// userInfo key naming the Tama a notification is about, so tapping
    /// it can open the app on that Tama's page.
    static let deviceIDKey = "deviceID"

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

    /// Only the Tama on screen ever runs live, so while the app is open
    /// a call is one the player is already looking at -- an alert for it
    /// is just noise (e.g. Yasashii's lit buttons trip the call detector
    /// every time one is pressed). Only alert once the app is closed.
    static func fireCallingNotification(device: TamaDevice) {
        DispatchQueue.main.async {
            guard UIApplication.shared.applicationState == .background else { return }
            post(deviceID: device.id, deviceTitle: device.title)
        }
    }

    private static func post(deviceID: TamaDevice.ID, deviceTitle: String) {
        let content = UNMutableNotificationContent()
        content.title = "Your Tama is calling"
        content.body = "\(deviceTitle) needs your attention."
        content.sound = .default
        content.userInfo = [deviceIDKey: deviceID]

        let request = UNNotificationRequest(
            // One per Tama: a newer call replaces the older one in
            // Notification Center instead of piling up beside it.
            identifier: "tama-calling-\(deviceTitle)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
