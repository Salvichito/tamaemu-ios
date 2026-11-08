import SwiftUI

/// The P1-era screen: real icon artwork and a real decorative background
/// pattern (both traced/sourced from references of the actual 1997
/// hardware -- personal use only, never distributed, see the
/// integration-research memory), with everything -- icons and the pixel
/// matrix alike -- sitting directly on the background, no separate boxed
/// panel for either. Square overall footprint -- same size and
/// proportions as every other Tamagotchi in the gallery (LCDView forces
/// the same `.aspectRatio(1, contentMode: .fit)`).
struct P1ScreenView: View {
    let state: P1ScreenState

    private let onColor = Color(red: 0.169, green: 0.165, blue: 0.157)
    private static let cornerRadius: CGFloat = 16
    private static let iconSize: CGFloat = 36
    /// The real device's background is a printed paper sheet physically
    /// behind the glass, not emulated data -- "P1BackgroundHearts" is the
    /// other pattern supplied alongside this one, swap freely. The icon
    /// positions below are measured against this specific image's own
    /// star layout (see iconPositions), so swapping backgrounds means
    /// re-measuring those too, not just this name.
    private static let backgroundAssetName = "P1BackgroundStars"

    /// TamaLib's own icon index order (confirmed against jcrona/tamatool's
    /// reference art and the user's own real P1 -- see the
    /// integration-research memory). Index 7 (attention) lights up on its
    /// own; it's not a selectable menu item, but still just an icon here.
    /// Traced from real P1 reference icons (Tamagotchi Fandom wiki), not
    /// SF Symbols -- the real "game" icon is a ball and bat, not a
    /// controller; the real "scolding" icon is a biting mouth, not a
    /// speech bubble.
    private static let iconAssetNames = [
        "P1IconFood",      // 0 food
        "P1IconLight",     // 1 light
        "P1IconGame",      // 2 game
        "P1IconMedicine",  // 3 medicine
        "P1IconBathroom",  // 4 poop cleaning
        "P1IconStatus",    // 5 stats
        "P1IconTraining",  // 6 scolding
        "P1IconAttention"  // 7 attention
    ]

    /// Each icon's center, as a fraction of the square's own width/height
    /// -- measured directly off P1BackgroundStars.imageset's actual pixel
    /// data (a connected-component scan found each star blob's centroid),
    /// not eyeballed, so the icons land squarely on top of their stars
    /// rather than just floating somewhere near them.
    private static let iconPositions: [(x: CGFloat, y: CGFloat)] = [
        (0.164, 0.140), // 0 food
        (0.393, 0.143), // 1 light
        (0.591, 0.141), // 2 game
        (0.814, 0.141), // 3 medicine
        (0.169, 0.856), // 4 bathroom
        (0.386, 0.853), // 5 status
        (0.604, 0.851), // 6 training
        (0.837, 0.859)  // 7 attention
    ]

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            screenContent(side: side)
                .frame(width: side, height: side)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func screenContent(side: CGFloat) -> some View {
        ZStack {
            Image(Self.backgroundAssetName)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: side, height: side)

            pixelGrid
                .aspectRatio(32.0 / 16.0, contentMode: .fit)
                .frame(width: side * 0.62)

            ForEach(0..<8, id: \.self) { i in
                Image(Self.iconAssetNames[i])
                    .resizable()
                    .scaledToFit()
                    .frame(width: Self.iconSize, height: Self.iconSize)
                    .foregroundStyle(onColor)
                    .opacity(state.icons[i] ? 1.0 : 0.35)
                    .position(x: Self.iconPositions[i].x * side, y: Self.iconPositions[i].y * side)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
    }

    private var pixelGrid: some View {
        GeometryReader { geo in
            if let image = makeBitmapImage() {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    /// "Off" pixels are fully transparent, not a solid LCD tint -- the
    /// background pattern shows straight through them, same as the icons
    /// sitting directly on it. Only "on" pixels are opaque.
    private func makeBitmapImage() -> CGImage? {
        let w = 32, h = 16
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                if state.pixel(x, y) {
                    pixels[i] = 43
                    pixels[i + 1] = 42
                    pixels[i + 2] = 40
                    pixels[i + 3] = 255
                }
            }
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        return context.makeImage()
    }
}

#Preview {
    P1ScreenView(state: .blank)
        .padding()
}
