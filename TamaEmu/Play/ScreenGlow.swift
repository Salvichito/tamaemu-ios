import SwiftUI

/// Wraps the LCD in two soft halos: a wider one behind it that bleeds into
/// the blurred backdrop, and a smaller, more subtle one right at its edge
/// that blends the sharp screen into that backdrop rather than leaving a
/// hard seam. `color` is the screen's own ambient color when its frame is
/// saturated enough to read as one, white otherwise (see
/// `CGImage.vividGlowColor()`).
private struct ScreenGlow: ViewModifier {
    let color: Color

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { geo in
                    let side = min(geo.size.width, geo.size.height)
                    RoundedRectangle(cornerRadius: side * LCDView.cornerRadiusRatio, style: .continuous)
                        .fill(color)
                        .blur(radius: side * 0.12)
                        .opacity(0.65)
                }
            }
            .overlay {
                GeometryReader { geo in
                    let side = min(geo.size.width, geo.size.height)
                    RoundedRectangle(cornerRadius: side * LCDView.cornerRadiusRatio, style: .continuous)
                        .strokeBorder(color.opacity(0.7), lineWidth: side * 0.025)
                        .blur(radius: side * 0.02)
                        .opacity(0.4)
                }
                .allowsHitTesting(false)
            }
    }
}

extension View {
    /// `image` is the Tama's current live frame — `nil` or a low-saturation
    /// frame both fall back to a plain white glow.
    func screenGlow(image: CGImage?) -> some View {
        modifier(ScreenGlow(color: image?.vividGlowColor() ?? .white))
    }
}
