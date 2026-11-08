import SwiftUI

/// The P1-era screen, styled to match the real 1997 hardware, inside a
/// square overall footprint -- same size and proportions as every other
/// Tamagotchi in the gallery (LCDView forces the same `.aspectRatio(1,
/// contentMode: .fit)`). A real P1's square face has the 8 status icons
/// printed directly on it (silkscreened onto the same paper behind the
/// glass that carries its decorative pattern -- still deferred, see the
/// ambient-background memory, `faceColor` stands in for it with a flat
/// grey for now), with the actual pixel screen as a separate, narrower
/// rectangle in the middle, in its own thin frame -- not one shared
/// tinted box containing icons and screen together, which is what this
/// looked like before a direct comparison against a real device's photo
/// caught it.
struct P1ScreenView: View {
    let state: P1ScreenState

    private let lcdTint = Color(red: 0.624, green: 0.682, blue: 0.510)
    private let bezelColor = Color(red: 0.169, green: 0.165, blue: 0.157)
    private let faceColor = Color(white: 0.68)
    private static let bezelCornerRadius: CGFloat = 16
    private static let faceCornerRadius: CGFloat = 10
    private static let screenCornerRadius: CGFloat = 4

    /// TamaLib's own icon index order (confirmed against jcrona/tamatool's
    /// reference art and the user's own real P1 -- see the
    /// integration-research memory). Index 7 (attention) lights up on its
    /// own; it's not a selectable menu item, but still just an icon here.
    private static let iconSymbols = [
        "fork.knife",                  // 0 food
        "lightbulb.fill",              // 1 light
        "gamecontroller.fill",         // 2 game
        "syringe.fill",                // 3 medicine
        "toilet",                      // 4 poop cleaning
        "gauge",                       // 5 stats
        "exclamationmark.bubble.fill", // 6 scolding
        "face.smiling.fill"            // 7 attention
    ]

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            screenContent
                .frame(width: side, height: side)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var screenContent: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Self.bezelCornerRadius, style: .continuous)
                .fill(bezelColor)

            RoundedRectangle(cornerRadius: Self.faceCornerRadius, style: .continuous)
                .fill(faceColor)
                .padding(10)

            VStack(spacing: 0) {
                iconRow(0..<4)
                Spacer(minLength: 10)
                pixelGrid
                    .aspectRatio(32.0 / 16.0, contentMode: .fit)
                    .padding(6)
                    .background(lcdTint)
                    .clipShape(RoundedRectangle(cornerRadius: Self.screenCornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Self.screenCornerRadius, style: .continuous)
                            .stroke(bezelColor, lineWidth: 3)
                    )
                Spacer(minLength: 10)
                iconRow(4..<8)
            }
            .padding(EdgeInsets(top: 20, leading: 18, bottom: 20, trailing: 18))
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.bezelCornerRadius, style: .continuous))
    }

    /// Selected state shows as full opacity vs. faint, not outline vs.
    /// filled -- matches both the user's own photo of a real P1 and how
    /// TamaTool itself renders this (alpha-blended, not swapped artwork).
    private func iconRow(_ range: Range<Int>) -> some View {
        HStack {
            ForEach(range, id: \.self) { i in
                Image(systemName: Self.iconSymbols[i])
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(bezelColor)
                    .opacity(state.icons[i] ? 1.0 : 0.35)
                if i != range.upperBound - 1 { Spacer() }
            }
        }
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

    private func makeBitmapImage() -> CGImage? {
        let w = 32, h = 16
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let on = (UInt8(43), UInt8(42), UInt8(40))
        let off = lcdTint.rgbaBytes()
        for y in 0..<h {
            for x in 0..<w {
                let c = state.pixel(x, y) ? on : off
                let i = (y * w + x) * 4
                pixels[i] = c.0
                pixels[i + 1] = c.1
                pixels[i + 2] = c.2
                pixels[i + 3] = 255
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

private extension Color {
    func rgbaBytes() -> (UInt8, UInt8, UInt8) {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (UInt8(r * 255), UInt8(g * 255), UInt8(b * 255))
    }
}

#Preview {
    P1ScreenView(state: .blank)
        .padding()
}
