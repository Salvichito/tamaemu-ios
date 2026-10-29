import UIKit
import WidgetKit

struct TamaEntry: TimelineEntry {
    let date: Date
    let image: UIImage?
    let deviceTitle: String?
}

/// Pure viewer — runs no simulation of its own. Just reads whatever the
/// main app (or its BGAppRefreshTask) last wrote to the shared App Group
/// container.
struct TamaProvider: TimelineProvider {
    func placeholder(in context: Context) -> TamaEntry {
        TamaEntry(date: Date(), image: nil, deviceTitle: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (TamaEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TamaEntry>) -> Void) {
        // A request for the next refresh, not a guarantee — WidgetKit's
        // own budget decides the real cadence.
        let nextRefresh = Date().addingTimeInterval(30 * 60)
        completion(Timeline(entries: [currentEntry()], policy: .after(nextRefresh)))
    }

    private func currentEntry() -> TamaEntry {
        var image: UIImage?
        if let path = WidgetSharedState.latestFramePath, let data = try? Data(contentsOf: path) {
            image = UIImage(data: data)
        }
        return TamaEntry(date: Date(), image: image, deviceTitle: WidgetSharedState.deviceTitle)
    }
}
