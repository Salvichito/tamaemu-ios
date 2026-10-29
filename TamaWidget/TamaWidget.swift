import SwiftUI
import WidgetKit

struct TamaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSharedState.widgetKind, provider: TamaProvider()) { entry in
            TamaWidgetView(entry: entry)
        }
        .configurationDisplayName("TamaEmu")
        .description("Shows your Tamagotchi's current status.")
        .supportedFamilies([.systemSmall])
        // Without this, WidgetKit insets our content with its own system
        // margin, which is what left a visible border of padding around
        // the LCD image — the rounded corners alone already read as
        // "contained" without it.
        .contentMarginsDisabled()
    }
}
