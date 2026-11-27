import SwiftUI
import WidgetKit

/// Full-bleed LCD look — no plastic shell/bezel at all, just the screen
/// texture (see LCDScreenEffect, shared with the in-app LCDView so the two
/// never drift apart), gated by the same Settings toggle as the app.
struct TamaWidgetView: View {
    let entry: TamaEntry
    /// .accented = the Home Screen uses tinted or clear icons.
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var isAccented: Bool { renderingMode == .accented }

    private var accentedMode: WidgetAccentedRenderingMode {
        switch entry.tintedLook {
        case .tinted: return .accentedDesaturated
        case .greyscale: return .desaturated
        case .fullColor: return .fullColor
        }
    }

    var body: some View {
        GeometryReader { geo in
            Group {
                if !entry.isPremium {
                    VStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(.title2)
                        Text("Premium")
                            .font(.caption2.bold())
                    }
                    .foregroundStyle(.secondary)
                } else if let image = entry.image {
                    // Without the accented-mode hint, iOS fills this opaque
                    // picture with one flat color: a plain white rectangle
                    // on tinted / clear Home Screens. The LCD texture is
                    // left off there too — its overlay layers would get the
                    // same flat fill and cover the Tama.
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.none)
                        .widgetAccentedRenderingMode(accentedMode)
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .lcdScreenEffect(enabled: WidgetSharedState.lcdEffectEnabled && !isAccented)
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "pawprint.fill")
                            .font(.title2)
                        Text(entry.isConfigured ? "Open Tomomix" : "Long-press to choose a pet")
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
                if entry.isPremium, let appClosedAt = entry.appClosedAt, entry.image != nil {
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
