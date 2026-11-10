import SwiftUI
import WidgetKit

struct TamaNeglectEntry: TimelineEntry {
    let date: Date
    /// When the app was last backgrounded, app-wide — see
    /// WidgetSharedState.recordAppClosed(). nil if it's never happened yet
    /// (fresh install, or the App Group container isn't available).
    let appClosedAt: Date?
}

/// Lock screen only — no per-Tama configuration, since the timer is about
/// the app as a whole, not any one pet. Unlike TamaProvider this needs no
/// AppIntent at all, which also means the system's widget gallery offers it
/// as a single plain entry rather than something to configure per instance.
struct TamaNeglectProvider: TimelineProvider {
    func placeholder(in context: Context) -> TamaNeglectEntry {
        TamaNeglectEntry(date: Date(), appClosedAt: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (TamaNeglectEntry) -> Void) {
        completion(TamaNeglectEntry(date: Date(), appClosedAt: WidgetSharedState.appClosedAt))
    }

    /// Text(date, style: .relative) was the obvious choice here, but it
    /// drops down to seconds for anything under a minute — not what we
    /// want. A plain formatted string doesn't have that problem, but unlike
    /// the system's date styles it's static: it won't tick forward on its
    /// own, so WidgetKit needs an actual timeline entry for every minute
    /// boundary to display, not just one entry covering the whole span.
    /// Pre-computing a few hours' worth up front keeps it stepping forward
    /// on schedule without the extension needing to wake up each minute;
    /// .atEnd asks for a fresh batch once this window runs out, recomputed
    /// from the same appClosedAt so the count stays correct even after a
    /// long gap.
    func getTimeline(in context: Context, completion: @escaping (Timeline<TamaNeglectEntry>) -> Void) {
        let now = Date()
        guard let appClosedAt = WidgetSharedState.appClosedAt else {
            completion(Timeline(entries: [TamaNeglectEntry(date: now, appClosedAt: nil)], policy: .atEnd))
            return
        }
        let elapsedMinutesNow = Int(now.timeIntervalSince(appClosedAt) / 60)
        let horizonMinutes = 180
        var entries = [TamaNeglectEntry(date: now, appClosedAt: appClosedAt)]
        for minute in 1...horizonMinutes {
            let boundary = appClosedAt.addingTimeInterval(Double(elapsedMinutesNow + minute) * 60)
            entries.append(TamaNeglectEntry(date: boundary, appClosedAt: appClosedAt))
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

/// Lock screen / StandBy accessory — the system renders this as a
/// single-color tinted mask (no custom colors survive), so this is just the
/// flattened egg glyph (WidgetEggGlyph, a template image with the face/feet
/// already punched out as transparent cutouts in the source art), sized to
/// fill most of the circle, with the neglect timer in its own row below —
/// not overlapping the glyph, since the system renders everything in one
/// flat tint and white-on-white text over the glyph's solid body would be
/// unreadable.
struct TamaNeglectWidgetView: View {
    let entry: TamaNeglectEntry

    private var label: String {
        guard let appClosedAt = entry.appClosedAt else { return "—" }
        return WidgetSharedState.formatNeglectDuration(max(0, entry.date.timeIntervalSince(appClosedAt)))
    }

    var body: some View {
        GeometryReader { geo in
            // Proportional to the circle's own size rather than a fixed
            // point value, so the icon stays "as big as it can be" across
            // whatever size accessoryCircular actually renders at. The
            // glyph and the timer are two separate rows, not one overlaid
            // on the other — the system renders this whole widget as one
            // flat tint with no color variation, so text sitting on top of
            // the glyph's solid body (it's not transparent there) would be
            // unreadable rather than just smaller.
            VStack(spacing: 0) {
                Image("WidgetEggGlyph")
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .frame(height: geo.size.height * 0.72)
                Text(label)
                    .font(.system(size: geo.size.height * 0.22, weight: .bold))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    // VStack already centers its children, but this pins
                    // the text to the center explicitly regardless of how
                    // many digits it ends up being ("1m" vs "47h 12m")
                    // rather than leaving it to a natural-width row that
                    // could drift.
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .containerBackground(for: .widget) { Color.clear }
    }
}

struct TamaNeglectWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSharedState.neglectWidgetKind, provider: TamaNeglectProvider()) { entry in
            TamaNeglectWidgetView(entry: entry)
        }
        .configurationDisplayName("TamaEmu")
        .description("Shows how long it's been since you last opened TamaEmu.")
        .supportedFamilies([.accessoryCircular])
    }
}
