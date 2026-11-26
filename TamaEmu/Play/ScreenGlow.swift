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
    /// `color` is the Tama's current live frame's ambient color (see
    /// `CGImage.vividGlowColor()`), computed once per frame change by
    /// whoever owns the image rather than here — recomputing it inline in
    /// this view's body ran it again on every unrelated re-render (e.g.
    /// `isPaused` toggling), each of which built its own Core Image
    /// pipeline from scratch.
    func screenGlow(color: Color) -> some View {
        modifier(ScreenGlow(color: color))
    }
}

/// A liquid-glass frame around a screen, the same glass as the A/B/C
/// buttons, with the screen itself looking set into it: a soft inner
/// shadow along its top edge and, for the printed-glass monochrome
/// screens, a faint glare.
///
/// The glass lives in its own tiny view (`GlassBezelBackdrop`) whose only
/// input is a number, so a page that re-renders on every LCD frame never
/// rebuilds the glass — rebuilding Liquid Glass that often made the A/B/C
/// buttons flicker. It never takes touches, for the same reason the
/// buttons' glass doesn't (see ButtonPad).
private struct GlassScreenFrame: ViewModifier {
    let cornerRadius: CGFloat
    let glare: Bool

    private static let bezel: CGFloat = 10

    func body(content: Content) -> some View {
        let screen = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .overlay {
                ZStack {
                    // Sunk in: shadow falls from the bezel's top lip.
                    screen
                        .strokeBorder(
                            LinearGradient(
                                colors: [.black.opacity(0.32), .black.opacity(0.06)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 2.5
                        )
                        .blur(radius: 1.5)
                    if glare {
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.22), location: 0),
                                .init(color: .white.opacity(0.05), location: 0.45),
                                .init(color: .clear, location: 0.46)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                    // A crisp seam where glass meets screen.
                    screen.strokeBorder(.black.opacity(0.18), lineWidth: 0.75)
                }
                .clipShape(screen)
                .allowsHitTesting(false)
            }
            .padding(Self.bezel)
            .background {
                GlassBezelBackdrop(cornerRadius: cornerRadius + Self.bezel)
                    .allowsHitTesting(false)
            }
    }
}

private struct GlassBezelBackdrop: View {
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 27.0, *) {
            shape
                .fill(.clear)
                .glassEffect(.regular, in: shape)
        } else {
            // Same frosted stand-in the buttons use below iOS 27.
            shape
                .fill(.ultraThinMaterial)
                .overlay {
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.6), .white.opacity(0.1)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                }
                .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        }
    }
}

extension View {
    /// See GlassScreenFrame. `cornerRadius` is the screen's own corner.
    func glassScreenFrame(cornerRadius: CGFloat, glare: Bool = false) -> some View {
        modifier(GlassScreenFrame(cornerRadius: cornerRadius, glare: glare))
    }
}
