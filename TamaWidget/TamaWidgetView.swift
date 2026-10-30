import SwiftUI
import WidgetKit

/// Full-bleed LCD look — no plastic shell/bezel at all, just the screen
/// texture: horizontal scanlines (the real device's dot-matrix rows) and a
/// soft glass-reflection sweep, the same two cues a real Tamagotchi's
/// screen gives at this viewing distance.
struct TamaWidgetView: View {
    let entry: TamaEntry

    /// The core's framebuffer is 128x128 — one scanline per emulated pixel
    /// row keeps the effect tied to the real dot-matrix grid rather than an
    /// arbitrary stripe count.
    private let panelRows: CGFloat = 128

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image = entry.image {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()

                    ScanlineOverlay(rows: panelRows)
                        .blendMode(.multiply)

                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.22), location: 0),
                            .init(color: .white.opacity(0.04), location: 0.4),
                            .init(color: .white.opacity(0), location: 0.6),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    .blendMode(.screen)
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "pawprint.fill")
                            .font(.title2)
                        Text("Open TamaEmu")
                            .font(.caption2)
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

private struct ScanlineOverlay: View {
    let rows: CGFloat

    var body: some View {
        Canvas { context, size in
            let spacing = size.height / rows
            var y: CGFloat = 0
            while y < size.height {
                context.fill(
                    Path(CGRect(x: 0, y: y, width: size.width, height: max(0.5, spacing * 0.35))),
                    with: .color(.black.opacity(0.22))
                )
                y += spacing
            }
        }
    }
}
