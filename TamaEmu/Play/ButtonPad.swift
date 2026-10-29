import SwiftUI

/// Three on-screen buttons mapped onto the firmware's physical A/B/C pins.
/// Dumb on purpose: all restyling happens here free of charge, without
/// touching InputController.
struct ButtonPad: View {
    let onPress: (InputController.Button) -> Void
    let onRelease: (InputController.Button) -> Void

    var body: some View {
        HStack(spacing: 28) {
            ButtonView(button: .a, label: "A", onPress: onPress, onRelease: onRelease)
            ButtonView(button: .b, label: "B", onPress: onPress, onRelease: onRelease)
            ButtonView(button: .c, label: "C", onPress: onPress, onRelease: onRelease)
        }
    }
}

private struct ButtonView: View {
    let button: InputController.Button
    let label: String
    let onPress: (InputController.Button) -> Void
    let onRelease: (InputController.Button) -> Void

    @AppStorage(AppSettings.Keys.buttonColorIndex) private var buttonColorIndex = 0
    @AppStorage(AppSettings.Keys.hapticsEnabled) private var hapticsEnabled = true

    // DragGesture's onChanged fires repeatedly for one physical touch (even
    // with no movement); track whether we've already reported this touch as
    // pressed so periph_buttons sees one press edge per touch, not several.
    @State private var isPressed = false

    var body: some View {
        Text(label)
            .font(.headline.bold())
            .frame(width: 56, height: 56)
            .background(Circle().fill(TamaPalette.buttonColor(at: buttonColorIndex)))
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
}
