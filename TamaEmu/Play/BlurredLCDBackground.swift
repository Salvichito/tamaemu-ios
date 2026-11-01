import SwiftUI

/// Fills the page behind the LCD with a heavily zoomed, heavily blurred
/// copy of that same Tama's current frame — the screen's own colors turned
/// into soft ambient color, full-bleed under the status bar and home
/// indicator. Deliberately stateless (just a pure function of `image` and
/// the environment's color scheme): a full-bleed `.ignoresSafeArea()` view
/// that instead owned `@State`/`.task` of its own previously made every
/// later sibling in the page invisible — see the "ignoresSafeArea + ZStack"
/// note on that bug. Reacts to `image` changes on its own (SwiftUI just
/// re-renders), and `image` itself only changes when the live frame's
/// pixels actually do (FrameStore gates that upstream), so this never
/// recomputes on the 60Hz display tick for an idle screen.
struct BlurredLCDBackground: View {
    let image: CGImage?
    @Environment(\.colorScheme) private var colorScheme

    /// How far past the LCD's own 128×128 content to zoom before blurring —
    /// higher reads as pure abstract color, lower keeps hints of shapes.
    private let zoom: CGFloat = 1.7

    var body: some View {
        GeometryReader { geo in
            let side = max(geo.size.width, geo.size.height)

            ZStack {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(zoom)
                        .clipped()
                        .blur(radius: side * 0.1)
                } else {
                    Color(.systemBackground)
                }

                // Same source both ways — light mode lifts it toward white
                // with a screen blend (which barely touches already-bright
                // pixels and only lightens the dark ones) so it keeps its
                // ambient color instead of washing flat grey.
                if colorScheme == .light {
                    Color.white.opacity(0.5).blendMode(.screen)
                }
            }
            .compositingGroup()
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
    }
}
