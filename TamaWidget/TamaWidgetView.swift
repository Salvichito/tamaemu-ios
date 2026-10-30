import SwiftUI
import WidgetKit

/// Skeuomorphic device shell: a plastic bezel around a recessed screen, with
/// a glossy highlight on the body and a glass-reflection sweep on the
/// screen — styled after a real Tamagotchi's body, not the system's Liquid
/// Glass material (that's wallpaper-driven and out of our control; see
/// WidgetKit's own "accented rendering mode" docs).
struct TamaWidgetView: View {
    let entry: TamaEntry

    private let shellColor = Color(red: 0.30, green: 0.73, blue: 0.75)
    private let bezelInset: CGFloat = 0.085   // fraction of the shorter side
    private let screenInset: CGFloat = 0.14

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let bezel = side * bezelInset
            let screenPad = side * screenInset

            ZStack {
                shellColor
                LinearGradient(
                    colors: [.white.opacity(0.55), .white.opacity(0), .black.opacity(0.12)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )

                RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                    .fill(Color(white: 0.96))
                    .padding(bezel)
                    .shadow(color: .black.opacity(0.25), radius: 1, x: 0, y: 1)

                screen(side: side)
                    .padding(screenPad)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // Mandatory on iOS 17 — a plain background color/material alone
        // triggers a runtime warning and visibly broken rendering.
        .containerBackground(for: .widget) {
            shellColor
        }
    }

    @ViewBuilder
    private func screen(side: CGFloat) -> some View {
        ZStack {
            Color.black

            if let image = entry.image {
                GeometryReader { inner in
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFill()
                        .frame(width: inner.size.width, height: inner.size.height)
                        .clipped()
                }
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "pawprint.fill")
                        .font(.title2)
                    Text("Open TamaEmu")
                        .font(.caption2)
                }
                .foregroundStyle(.white.opacity(0.7))
            }

            // Glass-reflection sweep over the screen, not the whole shell —
            // real LCD glass sits recessed in the bezel, so the reflection
            // should read as "on the screen," not "on the plastic."
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.32), location: 0),
                    .init(color: .white.opacity(0.05), location: 0.35),
                    .init(color: .white.opacity(0), location: 0.55),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )

            // A hairline inner shadow so the screen reads as recessed into
            // the bezel rather than flat on top of it.
            RoundedRectangle(cornerRadius: side * 0.1, style: .continuous)
                .stroke(Color.black.opacity(0.55), lineWidth: 1.5)
                .blur(radius: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: side * 0.1, style: .continuous))
    }
}
