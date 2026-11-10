import CoreGraphics
import Foundation
import TamaCore
import UIKit
import WidgetKit

/// The shared App Group container TamaEmu and its (future) widget extension
/// both read/write — the widget is a pure viewer, it runs no simulation of
/// its own, so this is the only channel between the two.
enum WidgetSharedState {
    static let appGroupID = "group.com.fluorescente.TamaEmu"

    /// Kind string for the widget's StaticConfiguration/the app's
    /// reloadTimelines(ofKind:) call — one shared constant rather than a
    /// literal duplicated in both targets, since a typo there would
    /// silently no-op reloads forever.
    static let widgetKind = "TamaLCDWidget"

    /// Kind string for the lock screen "left alone for" widget — a
    /// separate, non-configurable widget (no per-Tama picker), so it needs
    /// its own kind distinct from the home screen widget's.
    static let neglectWidgetKind = "TamaNeglectWidget"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// Per device, since several Tamas can now be live/published
    /// independently — filenames keyed by device.id, mirroring
    /// SavePaths' own `<id>.bin`/`<id>.sav` naming.
    static func latestFramePath(for device: TamaDevice) -> URL? {
        containerURL?.appendingPathComponent("latest_frame_\(device.id).png")
    }

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    /// Non-optional, for @AppStorage call sites (which need a concrete
    /// store) — falls back to .standard only if the App Group container
    /// somehow isn't available, same silent-degrade posture as `publish`.
    static var sharedDefaultsOrStandard: UserDefaults {
        sharedDefaults ?? .standard
    }

    /// Settings' "LCD Screen Effect" toggle, stored in the App Group suite
    /// (not AppSettings' UserDefaults.standard) specifically so the widget
    /// reads the exact same value the in-app screen does — one source of
    /// truth instead of a value that needs mirroring between the two.
    /// Stays global/flat — it's a display preference, not per-pet data.
    static let lcdEffectEnabledKey = "lcdEffectEnabled"

    static func deviceTitle(for device: TamaDevice) -> String? {
        sharedDefaults?.string(forKey: "deviceTitle.\(device.id)")
    }

    static func lastUpdated(for device: TamaDevice) -> Date? {
        sharedDefaults?.object(forKey: "lastUpdated.\(device.id)") as? Date
    }

    private static let appClosedAtKey = "appClosedAt"

    /// When the app as a whole was last backgrounded — global, not
    /// per-device, since the lock screen "left alone for" timer is about
    /// the player leaving the app entirely, not which pet's page they last
    /// had open. Stamped by the app's own scenePhase handler, not by
    /// per-page swiping between owned Tamas.
    static var appClosedAt: Date? {
        sharedDefaults?.object(forKey: appClosedAtKey) as? Date
    }

    /// Stamps now as the app-closed time and nudges the lock screen widget
    /// to pick it up — needed because the relative-time text itself ticks
    /// on its own once displayed, but WidgetKit still needs a new timeline
    /// entry to learn the start date changed at all.
    static func recordAppClosed() {
        sharedDefaults?.set(Date(), forKey: appClosedAtKey)
        WidgetCenter.shared.reloadTimelines(ofKind: neglectWidgetKind)
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
    }

    /// Minute granularity, never seconds. Starts at "1m" immediately and
    /// steps up exactly as each full minute elapses (floor+1, so it never
    /// reads "0m"), then switches to the "Xh Ym" form once past an hour.
    /// Shared by both the lock screen neglect widget and the home screen
    /// widget's own neglect badge so the two never drift apart.
    static func formatNeglectDuration(_ elapsed: TimeInterval) -> String {
        let totalMinutes = Int(elapsed / 60) + 1
        if totalMinutes < 60 {
            return "\(totalMinutes)m"
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return "\(hours)h \(minutes)m"
    }

    private static let ownedDeviceIDsKey = "ownedDeviceIDs"

    /// The widget extension runs in its own sandbox — `FileManager`'s
    /// `.applicationSupportDirectory` resolves to a different, per-process
    /// container there than in the main app, so `SavePaths`/
    /// `ActiveDeviceLookup`'s on-disk checks silently see nothing when
    /// called from the widget. The App Group suite is the only thing
    /// actually shared between the two processes, so the main app mirrors
    /// "which devices are owned" here whenever it changes, and the
    /// widget's configuration picker (`SelectTamaIntent`) reads from here
    /// instead of trying to stat files itself.
    static func publishOwnedDevices(_ devices: [TamaDevice]) {
        sharedDefaults?.set(devices.map(\.id), forKey: ownedDeviceIDsKey)
    }

    static func ownedDeviceIDs() -> [String] {
        sharedDefaults?.stringArray(forKey: ownedDeviceIDsKey) ?? []
    }

    static var lcdEffectEnabled: Bool {
        get { sharedDefaults?.object(forKey: lcdEffectEnabledKey) as? Bool ?? true }
        set { sharedDefaults?.set(newValue, forKey: lcdEffectEnabledKey) }
    }

    /// Settings changes to lcdEffectEnabled don't touch the frame/timestamp
    /// `publish()` already handles, so they need their own nudge to reach
    /// the widget before its next natural refresh (which can be ~30min out).
    static func requestWidgetRefresh() {
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
    }

    /// Writes the current LCD frame + device title to the shared
    /// container and asks the widget to refresh. Safe to call often —
    /// the write is atomic, and a missing App Group container (e.g. the
    /// entitlement isn't set up yet) just silently no-ops rather than
    /// crashing.
    static func publish(image: CGImage, device: TamaDevice) {
        guard let framePath = latestFramePath(for: device) else { return }
        guard let pngData = UIImage(cgImage: image).pngData() else { return }
        try? pngData.write(to: framePath, options: .atomic)
        sharedDefaults?.set(device.title, forKey: "deviceTitle.\(device.id)")
        sharedDefaults?.set(Date(), forKey: "lastUpdated.\(device.id)")
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
    }

    /// The last frame this device actually showed, read straight off disk —
    /// fast enough to call synchronously on launch so the play screen has
    /// *something* real to show immediately, instead of a black screen,
    /// while the engine loads/catches up off the main thread.
    static func loadLastFrameImage(for device: TamaDevice) -> CGImage? {
        guard let framePath = latestFramePath(for: device),
              let image = UIImage(contentsOfFile: framePath.path) else { return nil }
        return image.cgImage
    }
}
