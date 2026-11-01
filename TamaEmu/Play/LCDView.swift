import SwiftUI

/// Renders the emulator's LCD framebuffer. Thin and stable by design — once
/// the pixel pipeline is correct, all further visual work happens around
/// this view, not inside it.
struct LCDView: View {
    let image: CGImage?

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
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .stroke(Color(.separator), lineWidth: 1)
            )
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
