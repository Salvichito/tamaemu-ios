import SwiftUI

/// The P1-era screen: real icon artwork and a real decorative background
/// pattern (both traced/sourced from references of the actual 1997
/// hardware -- personal use only, never distributed, see the
/// integration-research memory), with everything -- icons and the pixel
/// matrix alike -- sitting directly on the background, no separate boxed
/// panel for either. Square overall footprint -- same size and
/// proportions as every other Tamagotchi in the gallery (LCDView forces
/// the same `.aspectRatio(1, contentMode: .fit)`).
///
/// The dot matrix itself (see PixelGhost/makeBitmapImage) models three
/// things a real passive-matrix LCD does that a flat on/off render
/// doesn't: a visible grid between cells, every cell staying faintly
/// visible even "off," and an asymmetric fade (fast on, slow off) that
/// produces the real hardware's trailing ghost on fast-changing content.
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

    /// Per-cell fade state for the dot matrix, keyed the same as
    /// P1ScreenState.bits (row-major, 32 wide). Persists across redraws
    /// via @State -- each cell only resets its transition when its own
    /// bit actually flips, not on every frame.
    @State private var ghosts = [PixelGhost](repeating: PixelGhost(), count: 32 * 16)
    /// True only while some cell is still mid-fade -- gates the 30fps
    /// TimelineView below so it ticks for a brief burst after each real
    /// change and then stops dead, rather than redrawing forever. The
    /// first version of this ticked continuously the whole time the page
    /// was open (wrapping the *entire* screen -- background image, all 8
    /// icons, everything -- not just the dot matrix), which nearly
    /// tripled this view's idle CPU cost and was starving the emulator's
    /// own stepping thread badly enough to look and sound frozen -- found
    /// via the user's own device, not caught here first.
    @State private var isAnimating = false
    @State private var animatingUntil = Date.distantPast

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            screenContent(side: side)
                .frame(width: side, height: side)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
        .onChange(of: state.bits) { _, newBits in
            let now = Date()
            for i in newBits.indices {
                ghosts[i].update(isOn: newBits[i], at: now)
            }
            animatingUntil = now.addingTimeInterval(PixelGhost.fallDuration)
            isAnimating = true
        }
    }

    private func screenContent(side: CGFloat) -> some View {
        ZStack {
            Image(Self.backgroundAssetName)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: side, height: side)

            pixelGridContainer
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

    /// Only this -- the small dot matrix, not the background or icons --
    /// ever sits inside a ticking TimelineView, and only while something
    /// is actually fading. Settled (the common case: nothing's changed in
    /// the last fallDuration) renders once, statically, same as before
    /// any of this existed.
    @ViewBuilder
    private var pixelGridContainer: some View {
        if isAnimating {
            TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
                pixelGrid(now: timeline.date)
                    .onChange(of: timeline.date) { _, newDate in
                        if newDate >= animatingUntil {
                            isAnimating = false
                        }
                    }
            }
        } else {
            pixelGrid(now: Date())
        }
    }

    private func pixelGrid(now: Date) -> some View {
        GeometryReader { geo in
            if let image = makeBitmapImage(now: now) {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    /// Supersamples each logical cell into a 4x4 block so there's room to
    /// draw a 1px grid line around it -- at native 32x16 there's nothing
    /// to inset a border into. `.interpolation(.none)` upstream keeps
    /// every block crisp and blocky when this gets scaled up, exactly
    /// like the real dot matrix's own hard cell edges. Kept to 4x, not
    /// more -- this buffer gets rebuilt from scratch on every tick while
    /// isAnimating, so its size is a direct, continuous CPU cost for
    /// however many bursts of fading happen, not a one-time one.
    private static let subpixelsPerCell = 4

    private func makeBitmapImage(now: Date) -> CGImage? {
        let cols = 32, rows = 16
        let sub = Self.subpixelsPerCell
        let w = cols * sub, h = rows * sub
        var pixels = [UInt8](repeating: 0, count: w * h * 4)

        for cy in 0..<rows {
            for cx in 0..<cols {
                let value = ghosts[cy * cols + cx].value(at: now)
                let fillAlpha = UInt8(clamping: Int(value * 255))
                // The grid line is always at least faintly visible, even
                // between two fully-off cells -- never dimmer than the
                // cell's own fill, so a lit pixel's border doesn't look
                // like a lighter ring around it.
                let gridAlpha = UInt8(clamping: max(Int(PixelGhost.gridLineFloor * 255), Int(fillAlpha)))

                for sy in 0..<sub {
                    for sx in 0..<sub {
                        let isBorder = sx == 0 || sy == 0
                        let alpha = isBorder ? gridAlpha : fillAlpha
                        let px = cx * sub + sx
                        let py = cy * sub + sy
                        let i = (py * w + px) * 4
                        pixels[i] = 43
                        pixels[i + 1] = 42
                        pixels[i + 2] = 40
                        pixels[i + 3] = alpha
                    }
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

/// Models one dot-matrix cell's brightness as an eased transition between
/// an always-faintly-visible floor and fully lit, asymmetric in duration
/// -- a real passive-matrix LCD's liquid crystal snaps into alignment
/// quickly when a field is applied (turning on), but only returns to
/// rest through slower elastic relaxation once the field is removed
/// (turning off), which is what produces the classic trailing ghost on
/// fast-changing old LCD screens. Computed purely from (isOn,
/// transitionStart, startValue) rather than stepped by a running timer,
/// so it doesn't need updating except when its own bit actually flips --
/// whatever redraws this (a TimelineView tick) just asks for the value
/// at a given moment.
private struct PixelGhost {
    var isOn = false
    var transitionStart = Date.distantPast
    var startValue = PixelGhost.offFloor

    /// "Off" cells are never fully invisible -- the whole grid reads as a
    /// faint, always-present texture, same idea as an unselected icon's
    /// own opacity.
    static let offFloor: Double = 0.14
    /// The grid line between cells stays at least this visible even where
    /// both neighboring cells are off.
    static let gridLineFloor: Double = 0.24
    static let riseDuration: TimeInterval = 0.05
    static let fallDuration: TimeInterval = 0.22

    mutating func update(isOn newIsOn: Bool, at now: Date) {
        guard newIsOn != isOn else { return }
        startValue = value(at: now)
        isOn = newIsOn
        transitionStart = now
    }

    func value(at now: Date) -> Double {
        let target = isOn ? 1.0 : Self.offFloor
        let duration = isOn ? Self.riseDuration : Self.fallDuration
        guard duration > 0 else { return target }
        let elapsed = now.timeIntervalSince(transitionStart)
        let t = min(1, max(0, elapsed / duration))
        let eased = 1 - pow(1 - t, 2) // ease-out: matches a relaxation curve better than linear
        return startValue + (target - startValue) * eased
    }
}

#Preview {
    P1ScreenView(state: .blank)
        .padding()
}
