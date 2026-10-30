import SwiftUI

/// Renders the emulator's LCD framebuffer. Thin and stable by design — once
/// the pixel pipeline is correct, all further visual work happens around
/// this view, not inside it.
struct LCDView: View {
    let image: CGImage?

    @AppStorage(AppSettings.Keys.sharpPixels) private var sharpPixels = true
    @AppStorage(WidgetSharedState.lcdEffectEnabledKey, store: WidgetSharedState.sharedDefaultsOrStandard)
    private var lcdEffectEnabled = true

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            // Same curvature convention as an app icon's squircle.
            let corner = side * 0.2237

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
