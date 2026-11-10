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
            .overlay(alignment: .bottom) {
                // Only once there's an actual Tama on screen to be neglected
                // — the "long-press to choose a Tama" placeholder has
                // nothing to count. A dark capsule behind the text keeps it
                // legible over whatever colors the LCD frame underneath
                // happens to have, unlike the lock screen widget's flat
                // system tint.
                if let appClosedAt = entry.appClosedAt, entry.image != nil {
                    Text(WidgetSharedState.formatNeglectDuration(max(0, entry.date.timeIntervalSince(appClosedAt))))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .padding(.bottom, 6)
                }
            }
        }
        // Mandatory on iOS 17 — a plain background color/material alone
        // triggers a runtime warning and visibly broken rendering.
        .containerBackground(for: .widget) {
            Color(.systemBackground)
        }
    }
}
