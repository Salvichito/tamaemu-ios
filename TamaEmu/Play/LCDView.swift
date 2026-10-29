import SwiftUI

/// Renders the emulator's LCD framebuffer. Thin and stable by design — once
/// the pixel pipeline is correct, all further visual work happens around
/// this view, not inside it.
struct LCDView: View {
    let image: CGImage?

    @AppStorage(AppSettings.Keys.sharpPixels) private var sharpPixels = true

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(sharpPixels ? .none : .high)
                    .aspectRatio(1, contentMode: .fit)
            } else {
                Color.black.aspectRatio(1, contentMode: .fit)
            }
        }
    }
}
