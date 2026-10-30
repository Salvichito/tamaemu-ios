import CoreGraphics
import Foundation
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

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    static var latestFramePath: URL? {
        containerURL?.appendingPathComponent("latest_frame.png")
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

    private static let deviceTitleKey = "deviceTitle"
    private static let lastUpdatedKey = "lastUpdated"

    /// Settings' "LCD Screen Effect" toggle, stored in the App Group suite
    /// (not AppSettings' UserDefaults.standard) specifically so the widget
    /// reads the exact same value the in-app screen does — one source of
    /// truth instead of a value that needs mirroring between the two.
    static let lcdEffectEnabledKey = "lcdEffectEnabled"

    static var deviceTitle: String? {
        get { sharedDefaults?.string(forKey: deviceTitleKey) }
        set { sharedDefaults?.set(newValue, forKey: deviceTitleKey) }
    }

    static var lastUpdated: Date? {
        get { sharedDefaults?.object(forKey: lastUpdatedKey) as? Date }
        set { sharedDefaults?.set(newValue, forKey: lastUpdatedKey) }
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
    static func publish(image: CGImage, deviceTitle: String) {
        guard let framePath = latestFramePath else { return }
        guard let pngData = UIImage(cgImage: image).pngData() else { return }
        try? pngData.write(to: framePath, options: .atomic)
        self.deviceTitle = deviceTitle
        lastUpdated = Date()
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
    }
}
