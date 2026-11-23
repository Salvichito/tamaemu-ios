import CT7Emu
import SwiftUI

/// The Tama-Go/Tamagotchi Friends screen, laid out like the real toy's
/// LCD: the 48x31, 4-gray-level dot-matrix full width in the middle, and
/// the 10 status icons (generic SF Symbols for now) floating on the same
/// glass, five above and five below. Icon order is from T7Emu's own source
/// comment (t7.c's t7_get_icons), not guessed.
struct T7ScreenView: View {
    let state: T7ScreenState

    private static let cornerRadius: CGFloat = 16
    private static let onColor = Color(red: 0.169, green: 0.165, blue: 0.157)

    /// t7.c's t7_get_icons doc comment, in order: 0-4 sit above the
    /// dot-matrix, 5-9 below it, five per row like the real toy.
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

    /// One LCD, like the real Tama-Go: a single gray glass with the
    /// dot-matrix running edge to edge across the middle and the ten
    /// icons printed straight onto it, five above and five below -- no
    /// bezel or panels between them. Same structure as P1ScreenView.
    private func screenContent(side: CGFloat) -> some View {
        let gridHeight = side * CGFloat(IOS_T7_LCD_HEIGHT) / CGFloat(IOS_T7_LCD_WIDTH)
        let band = (side - gridHeight) / 2
        let iconSize = band * 0.5
        return ZStack {
            LinearGradient(
                colors: [Color(red: 0.80, green: 0.80, blue: 0.78), Color(red: 0.69, green: 0.69, blue: 0.67)],
                startPoint: .top,
                endPoint: .bottom
            )

            pixelGrid
                .frame(width: side, height: gridHeight)

            ForEach(0..<Int(IOS_T7_ICON_COUNT), id: \.self) { i in
                let column = CGFloat(i % 5)
                let x = side * (0.1 + column * 0.2)
                let y = i < 5 ? band / 2 : side - band / 2
                Image(systemName: Self.iconSymbolNames[i])
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .foregroundStyle(Self.onColor)
                    .opacity(state.icons[i] > 0 ? Double(state.icons[i]) / 3.0 * 0.65 + 0.35 : 0.12)
                    .position(x: x, y: y)
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

    private static let cols = Int(IOS_T7_LCD_WIDTH), rows = Int(IOS_T7_LCD_HEIGHT)
    /// Each logical LCD pixel is rendered as an oversample x oversample
    /// block, with its rightmost/bottommost texel left transparent -- the
    /// same thin gap line P1ScreenView uses.
    private static let oversample = 16
    /// "Off" pixels are transparent so the LCD glass shows through, as on
    /// P1. The three "on" levels are the same ink at 1/3, 2/3 and full
    /// strength -- evenly spaced like the reference tamago palette.
    private func makeBitmapImage() -> CGImage? {
        let scale = Self.oversample
        let w = Self.cols * scale, h = Self.rows * scale
        let ink = 34.0
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let localY = y % scale
            guard localY < scale - 1 else { continue }
            let py = y / scale
            for x in 0..<w {
                let localX = x % scale
                guard localX < scale - 1 else { continue }
                let level = state.pixel(x / scale, py) // 0...3
                guard level > 0 else { continue }
                // Premultiplied alpha, so RGB is scaled by alpha too.
                let alpha = Double(level) / 3.0 * 0.92
                let c = UInt8((ink * alpha).rounded())
                let i = (y * w + x) * 4
                pixels[i] = c; pixels[i + 1] = c; pixels[i + 2] = c
                pixels[i + 3] = UInt8((alpha * 255).rounded())
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
