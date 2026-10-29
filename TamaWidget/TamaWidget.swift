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
    }
}
