import SwiftUI

/// Renders the emulator's LCD framebuffer. Thin and stable by design — once
/// the pixel pipeline is correct, all further visual work happens around
/// this view, not inside it.
struct LCDView: View {
    let image: CGImage?

    /// False for the screenshot/video export render path (ScreenRecorder's
    /// `renderLCDSnapshot`): that output stands alone with no surrounding
    /// bezel chrome, so the clipped-away corners would otherwise end up
    /// transparent — and since neither a saved JPEG nor an H.264 video
    /// carries alpha, they'd flatten to solid black triangles. The live
    /// on-screen view keeps the rounding.
    var rounded: Bool = true

    /// Subtle rounding, closer to a standard rounded rect than an icon's
    /// squircle — shared with ScreenGlow so its halo's corners match this
    /// view's own clip shape exactly.
    static let cornerRadiusRatio: CGFloat = 0.08

    @AppStorage(AppSettings.Keys.sharpPixels) private var sharpPixels = true
    @AppStorage(WidgetSharedState.lcdEffectEnabledKey, store: WidgetSharedState.sharedDefaultsOrStandard)
    private var lcdEffectEnabled = true

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let corner = side * Self.cornerRadiusRatio

            Group {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(sharpPixels ? .none : .high)
                } else {
                    Color.black
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .lcdScreenEffect(enabled: lcdEffectEnabled)
            .clipShape(RoundedRectangle(cornerRadius: rounded ? corner : 0, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: rounded ? corner : 0, style: .continuous)
                    .stroke(rounded ? Color(.separator) : .clear, lineWidth: 1)
            )
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
