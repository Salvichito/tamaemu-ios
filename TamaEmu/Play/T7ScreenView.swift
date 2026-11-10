import CT7Emu
import SwiftUI

/// The Tama-Go/Tamagotchi Friends screen: a plain dark bezel with the real
/// 48x31, 4-grayscale-level pixel grid and 10 status icons as generic SF
/// Symbols. Deliberately simple for now, same starting point P1ScreenView
/// itself had before real reference artwork/background existed for it
/// (see that view's own history) -- nothing here is traced from or
/// matched against real device photos yet, just a functional first pass.
/// Icon order/meaning is confirmed from T7Emu's own source comment
/// (t7.c's t7_get_icons), not guessed.
struct T7ScreenView: View {
    let state: T7ScreenState

    private static let cornerRadius: CGFloat = 16
    private static let iconSize: CGFloat = 20
    private static let bezelColor = Color(red: 0.169, green: 0.165, blue: 0.157)
    private static let onColor = Color(red: 0.43, green: 0.42, blue: 0.40)

    /// t7.c's t7_get_icons doc comment, in order.
    private static let iconSymbolNames = [
        "square.grid.2x2", // 0 dashboard
        "fork.knife", // 1 food
        "trash", // 2 trash
        "globe", // 3 globe
        "person.fill", // 4 user
        "bubble.left.and.bubble.right.fill", // 5 comments
        "cross.case.fill", // 6 medkit
        "heart.fill", // 7 heart
        "book.fill", // 8 book
        "bell.fill" // 9 bell
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
        VStack(spacing: side * 0.03) {
            iconRow
            pixelGrid
                .aspectRatio(CGFloat(IOS_T7_LCD_WIDTH) / CGFloat(IOS_T7_LCD_HEIGHT), contentMode: .fit)
                .frame(width: side * 0.92)
        }
        .padding(side * 0.04)
        .frame(width: side, height: side)
        .background(Self.bezelColor)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
    }

    private var iconRow: some View {
        HStack(spacing: 0) {
            ForEach(0..<Int(IOS_T7_ICON_COUNT), id: \.self) { i in
                Image(systemName: Self.iconSymbolNames[i])
                    .resizable()
                    .scaledToFit()
                    .frame(width: Self.iconSize, height: Self.iconSize)
                    .foregroundStyle(Self.onColor)
                    .opacity(state.icons[i] > 0 ? Double(state.icons[i]) / 3.0 * 0.7 + 0.3 : 0.2)
                    .frame(maxWidth: .infinity)
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

    private static let cols = Int(IOS_T7_LCD_WIDTH), rows = Int(IOS_T7_LCD_HEIGHT)
    /// Each logical LCD pixel is rendered as an oversample x oversample
    /// block, with its rightmost/bottommost texel left as background --
    /// same thin-gap-line trick P1ScreenView uses, so adjacent "on" pixels
    /// read as separate squares instead of one solid blob.
    private static let oversample = 16
    private func makeBitmapImage() -> CGImage? {
        let scale = Self.oversample
        let w = Self.cols * scale, h = Self.rows * scale
        // Background "off" color for the LCD itself (not transparent --
        // unlike P1, there's no decorative artwork behind this yet).
        let bgR: UInt8 = 150, bgG: UInt8 = 168, bgB: UInt8 = 140
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let localY = y % scale
            let py = y / scale
            for x in 0..<w {
                let localX = x % scale
                let px = x / scale
                let gap = localY >= scale - 1 || localX >= scale - 1
                let level = state.pixel(px, py) // 0...3
                let i = (y * w + x) * 4
                if gap || level == 0 {
                    pixels[i] = bgR; pixels[i + 1] = bgG; pixels[i + 2] = bgB; pixels[i + 3] = 255
                } else {
                    // Darker as the level rises, matching a 4-level
                    // grayscale LCD's own on-shades (level 3 = darkest).
                    let shade = UInt8(max(0, 70 - Int(level) * 20))
                    pixels[i] = shade; pixels[i + 1] = shade; pixels[i + 2] = shade; pixels[i + 3] = 255
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
    T7ScreenView(state: .blank)
        .padding()
}
