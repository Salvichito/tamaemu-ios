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
}

/// Pure viewer — runs no simulation of its own. Just reads whatever the
/// main app (or its BGAppRefreshTask) last wrote to the shared App Group
/// container for whichever Tama this widget instance is configured to.
struct TamaProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TamaEntry {
        TamaEntry(date: Date(), image: nil, deviceTitle: nil, isConfigured: false)
    }

    func snapshot(for configuration: SelectTamaIntent, in context: Context) async -> TamaEntry {
        currentEntry(for: configuration)
    }

    func timeline(for configuration: SelectTamaIntent, in context: Context) async -> Timeline<TamaEntry> {
        // A request for the next refresh, not a guarantee — WidgetKit's
        // own budget decides the real cadence.
        let nextRefresh = Date().addingTimeInterval(30 * 60)
        return Timeline(entries: [currentEntry(for: configuration)], policy: .after(nextRefresh))
    }

    private func currentEntry(for configuration: SelectTamaIntent) -> TamaEntry {
        guard let id = configuration.tama?.id, let device = DeviceCatalog.find(name: id) else {
            return TamaEntry(date: Date(), image: nil, deviceTitle: nil, isConfigured: false)
        }
        var image: UIImage?
        if let path = WidgetSharedState.latestFramePath(for: device), let data = try? Data(contentsOf: path) {
            image = UIImage(data: data)
        }
        return TamaEntry(
            date: Date(),
            image: image,
            deviceTitle: WidgetSharedState.deviceTitle(for: device),
            isConfigured: true
        )
    }
}
