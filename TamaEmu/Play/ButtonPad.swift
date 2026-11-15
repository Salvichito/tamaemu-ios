import SwiftUI

/// Three on-screen buttons mapped onto the firmware's physical A/B/C pins.
/// Dumb on purpose: all restyling happens here free of charge, without
/// touching InputController. Unlabeled, like the physical buttons they
/// stand in for.
struct ButtonPad: View {
    let onPress: (InputController.Button) -> Void
    let onRelease: (InputController.Button) -> Void

    var body: some View {
        // Several glass shapes side by side belong in one container: it
        // gives the three a single shared backdrop sample, so they always
        // agree with each other. The spacing is well under the 28pt gap,
        // so they never melt into one blob. iOS 27+ only — see
        // `ButtonView.shape` for why iOS 26 gets no system glass here.
        if #available(iOS 27.0, *) {
            GlassEffectContainer(spacing: 8) { row }
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 28) {
            ButtonView(button: .a, onPress: onPress, onRelease: onRelease)
            ButtonView(button: .b, onPress: onPress, onRelease: onRelease)
            ButtonView(button: .c, onPress: onPress, onRelease: onRelease)
        }
    }
}

private struct ButtonView: View {
    let button: InputController.Button
    let onPress: (InputController.Button) -> Void
    let onRelease: (InputController.Button) -> Void

    @AppStorage(AppSettings.Keys.hapticsEnabled) private var hapticsEnabled = true
    @Environment(\.isEnabled) private var isEnabled

    // DragGesture's onChanged fires repeatedly for one physical touch (even
    // with no movement); track whether we've already reported this touch as
    // pressed so periph_buttons sees one press edge per touch, not several.
    @State private var isPressed = false

    var body: some View {
        // The touch target is its own plain, explicitly-shaped layer and the
        // glass is only a non-hit-testable backdrop behind it. Attaching the
        // gesture straight to the glass view left the buttons dead on
        // iOS 26 (the glass layer either didn't hit-test or swallowed the
        // touch); this way the look can never affect input on any OS.
        Color.clear
            .frame(width: 56, height: 56)
            .background { shape.allowsHitTesting(false) }
            .contentShape(Circle())
            .scaleEffect(isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.08), value: isPressed)
            .sensoryFeedback(trigger: isPressed) { _, new in
                hapticsEnabled && new ? .impact(weight: .light) : nil
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        onPress(button)
                    }
                    .onEnded { _ in
                        isPressed = false
                        onRelease(button)
                    }
            )
    }

    // Three looks, by OS:
    //
    // iOS 27+: real, untinted system Liquid Glass — matches the toolbar's
    // "..." button and follows light/dark mode. Deliberately not
    // .interactive(): that variant's own live touch tracking, next to the
    // 60Hz-updating LCD, froze the whole screen on real hardware. Disabled
    // (loading/paused) is shown by thinning to the clear variant, never by
    // fading: `.opacity()` on Liquid Glass falls back to a flat grey disc.
    //
    // iOS 26: NOT system glass. There, regular glass picks light or dark
    // by itself from whatever is behind it, and over the constantly
    // changing ambient backdrop these three kept flipping white <-> black
    // on a real iPad. The SDK has no switch to pin that, so iOS 26 gets a
    // hand-drawn frosted disc instead (blur material + bright rim + soft
    // shadow): it only ever follows the app's light/dark appearance.
    //
    // Below iOS 26: the plain translucent disc.
    @ViewBuilder
    private var shape: some View {
        if #available(iOS 27.0, *) {
            Circle()
                .fill(.clear)
                .glassEffect(isEnabled ? .regular : .clear, in: Circle())
        } else if #available(iOS 26.0, *) {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay {
                    Circle().strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.6), .white.opacity(0.1)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                }
                .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
                .opacity(isEnabled ? 1 : 0.45)
        } else {
            Circle()
                .fill(Color(.secondarySystemBackground).opacity(0.25))
                .opacity(isEnabled ? 1 : 0.4)
        }
    }
}
