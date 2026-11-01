import SwiftUI
import WidgetKit

/// Full-bleed LCD look — no plastic shell/bezel at all, just the screen
/// texture (see LCDScreenEffect, shared with the in-app LCDView so the two
/// never drift apart), gated by the same Settings toggle as the app.
struct TamaWidgetView: View {
    let entry: TamaEntry

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image = entry.image {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .lcdScreenEffect(enabled: WidgetSharedState.lcdEffectEnabled)
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "pawprint.fill")
                            .font(.title2)
                        Text(entry.isConfigured ? "Open TamaEmu" : "Long-press to choose a Tama")
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // Mandatory on iOS 17 — a plain background color/material alone
        // triggers a runtime warning and visibly broken rendering.
        .containerBackground(for: .widget) {
            Color(.systemBackground)
        }
    }
}
