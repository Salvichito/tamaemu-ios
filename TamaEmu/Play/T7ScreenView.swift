import CT7Emu
import SwiftUI

/// The Tama-Go/Tamagotchi Friends screen, laid out like the real toy's
/// LCD: the 48x31, 4-gray-level dot-matrix full width in the middle, and
/// the 10 status icons (the user's own art) floating on the same
/// glass, five above and five below.
///
/// The core's icon numbers are the same physical spots on both toys (0-4
/// top row, 5-9 bottom row, left to right), but the two models print
/// different icons in some of those spots, so each has its own set.
struct T7ScreenView: View {
    let state: T7ScreenState
    var isFriends = false
    /// Tap-an-icon shortcut (see T7EmulatorEngine.openMenuIcon): called
    /// with the icon's index when a tappable one is tapped. nil draws
    /// them inert.
    var onIconTap: ((Int) -> Void)?
    /// False for screenshots and video, which can't carry transparent
    /// corners -- see renderT7Snapshot.
    var rounded = true

    @Environment(\.displayScale) private var displayScale

    static let cornerRadius: CGFloat = 16
    private static let onColor = Color(red: 0.169, green: 0.165, blue: 0.157)

    /// Tama-Go, per Bandai's quick-start guide and a hands-on review
    /// (matches a photo of the toy). The user's own icon art; the shared
    /// ones are the same P1Icon* assets the first-gen screens use.
    private static let tamaGoIconAssets = [
        "P1IconStatus", // 0 information
        "P1IconFood", // 1 food
        "P1IconBathroom", // 2 toilet
        "T7IconDoor", // 3 door (games, shop, park, PC, date place)
        "T7IconFigure", // 4 Gotchi Figure (only with a figure attached)
        "T7IconTalk", // 5 training (praise / time out)
        "P1IconMedicine", // 6 medicine
        "T7IconConnect", // 7 IR communication
        "T7IconMemory", // 8 album
        "P1IconAttention" // 9 attention
    ]

    /// Tamagotchi Friends, per its official manual; spots 4-8 checked by
    /// opening each menu in the emulator (Exchange, Text, Collection,
    /// Friends/Memory, then Medicine).
    private static let friendsIconAssets = [
        "P1IconStatus", // 0 information
        "P1IconFood", // 1 food
        "P1IconBathroom", // 2 toilet
        "T7IconDoor", // 3 door (game, shop, park, PC)
        "T7IconConnect", // 4 bump / connect
        "T7IconText", // 5 text messages
        "T7IconJewelry", // 6 jewelry box
        "T7IconMemory", // 7 memory
        "P1IconMedicine", // 8 medicine
        "P1IconAttention" // 9 attention
    ]

    /// A steps through icons 0-8 on both toys; attention (9) only lights
    /// by itself. The Tama-Go's Figure icon (4) is skipped by A without a
    /// figure attached, so it stays a plain picture.
    static func isTappable(_ icon: Int, isFriends: Bool) -> Bool {
        icon < T7EmulatorEngine.menuIconCount && (isFriends || icon != 4)
    }

    private var iconAssets: [String] {
        isFriends ? Self.friendsIconAssets : Self.tamaGoIconAssets
    }

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
        let iconSize = band * 0.6
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
                TappableIcon(
                    enabled: onIconTap != nil && Self.isTappable(i, isFriends: isFriends),
                    onTap: { onIconTap?(i) }
                ) {
                    Image(iconAssets[i])
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: iconSize, height: iconSize)
                        .foregroundStyle(Self.onColor)
                        .opacity(state.icons[i] > 0 ? Double(state.icons[i]) / 3.0 * 0.65 + 0.35 : 0.12)
                }
                .position(x: x, y: y)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: rounded ? Self.cornerRadius : 0, style: .continuous))
    }

    private var pixelGrid: some View {
        GeometryReader { geo in
            if let image = makeBitmapImage(size: geo.size) {
                Image(decorative: image, scale: displayScale, orientation: .up)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    private static let cols = Int(IOS_T7_LCD_WIDTH), rows = Int(IOS_T7_LCD_HEIGHT)
    /// The gap line between LCD pixels, as a share of one pixel's width
    /// (the old fixed 16x oversample's one texel). Drawn at real device
    /// size by PixelGridBitmap, same as P1ScreenView.
    private static let gapFraction: CGFloat = 1.0 / 16.0
    /// "Off" pixels are transparent so the LCD glass shows through, as on
    /// P1. The three "on" levels are the same ink at 1/3, 2/3 and full
    /// strength -- evenly spaced like the reference tamago palette.
    private static let levels: [PixelGridBitmap.RGBA] = (1...3).map { level in
        // Premultiplied alpha, so RGB is scaled by alpha too.
        let alpha = Double(level) / 3.0 * 0.92
        let c = UInt8((34.0 * alpha).rounded())
        return PixelGridBitmap.RGBA(r: c, g: c, b: c, a: UInt8((alpha * 255).rounded()))
    }
    private func makeBitmapImage(size: CGSize) -> CGImage? {
        PixelGridBitmap.make(
            cols: Self.cols, rows: Self.rows,
            size: size, scale: displayScale,
            gapFraction: Self.gapFraction
        ) { px, py in
            let level = Int(state.pixel(px, py)) // 0...3
            return level > 0 ? Self.levels[min(level, 3) - 1] : nil
        }
    }
}

#Preview {
    T7ScreenView(state: .blank)
        .padding()
}
