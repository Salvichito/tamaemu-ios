import AppIntents
import TamaCore
import UIKit
import WidgetKit

struct TamaEntry: TimelineEntry {
    let date: Date
    let image: UIImage?
    let deviceTitle: String?
    /// Distinguishes "configured, but this Tama hasn't published a frame
    /// yet" from "never configured" — the two placeholders read differently
    /// (see TamaWidgetView).
    let isConfigured: Bool
    /// Same app-wide "last closed" stamp the lock screen neglect widget
    /// reads — see WidgetSharedState.recordAppClosed(). Threaded through so
    /// TamaWidgetView can show its own neglect badge without a second
    /// provider.
    let appClosedAt: Date?
}

/// Pure viewer — runs no simulation of its own. Just reads whatever the
/// main app (or its BGAppRefreshTask) last wrote to the shared App Group
/// container for whichever Tama this widget instance is configured to.
struct TamaProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TamaEntry {
        TamaEntry(date: Date(), image: nil, deviceTitle: nil, isConfigured: false, appClosedAt: nil)
    }

    func snapshot(for configuration: SelectTamaIntent, in context: Context) async -> TamaEntry {
        currentEntry(for: configuration, at: Date())
    }

    /// The image/title/isConfigured fields only ever change when the main
    /// app republishes (which itself nudges WidgetKit to reload), so one
    /// entry per 30 minutes would be plenty for those alone. But the
    /// neglect badge needs to tick forward minute-by-minute like the lock
    /// screen widget does, so this pre-computes a full timeline of
    /// per-minute entries up to that same refresh horizon instead of just
    /// one — same reasoning as TamaNeglectProvider.getTimeline.
    func timeline(for configuration: SelectTamaIntent, in context: Context) async -> Timeline<TamaEntry> {
        let now = Date()
        // A request for the next refresh, not a guarantee — WidgetKit's
        // own budget decides the real cadence.
        let nextRefresh = now.addingTimeInterval(30 * 60)
        var entries = [currentEntry(for: configuration, at: now)]
        if WidgetSharedState.appClosedAt != nil {
            var minute = 1
            while true {
                let boundary = now.addingTimeInterval(Double(minute) * 60)
                guard boundary < nextRefresh else { break }
                entries.append(currentEntry(for: configuration, at: boundary))
                minute += 1
            }
        }
        return Timeline(entries: entries, policy: .after(nextRefresh))
    }

    private func currentEntry(for configuration: SelectTamaIntent, at date: Date) -> TamaEntry {
        guard let id = configuration.tama?.id, let device = DeviceCatalog.find(name: id) else {
            return TamaEntry(date: date, image: nil, deviceTitle: nil, isConfigured: false, appClosedAt: nil)
        }
        var image: UIImage?
        if let path = WidgetSharedState.latestFramePath(for: device), let data = try? Data(contentsOf: path) {
            image = UIImage(data: data)
        }
        return TamaEntry(
            date: date,
            image: image,
            deviceTitle: WidgetSharedState.deviceTitle(for: device),
            isConfigured: true,
            appClosedAt: WidgetSharedState.appClosedAt
        )
    }
}
