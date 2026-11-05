import CoreGraphics
import SwiftUI

/// Scanlines + a glass-reflection sweep, shared verbatim between the
/// in-app LCDView and the widget so the two can't drift apart visually —
/// AppSettings' toggle is meant to turn the same look on/off in both
/// places at once.
struct LCDScreenEffect: ViewModifier {
    /// The core's framebuffer is 128x128 — one scanline per emulated pixel
    /// row ties this to the real dot-matrix grid rather than an arbitrary
    /// stripe count.
    var rows: CGFloat = 128
    var enabled: Bool = true

    func body(content: Content) -> some View {
        content.overlay {
            if enabled {
                GeometryReader { geo in
                    ZStack {
                        // The stripe pattern itself never changes — same
                        // rows, same look, every time — but it used to be
                        // redrawn through Canvas (128 Path fills) on every
                        // single call, which in practice meant every time
                        // the LCD's own image changed underneath it: this
                        // view sits in the same overlay chain as the live
                        // 128×128 framebuffer, so a static decoration was
                        // paying a real, continuous redraw cost for
                        // content that's identical call to call. Rendered
                        // once into a bitmap and reused as a plain Image
                        // instead — a GPU texture blit, not 128 path
                        // fills recomputed from scratch.
                        if let scanlines = Self.scanlineImage(rows: rows) {
                            Image(decorative: scanlines, scale: 1)
                                .resizable()
                                .frame(width: geo.size.width, height: geo.size.height)
                                .blendMode(.multiply)
                        }

                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.22), location: 0),
                                .init(color: .white.opacity(0.04), location: 0.4),
                                .init(color: .white.opacity(0), location: 0.6),
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                        .blendMode(.screen)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
                .allowsHitTesting(false)
            }
        }
    }

    /// Square and resolution-independent — SwiftUI stretches it to fit
    /// via `.resizable()`, so one render at a fixed reference size covers
    /// every screen size and both call sites (LCDView, the widget), and
    /// the stripe spacing stays proportional to `rows` exactly like the
    /// original per-frame Canvas draw did.
    private static let referenceSize = 512
    private static var cache: [CGFloat: CGImage] = [:]

    private static func scanlineImage(rows: CGFloat) -> CGImage? {
        if let cached = cache[rows] { return cached }
        guard let context = CGContext(
            data: nil,
            width: referenceSize,
            height: referenceSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let size = CGFloat(referenceSize)
        let spacing = size / rows
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.22)
        var y: CGFloat = 0
        while y < size {
            context.fill(CGRect(x: 0, y: y, width: size, height: max(0.5, spacing * 0.35)))
            y += spacing
        }
        let image = context.makeImage()
        if let image { cache[rows] = image }
        return image
    }
}

extension View {
    func lcdScreenEffect(rows: CGFloat = 128, enabled: Bool = true) -> some View {
        modifier(LCDScreenEffect(rows: rows, enabled: enabled))
    }
}
