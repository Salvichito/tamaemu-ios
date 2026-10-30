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
                        Canvas { context, size in
                            let spacing = size.height / rows
                            var y: CGFloat = 0
                            while y < size.height {
                                context.fill(
                                    Path(CGRect(x: 0, y: y, width: size.width, height: max(0.5, spacing * 0.35))),
                                    with: .color(.black.opacity(0.22))
                                )
                                y += spacing
                            }
                        }
                        .blendMode(.multiply)

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
}

extension View {
    func lcdScreenEffect(rows: CGFloat = 128, enabled: Bool = true) -> some View {
        modifier(LCDScreenEffect(rows: rows, enabled: enabled))
    }
}
