import SwiftUI
import WatchKit

/// The Tama's screen as big as the watch allows: edge to edge across the
/// full width (the screens are square and the watch is taller than wide,
/// so filling the height would cut off the icons at the left and right
/// edges), with the unlabeled A/B/C row floating over its lower part.
struct WatchScreenView: View {
    @Environment(WatchLink.self) private var link
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black
            screen
            VStack {
                Spacer()
                // Mostly in the black strip under the (square) screen, so
                // they hide as little of its bottom icon row as possible.
                HStack(spacing: 22) {
                    ForEach(0..<3, id: \.self) { i in
                        WatchButton(enabled: link.live && !link.loading,
                                    onPress: { link.press(i) },
                                    onRelease: { link.release(i) })
                    }
                }
                .padding(.bottom, 2)
            }
        }
        .ignoresSafeArea()
        .toolbar(.hidden, for: .navigationBar)
        // scenePhase can already be .active when the screen first shows
        // (then onChange never fires): found 2026-11-26 when opening the app
        // from the watch's own app list never said hello to the phone.
        .onAppear { if scenePhase != .background { link.hello() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { link.hello() } else if phase == .background { link.bye() }
        }
    }

    private var message: String? {
        if link.live { return link.loading ? "Waking your Tama…" : nil }
        if link.unreachable { return "Can't reach your iPhone" }
        if link.phoneHasNoTama { return "Add a Tama in Tomomix on your iPhone" }
        return "Waking your iPhone…"
    }

    private var screen: some View {
        ZStack {
            if let image = link.image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .opacity(link.live && !link.loading ? 1 : 0.35)
            }
            if let message {
                Text(message)
                    .font(.footnote.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.6), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WatchButton: View {
    let enabled: Bool
    let onPress: () -> Void
    let onRelease: () -> Void
    @State private var isPressed = false

    var body: some View {
        Circle()
            .fill(isPressed ? Color.white.opacity(0.6) : Color.black.opacity(0.35))
            .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.4), radius: 2)
            .frame(width: 34, height: 34)
            .scaleEffect(isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.08), value: isPressed)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard enabled, !isPressed else { return }
                        isPressed = true
                        WKInterfaceDevice.current().play(.click)
                        onPress()
                    }
                    .onEnded { _ in
                        guard isPressed else { return }
                        isPressed = false
                        onRelease()
                    }
            )
    }
}
